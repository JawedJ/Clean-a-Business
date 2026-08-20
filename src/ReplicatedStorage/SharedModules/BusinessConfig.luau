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
		BaseReward = 7500,
		Unlocked = true,
		Name = "Frosty's",
		UniqueID = "gasStation",
		Completions = 0,
		XpReward = 999,
		RequiredLevel = 1,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher" },
	},

	
	chipotle = {
		BaseReward = 8000,
		Unlocked = false,
		Name = "Chipotle",
		UniqueID = "chipotle",
		Completions = 0,
		XpReward = 950,
		RequiredLevel = 15,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher", "startingBroom", "mop" },
	},

	fiveGuys = {
		BaseReward = 10000,
		Unlocked = false,
		Name = "Five Guys",
		UniqueID = "fiveGuys",
		Completions = 0,
		XpReward = 1150,
		RequiredLevel = 18,
		-- Walls only (no stains), so the pressure washer is the only tool needed.
		RequiredItems = { "pressureWasher", "startingBroom", "mop" },
	},

	gamestop = {
		BaseReward = 14000,
		Unlocked = false,
		Name = "Gamestop",
		UniqueID = "gamestop",
		Completions = 0,
		XpReward = 2000,
		RequiredLevel = 20,
		-- Walls, stains and spills -- all three tools required.
		RequiredItems = { "pressureWasher", "startingBroom", "mop" },
	},

	dollarTree = {
		BaseReward = 23000,
		Unlocked = false,
		Name = "Dollar Store",
		UniqueID = "dollarTree",
		Completions = 0,
		XpReward = 5000,
		RequiredLevel = 24,
		RequiredItems = { "pressureWasher", "startingBroom", "mop", "vacuum" },
	},
	--next level req 24
	--photo images are 1022x926
}

return BusinessConfig
