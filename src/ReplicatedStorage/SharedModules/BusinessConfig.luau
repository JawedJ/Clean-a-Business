--!strict

-- Static catalog of every business in the game.
-- This holds business DEFINITIONS only. Per-player progress (Unlocked, Cleaned,
-- CleanedParts, CleanedStains) lives in DataTemplate.BusinessList and is written
-- through DataService. Adding a new business = add one entry here.

local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)

local BusinessConfig: { [string]: DataTemplate.Business } = {
	mcDonalds = {
		BaseRate = 100,
		Unlocked = true,
		Cleaned = false,
		Name = "McDonalds",
		UniqueID = "mcDonalds",
		CleanedParts = {},
		CleanedStains = {},
	},

	starbucks = {
		BaseRate = 500,
		Unlocked = false,
		Cleaned = false,
		Name = "Starbucks",
		UniqueID = "starbucks",
		CleanedParts = {},
		CleanedStains = {},
	},
}

return BusinessConfig
