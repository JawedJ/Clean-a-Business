--!strict

export type Item = {
	Name: string,
	Equipped: boolean,
	Unlocked: boolean,
	Cost: number,
	UniqueID: string,

	Range: number?, -- max cleaning distance (studs)
	Power: number?,
	UseTime: number?,
	Radius: number?,
}

-- a funciton will be made to compute the xp requirements for the next level, using some formula
export type Level = {
	CurrentLevel: number,
	XP: number,
}

-- Per-player business record. We no longer persist cleaned state (jobs are
-- per-session and reset every time they're accepted), so this only tracks whether
-- the player has Unlocked the business -- which is what gates accepting its job.
export type Business = {
	BaseReward: number,
	Unlocked: boolean,
	Name: string,
	UniqueID: string,
	Completions: number,
}



local DataTemplate = {

	Cash = 100,

	Level = {
		CurrentLevel = 1,
		XP = 0
	} :: Level,

	BusinessList = {
		["mcDonalds"] = {
			BaseReward = 100,
			Unlocked = true,
			Name = "McDonalds",
			UniqueID = "mcDonalds",
			Completions = 0
		},


	} :: { [string]: Business },

	Inventory = {
		["startingBroom"] = {
		Name = "Broom",
		Equipped = false,
		Unlocked = true,
		Cost = 0,
		UniqueID = "startingBroom",
		Power = 1,
		UseTime = 2.5,
		Range = 70,
		},

		["pressureWasher"] = {
		Name = "Pressure Washer",
		Equipped = false,
		Unlocked = true,
		Cost = 0,
		UniqueID = "pressureWasher",
		Range = 70,
		Power = 1,
		Radius = 0.8,
		},

	} :: { [string]: Item },




}

export type dataTemplate = typeof(DataTemplate)


return DataTemplate
