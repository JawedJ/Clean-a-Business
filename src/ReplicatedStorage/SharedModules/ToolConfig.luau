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
		Power = 1.0,
		UseTime = 3.0, -- seconds of cleaning before a stain is removed
		Range = 70,
	},

	pressureWasher = {
		Name = "Pressure Washer",
		Equipped = false,
		Unlocked = true,
		Cost = 0,
		UniqueID = "pressureWasher",
		Range = 70,
		Power = 1.0,
		Radius = 1.0,
	},
}

return ToolConfig
