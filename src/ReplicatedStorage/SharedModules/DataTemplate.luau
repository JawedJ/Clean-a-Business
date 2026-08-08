--!strict

export type Item = {
	Name: string,
	Equipped: boolean,
	Unlocked: boolean,
	Cost: number,
	UniqueID: string,
	Level: number, -- upgrade level; starts at 0, capped at ItemUpgrades.MAX_LEVEL

	Range: number?, -- max cleaning distance (studs)
	Power: number?, -- mop: Transparency added per second while cleaning a spill (0..1/s)
	UseTime: number?,
	Radius: number?,
	SlotNumber: number?,

	-- Icon shown wherever the tool is displayed as a requirement (the job board's RequiredItems
	-- row). Static catalog property (ToolConfig), not a per-player record field.
	Image: string?,

	-- Upgrade tuning (see ItemUpgrades). BaseUpgradeCost marks an item upgradeable, and is the
	-- base price its upgrade ladder is measured against -- but only for FREE starter tools; a tool
	-- with a purchase Cost measures its ladder against that Cost instead, so buying it and
	-- levelling it never cost the same. UpgradeRange/UpgradeRadius
	-- are how much each upgrade adds to the item's Range/Radius; UpgradeUseTime is how much each
	-- upgrade SUBTRACTS from the item's UseTime (faster cleaning). An item with no BaseUpgradeCost
	-- isn't upgradeable.
	BaseUpgradeCost: number?,
	-- What the item's LAST upgrade (level MAX_LEVEL - 1 -> MAX_LEVEL) should cost -- i.e. where its
	-- price ladder caps out. Optional per-item override: omitted items ride the shared
	-- ItemUpgrades.FINAL_MULTIPLE off their base price instead. Set it when a tool's own top price
	-- matters (the mop and vacuum have very different base prices, so one global multiple can't
	-- land both). Ignored if it isn't above the item's base price.
	MaxUpgradeCost: number?,
	UpgradeRange: number?,
	UpgradeRadius: number?,
	UpgradeUseTime: number?,
	UpgradePower: number?, -- how much each upgrade ADDS to the mop's Power (faster fade)
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

-- Permanent perks bought with Robux from the store (PlayerGui.ScreenGui.ShopUI -- see
-- ShopProducts / ShopPerks). Unlike the store's cash/gem packs, which are spent the moment they're
-- credited, these are standing effects that must survive a rejoin, so they live in the profile:
--   * CashMultiplier / GemMultiplier -- multiply every Cash/Gem award (ProgressionService), on top
--     of the Greed/Hoarding skills. 1 = not bought.
--   * SpeedBonus -- studs/sec ADDED to walk speed after the Speedy skill's multiplier, both
--     free-roam (SkillsService) and on the job (JobServer). 0 = not bought.
-- Each is written as an idempotent "at least this much" set, never accumulated, so a re-delivered
-- receipt can't stack a perk the player paid for once.
export type ShopBoosts = {
	CashMultiplier: number,
	GemMultiplier: number,
	SpeedBonus: number,
}

-- Running tally of the player's per-job star ratings (1..5 per job -- see JobRating), used to
-- show their business's AVERAGE rating in the Company UI. We store the running Sum + Count rather
-- than the average itself so each new job folds in exactly (average = Sum / Count). A fresh
-- player has rated no jobs (Count 0), which the UI shows as the 1-star floor. Recorded on every
-- job end -- full completion (always 5) and finish-early (prorated) alike -- by JobServer.
export type Ratings = {
	Sum: number,
	Count: number,
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
	-- Fraction (0..1) of the completion bar this business's cleanable SPILLS (mop targets) fill,
	-- when it has any. Optional -- omitted businesses with spills use CleaningConfig.DefaultSpillWeight;
	-- businesses without spills ignore it entirely. Static catalog property (BusinessConfig), like
	-- DecalWeight, not a per-player record field. See CompletionWeights.
	SpillWeight: number?,
	-- Fraction (0..1) of the completion bar this business's cleanable WEBS (vacuum targets) fill,
	-- when it has any. Optional -- omitted businesses with webs use CleaningConfig.DefaultWebWeight;
	-- businesses without webs ignore it entirely. Static catalog property (BusinessConfig), like
	-- DecalWeight, not a per-player record field. See CompletionWeights.
	WebWeight: number?,
}



local DataTemplate = {

	Cash = 5000,

	Gems = 499,

	-- Offline (AFK) gem earnings bookkeeping (see AfkEarningsService). Both are snapshotted when
	-- the player leaves and read back on their next join to compute what they earned while away:
	--   * LastOnlineTime -- os.time() at the moment they left (0 for a player who has never left,
	--     which suppresses the offline reward on a first-ever join).
	--   * LastGemsPerSecond -- the plot's gems/sec at that moment, already scaled by their Hoarding
	--     skill so it matches what they'd have earned staying online. Offline pay is
	--     (LastGemsPerSecond / OfflineRateDivisor) * secondsAway, capped at one day's online rate.
	-- Reconciled onto existing profiles like the other fields.
	LastOnlineTime = 0,
	LastGemsPerSecond = 0,
	-- Offline gems that have been earned but NOT yet claimed. Each join folds the newly-earned
	-- offline amount into this bank (rather than replacing it), so a player who leaves without
	-- pressing Claim keeps what they'd accrued and it simply keeps growing. Zeroed the moment the
	-- reward is claimed (Claim or Double). Reconciled onto existing profiles.
	UnclaimedAfkGems = 0,

	-- Live plot output in gems/sec, already scaled by the Hoarding skill (i.e. what the player is
	-- actually earning). Mirrored out of PlotButtonService by CompanyService while they're online so
	-- the client can SHOW the rate (the Company UI's EarningsCard) -- unlike LastGemsPerSecond, which
	-- is a leave-time snapshot the client never sees. Reconciled onto existing profiles.
	GemsPerSecond = 0,

	-- Set the first time the player's character is ever placed on their plot, and never cleared.
	-- While it's false their FIRST spawn goes to the plot's FirstSpawn part instead of the usual
	-- spawnPart (see PlotService); every respawn after that, and every later session, uses the
	-- normal one. Reconciled onto existing profiles -- which means an EXISTING player reconciles in
	-- at false and gets one first-spawn placement on their next join. Intentional: there's no way
	-- to tell them apart from a genuinely new player after the fact.
	HasSpawnedBefore = false,

	-- Whether the player has already been through the onboarding tutorial, and so must never see it
	-- again. Set the moment the tutorial STARTS, not when it finishes: a player who leaves partway
	-- through has still had their one run at it, and replaying a half-finished tutorial on their next
	-- join would re-lock a plot they've already started building. So the flag means "has been offered
	-- the tutorial", and a rejoining player always lands in the normal, fully-unlocked game whether
	-- they finished or not. Reconciled onto existing profiles -- which means every EXISTING player
	-- reconciles in at false and gets the tutorial once on their next join, exactly like a new one.
	TutorialComplete = false,

	-- Lifetime seconds the player has spent in-game ("Business Age" in the Company UI). Accrued by
	-- CompanyService: flushed into the profile periodically while online and once more on leave, so
	-- the stored value is always the true running total. Reconciled onto existing profiles.
	PlaytimeSeconds = 0,

	-- When the player's purchased 10x gem boost runs out, as an ABSOLUTE os.time() stamp (0 = no
	-- boost). Absolute rather than a countdown so it keeps ticking while they're offline, which is
	-- what lets the offline payout pay boosted for whatever slice of the absence it covered (see
	-- GemBuff / AfkEarningsService). Reconciled onto existing profiles.
	GemBuffExpiresAt = 0,

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

	-- Permanent Robux store perks (see ShopBoosts type). A fresh player has none: multipliers at
	-- 1 (no change) and no speed bonus. Reconciled onto existing profiles like the other tables.
	ShopBoosts = {
		CashMultiplier = 1,
		GemMultiplier = 1,
		SpeedBonus = 0,
	} :: ShopBoosts,

	-- Free-text description the player writes for their business in the Company UI, persisted so it
	-- re-displays each session. Empty on a fresh profile (the UI shows its placeholder then).
	-- Reconciled onto existing profiles like the other fields.
	BusinessDescription = "",

	-- Running per-job star-rating tally (see Ratings type). Both start at 0 -> a fresh player shows
	-- the 1-star floor until their first job is rated.
	Ratings = {
		Sum = 0,
		Count = 0,
	} :: Ratings,

	BusinessList = {
		-- Deliberately minimal: the authoritative list of businesses is the BusinessConfig
		-- catalog, and BusinessService seeds a locked record for every catalog entry missing
		-- from the profile on join (see ServerScriptService.BusinessService). Do NOT mirror the
		-- catalog here -- a template entry wins over seeding, so a stale copy silently pins the
		-- wrong Name/reward onto every profile forever. One entry is kept only so the table has
		-- a shape for reconcile to key off.
		["starbucks"] = {
			BaseReward = 2500,
			Unlocked = false,
			Name = "Starbucks",
			UniqueID = "starbucks",
			Completions = 0,
			XpReward = 350
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

		["mop"] = {
		Name = "Mop",
		Equipped = false,
		Unlocked = false,
		Cost = 50000,
		UniqueID = "mop",
		Level = 0,
		SlotNumber = 3,
		Power = 0.4, -- Transparency/sec while cleaning: a spill fully fades in ~2.5s at level 0
		Range = 30,
		BaseUpgradeCost = 250,
		MaxUpgradeCost = 15000000,
		UpgradePower = 0.08, -- each level fades faster
		UpgradeRange = 5,
		},

		["vacuum"] = {
		Name = "Vacuum",
		Equipped = false,
		Unlocked = false,
		Cost = 500000,
		UniqueID = "vacuum",
		Level = 0,
		SlotNumber = 4,
		UseTime = 2.5,
		Range = 30,
		BaseUpgradeCost = 500,
		MaxUpgradeCost = 20000000,
		UpgradeRange = 5,
		UpgradeUseTime = 0.1,
		},

	} :: { [string]: Item },




}

export type dataTemplate = typeof(DataTemplate)


return DataTemplate
