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
		Level = 0,
		UseTime = 2.5, -- seconds of cleaning before a stain is removed
		Range = 30,
		SlotNumber = 2,
		BaseUpgradeCost = 100,
		UpgradeRange = 5,
	},

	pressureWasher = {
		Name = "Pressure Washer",
		Equipped = false,
		Unlocked = true,
		Cost = 0,
		UniqueID = "pressureWasher",
		Level = 0,
		Range = 30,
		Radius = 0.8,
		SlotNumber = 1,
		BaseUpgradeCost = 200,
		UpgradeRange = 5,
		UpgradeRadius = 0.1,
	},
}

return ToolConfig
