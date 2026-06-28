--!strict

-- Shared constants for the pressure-washer cleaning system.
-- Required by both the client (surface overlay + controller) and the server
-- (tool giving + surface spawning) so the tag/id strings never drift apart.

local CleaningConfig = {
	-- CollectionService tag every cleanable BasePart carries.
	SurfaceTag = "CleanableSurface",

	-- Attribute value identifying the pressure washer Tool.
	ToolId = "pressureWasher",

	-- Attributes each cleanable part carries, used to key its saved cleaned state
	-- (BusinessList[BusinessId].CleanedParts[SurfaceId] = true).
	BusinessIdAttribute = "BusinessId",
	SurfaceIdAttribute = "SurfaceId",

	-- The dirt overlay texture. If it fails to load we fall back to a flat brown.
	DirtAsset = "rbxassetid://103492282492264",

	-- EditableImage resolution (square). 512x512.
	ImageSize = 512,

	-- Brush radius in studs (world space). Converted to pixels per surface.
	BrushWorldRadius = 1.0,

	-- Fraction of the dirt that must be erased before a surface counts as clean.
	CompletionThreshold = 0.95,

	-- Max cleaning distance (studs).
	Range = 70,

	-- Brown fallback, used ONLY if DirtAsset fails to load.
	FallbackColor = Color3.fromRGB(102, 61, 24),
	FallbackTransparency = 0.2,

	-- Flip these if the cleaned spot appears mirrored from where you aim.
	FlipU = true,
	FlipV = false,
}

return CleaningConfig
