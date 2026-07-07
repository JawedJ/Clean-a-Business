--!strict

-- Pure leveling math, shared so the client can display level/XP progress and the
-- server can award XP authoritatively. XP is progress WITHIN the current level: it
-- counts up from 0 toward xpForLevel(CurrentLevel) and rolls over on level-up.

local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)

type Level = DataTemplate.Level

-- XP curve tuning. xpForLevel(n) is the XP needed to go from level n to n+1.
local BASE_XP = 100
local GROWTH = 1.25

local Leveling = {}

-- XP required to advance from `level` to the next level. Grows GROWTH x per level.
function Leveling.xpForLevel(level: number): number
	return math.floor(BASE_XP * GROWTH ^ (level - 1))
end

-- Returns a NEW Level with `amount` XP added, rolling over into as many level-ups
-- as the XP covers. Pure: it does not mutate the input.
function Leveling.addXp(level: Level, amount: number): Level
	local currentLevel = level.CurrentLevel
	local xp = level.XP + amount

	local needed = Leveling.xpForLevel(currentLevel)
	while xp >= needed do
		xp -= needed
		currentLevel += 1
		needed = Leveling.xpForLevel(currentLevel)
	end

	return { CurrentLevel = currentLevel, XP = xp }
end

return Leveling
