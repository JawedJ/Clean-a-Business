--!strict

-- The player's PERMANENT Robux store perks (DataTemplate.ShopBoosts), as a tiny read/write layer
-- over DataService. Kept separate from ShopProductsService -- which sells them -- because the
-- systems that APPLY them (ProgressionService for cash/gems, SkillsService and JobServer for walk
-- speed) must read them without pulling in the whole purchase pipeline. This module requires
-- nothing but DataService, so it can sit underneath all of them with no require cycle.
--
-- Every grant is an "at least this much" write, never an accumulate: a perk the player bought once
-- lands on the same value however many times it's applied, so a re-delivered receipt (or a second
-- purchase of the same permanent perk) can't stack it. That's what lets the receipt handlers stay
-- safely idempotent.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local ShopPerks = {}

-- Multiplier perks read as 1 (no effect) and the speed bonus as 0 until bought -- and also for the
-- brief window before a profile has reconciled, so every caller can use these unconditionally.
local DEFAULT_MULTIPLIER = 1
local DEFAULT_SPEED_BONUS = 0

-- One ShopBoosts field, or `fallback` when it's unset / not yet reconciled.
local function readBoost(player: Player, field: string, fallback: number): number
	local value = DataService:get(player, { "ShopBoosts", field })
	return if type(value) == "number" then value else fallback
end

-- Raise a ShopBoosts field to `value`, leaving it alone if it's already at least that. Idempotent
-- by construction (see the header) -- and it also means a future, bigger version of a perk can be
-- sold without the smaller one being able to undo it.
local function raiseBoost(player: Player, field: string, value: number)
	DataService:update(player, { "ShopBoosts", field }, function(current: number?)
		return math.max(current or 0, value)
	end)
end

-- Multiplier applied to every Cash award on top of the Greed skill (1 when unbought).
function ShopPerks.getCashMultiplier(player: Player): number
	return readBoost(player, "CashMultiplier", DEFAULT_MULTIPLIER)
end

-- Multiplier applied to every Gem award on top of the Hoarding skill (1 when unbought).
function ShopPerks.getGemMultiplier(player: Player): number
	return readBoost(player, "GemMultiplier", DEFAULT_MULTIPLIER)
end

-- Studs/sec ADDED to the player's walk speed, free-roam and on the job alike (0 when unbought).
-- Added AFTER the Speedy skill's multiplier so the perk is worth exactly what it says (+10 means
-- +10), rather than being quietly scaled by however many Speedy levels the player happens to own.
function ShopPerks.getSpeedBonus(player: Player): number
	return readBoost(player, "SpeedBonus", DEFAULT_SPEED_BONUS)
end

function ShopPerks.grantCashMultiplier(player: Player, value: number)
	raiseBoost(player, "CashMultiplier", value)
end

function ShopPerks.grantGemMultiplier(player: Player, value: number)
	raiseBoost(player, "GemMultiplier", value)
end

function ShopPerks.grantSpeedBonus(player: Player, value: number)
	raiseBoost(player, "SpeedBonus", value)
end

return ShopPerks
