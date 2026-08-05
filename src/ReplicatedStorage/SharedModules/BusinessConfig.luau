--!strict

-- Static catalog of every business in the game.
-- This holds business DEFINITIONS only. The per-player Unlocked flag (which gates
-- accepting a business's job) lives in DataTemplate.BusinessList and is written
-- through DataService. Cleaned state is no longer tracked -- jobs are per-session.
-- Adding a new business = add one entry here.

local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)

local BusinessConfig: { [string]: DataTemplate.Business } = {
	mcDonalds = {
		BaseReward = 6000,
		Unlocked = false,
		Name = "McDonalds",
		UniqueID = "mcDonalds",
		Completions = 0,
		XpReward = 600,
		-- Stains fill 25% of the completion bar here, walls the other 75%.
		DecalWeight = 0.25,
		RequiredLevel = 10,
		-- Stains need the broom, walls the pressure washer, spills the mop -- all three required.
		RequiredItems = { "pressureWasher", "startingBroom" },
	},

	starbucks = {
		BaseReward = 2500,
		Unlocked = false,
		Name = "Starbucks",
		UniqueID = "starbucks",
		Completions = 0,
		XpReward = 350,
		RequiredLevel = 3,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher", "startingBroom" },
	},
	apple = {
		BaseReward = 4000,
		Unlocked = false,
		Name = "Apples",
		UniqueID = "apple",
		Completions = 0,
		XpReward = 500,
		RequiredLevel = 7,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher", "startingBroom" },
	},

	gasStation = {
		BaseReward = 1500,
		Unlocked = true,
		Name = "Frosty's",
		UniqueID = "gasStation",
		Completions = 0,
		XpReward = 250,
		RequiredLevel = 1,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher" },
	},

	
	chipotle = {
		BaseReward = 9000,
		Unlocked = false,
		Name = "Chipotle",
		UniqueID = "chipotle",
		Completions = 0,
		XpReward = 950,
		RequiredLevel = 15,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher", "startingBroom", "mop" },
	},
}

return BusinessConfig
