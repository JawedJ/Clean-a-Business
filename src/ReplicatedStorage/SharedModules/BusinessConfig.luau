--!strict

-- Static catalog of every business in the game.
-- This holds business DEFINITIONS only. The per-player Unlocked flag (which gates
-- accepting a business's job) lives in DataTemplate.BusinessList and is written
-- through DataService. Cleaned state is no longer tracked -- jobs are per-session.
-- Adding a new business = add one entry here.

local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)

local BusinessConfig: { [string]: DataTemplate.Business } = {
	mcDonalds = {
		BaseReward = 2500,
		Unlocked = true,
		Name = "McDonalds",
		UniqueID = "mcDonalds",
		Completions = 0,
		XpReward = 250,
		-- Stains fill 25% of the completion bar here, walls the other 75%.
		DecalWeight = 0.25,
		RequiredLevel = 5,
		-- Stains need the broom, walls the pressure washer, spills the mop -- all three required.
		RequiredItems = { "pressureWasher", "startingBroom", "mop" },
	},

	starbucks = {
		BaseReward = 1000,
		Unlocked = false,
		Name = "Starbucks",
		UniqueID = "starbucks",
		Completions = 0,
		XpReward = 500,
		RequiredLevel = 1,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher" },
	},
	apple = {
		BaseReward = 1000,
		Unlocked = false,
		Name = "Apples",
		UniqueID = "apple",
		Completions = 0,
		XpReward = 500,
		RequiredLevel = 1,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher" },
	},

	gasStation = {
		BaseReward = 1000,
		Unlocked = false,
		Name = "Frosty's",
		UniqueID = "gasStation",
		Completions = 0,
		XpReward = 500,
		RequiredLevel = 1,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher" },
	},
}

return BusinessConfig
