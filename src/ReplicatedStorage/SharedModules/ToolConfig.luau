--!strict

-- Static catalog of every tool in the game (starters included).
-- This holds tool DEFINITIONS only. Per-player owned/equipped state lives in
-- DataTemplate.Inventory and is written through DataService on unlock/equip.
-- Adding a new tool = add one entry here.

local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)

local ToolConfig: { [string]: DataTemplate.Item } = {
	startingBroom = {
		Name = "Broom",
		Equipped = false,
		Unlocked = true,
		Cost = 0,
		UniqueID = "startingBroom",
	},

	pressureWasher = {
		Name = "Pressure Washer",
		Equipped = false,
		Unlocked = true,
		Cost = 0,
		UniqueID = "pressureWasher",
		Range = 60,
		MaxAmmo = 100,
		AmmoPerStep = 0.6,
		RegenPerSec = 30,
	},
}

return ToolConfig
