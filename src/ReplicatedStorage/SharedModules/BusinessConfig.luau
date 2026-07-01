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
	},

	starbucks = {
		BaseReward = 1000,
		Unlocked = false,
		Name = "Starbucks",
		UniqueID = "starbucks",
		Completions = 0,
		XpReward = 500,
	},
}

return BusinessConfig
