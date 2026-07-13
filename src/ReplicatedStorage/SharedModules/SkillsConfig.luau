--!strict

-- Shared definitions + math for the gem-purchased SKILLS (PlayerGui.ScreenGui.SkillsDisplay,
-- driven by the client's SkillsUiController and re-validated by the server's SkillsService), so
-- the two can never disagree on price, level cap, or effect strength.
--
-- Each skill is a passive percentage boost the player buys up level-by-level with Gems. A skill
-- starts at level 0 and caps at MAX_LEVEL; every level adds `effectPerLevel` to a 1.0 base
-- multiplier, so level L gives a multiplier of (1 + effectPerLevel * L). The skills, keyed by the
-- SkillName attribute authored on each Skill ImageLabel:
--   * RadiusMaster -- +5%/level cleaning brush radius   (applied client-side in PressureWasherController)
--   * Speedy       -- +5%/level walk speed              (applied server-side in SkillsService/JobServer)
--   * Inteligence  -- +5%/level XP gain                 (applied in ProgressionService.awardXp)
--   * Greed        -- +5%/level Cash gain               (applied in ProgressionService.awardCash)
--   * Hoarding     -- +5%/level Gem gain                (applied in ProgressionService.awardGems)
--
-- Price of the NEXT level grows geometrically from BASE_PRICE (the level 0 -> 1 cost):
--     cost(level) = floor(BASE_PRICE * GROWTH ^ level)
-- so the first level of every skill costs exactly BASE_PRICE (100k Gems) and each further level
-- costs GROWTH x more.

local SkillsConfig = {}

-- Highest level any skill can reach. Single source for the client's "5 circles" display and the
-- server's purchase gate.
SkillsConfig.MAX_LEVEL = 5

-- Price of the FIRST level (0 -> 1) of every skill, in Gems.
SkillsConfig.BASE_PRICE = 100000

-- How much each successive level costs relative to the previous one.
local GROWTH = 2

-- Every skill, keyed by its SkillName attribute. `effectPerLevel` is the fraction added to the
-- 1.0 base multiplier per level bought.
SkillsConfig.Skills = {
	RadiusMaster = { effectPerLevel = 0.05 },
	Speedy = { effectPerLevel = 0.05 },
	Inteligence = { effectPerLevel = 0.05 },
	Greed = { effectPerLevel = 0.05 },
	Hoarding = { effectPerLevel = 0.05 },
} :: { [string]: { effectPerLevel: number } }

-- Whether `name` names a real skill.
function SkillsConfig.isSkill(name: string): boolean
	return SkillsConfig.Skills[name] ~= nil
end

-- Cost (Gems) to buy the NEXT level of a skill currently at `level`. Not gated on the cap -- use
-- canUpgrade for that.
function SkillsConfig.getCost(level: number): number
	return math.floor(SkillsConfig.BASE_PRICE * GROWTH ^ level)
end

-- Whether a skill at `level` can still be levelled up (below the cap).
function SkillsConfig.canUpgrade(level: number): boolean
	return level < SkillsConfig.MAX_LEVEL
end

-- The passive multiplier a skill grants at `level`: 1.0 at level 0, +effectPerLevel each level.
-- Returns 1.0 for an unknown skill so a caller can multiply unconditionally.
function SkillsConfig.multiplier(name: string, level: number): number
	local def = SkillsConfig.Skills[name]
	if not def then
		return 1
	end
	return 1 + def.effectPerLevel * level
end

return SkillsConfig
