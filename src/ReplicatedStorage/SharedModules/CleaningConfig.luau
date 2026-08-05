--!strict

-- Shared constants for the pressure-washer cleaning system.
-- Required by both the client (surface overlay + controller) and the server
-- (tool giving + surface spawning) so the tag/id strings never drift apart.

-- Tool identity (the "ToolId" attribute on each Tool) and per-tool stats
-- (Range, UseTime, Power) are NOT here -- they live in ToolConfig as defaults and,
-- at runtime, in each player's DataService Inventory so they can change with
-- upgrades. This module holds only mechanic-wide constants.
local CleaningConfig = {
	-- Businesses are SHARED, pre-placed buildings under one Workspace folder, one per
	-- businessId (NOT cloned per plot -- every player cleans the same building):
	--   Workspace.<BusinessesFolderName>.<businessId>
	-- Each building holds a TeleportPart (where accepting the job drops the player) and
	-- a Cleanables folder authored directly in the building. The Cleanables geometry is
	-- shared/replicated; only the per-client wall overlays are built at job time.
	--
	-- Cleanable walls live at:
	--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableWalls.<part>
	-- The business folder's name is the BusinessId and the part's name is the
	-- SurfaceId. Cleaned state is NOT saved -- jobs are per-session.
	BusinessesFolderName = "Businesses",
	CleanablesFolderName = "Cleanables",
	WallsFolderName = "CleanableWalls",

	-- Interior geometry (windows, props) authored inside each business at:
	--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.<InteriorFolderName>
	-- The cleaning ray ignores this folder's descendants so interior objects sitting in
	-- front of a wall never block the wash from reaching the wall behind them.
	InteriorFolderName = "Interior",

	-- Cleanable stains (broom targets) live alongside the walls:
	--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableDecals.<model>
	-- Each <model> has a child BasePart named HitboxName the player clicks, and a
	-- SurfaceIdAttribute attribute whose value is the stain's id (used server-side to
	-- track which stains a player has already cleaned this session).
	DecalsFolderName = "CleanableDecals",
	HitboxName = "Hitbox",
	SurfaceIdAttribute = "surfaceId",

	-- Cleanable webs (vacuum targets) live alongside the walls + stains:
	--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableWebs.<web>
	-- Each <web> is the direct child of the folder carrying a SurfaceIdAttribute attribute, and may
	-- be authored either as a single BasePart (the mesh itself is the target) OR as a Model grouping
	-- parts -- the vacuum ray hits the web's own geometry and WebResolver climbs to the folder child.
	-- Webs clean like stains: the vacuum click starts a server-authoritative UseTime timer that
	-- removes the web wholesale. Only the tool + folder differ from stains; see WebResolver /
	-- VacuumController.
	WebsFolderName = "CleanableWebs",

	-- Cleanable spills (mop targets) live alongside the walls + stains:
	--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableSpills.<model>
	-- Each <model> is a spill whose parts the player mops away by holding click: the mop
	-- fades the whole model's Transparency toward 1 (invisible) at the mop's Power per
	-- second, then hides it locally once fully faded. Each spill carries a SpillSurfaceIdAttribute
	-- so the server can dedupe which spills a player has already cleaned this job.
	--
	-- A spill's visible geometry is often CanQuery=false (a thin puddle the ray would pass
	-- through), so a spill model can carry an invisible child BasePart named HitboxName (the same
	-- name the stains use) purely to give the mop ray something to hit. The mop resolves ANY
	-- BasePart in the model to the spill, so a hitbox is optional -- it just makes thin spills
	-- easier to aim at. The hitbox is excluded from the fade (see MopController).
	SpillsFolderName = "CleanableSpills",
	-- Attribute holding a spill's unique id, authored on the spill Model. Capitalised "SurfaceId"
	-- -- distinct from the stains'/walls' lowercase SurfaceIdAttribute -- because that's how the
	-- spill models are authored in Studio.
	SpillSurfaceIdAttribute = "SurfaceId",

	-- Plots are still a thing: each joining player is assigned a personal plot (their
	-- home/spawn base) named Plot1..Plot(PlotCount), living under one Workspace folder:
	--   Workspace.<PlotsFolderName>.Plot(i)
	-- The assigned plot's name is published to the owner via PlotAttribute. Plots no
	-- longer hold businesses -- cleaning happens at the shared buildings above, gated by
	-- the player's accepted job rather than plot ownership.
	PlotsFolderName = "Plots",
	PlotCount = 6,
	PlotAttribute = "Plot",

	-- Model grouping every pad the plot teleports a character ONTO -- the two spawn parts below and
	-- the portal's two landing pads:
	--   Plot(i).<PlotTeleportsModelName>.<PlotSpawnPartName / PlotFirstSpawnPartName /
	--                                    PortalDestinationFromFirst / PortalDestinationFromSecond>
	-- Grouping them in one Model is what lets them be marked never-streamed-out
	-- (Model.ModelStreamingMode, which only exists on a Model -- loose parts can't be pinned).
	-- Lookups go through PlotService.findPart, which also accepts a pad still sitting directly
	-- under the plot folder, so a plot that hasn't been regrouped yet still works.
	PlotTeleportsModelName = "Teleports",

	-- Part the owner's character spawns on when assigned the plot and on every respawn
	-- (unless they currently hold a job, see ActiveJob).
	PlotSpawnPartName = "spawnPart",

	-- Part used INSTEAD of PlotSpawnPartName for a player's very first spawn in the game, ever
	-- (DataTemplate.HasSpawnedBefore -- see PlotService). Every respawn after that, and every
	-- later session, uses the normal spawn part. A plot missing this part just falls back to the
	-- normal one.
	PlotFirstSpawnPartName = "FirstSpawn",

	-- The plot's warehouse name sign (see PlotSignService), stamped with the owner's name on
	-- assign and blanked on release. The path below is walked from the plot:
	--   Plot(i).Warehouse.OutsideDesign.<PlotSignPath...>
	-- ending at a TextBox whose Text becomes "<Owner>'s Warehouse".
	PlotWarehouseFolderName = "Warehouse",
	PlotSignPath = { "OutsideDesign", "Wood Sign", "TextPart", "SurfaceGui", "TextBox" },

	-- Per-plot purchase progression (see PlotButtonService). Each plot holds two folders:
	--   Plot(i).<PlotButtonsFolderName>     -- purchase buttons, named "Button1".."ButtonN"
	--   Plot(i).<PlotSpawnablesFolderName>  -- the things buttons unlock, one Model per UnlockID
	-- Every button Model carries three attributes, plus one optional:
	--   Cost (number)      -- Cash charged when the owner steps on the button's Interact part
	--   UnlockID (string)  -- name of the Spawnables Model this button makes visible
	--   UnlockTwo (boolean)-- if true, buying this button reveals the NEXT TWO buttons instead
	--                         of just the next one (still destroys this button either way)
	--   RequiresButton     -- OPTIONAL number: this button stays hidden until Button<N> has been
	--     (number)            bought, no matter how far the chain has advanced (e.g. 9 on Button11
	--                         means Button11 only ever appears once Button9 is purchased). While it
	--                         is gated the chain skips over it and reveals the next button instead.
	-- The button is triggered when the owner steps on its child BasePart named
	-- PlotButtonInteractPartName. Progress persists per player (DataTemplate.PlotButtonsBought),
	-- and each plot is fully hidden on release and rebuilt from the next owner's save data.
	PlotButtonsFolderName = "Buttons",
	PlotSpawnablesFolderName = "Spawnables",
	PlotButtonInteractPartName = "Interact",
	PlotButtonCostAttribute = "Cost",
	PlotButtonUnlockIdAttribute = "UnlockID",
	PlotButtonUnlockTwoAttribute = "UnlockTwo",
	PlotButtonRequiresAttribute = "RequiresButton",

	-- The Portal spawnable (see PortalService): a two-ended teleporter inside a plot. Authored as
	--   Plot(i).<PlotSpawnablesFolderName>.<PortalModelName>                       -- the top end
	--     .<PortalTouchPartName>                                                   -- sends to Teleport2
	--     .<PortalSecondModelName>.<PortalTouchPartName>                           -- sends to Teleport1
	-- with the two landing pads inside the plot's teleports model (see PlotTeleportsModelName):
	--   Plot(i).<PlotTeleportsModelName>.<PortalDestinationFromSecond / PortalDestinationFromFirst>
	-- Both ends teleport within the SAME plot as the portal that was touched. While the spawnable
	-- is still locked PlotButtonService leaves it CanTouch = false, so the pads are unreachable
	-- until it's bought.
	PortalModelName = "Portal",
	PortalSecondModelName = "SecondPortal",
	PortalTouchPartName = "TouchDetector",
	PortalDestinationFromFirst = "Teleport2",
	PortalDestinationFromSecond = "Teleport1",

	-- === Gem generation (see PlotButtonService) ===
	-- Gem income is a WORKER + BUFF model. "Workers" are the base generators; every other
	-- unlocked spawnable is a buff that scales what each worker produces. Per plot, per second:
	--   perWorker = (PlotWorkerBaseGemRate + sum(flat buffs)) * product(multiplier buffs)
	--   gems      = perWorker * (active worker count)   [+ any standalone GemRate generators]
	-- So a flat buff gives every worker +N/s, and a multiplier buff makes every worker earn xN.
	-- With no workers unlocked, buffs produce nothing (there's nothing to scale).

	-- The worker spawnables: unlocked, each contributes PlotWorkerBaseGemRate to the base before
	-- buffs. Identified by Model name (they carry NO attributes). Add more workers here as needed.
	PlotWorkerSpawnables = { Car1 = true, Car2 = true } :: { [string]: boolean },
	PlotWorkerBaseGemRate = 1,

	-- Buff attributes on a (non-worker) Spawnables Model, applied to EVERY active worker:
	--   BaseAdd        (number) -- adds this many Gems/sec to each worker (before the multiplier)
	--   BaseMultiplier (number) -- multiplies each worker's Gems/sec (e.g. 1.2 = +20%); buffs
	--                              stack multiplicatively across spawnables
	PlotSpawnableGemFlatAttribute = "BaseAdd",
	PlotSpawnableGemMultiplierAttribute = "BaseMultiplier",

	-- Optional number attribute for a STANDALONE gem generator (a spawnable that just emits Gems
	-- on its own, independent of the worker/buff model above). Added on top of worker income.
	-- Absent or 0 = nothing. Workers use PlotWorkerBaseGemRate instead, not this.
	PlotSpawnableGemRateAttribute = "GemRate",

	-- Offline (AFK) earnings pay a FRACTION of the online rate: gems/sec divided by this, per second
	-- away (see AfkEarningsService). Shared rather than server-local because the Company UI's
	-- ClaimCard projects a payout at the same reduced rate, and must quote what the server grants.
	OfflineRateDivisor = 15,
	-- The stretch of offline earnings the ClaimCard's "24-Hour Earnings" product pays out, and the
	-- window the ClaimCard's label projects.
	ClaimEarningsSeconds = 86400,

	-- The player's currently accepted job (a businessId) is published to their own
	-- client through this attribute. The client builds wall overlays for whichever
	-- business it names and tears them down when it changes. Cleared (nil) = no job.
	ActiveJobAttribute = "ActiveJob",

	-- Walk speed the owner's character is pinned to for the duration of a job (reasserted if
	-- anything changes it, and reapplied on a mid-job respawn). This is Roblox's default, so
	-- it just holds the line against speed boosts while on the clock. See JobServer.
	JobWalkSpeed = 16,

	-- Part inside each shared business building the player is teleported onto when
	-- they accept that business's job. (Respawns always go back to the player's plot,
	-- never the job.) Lifted by TeleportOffset so the character drops in upright.
	TeleportPartName = "TeleportPart",
	TeleportOffset = Vector3.new(0, 5, 0),

	-- The dirt overlay texture. If it fails to load we fall back to a flat brown.
	DirtAsset = "rbxassetid://103492282492264",

	-- EditableImage resolution (square), in pixels. Lower = cheaper to build/clean,
	-- at lower cleaning resolution (e.g. 256 is 4x less pixel work than 512).
	ImageSize = 512,

	-- Fallback brush radius in studs (world space), used only if a cleaning tool's
	-- per-player Radius isn't available. The live value comes from the player's
	-- DataService Inventory (ToolConfig holds the default), like Range and UseTime.
	BrushWorldRadius = 0.8,

	-- Max world distance (studs) between two consecutive cleaning hits for the
	-- stroke to bridge the gap. Keeps fast strokes hole-free (including across the
	-- seam between two adjacent parts) without smearing an unrelated wall when the
	-- aim genuinely jumps far.
	MaxBridgeWorldDistance = 16.0,

	-- Default fraction (0..1) of the completion bar filled by a business's cleanable stains;
	-- walls fill the rest (1 - this). Used for any business whose BusinessConfig entry doesn't
	-- set its own DecalWeight. Both the client bar (JobClient) and the server's finish-early
	-- payout (JobServer) read this so the two stay in sync.
	DefaultDecalWeight = 0.2,

	-- Fraction (0..1) of the completion bar filled by a business's cleanable SPILLS (mop
	-- targets), when it has any. Used for any business whose BusinessConfig entry doesn't set
	-- its own SpillWeight. Spills carve out this slice; whatever's left (1 - SpillWeight) is
	-- split between walls and decals exactly as before (see CompletionWeights), so a business
	-- with no spills is unaffected. Both the client bar (JobClient) and the server payout
	-- (JobServer) read this through CompletionWeights so the two stay in sync.
	DefaultSpillWeight = 0.2,

	-- Fraction (0..1) of the completion bar filled by a business's cleanable WEBS (vacuum
	-- targets), when it has any. Used for any business whose BusinessConfig entry doesn't set its
	-- own WebWeight. Webs carve out this slice exactly like spills do; a business with no webs is
	-- unaffected (their weight is zeroed and the rest renormalised -- see CompletionWeights). Both
	-- the client bar (JobClient) and the server payout (JobServer) read this so the two stay in sync.
	DefaultWebWeight = 0.2,

	-- Fraction of the dirt that must be erased before a surface counts as clean.
	-- Default for every wall; an individual CleanableWall part can override it with a
	-- numeric "Percentage" attribute (a 0-1 fraction like 0.9, or a 0-100 percentage
	-- like 90 -- values > 1 are read as a percentage).
	CompletionThreshold = 0.975,

	-- Brown fallback, used ONLY if DirtAsset fails to load.
	FallbackColor = Color3.fromRGB(102, 61, 24),
	FallbackTransparency = 0.2,

	-- Flip these if the cleaned spot appears mirrored from where you aim.
	FlipU = false,
	FlipV = false,
}

return CleaningConfig
