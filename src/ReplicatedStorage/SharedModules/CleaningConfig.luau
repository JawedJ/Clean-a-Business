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

	-- Cleanable GARBAGE (carryable litter) lives alongside the walls + stains + webs:
	--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableGarbage.<garbage>
	-- Each <garbage> is the direct child of the folder carrying a GarbageSurfaceIdAttribute, and --
	-- like a web -- may be authored as a single BasePart (a mesh/part IS the target) OR as a Model
	-- grouping parts; GarbageResolver climbs to the folder child either way.
	--
	-- Garbage is not cleaned in place: the player walks up to it and CARRIES it (see
	-- GarbageCarryService / GarbageCarryController), floating it AROUND their crosshair -- up to
	-- GarbageCarryLimit pieces at once, ringed so the centre of the screen stays clear -- until they
	-- let go. The carrier owns it on the network, so its movement replicates to everyone without a
	-- per-frame remote.
	--
	-- A piece is ALWAYS unanchored and always collides with the building: that's what stops a player
	-- walking their piece through a wall and out of the map, and what makes a dropped piece fall and
	-- settle on the floor. What it never collides with is a CHARACTER -- every piece sits in its own
	-- collision group that ignores the players' one (see GarbageCarryService), so garbage can't
	-- shove, trap or be stood on by anyone. Left alone for GarbageResetSeconds, a piece returns to
	-- the position it was authored at.
	GarbageFolderName = "CleanableGarbage",
	-- Attribute holding a piece of garbage's unique id. Capitalised "SurfaceId" -- the same spelling
	-- the spill models use, and how the garbage is authored in Studio.
	GarbageSurfaceIdAttribute = "SurfaceId",
	-- How close (studs, character root -> the garbage's position) the player must be to pick a piece
	-- up. The server re-checks this with a small tolerance for lag.
	GarbagePickupRange = 13,
	-- Extra reach (studs) for TOUCH devices only. Aiming with a finger on a small screen is far less
	-- precise than with a cursor, so mobile players get to grab a piece from further back rather than
	-- having to walk right on top of it.
	--
	-- The SERVER can't tell a phone from a desktop -- device type is a client claim, and one worth
	-- nothing -- so its range check allows this bonus for EVERYONE. That is the deliberate trade: the
	-- validation exists to stop pickups from across the building, which 13 + 12 + slack still does,
	-- and the worst a desktop player gains by faking it is a reach that mobile has anyway.
	GarbagePickupRangeTouchBonus = 12,
	-- How close the player must be for a piece to light up under the crosshair. Kept as its own knob
	-- (rather than reusing the pickup range) so the outline can be pulled in independently later; at
	-- the same value, everything you can pick up also lights up.
	GarbageHoverRange = 13,
	-- How far in front of the crosshair (studs, from the camera along the aim ray) carried garbage is
	-- pulled toward -- i.e. how far out from the player the piece floats while held.
	GarbageCarryDistance = 7,
	-- How many pieces a player may hold at once. They float in a ring around the crosshair rather
	-- than in front of it -- one above it, two either side of it, three in a triangle about it -- so
	-- the centre of the screen stays clear for aiming at (and picking up) the next piece. The server
	-- enforces this too; the client only stops asking. See GarbageCarryController's slot layout.
	GarbageCarryLimit = 3,
	-- The clear space (studs) held pieces are given: how far the NEAREST FACE of a held piece is kept
	-- from the crosshair, and how much air is left between two neighbouring pieces in the ring. Both
	-- are measured off the pieces' own sizes (like the shredder queue's gap), so a bin bag and a
	-- crumpled can are both spaced properly rather than one overlapping and the other floating away.
	--
	-- The clearance is deliberately SMALL: a single held piece should sit just clear of the crosshair,
	-- close enough to read as being held in front of the player rather than parked at the top of the
	-- screen. It's measured along the direction the piece actually sits in (so the height of a piece
	-- hovering above the crosshair, not its longest side), which is what lets it be this tight.
	GarbageCarryClearStuds = 0.25,
	GarbageCarryGapStuds = 0.6,
	-- How long (seconds) a piece sits untouched where it was dropped before it returns to the
	-- position it was authored at. Restarts on every pickup/drop, so a piece being worked with is
	-- never yanked out from under the player.
	GarbageResetSeconds = 60,

	-- === The Shredder: how a piece of garbage is actually CLEANED ===
	-- Every business that has cleanable garbage authors one shredder model directly in the building:
	--   Workspace.<BusinessesFolderName>.<businessId>.<ShredderModelName>
	-- holding three invisible parts: a Hitbox the garbage is fed into, and two markers p1/p2 the
	-- piece is drawn through on its way in. Touching the hitbox with a piece takes it out of the
	-- player's hands and runs the disposal animation (see GarbageShredController), after which the
	-- piece is gone and counts toward the job (GarbageShredService -> JobServer.markGarbageCleaned).
	ShredderModelName = "Shredder",
	-- The part a piece has to touch to be fed in. Named the same as the stains'/spills' hitbox.
	ShredderHitboxName = "Hitbox",
	-- The two markers the piece is pulled through: p1 is the mouth (where it's held for a beat) and
	-- p2 is inside/below the machine (where it's destroyed).
	ShredderEntryPartName = "p1",
	ShredderExitPartName = "p2",
	-- The disposal animation's three beats, in seconds: snap to the mouth, hold there, then get
	-- dragged down through the blades (shaking violently) and vanish. Shared rather than
	-- client-local because the SERVER waits out the same total before marking the piece cleaned, so
	-- the completion bar ticks as the piece disappears rather than as it starts moving.
	GarbageShredEntrySeconds = 0.3,
	GarbageShredHoldSeconds = 0.45,
	GarbageShredDropSeconds = 2,
	-- The SFX (ReplicatedStorage.Audios.SFX.<name>). It covers the DESCENT -- cut off the instant the
	-- piece is shredded -- because the sound is the machine chewing, and that's the beat where it's
	-- being chewed. Played POSITIONALLY, out of the shredder's hitbox (see SoundManager.playAt), so
	-- it fades with distance like the machine it's coming from.
	ShredderSoundName = "ShredderSFX",
	-- How far into the HOLD the sound starts, ahead of the descent it belongs to. The file opens on
	-- the machine spinning up, so starting it dead on the drop puts the bite after the piece is
	-- already moving; this much lead lands the two together. Clamped to the hold's own length.
	GarbageShredSoundLeadSeconds = 0.3,
	-- Played the moment the machine ACCEPTS a piece -- whether it goes straight down or joins the
	-- queue above the mouth. Unlike ShredderSoundName this one is 2D and belongs to the PLAYER, not
	-- the machine: it's the feedback for "that went in", so only the player who walked the piece in
	-- hears it. A party member feeding their own piece into the same shredder doesn't play it for
	-- everyone else (see GarbageShredController -- the `reported` set is exactly this client's own).
	GarbageFeedSoundName = "woosh",
	-- The QUEUE. The machine chews one piece from start to finish, so anything fed in while it's
	-- busy leaves its carrier's hands anyway and hovers in a vertical line above the mouth (p1),
	-- lowest first, waiting its turn (see GarbageShredController).
	--
	-- The gap is the CLEAR SPACE between pieces -- measured between their bounding boxes, not their
	-- pivots -- so a bin bag and a crumpled can are spaced the same and neither can overlap the
	-- other. The same gap separates the lowest waiting piece from whatever is at the mouth.
	GarbageQueueGapStuds = 0.3,
	-- How long a piece takes to float up into its slot, and to shuffle down when the piece beneath
	-- it is taken. Short on purpose: the queue should read as a line stepping down, not as garbage
	-- drifting about above the machine.
	GarbageQueueTravelSeconds = 0.35,

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

	-- Fraction (0..1) of the completion bar filled by a business's cleanable GARBAGE, when it has
	-- any. Used for any business whose BusinessConfig entry doesn't set its own GarbageWeight.
	-- Garbage carves out this slice exactly like spills and webs do; a business with no garbage is
	-- unaffected (its weight is zeroed and the rest renormalised -- see CompletionWeights).
	DefaultGarbageWeight = 0.2,

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
