--!strict

-- Owns the per-player BusinessList domain. DataService reconcile only fills template-defined
-- keys, and the template is deliberately minimal, so the authoritative list of businesses lives
-- in the BusinessConfig catalog. On join we SEED every catalog business into the player's profile
-- (locked, zero completions) and then RESOLVE which ones they've earned.
--
-- Unlocking is one-way: once a business is unlocked it stays unlocked forever -- resolve() only
-- ever grants, never revokes. Resolution re-runs on join and whenever the player's Level or
-- Inventory changes, so reaching a business's RequiredLevel or buying its last RequiredItems tool
-- unlocks it live (the client board refreshes off the BusinessList changed signal).
--
-- Requirements are RequiredLevel + RequiredItems (owned tools); both must pass. New gate kinds
-- slot into meetsRequirements without touching the seed/resolve flow.
--
-- Because unlocking is one-way, an already-unlocked business stays unlocked even if a later
-- config change adds a requirement its owner doesn't meet. That's why JobService.accept re-checks
-- meetsRequirements at accept time instead of trusting the Unlocked flag alone.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local DataTemplate = require(ReplicatedStorage.SharedModules.DataTemplate)
local BusinessConfig = require(ReplicatedStorage.SharedModules.BusinessConfig)

local BusinessService = {}

-- A freshly seeded per-player record: the catalog's static fields, but always LOCKED with zero
-- completions -- unlock is earned per player, never inherited from the catalog's default flag.
-- DecalWeight / RequiredLevel stay catalog-only (read from BusinessConfig), so they aren't copied.
local function freshRecord(def: DataTemplate.Business): DataTemplate.Business
	return {
		BaseReward = def.BaseReward,
		Unlocked = false,
		Name = def.Name,
		UniqueID = def.UniqueID,
		Completions = 0,
		XpReward = def.XpReward,
	}
end

-- Whether the player currently satisfies a business's unlock requirements: they're at or above
-- its RequiredLevel (default 1 -- no gate) AND they own every tool in its RequiredItems (default
-- none). This is the one place to extend when new requirement kinds are added, and the single
-- server-side definition of "may this player play this business" -- JobService.accept re-checks it
-- rather than keeping its own copy.
function BusinessService.meetsRequirements(player: Player, businessId: string): boolean
	local def = BusinessConfig[businessId]
	if not def then
		return false
	end
	local level = DataService:get(player, { "Level", "CurrentLevel" })
	if type(level) ~= "number" or level < (def.RequiredLevel or 1) then
		return false
	end
	for _, toolId in def.RequiredItems or {} do
		if DataService:get(player, { "Inventory", toolId, "Unlocked" }) ~= true then
			return false
		end
	end
	return true
end

-- Whether this player may PLAY a business's job right now: they've unlocked it AND they still meet
-- its live requirements. Unlocking is one-way, so the Unlocked flag alone can outlive the
-- requirements that earned it (a config change adding a gate to a business someone already owns) --
-- hence both halves. The single definition of the entitlement, shared by JobService.accept (which
-- checks every member of a party before starting the job) and PartyService (which checks it before
-- letting a player create or join a party for that business).
function BusinessService.canPlay(player: Player, businessId: string): boolean
	if DataService:get(player, { "BusinessList", businessId, "Unlocked" }) ~= true then
		return false
	end
	return BusinessService.meetsRequirements(player, businessId)
end

-- Seed any missing businesses into the player's list, then unlock any that are still locked but
-- now qualify. Only writes when something actually changes, so it's cheap to call repeatedly
-- (join + every level change) and never re-locks an already-unlocked business.
local function resolve(player: Player)
	local list = DataService:get(player, { "BusinessList" })
	local records = if type(list) == "table" then list else {}

	for businessId, def in BusinessConfig do
		local record = records[businessId]
		if type(record) ~= "table" then
			-- Not in the profile yet (new business, or a fresh player): seed it locked.
			DataService:set(player, { "BusinessList", businessId }, freshRecord(def))
			record = nil
		end

		local alreadyUnlocked = type(record) == "table" and record.Unlocked == true
		if not alreadyUnlocked and BusinessService.meetsRequirements(player, businessId) then
			DataService:set(player, { "BusinessList", businessId, "Unlocked" }, true)
		end
	end
end

local function setupPlayer(player: Player)
	-- BusinessList can't be seeded/read until the player's profile has loaded.
	DataService:waitForData(player)
	resolve(player)

	-- Levelling up can newly satisfy a business's RequiredLevel; re-resolve to grant it live.
	DataService:getChangedSignal(player, { "Level" }):Connect(function()
		resolve(player)
	end)

	-- Buying a tool can newly satisfy a business's RequiredItems, so re-resolve on that too --
	-- otherwise the unlock would wait for the player's next level-up or rejoin.
	DataService:getChangedSignal(player, { "Inventory" }):Connect(function()
		resolve(player)
	end)
end

function BusinessService.init()
	for _, player in Players:GetPlayers() do
		task.spawn(setupPlayer, player)
	end
	Players.PlayerAdded:Connect(function(player)
		setupPlayer(player)
	end)
end

return BusinessService
