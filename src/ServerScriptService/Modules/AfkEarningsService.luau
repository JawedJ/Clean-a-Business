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
--
-- Unclaimed earnings are NEVER lost. Each join FOLDS the freshly-earned offline amount into a
-- persisted bank (DataTemplate.UnclaimedAfkGems) rather than replacing it, and advances the offline
-- clock (LastOnlineTime) so the same stretch is never counted twice. So a player who leaves without
-- pressing Claim keeps what they'd accrued and it simply keeps growing offline; the bank is zeroed
-- only when the reward is actually claimed (Claim or Double).

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
-- Never pay more than one day of the FULL online rate for a single offline stretch, however long
-- they were away. (The unclaimed BANK can exceed this across multiple unclaimed stretches -- the
-- cap guards one continuous absence, not gems already earned.)
local MAX_OFFLINE_SECONDS = 86400
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
-- profile data directly just before it's saved. The unclaimed bank (UnclaimedAfkGems) is left
-- alone -- it was already banked on join and is only zeroed by a claim -- so leaving without
-- claiming preserves it.
local function onLeave(player: Player, data: any)
	local rate = PlotButtonService.getGemsPerSecond(player) * SkillsService.getMultiplier(player, "Hoarding")
	data.LastGemsPerSecond = rate
	data.LastOnlineTime = os.time()
	print(string.format("[AfkEarnings] onLeave %s: saving rate=%s (raw=%s) time=%d", player.Name, tostring(rate), tostring(PlotButtonService.getGemsPerSecond(player)), os.time()))
	pending[player] = nil
end

-- On join, fold this offline stretch's earnings into the unclaimed bank, advance the offline clock,
-- and -- if the running total is worth anything -- hold it as pending and tell the client to open
-- the AfkEarnings UI (passing the total gems and this stretch's seconds away, which the UI displays).
local function onJoin(player: Player)
	DataService:waitForData(player)

	local lastOnline = DataService:get(player, { "LastOnlineTime" })
	local rate = DataService:get(player, { "LastGemsPerSecond" })
	local bankedRaw = DataService:get(player, { "UnclaimedAfkGems" })
	local banked = if type(bankedRaw) == "number" then bankedRaw else 0

	-- Earnings for THIS offline stretch (capped), on top of whatever was banked from before.
	local secondsAway = 0
	local newOffline = 0
	if type(lastOnline) == "number" and lastOnline > 0 then
		secondsAway = math.max(0, os.time() - lastOnline)
		if type(rate) == "number" and rate > 0 then
			local payableSeconds = math.min(secondsAway, MAX_OFFLINE_SECONDS)
			newOffline = math.floor(rate / OFFLINE_RATE_DIVISOR * payableSeconds)
		end
	end

	local total = banked + newOffline
	print(string.format("[AfkEarnings] onJoin %s: lastOnline=%s rate=%s banked=%d new=%d total=%d", player.Name, tostring(lastOnline), tostring(rate), banked, newOffline, total))

	-- Account for offline earnings up to now: advance the clock (so this stretch is never recounted)
	-- and persist the running bank (so leaving without claiming keeps it). dontReplicate -- pure
	-- server bookkeeping the client never reads.
	DataService:set(player, { "LastOnlineTime" }, os.time(), true)
	DataService:set(player, { "UnclaimedAfkGems" }, total, true)

	if total <= 0 then
		return
	end

	pending[player] = total
	print(string.format("[AfkEarnings] firing ShowAfkEarnings to %s (%d gems)", player.Name, total))
	ShowAfkEarnings:FireClient(player, total, secondsAway)
end

-- Claim the pending offline reward (the single, non-doubled amount). Clearing pending first makes a
-- repeated fire a no-op, so a spammed remote can't grant twice; zeroing the bank means it's no
-- longer owed on the next join.
local function onClaim(player: Player)
	local gems = pending[player]
	if not gems then
		return
	end
	pending[player] = nil
	DataService:set(player, { "UnclaimedAfkGems" }, 0, true)
	grantGems(player, gems)
end

function AfkEarningsService.init()
	DataService:addPlayerRemovingCallback(onLeave)
	ClaimAfkEarnings.OnServerEvent:Connect(onClaim)

	-- The Double button buys this product; deliver 2x the pending reward through the shared receipt
	-- dispatcher. Clearing pending as we grant keeps it from also being claimed via ClaimAfkEarnings.
	PurchaseService.register(DOUBLE_PRODUCT_ID, function(player)
		local gems = pending[player]
		if gems then
			pending[player] = nil
			DataService:set(player, { "UnclaimedAfkGems" }, 0, true)
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
