--!strict

-- Shared constants for the pressure-washer cleaning system.
-- Required by both the client (surface overlay + controller) and the server
-- (tool giving + surface spawning) so the tag/id strings never drift apart.

-- Tool identity (the "ToolId" attribute on each Tool) and per-tool stats
-- (Range, UseTime, Power) are NOT here -- they live in ToolConfig as defaults and,
-- at runtime, in each player's DataService Inventory so they can change with
-- upgrades. This module holds only mechanic-wide constants.
local CleaningConfig = {
	-- Cleanable walls live in the workspace under each plot:
	--   Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableWalls.<part>
	-- The business folder's name is the BusinessId and the part's name is the
	-- SurfaceId used to key saved cleaned state
	-- (BusinessList[BusinessId].CleanedParts[SurfaceId] = true).
	BusinessesFolderName = "Businesses",
	CleanablesFolderName = "Cleanables",
	WallsFolderName = "CleanableWalls",

	-- Cleanable stains (broom targets) live alongside the walls under each plot:
	--   Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableDecals.<model>
	-- Each <model> has a child BasePart named HitboxName the player clicks, and a
	-- SurfaceIdAttribute attribute whose value is the stain's id, used to key saved
	-- cleaned state (BusinessList[BusinessId].CleanedStains[SurfaceId] = true).
	DecalsFolderName = "CleanableDecals",
	HitboxName = "Hitbox",
	SurfaceIdAttribute = "surfaceId",

	-- Plots are direct children of Workspace named Plot1..Plot(PlotCount). Each
	-- joining player is assigned one and may only clean walls within it. The
	-- assigned plot's name is published to the owner via this player attribute.
	PlotCount = 8,
	PlotAttribute = "Plot",

	-- Part inside each plot folder the owner's character is teleported onto when
	-- they're assigned the plot and whenever they respawn.
	PlotSpawnPartName = "spawnPart",

	-- Business templates (Models named after their businessId) live in
	-- ReplicatedStorage.<BusinessesFolderName>. On assignment, each owned business
	-- is cloned into the plot's Businesses folder and pivoted onto its spawn part,
	-- which lives in the plot's SpawnsFolderName folder and is named
	-- <businessId> .. SpawnSuffix (e.g. "mcDonaldsSpawn").
	SpawnsFolderName = "BusinessSpawns",
	SpawnSuffix = "Spawn",

	-- Reference part inside each business template. The business is translated so
	-- this part lands exactly on its spawn point (orientation kept as authored).
	BusinessBasePartName = "BasePart",

	-- The dirt overlay texture. If it fails to load we fall back to a flat brown.
	DirtAsset = "rbxassetid://103492282492264",

	-- EditableImage resolution (square), in pixels. Lower = cheaper to build/clean,
	-- at lower cleaning resolution (e.g. 256 is 4x less pixel work than 512).
	ImageSize = 512,

	-- Fallback brush radius in studs (world space), used only if a cleaning tool's
	-- per-player Radius isn't available. The live value comes from the player's
	-- DataService Inventory (ToolConfig holds the default), like Range and UseTime.
	BrushWorldRadius = 1.0,

	-- Max world distance (studs) between two consecutive cleaning hits for the
	-- stroke to bridge the gap. Keeps fast strokes hole-free (including across the
	-- seam between two adjacent parts) without smearing an unrelated wall when the
	-- aim genuinely jumps far.
	MaxBridgeWorldDistance = 16.0,

	-- Fraction of the dirt that must be erased before a surface counts as clean.
	CompletionThreshold = 0.99,

	-- Brown fallback, used ONLY if DirtAsset fails to load.
	FallbackColor = Color3.fromRGB(102, 61, 24),
	FallbackTransparency = 0.2,

	-- Flip these if the cleaned spot appears mirrored from where you aim.
	FlipU = false,
	FlipV = false,
}

return CleaningConfig
