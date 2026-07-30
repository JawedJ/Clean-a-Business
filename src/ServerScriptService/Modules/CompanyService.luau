--!strict

-- Server authority for the player's persisted business description (the DescriptionEditableTxt box
-- in the Company UI). Mirrors SettingsService: the client edits the box locally for instant
-- feedback, but a client's own DataService writes neither replicate nor save -- so to REMEMBER the
-- text the client fires UpdateBusinessDescription on focus-lost and this re-validates and writes it
-- through DataService, which persists it and replicates the confirmed value back.
--
-- The raw value is coerced to a string, trimmed, and capped at MAX_LENGTH so a client can't stuff a
-- non-string or an unbounded blob into its profile.
--
-- It also feeds the two Company UI stat cards the client can't work out for itself (the other two
-- -- completion and jobs finished -- it derives from data it already has):
--   * GemsPerSecond   -- mirrored out of PlotButtonService (Hoarding-scaled, exactly the rate the
--     offline snapshot uses) so the EarningsCard can show it live. Written only when it CHANGES.
--   * PlaytimeSeconds -- lifetime "Business Age", accrued from each session's wall time: flushed
--     into the profile every FLUSH_INTERVAL and once more when the player leaves, so the stored
--     total is always current (and replicates to the client between flushes).
--
-- Both are ALSO refreshed on demand when the client opens its Company UI (RefreshCompanyStats), so
-- the cards -- including the 24-hour claim quote derived from the rate -- never show a figure the
-- FLUSH_INTERVAL tick hasn't caught up to yet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local PlotButtonService = require(script.Parent.PlotButtonService)
local SkillsService = require(script.Parent.SkillsService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateBusinessDescription = Remotes:WaitForChild("UpdateBusinessDescription") :: RemoteEvent
-- Fired by the client as the Company UI opens, asking for an immediate stats mirror rather than
-- waiting out the rest of the FLUSH_INTERVAL tick (see onRefreshRequest).
local RefreshCompanyStats = Remotes:WaitForChild("RefreshCompanyStats") :: RemoteEvent

-- Longest description we persist. The box is small; this just bounds what a client can write.
local MAX_LENGTH = 200

-- How often the stats loop runs: how fresh the mirrored gems/sec is, and how often accrued playtime
-- is folded into the profile. The Time card only shows hours, so this is plenty.
local FLUSH_INTERVAL = 15

local CompanyService = {}

-- os.clock() at the last playtime flush, per player. Set on join and advanced on every flush, so
-- each flush adds only the stretch since the previous one and nothing is ever double-counted.
local lastFlush: { [Player]: number } = {}

-- Trim leading/trailing whitespace so an all-spaces submission saves as empty (-> placeholder).
local function trim(text: string): string
	return (text:gsub("^%s*(.-)%s*$", "%1"))
end

-- Run the raw text through Roblox text filtering before we persist it. We use the broadcast getter
-- (rather than a per-viewer chat filter) because the description is stored once and may be shown to
-- anyone, so it must be safe for every audience. Both calls can throw (network/service hiccups); on
-- any failure we return nil and skip the write rather than risk persisting unfiltered text.
local function filterDescription(player: Player, text: string): string?
	if text == "" then
		return "" -- nothing to filter; clears back to the placeholder
	end
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(text, player.UserId)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		warn(`CompanyService: failed to filter description for {player.Name}: {result}`)
		return nil
	end
	return result
end

local function onUpdate(player: Player, value: unknown)
	if type(value) ~= "string" then
		return
	end
	local clean = trim(value)
	if #clean > MAX_LENGTH then
		clean = clean:sub(1, MAX_LENGTH)
	end
	local filtered = filterDescription(player, clean)
	if filtered == nil then
		return -- filtering failed; leave the previously saved value untouched
	end
	DataService:set(player, { "BusinessDescription" }, filtered)
end

-- Fold the time since this player's last flush into their lifetime PlaytimeSeconds and re-arm the
-- clock. Safe to call repeatedly (a zero-length stretch is skipped) and on a player who never got a
-- start stamp (they're stamped now and counted from here).
local function flushPlaytime(player: Player)
	local now = os.clock()
	local since = lastFlush[player]
	lastFlush[player] = now
	if not since then
		return
	end
	local elapsed = now - since
	if elapsed <= 0 then
		return
	end
	DataService:update(player, { "PlaytimeSeconds" }, function(current: number?)
		return (current or 0) + elapsed
	end)
end

-- Mirror the player's live plot rate into their profile so the client can display it. Hoarding is
-- applied here for the same reason AfkEarningsService applies it at leave: it's what they actually
-- earn. Written only on a change, so an idle plot doesn't replicate an identical value every tick.
local function refreshGemsPerSecond(player: Player)
	local rate = PlotButtonService.getGemsPerSecond(player) * SkillsService.getMultiplier(player, "Hoarding")
	if DataService:get(player, { "GemsPerSecond" }) ~= rate then
		DataService:set(player, { "GemsPerSecond" }, rate)
	end
end

-- Shortest gap between two honoured refresh requests from the same player. The work is cheap and
-- idempotent, but the remote is client-fired, so this bounds how hard it can be spammed.
local REFRESH_COOLDOWN = 0.5

-- os.clock() at each player's last honoured refresh request, for REFRESH_COOLDOWN.
local lastRefresh: { [Player]: number } = {}

-- The client opened its Company UI and wants the stat cards current NOW: mirror the plot rate (and
-- fold in playtime, which the Time card reads) immediately instead of showing whatever the last
-- FLUSH_INTERVAL tick left behind. Both writes are the same ones the loop makes and both no-op when
-- nothing moved, so an extra call costs nothing. Only ever refreshes the CALLER's own stats.
local function onRefreshRequest(player: Player)
	if not lastFlush[player] then
		return -- profile still loading; the loop will pick them up
	end
	local now = os.clock()
	local previous = lastRefresh[player]
	if previous and now - previous < REFRESH_COOLDOWN then
		return
	end
	lastRefresh[player] = now

	flushPlaytime(player)
	refreshGemsPerSecond(player)
end

-- Start the clock for a joining player once their profile is loaded (the flush writes through
-- DataService, which needs data). Nothing is added for the load itself -- the first flush counts
-- from here.
local function onJoin(player: Player)
	DataService:waitForData(player)
	if player.Parent then
		lastFlush[player] = os.clock()
	end
end

-- Final playtime flush as the player leaves, mutating the profile data directly just before it's
-- saved (a DataService removal callback, like the AfkEarnings leave snapshot) so the last partial
-- interval isn't lost.
local function onLeave(player: Player, data: any)
	local since = lastFlush[player]
	lastFlush[player] = nil
	lastRefresh[player] = nil
	if since then
		local elapsed = os.clock() - since
		if elapsed > 0 then
			data.PlaytimeSeconds = (data.PlaytimeSeconds or 0) + elapsed
		end
	end
end

-- Keep both live stats current for everyone online. One shared loop (rather than a task per
-- player) -- both writes are cheap and skipped when nothing changed.
local function startStatsLoop()
	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			for _, player in Players:GetPlayers() do
				if lastFlush[player] then
					flushPlaytime(player)
					refreshGemsPerSecond(player)
				end
			end
		end
	end)
end

function CompanyService.init()
	UpdateBusinessDescription.OnServerEvent:Connect(onUpdate)
	RefreshCompanyStats.OnServerEvent:Connect(onRefreshRequest)

	DataService:addPlayerRemovingCallback(onLeave)

	local function hookJoin(player: Player)
		task.spawn(onJoin, player)
	end
	Players.PlayerAdded:Connect(hookJoin)
	for _, player in Players:GetPlayers() do
		hookJoin(player)
	end

	startStatsLoop()
end

return CompanyService
