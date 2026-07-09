--!strict

-- Owns the per-player BusinessList domain. DataService reconcile only fills template-defined
-- keys, and the template is deliberately minimal, so the authoritative list of businesses lives
-- in the BusinessConfig catalog. On join we SEED every catalog business into the player's profile
-- (locked, zero completions) and then RESOLVE which ones they've earned.
--
-- Unlocking is one-way: once a business is unlocked it stays unlocked forever -- resolve() only
-- ever grants, never revokes. Resolution re-runs on join and whenever the player's level changes,
-- so reaching a business's RequiredLevel unlocks it live (the client board refreshes off the
-- BusinessList changed signal). Requirements today are just RequiredLevel; future gates (e.g. an
-- owned tool) slot into meetsRequirements without touching the seed/resolve flow.

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

-- Whether the player currently satisfies a business's unlock requirements. Today that's just
-- being at or above its RequiredLevel (default 1 -- no gate). This is the one place to extend
-- when new requirement kinds (owned tools, etc.) are added.
local function meetsRequirements(player: Player, businessId: string): boolean
	local def = BusinessConfig[businessId]
	if not def then
		return false
	end
	local required = def.RequiredLevel or 1
	local level = DataService:get(player, { "Level", "CurrentLevel" })
	return type(level) == "number" and level >= required
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
		if not alreadyUnlocked and meetsRequirements(player, businessId) then
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
