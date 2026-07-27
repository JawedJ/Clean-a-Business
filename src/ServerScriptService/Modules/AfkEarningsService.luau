--!strict

-- Offline (AFK) gem earnings. While a player is away their plot obviously stops paying out, so on
-- rejoin we grant a fraction of what it *would* have made: (gems/sec / OFFLINE_RATE_DIVISOR) times
-- the seconds they were gone, capped at one day of full online rate. The rate and a leave timestamp
-- are snapshotted into their save when they leave (see DataTemplate.LastGemsPerSecond /
-- LastOnlineTime) and read back here on their next join.
--
-- The reward isn't granted automatically: on join we compute it, hold it server-side as this
-- session's pending amount, and tell the client to show the AfkEarnings UI. The player then either
--   * ClaimAfkEarnings -- grants the pending amount, or
--   * buys the DOUBLE_PRODUCT_ID dev product -- grants twice the pending amount (delivered through
--     PurchaseService's receipt handler).
-- Either way the pending amount is cleared so it can't be collected twice, and the server is the
-- sole authority on how much is owed (the client only triggers the claim, never names the amount).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local PlotButtonService = require(script.Parent.PlotButtonService)
local SkillsService = require(script.Parent.SkillsService)
local PurchaseService = require(script.Parent.PurchaseService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShowAfkEarnings = Remotes:WaitForChild("ShowAfkEarnings") :: RemoteEvent
local ClaimAfkEarnings = Remotes:WaitForChild("ClaimAfkEarnings") :: RemoteEvent

-- Offline pay is 1/15th of the online rate.
local OFFLINE_RATE_DIVISOR = 15
-- Never pay more than one day of the FULL online rate, however long they were away.
local MAX_OFFLINE_SECONDS = 86400
-- Below this, no reward is offered -- a quick reconnect shouldn't pop the UI for a handful of gems.
local MIN_OFFLINE_SECONDS = 0
-- Robux dev product the Double button buys: grants twice the pending offline amount.
local DOUBLE_PRODUCT_ID = 3611857315

local AfkEarningsService = {}

-- This session's uncollected offline gems per player (the base amount; the Double product pays 2x).
-- Cleared the instant it's claimed so neither button can collect it twice.
local pending: { [Player]: number } = {}

-- Add `gems` straight to the player's balance. Offline gems are granted at their computed value --
-- the snapshotted rate already includes the Hoarding skill (see onLeave) -- so this doesn't route
-- through ProgressionService.awardGems, which would apply Hoarding a second time.
local function grantGems(player: Player, gems: number)
	if gems <= 0 then
		return
	end
	DataService:update(player, { "Gems" }, function(current: number?)
		return (current or 0) + gems
	end)
end

-- Snapshot the player's leave time and current (Hoarding-scaled) gems/sec into their save, so their
-- next join can compute the offline reward. Runs as a DataService removal callback, mutating the
-- profile data directly just before it's saved.
local function onLeave(player: Player, data: any)
	local rate = PlotButtonService.getGemsPerSecond(player) * SkillsService.getMultiplier(player, "Hoarding")
	data.LastGemsPerSecond = rate
	data.LastOnlineTime = os.time()
	print(string.format("[AfkEarnings] onLeave %s: saving rate=%s (raw=%s) time=%d", player.Name, tostring(rate), tostring(PlotButtonService.getGemsPerSecond(player)), os.time()))
	pending[player] = nil
end

-- On join, compute this session's offline reward from the saved snapshot and, if it's worth
-- showing, hold it as pending and tell the client to open the AfkEarnings UI (passing the gem
-- amount and the actual seconds away, which the UI displays -- uncapped, unlike the reward).
local function onJoin(player: Player)
	DataService:waitForData(player)

	local lastOnline = DataService:get(player, { "LastOnlineTime" })
	local rate = DataService:get(player, { "LastGemsPerSecond" })
	print(string.format("[AfkEarnings] onJoin %s: lastOnline=%s rate=%s", player.Name, tostring(lastOnline), tostring(rate)))
	if type(lastOnline) ~= "number" or lastOnline <= 0 or type(rate) ~= "number" or rate <= 0 then
		print("[AfkEarnings] bail: never left before / rate is 0")
		return -- never left before, or nothing was being earned -- no offline reward
	end

	local secondsAway = os.time() - lastOnline
	if secondsAway < MIN_OFFLINE_SECONDS then
		print(string.format("[AfkEarnings] bail: secondsAway=%d below MIN=%d", secondsAway, MIN_OFFLINE_SECONDS))
		return
	end

	local payableSeconds = math.min(secondsAway, MAX_OFFLINE_SECONDS)
	local gems = math.floor(rate / OFFLINE_RATE_DIVISOR * payableSeconds)
	print(string.format("[AfkEarnings] secondsAway=%d gems=%d", secondsAway, gems))
	if gems <= 0 then
		print("[AfkEarnings] bail: gems <= 0")
		return
	end

	pending[player] = gems
	print(string.format("[AfkEarnings] firing ShowAfkEarnings to %s (%d gems)", player.Name, gems))
	ShowAfkEarnings:FireClient(player, gems, secondsAway)
end

-- Claim the pending offline reward (the single, non-doubled amount). Clearing pending first makes a
-- repeated fire a no-op, so a spammed remote can't grant twice.
local function onClaim(player: Player)
	local gems = pending[player]
	if not gems then
		return
	end
	pending[player] = nil
	grantGems(player, gems)
end

function AfkEarningsService.init()
	DataService:addPlayerRemovingCallback(onLeave)
	ClaimAfkEarnings.OnServerEvent:Connect(onClaim)

	-- The Double button buys this product; deliver 2x the pending reward through the shared receipt
	-- dispatcher. Clearing pending as we grant keeps it from also being claimed via ClaimAfkEarnings.
	PurchaseService.register(DOUBLE_PRODUCT_ID, function(player)
		local gems = pending[player]
		pending[player] = nil
		if gems then
			grantGems(player, gems * 2)
		end
		return true
	end)

	local function hookJoin(player: Player)
		task.spawn(onJoin, player)
	end
	Players.PlayerAdded:Connect(hookJoin)
	for _, player in Players:GetPlayers() do
		hookJoin(player)
	end
end

return AfkEarningsService
