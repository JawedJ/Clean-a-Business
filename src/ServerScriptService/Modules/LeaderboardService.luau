--!strict

-- Global (cross-server) top-100 leaderboards for the three boards in workspace.Leaderboard.
--
-- Each stat gets its own OrderedDataStore, which is what makes the ranking GLOBAL rather than
-- per-server: every server publishes its own players' figures into the store, and every server
-- reads the same sorted top-100 back out. Nothing about a board depends on who happens to be in
-- this server.
--
-- The three tracked stats and where their value comes from (see STATS):
--   * Gems     -- the player's live Gems balance.
--   * Playtime -- lifetime PlaytimeSeconds (CompanyService accrues it; we publish whole seconds).
--   * Jobs     -- lifetime jobs finished, i.e. every BusinessList record's Completions summed --
--     the same figure the Company UI's JobsCard shows.
--
-- Two loops, deliberately on different clocks:
--   * PUBLISH_INTERVAL -- write each online player's current figures into the ordered stores. Also
--     done once on join (so a brand-new player appears without waiting a full interval) and once
--     more on leave, via a DataService removal callback, so the stored value is never a stale
--     mid-session snapshot.
--   * REFRESH_INTERVAL -- read the top TOP_COUNT back out of each store, resolve the user ids to
--     names, and broadcast the result to every client. Slower than publishing because the read is
--     the expensive half and a leaderboard being a minute stale is invisible.
--
-- The client (LeaderboardController) owns all the UI; this module only ever ships it data. A
-- joining player is sent the cached payload immediately rather than waiting out the refresh tick.
--
-- Every DataStore call is pcall'd: in Studio without API services enabled (and during live
-- outages) they simply throw, and a dead leaderboard must never take a service down with it.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local LeaderboardUpdate = Remotes:WaitForChild("LeaderboardUpdate") :: RemoteEvent

-- How many ranks a board holds. Also the page size we ask GetSortedAsync for, so the top 100
-- arrives in a single page.
local TOP_COUNT = 100

-- Seconds between full top-100 re-reads + broadcasts.
local REFRESH_INTERVAL = 120

-- Seconds between pushes of the online players' figures into the ordered stores.
local PUBLISH_INTERVAL = 60

-- Bumping this suffix starts every board over from empty -- the old keys are simply no longer
-- read. Useful if a stat's meaning ever changes (e.g. Playtime switching units).
local STORE_VERSION = "_v1"

export type Entry = {
	userId: number,
	name: string,
	value: number,
}

export type Payload = { [string]: { Entry } }

local LeaderboardService = {}

-- One descriptor per board. `id` is what the client keys its boards off (see the client's
-- STAT_FOR_MODEL mapping); `read` pulls the player's current figure out of their loaded profile.
-- Values are floored to whole numbers on publish because OrderedDataStore only stores integers.
local STATS: { { id: string, store: string, read: (Player) -> number? } } = {
	{
		id = "Gems",
		store = "Leaderboard_Gems" .. STORE_VERSION,
		read = function(player: Player): number?
			local gems = DataService:get(player, { "Gems" })
			return if type(gems) == "number" then gems else nil
		end,
	},
	{
		id = "Playtime",
		store = "Leaderboard_Playtime" .. STORE_VERSION,
		read = function(player: Player): number?
			local seconds = DataService:get(player, { "PlaytimeSeconds" })
			return if type(seconds) == "number" then seconds else nil
		end,
	},
	{
		id = "Jobs",
		store = "Leaderboard_Jobs" .. STORE_VERSION,
		read = function(player: Player): number?
			local list = DataService:get(player, { "BusinessList" })
			if type(list) ~= "table" then
				return nil
			end
			local total = 0
			for _, record in list :: { [string]: any } do
				if type(record) == "table" and type(record.Completions) == "number" then
					total += record.Completions
				end
			end
			return total
		end,
	},
}

-- Ordered store handles, keyed by stat id. Built once in init.
local stores: { [string]: OrderedDataStore } = {}

-- Last broadcast payload, kept so a joining player can be handed the current boards immediately.
-- Empty until the first successful refresh (clients treat a missing stat as "no entries yet").
local cache: Payload = {}

-- userId -> display name, so a player who sits in the top 100 across refreshes is only looked up
-- once. Never invalidated: a name change mid-session showing the old name until the server
-- restarts is not worth an extra web call per refresh.
local nameCache: { [number]: string } = {}

-- True once the player's profile is loaded and they're still here, i.e. their figures are safe to
-- read. Cleared on leave so the publish loop skips players on their way out (their final push is
-- handled by the removal callback, which reads the about-to-be-saved data directly).
local ready: { [Player]: boolean } = {}

-- Push one player's current figure for every stat. Each write is independent: one store erroring
-- (throttle, outage) must not cost the other two their update.
local function publish(player: Player)
	for _, stat in STATS do
		local store = stores[stat.id]
		local value = stat.read(player)
		if not store or value == nil then
			continue
		end
		-- Negative figures can't happen with these three stats, but a negative would sort ABOVE
		-- nothing and simply waste a rank, so clamp rather than trust.
		local whole = math.max(0, math.floor(value))
		local ok, err = pcall(function()
			store:SetAsync(tostring(player.UserId), whole)
		end)
		if not ok then
			warn(`LeaderboardService: failed to publish {stat.id} for {player.Name}: {err}`)
		end
	end
