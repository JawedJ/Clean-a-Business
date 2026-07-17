--!strict

-- Static catalog of every tool in the game (starters included).
-- This holds tool DEFINITIONS only. Per-player owned/equipped state lives in
-- DataTemplate.Inventory and is written through DataService on unlock/equip.
-- Adding a new tool = add one entry here.

local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)

local ToolConfig: { [string]: DataTemplate.Item } = {
	startingBroom = {
		Name = "Brush",
		Equipped = false,
		Unlocked = false,
		Cost = 500,
		UniqueID = "startingBroom",
		Level = 0,
		Image = "rbxassetid://130011328987909",
		UseTime = 2.5, -- seconds of cleaning before a stain is removed
		Range = 30,
		SlotNumber = 2,
		BaseUpgradeCost = 500,
		UpgradeRange = 5,
		UpgradeUseTime = 0.1, -- each upgrade shortens UseTime by this many seconds
	},

	pressureWasher = {
		Name = "Pressure Washer",
		Equipped = false,
		Unlocked = true,
		Cost = 0,
		UniqueID = "pressureWasher",
		Level = 0,
		Image = "rbxassetid://134996005011791",
		Range = 25,
		Radius = 0.8,
		SlotNumber = 1,
		BaseUpgradeCost = 100,
		UpgradeRange = 3,
		UpgradeRadius = 0.025,
	},

	mop = {
		Name = "Mop",
		Equipped = false,
		Unlocked = true,
		Cost = 0,
		UniqueID = "mop",
		Level = 0,
		Image = "rbxassetid://85297772324862",
		SlotNumber = 3,
		Power = 0.4, -- Transparency/sec while cleaning: a spill fully fades in ~2.5s at level 0
		Range = 30,
		BaseUpgradeCost = 250,
		UpgradePower = 0.08, -- each upgrade fades spills faster
		UpgradeRange = 5,
	},
}

return ToolConfig
