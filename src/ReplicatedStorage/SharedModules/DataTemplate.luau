--!strict

export type Item = {
	Name: string,
	Equipped: boolean,
	Unlocked: boolean,
	Cost: number,
	UniqueID: string,

	-- Optional per-tool stats (e.g. the pressure washer). Tools that don't use a
	-- stat leave it nil.
	Range: number?, -- max cleaning raycast distance (studs)
	MaxAmmo: number?, -- water tank capacity
	AmmoPerStep: number?, -- water drained per cleaning tick
	RegenPerSec: number?, -- water regenerated per second while not firing
}

-- a funciton will be made to compute the xp requirements for the next level, using some formula
export type Level = {
	CurrentLevel: number,
	XP: number,
}

export type Business = {
	BaseRate: number,
	Unlocked: boolean,
	Cleaned: boolean,
	Name: string,
	UniqueID: string,
	CleanedParts: { [string]: boolean }?,
	CleanedStains: { [string]: boolean }?,


}


local DataTemplate = {

	Cash = 100,

	Level = {
		CurrentLevel = 1,
		XP = 0
	} :: Level,

	BusinessList = {
		["mcDonalds"] = {
			BaseRate = 100,
			Unlocked = true,
			Cleaned = false,
			Name = "McDonalds",
			UniqueID = "mcDonalds",
			CleanedParts = {},
			CleanedStains = {},
		},


	} :: { [string]: Business },

	Inventory = {
		["startingBroom"] = {
			Name = "Broom",
			Equipped = false,
			Unlocked = true,
			Cost = 0,
			UniqueID = "startingBroom"
		},

		["pressureWasher"] = {
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

	} :: { [string]: Item },




}

export type dataTemplate = typeof(DataTemplate)


return DataTemplate