end

-- Resolve user ids to names, filling nameCache. UserService batches the whole page into one call
-- (far cheaper than a GetNameFromUserIdAsync per rank) and gives us the DisplayName, which is what
-- players expect to see. Any id the batch doesn't cover -- a failed call, a deleted account --
-- falls back to "Player<id>" so a board never renders a blank row.
local function resolveNames(userIds: { number })
	local missing: { number } = {}
	for _, userId in userIds do
		if not nameCache[userId] then
			table.insert(missing, userId)
		end
	end
	if #missing == 0 then
		return
	end

	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if ok and type(infos) == "table" then
		for _, info in infos :: { any } do
			local name = info.DisplayName
			if type(name) ~= "string" or name == "" then
				name = info.Username
			end
			if type(name) == "string" and name ~= "" then
				nameCache[info.Id] = name
			end
		end
	else
		warn(`LeaderboardService: failed to resolve names: {infos}`)
	end

	for _, userId in missing do
		if not nameCache[userId] then
			nameCache[userId] = `Player{userId}`
		end
	end
end

-- Read one board's top TOP_COUNT, newest-first by value. Returns nil (rather than an empty list)
-- when the read FAILS, so the caller can keep showing the last good page instead of blanking the
-- board on a transient DataStore error.
local function readTop(stat: { id: string, store: string, read: (Player) -> number? }): { Entry }?
	local store = stores[stat.id]
	if not store then
		return nil
	end

	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, TOP_COUNT)
	end)
	if not ok then
		warn(`LeaderboardService: failed to read {stat.id}: {pages}`)
		return nil
	end

	local ok2, page = pcall(function()
		return (pages :: DataStorePages):GetCurrentPage()
	end)
	if not ok2 then
		warn(`LeaderboardService: failed to page {stat.id}: {page}`)
		return nil
	end

	local userIds: { number } = {}
	for _, row in page :: { { key: string, value: number } } do
		local userId = tonumber(row.key)
		if userId then
			table.insert(userIds, userId)
		end
	end
	resolveNames(userIds)

	local entries: { Entry } = {}
	for _, row in page :: { { key: string, value: number } } do
		local userId = tonumber(row.key)
		if userId then
			table.insert(entries, {
				userId = userId,
				name = nameCache[userId] or `Player{userId}`,
				value = row.value,
			})
		end
	end
	return entries
end

-- Re-read every board and broadcast the result. Stats that failed to read keep their previous
-- entries in the cache, so one bad store doesn't wipe the other two off the wall either.
local function refresh()
	local changed = false
	for _, stat in STATS do
		local entries = readTop(stat)
		if entries then
			cache[stat.id] = entries
			changed = true
		end
	end
	if changed then
		LeaderboardUpdate:FireAllClients(cache)
	end
end

local function onJoin(player: Player)
	DataService:waitForData(player)
	if not player.Parent then
		return
	end
	ready[player] = true
	-- Hand them whatever we already have so the boards aren't blank while they walk over; the
	-- next refresh reaches them through the broadcast like everyone else.
	if next(cache) then
		LeaderboardUpdate:FireClient(player, cache)
	end
	publish(player)
end

-- Final push as the player leaves. This runs as a DataService removal callback, so `data` is the
-- profile about to be saved -- read straight from it rather than through DataService, whose
-- per-player accessors are already tearing down by now.
local function onLeave(player: Player, data: any)
	ready[player] = nil
	if type(data) ~= "table" then
		return
	end

	local jobs = 0
	if type(data.BusinessList) == "table" then
		for _, record in data.BusinessList :: { [string]: any } do
			if type(record) == "table" and type(record.Completions) == "number" then
				jobs += record.Completions
			end
		end
	end

	local finals: { [string]: number } = {
		Gems = if type(data.Gems) == "number" then data.Gems else 0,
		Playtime = if type(data.PlaytimeSeconds) == "number" then data.PlaytimeSeconds else 0,
		Jobs = jobs,
	}

	for _, stat in STATS do
		local store = stores[stat.id]
		local value = finals[stat.id]
		if not store or value == nil then
			continue
		end
		local whole = math.max(0, math.floor(value))
		local ok, err = pcall(function()
			store:SetAsync(tostring(player.UserId), whole)
		end)
		if not ok then
			warn(`LeaderboardService: failed final publish of {stat.id} for {player.Name}: {err}`)
		end
	end
end

local function startLoops()
	task.spawn(function()
		while true do
			refresh()
			task.wait(REFRESH_INTERVAL)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(PUBLISH_INTERVAL)
			for _, player in Players:GetPlayers() do
				if ready[player] then
					publish(player)
				end
			end
		end
	end)
end

function LeaderboardService.init()
	for _, stat in STATS do
		local ok, store = pcall(function()
			return DataStoreService:GetOrderedDataStore(stat.store)
		end)
		if ok then
			stores[stat.id] = store
		else
			warn(`LeaderboardService: no store for {stat.id}: {store}`)
		end
	end

	DataService:addPlayerRemovingCallback(onLeave)

	local function hookJoin(player: Player)
		task.spawn(onJoin, player)
	end
	Players.PlayerAdded:Connect(hookJoin)
	for _, player in Players:GetPlayers() do
		hookJoin(player)
	end

	startLoops()
end

return LeaderboardService
