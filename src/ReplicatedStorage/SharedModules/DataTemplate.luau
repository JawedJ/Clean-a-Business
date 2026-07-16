--!strict

export type Item = {
	Name: string,
	Equipped: boolean,
	Unlocked: boolean,
	Cost: number,
	UniqueID: string,
	Level: number, -- upgrade level; starts at 0, capped at ItemUpgrades.MAX_LEVEL

	Range: number?, -- max cleaning distance (studs)
	Power: number?,
	UseTime: number?,
	Radius: number?,
	SlotNumber: number?,

	-- Icon shown wherever the tool is displayed as a requirement (the job board's RequiredItems
	-- row). Static catalog property (ToolConfig), not a per-player record field.
	Image: string?,

	-- Upgrade tuning (see ItemUpgrades). BaseUpgradeCost is the price of the FIRST upgrade
	-- (level 0 -> 1); the shared cost formula scales it up per level. UpgradeRange/UpgradeRadius
	-- are how much each upgrade adds to the item's Range/Radius; UpgradeUseTime is how much each
	-- upgrade SUBTRACTS from the item's UseTime (faster cleaning). An item with no BaseUpgradeCost
	-- isn't upgradeable.
	BaseUpgradeCost: number?,
	UpgradeRange: number?,
	UpgradeRadius: number?,
	UpgradeUseTime: number?,
}

-- a funciton will be made to compute the xp requirements for the next level, using some formula
export type Level = {
	CurrentLevel: number,
	XP: number,
}

-- Player-tunable client preferences. Volumes are 0..1 master multipliers applied to the
-- SFX / music SoundGroups (see SoundGroups); 0.5 is the mid-slider default a new player starts
-- at. HidePlayers, when true, hides every OTHER player's character locally (see
-- HidePlayersController). Persisted like the rest of the profile so a player's preferences are
-- remembered across sessions.
export type Settings = {
	MusicVolume: number,
	SFXVolume: number,
	HidePlayers: boolean,
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
	XpReward: number,
	-- Fraction (0..1) of the completion bar the business's cleanable stains fill; walls
	-- fill the rest (1 - DecalWeight). Optional -- omitted businesses use
	-- CleaningConfig.DefaultDecalWeight. Only meaningful on the static BusinessConfig
	-- catalog, not the per-player record.
	DecalWeight: number?,
	-- Minimum player level required to accept this business's job. Optional -- omitted
	-- businesses default to level 1 (no gate). Like DecalWeight this is a static catalog
	-- property (BusinessConfig), not a per-player record field.
	RequiredLevel: number?,
	-- Tool UniqueIDs (ToolConfig keys) the player must have Unlocked in their Inventory before
	-- they can accept this business's job -- a gate on top of RequiredLevel, not a replacement:
	-- both must pass. Order drives the board's RequiredItems icons (first entry -> Item1). At
	-- most 5 (the board authors that many slots). Optional -- omitted businesses need no tools.
	-- Static catalog property (BusinessConfig), not a per-player record field.
	RequiredItems: { string }?,
}



local DataTemplate = {

	Cash = 1000,

	Gems = 100,

	-- Per-plot purchase progression (see PlotButtonService). A set of the button names the
	-- player has bought (e.g. { Button1 = true, Button2 = true }). Layout-agnostic: buttons and
	-- spawnables share the same names across every plot, so this replays onto whichever plot the
	-- player is assigned. Empty for a fresh player -> only Button1 visible on their plot.
	PlotButtonsBought = {} :: { [string]: boolean },

	Level = {
		CurrentLevel = 1,
		XP = 0
	} :: Level,

	-- Passive gem-purchased skill levels, keyed by SkillName (see SkillsConfig). Each starts at
	-- level 0 and is bought up to SkillsConfig.MAX_LEVEL through the SkillsDisplay UI. Reconciled
	-- onto existing profiles like the other tables.
	Skills = {
		RadiusMaster = 0,
		Speedy = 0,
		Inteligence = 0,
		Greed = 0,
		Hoarding = 0,
	} :: { [string]: number },

	-- Sliders start centered (0.5) on a first join; HidePlayers defaults off. Reconciled onto
	-- existing profiles.
	Settings = {
		MusicVolume = 0.5,
		SFXVolume = 0.5,
		HidePlayers = false,
	} :: Settings,

	BusinessList = {
		-- Every business starts LOCKED; BusinessService grants unlocks as requirements are met
		-- when the player joins (see ServerScriptService.BusinessService). Keep this list in sync
		-- with the BusinessConfig catalog -- one entry per business.
		["mcDonalds"] = {
			BaseReward = 2500,
			Unlocked = false,
			Name = "McDonalds",
			UniqueID = "mcDonalds",
			Completions = 0,
			XpReward = 250
		},

		["starbucks"] = {
			BaseReward = 1000,
			Unlocked = false,
			Name = "Starbucks",
			UniqueID = "starbucks",
			Completions = 0,
			XpReward = 500
		},


	} :: { [string]: Business },

	Inventory = {
		["startingBroom"] = {
		Name = "Brush",
		Equipped = false,
		Unlocked = false,
		Cost = 500,
		UniqueID = "startingBroom",
		Level = 0,
		UseTime = 2.5,
		Range = 30,
		SlotNumber = 2,
		BaseUpgradeCost = 500,
		UpgradeRange = 5,
		UpgradeUseTime = 0.1,
		},

		["pressureWasher"] = {
		Name = "Pressure Washer",
		Equipped = false,
		Unlocked = true,
		Cost = 0,
		UniqueID = "pressureWasher",
		Level = 0,
		Range = 25,
		Radius = 0.8,
		SlotNumber = 1,
		BaseUpgradeCost = 100,
		UpgradeRange = 3,
		UpgradeRadius = 0.025,
		},

	} :: { [string]: Item },




}

export type dataTemplate = typeof(DataTemplate)


return DataTemplate
