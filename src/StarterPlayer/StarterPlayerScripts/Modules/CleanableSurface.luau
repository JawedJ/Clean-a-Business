--!nonstrict

-- One dirt overlay for one cleanable BasePart.
--
-- The overlay goes on whichever face the wall's own Texture faces, so the map author
-- controls it just by texturing the visible side -- no matter how the part was oriented
-- when the map was built. A wall with no Texture falls back to the Left face. The face's
-- (u,v) axis mapping and the brush radius scaling both follow that same choice, so
-- erasing always tracks the brush.
--
-- Performance contract (this is the whole reason past attempts went choppy):
--   * The pixel data lives in ONE persistent buffer, allocated once at construct.
--   * Erasing mutates that buffer IN PLACE, then does a single WritePixelsBuffer.
--   * There is ZERO per-frame heap allocation, so there is no GC churn to build
--     up over time. The cost of cleaning is constant, not growing.
--   * Every surface starts from the SAME dirt image, so the initial pixels and
--     dirty-pixel count are computed ONCE (getTemplate) and cloned per surface.
--     Construction therefore does no per-surface DrawImage / ReadPixelsBuffer and
--     no per-surface counting loop -- just a buffer copy + one upload.
--
-- (nonstrict: the EditableImage / Content APIs aren't fully covered by the Luau
--  type solver yet, and casting every call would just add noise.)

local AssetService = game:GetService("AssetService")

local Config = require(game.ReplicatedStorage.SharedModules.CleaningConfig)

local IMAGE_SIZE = Config.ImageSize
local SIZE_VEC = Vector2.new(IMAGE_SIZE, IMAGE_SIZE)

-- How each face maps a local point to overlay pixels:
--   * `uComp`/`uSign` say image-right (+u) runs along uSign * local uComp axis.
--   * `vComp`/`vSign` say image-up runs along vSign * local vComp axis (v is
--     image-DOWN, so v = 0.5 - vSign * lp[vComp] / Size[vComp]).
-- These are Roblox's own decal texture orientation for each face (right x up =
-- outward normal), anchored on the known-good Left case, so the painted pixels line
-- up with what the Decal displays. uComp/vComp also drive the brush-radius scaling,
-- since a world-space circle becomes an ellipse on a non-square face.
local FACE_MAPS = {
	[Enum.NormalId.Left] = { uComp = "Z", uSign = 1, vComp = "Y", vSign = 1 },
	[Enum.NormalId.Right] = { uComp = "Z", uSign = -1, vComp = "Y", vSign = 1 },
	[Enum.NormalId.Front] = { uComp = "X", uSign = -1, vComp = "Y", vSign = 1 },
	[Enum.NormalId.Back] = { uComp = "X", uSign = 1, vComp = "Y", vSign = 1 },
	[Enum.NormalId.Top] = { uComp = "X", uSign = -1, vComp = "Z", vSign = 1 },
	[Enum.NormalId.Bottom] = { uComp = "X", uSign = 1, vComp = "Z", vSign = 1 },
}
-- Used when a wall has no Texture to point us at a face (preserves the old behaviour).
local DEFAULT_FACE = Enum.NormalId.Left

-- Reads a named component off a Vector3 (Size or a local point).
local function comp(v: Vector3, axis: string): number
	if axis == "X" then
		return v.X
	elseif axis == "Y" then
		return v.Y
	end
	return v.Z
end

-- The face the overlay should live on: the face of the part's own Texture (the visible
-- side the map author textured), or Left if the part has no Texture.
local function overlayFace(part: BasePart): Enum.NormalId
	for _, child in part:GetChildren() do
		if child:IsA("Texture") then
			return child.Face
		end
	end
	return DEFAULT_FACE
end

-- The dirt source is downloaded once and shared by every surface.
local cachedSource: EditableImage? = nil
local cacheFailed = false

local function getSource(): EditableImage?
	if cachedSource then
		return cachedSource
	end
	if cacheFailed then
		return nil
	end
	local ok, source = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(Config.DirtAsset))
	end)
	if ok and source then
		cachedSource = source
	else
		cacheFailed = true
	end
	return cachedSource
end

-- Draws the dirt texture onto `image`, scaling to fill if needed. Returns false
-- if the asset couldn't be loaded/drawn (caller then uses the brown fallback).
local function loadDirt(image: EditableImage): boolean
	local source = getSource()
	if not source then
		return false
	end
	return (pcall(function()
		local s = source.Size
		if s.X == IMAGE_SIZE and s.Y == IMAGE_SIZE then
			image:DrawImage(Vector2.zero, source, Enum.ImageCombineType.Overwrite)
		else
			image:DrawImageTransformed(
				Vector2.new(IMAGE_SIZE / 2, IMAGE_SIZE / 2),
				Vector2.new(IMAGE_SIZE / s.X, IMAGE_SIZE / s.Y),
				0,
				source,
				{ CombineType = Enum.ImageCombineType.Overwrite }
			)
		end
	end))
end

-- The initial dirt pixels shared by every surface, built once on first use.
local templatePixels: buffer? = nil
local templateDirtyTotal = 0

-- Fills `image` with the flat brown fallback at the configured transparency.
local function fillBrown(image: EditableImage)
	local c = Config.FallbackColor
	local r = math.floor(c.R * 255 + 0.5)
	local g = math.floor(c.G * 255 + 0.5)
	local b = math.floor(c.B * 255 + 0.5)
	local a = math.floor((1 - Config.FallbackTransparency) * 255 + 0.5)

	local px = buffer.create(IMAGE_SIZE * IMAGE_SIZE * 4)
	for i = 0, IMAGE_SIZE * IMAGE_SIZE - 1 do
		local o = i * 4
		buffer.writeu8(px, o, r)
		buffer.writeu8(px, o + 1, g)
		buffer.writeu8(px, o + 2, b)
		buffer.writeu8(px, o + 3, a)
	end
	image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, px)
end

-- Builds (once) and returns the dirt pixel buffer + its dirty-pixel count that
-- every surface starts from. Yields on the first call while the dirt asset loads.
local function getTemplate(): (buffer, number)
	if templatePixels then
		return templatePixels, templateDirtyTotal
	end

	-- Draw the initial dirt onto a throwaway image and read it back once.
	local scratch = AssetService:CreateEditableImage({ Size = SIZE_VEC })
	if not loadDirt(scratch) then
		fillBrown(scratch)
	end
	local px = scratch:ReadPixelsBuffer(Vector2.zero, SIZE_VEC)
	scratch:Destroy()

	local dirty = 0
	for i = 0, IMAGE_SIZE * IMAGE_SIZE - 1 do
		if buffer.readu8(px, i * 4 + 3) ~= 0 then
			dirty += 1
		end
	end

	templatePixels = px
	templateDirtyTotal = math.max(dirty, 1)
	return px, templateDirtyTotal
end

local CleanableSurface = {}
CleanableSurface.__index = CleanableSurface

export type CleanableSurface = typeof(setmetatable(
	{} :: {
		part: BasePart,
		image: EditableImage,
		decal: Decal,
		face: Enum.NormalId,
		faceMap: { uComp: string, uSign: number, vComp: string, vSign: number },
		pixels: buffer,
		dirtyTotal: number,
		cleanedCount: number,
		threshold: number,
		cleaned: boolean,
		glowing: boolean,
		-- Reveal-glow display buffer (built lazily by setGlow, dropped when the glow ends).
		-- It's a recolored copy of the dirt pixels -- still-dirty pixels pushed toward neon
		-- yellow, cleaned pixels left transparent -- uploaded to the SAME dirt image/decal
		-- while the glow is on (no second decal, so nothing z-fights). Its alpha is zeroed in
		-- lockstep with the dirt by `stamp`, so the glow shrinks as the player cleans.
		glowBuffer: buffer?,
		onCleaned: (() -> ())?,
		onProgress: (() -> ())?,
	},
	CleanableSurface
))

-- The fraction of dirt that must be erased before this surface counts as clean.
-- Defaults to the shared Config.CompletionThreshold, but a part can override it with
-- an optional "Percentage" attribute. The attribute may be authored as a 0-1 fraction
-- (e.g. 0.9) or a 0-100 percentage (e.g. 90); values > 1 are treated as a percentage.
local function resolveThreshold(part: BasePart): number
	local pct = part:GetAttribute("Percentage")
	if typeof(pct) ~= "number" then
		return Config.CompletionThreshold
	end
	local fraction = if pct > 1 then pct / 100 else pct
	return math.clamp(fraction, 0, 1)
end

function CleanableSurface.new(part: BasePart): CleanableSurface
	local face = overlayFace(part)
	local faceMap = FACE_MAPS[face]
	local template, dirtyTotal = getTemplate()

	-- Persistent working copy: clone the shared template (a fast buffer copy, not a
	-- per-surface DrawImage + read-back), then upload it once.
	local pixels = buffer.create(IMAGE_SIZE * IMAGE_SIZE * 4)
	buffer.copy(pixels, 0, template, 0, buffer.len(template))

	local image = AssetService:CreateEditableImage({ Size = SIZE_VEC })
	image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, pixels)

	local decal = Instance.new("Decal")
	decal.Face = face
	decal.TextureContent = Content.fromObject(image)
	decal.Parent = part

	return setmetatable({
		part = part,
		image = image,
		decal = decal,
		face = face,
		faceMap = faceMap,
		pixels = pixels,
		dirtyTotal = dirtyTotal,
		cleanedCount = 0,
		threshold = resolveThreshold(part),
		cleaned = false,
		glowing = false,
		glowBuffer = nil,
		onCleaned = nil,
		onProgress = nil,
	}, CleanableSurface)
end

-- World point -> pixel coordinates on the overlay face. The face's u/v axes were
-- resolved at construct time (self.faceMap); u spans uComp, v spans vComp.
local function worldToPixel(self: CleanableSurface, worldPos: Vector3): (number, number)
	local lp = self.part.CFrame:PointToObjectSpace(worldPos)
	local f = self.faceMap
	local size = self.part.Size
	local u = 0.5 + f.uSign * comp(lp, f.uComp) / comp(size, f.uComp)
	local v = 0.5 - f.vSign * comp(lp, f.vComp) / comp(size, f.vComp)
	if Config.FlipU then
		u = 1 - u
	end
	if Config.FlipV then
		v = 1 - v
	end
	return u * IMAGE_SIZE, v * IMAGE_SIZE
end

-- Erases one elliptical stamp centered at pixel (cxf, cyf) with pixel radii
-- (rx, ry), in place.
local function stamp(self: CleanableSurface, cxf: number, cyf: number, rx: number, ry: number)
	local pixels = self.pixels
	-- If the reveal glow is up, zero its alpha in lockstep so the yellow shrinks with the dirt
	-- (same buffer layout, so the same alpha offset applies to both).
	local glowBuffer = self.glowBuffer

	local x0 = math.max(0, math.floor(cxf - rx))
	local x1 = math.min(IMAGE_SIZE - 1, math.ceil(cxf + rx))
	local y0 = math.max(0, math.floor(cyf - ry))
	local y1 = math.min(IMAGE_SIZE - 1, math.ceil(cyf + ry))

	local count = 0
	for py = y0, y1 do
		local ndy = (py - cyf) / ry
		local ndy2 = ndy * ndy
		local rowBase = py * IMAGE_SIZE
		for px = x0, x1 do
			local ndx = (px - cxf) / rx
			if ndx * ndx + ndy2 <= 1 then
				local a = (rowBase + px) * 4 + 3
				if buffer.readu8(pixels, a) ~= 0 then
					buffer.writeu8(pixels, a, 0)
					if glowBuffer then
						buffer.writeu8(glowBuffer, a, 0)
					end
					count += 1
				end
			end
		end
	end
	self.cleanedCount += count
end

-- Cleans at `worldPos` with brush radius `worldRadius` (studs). If `fromWorldPos`
-- is given, fills the gap between the previous point and this one so fast strokes
-- leave no holes.
function CleanableSurface.clean(
	self: CleanableSurface,
	worldPos: Vector3,
	fromWorldPos: Vector3?,
	worldRadius: number?
)
	if self.cleaned then
		return
	end

	local erasedBefore = self.cleanedCount

	-- Circle in world space -> ellipse in pixel space on non-square parts. The
	-- overlay face's u axis spans local uComp and its v axis spans vComp; scale the
	-- radius by each so the brush stays a world-space circle. Computed per call so
	-- the radius can change with tool upgrades.
	local f = self.faceMap
	local size = self.part.Size
	local r = worldRadius or Config.BrushWorldRadius
	local rx = r / comp(size, f.uComp) * IMAGE_SIZE
	local ry = r / comp(size, f.vComp) * IMAGE_SIZE

	local cx, cy = worldToPixel(self, worldPos)
	if fromWorldPos then
		local fx, fy = worldToPixel(self, fromWorldPos)
		local dx, dy = cx - fx, cy - fy
		local dist = math.sqrt(dx * dx + dy * dy)
		local minR = math.min(rx, ry)
		local steps = math.clamp(math.ceil(dist / (minR * 0.5)), 1, 256)
		for i = 1, steps do
			local t = i / steps
			stamp(self, fx + dx * t, fy + dy * t, rx, ry)
		end
	else
		stamp(self, cx, cy, rx, ry)
	end

	-- Single full upload. Constant cost, zero allocation. While the reveal glow is up we show
	-- the recolored buffer (stamp kept its alpha in step with the dirt); otherwise plain dirt.
	self.image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, self.glowBuffer or self.pixels)

	-- Mark done first so onProgress sees the final state (a finished wall reads as fully
	-- clean, not stuck at the ~0.99 threshold), then report progress, then completion.
	local justCleaned = false
	if self.cleanedCount / self.dirtyTotal >= self.threshold then
		self.cleaned = true
		self.decal:Destroy()
		-- The wall's done -- tear the glow overlay down with it.
		self:setGlow(false)
		justCleaned = true
	end

	-- Only signal when dirt actually came off, so the completion bar tracks the wash live
	-- but idle aiming at clean pixels costs nothing.
	if self.cleanedCount > erasedBefore and self.onProgress then
		self.onProgress()
	end

	if justCleaned and self.onCleaned then
		self.onCleaned()
	end
end

-- Reveal glow: still-dirty pixels are pushed toward neon yellow.
local GLOW_COLOR = Color3.fromRGB(255, 234, 0)
-- How hard dirty pixels are pulled toward the glow color (0 = untouched dirt, 1 = solid
-- yellow). Kept below 1 so the dirt texture still reads through as a highlight, not repaint.
local GLOW_BLEND = 0.15

local GLOW_R = math.floor(GLOW_COLOR.R * 255 + 0.5)
local GLOW_G = math.floor(GLOW_COLOR.G * 255 + 0.5)
local GLOW_B = math.floor(GLOW_COLOR.B * 255 + 0.5)

-- Toggle the reveal glow. It recolors the still-dirty pixels of the wall's OWN dirt image
-- toward neon yellow and uploads that to the existing dirt decal -- there is no second decal,
-- so nothing z-fights (two coplanar decals rendered unreliably: some walls showed no glow,
-- others lit up whole). `self.pixels` stays the untouched source of truth; on enable we build
-- a recolored copy (`glowBuffer`) whose alpha `stamp` keeps in step with the dirt so the yellow
-- shrinks live as the player cleans. On disable (or when the wall finishes) we re-upload the
-- plain dirt and drop the buffer.
function CleanableSurface.setGlow(self: CleanableSurface, enabled: boolean)
	if self.glowing == enabled then
		return
	end

	if enabled then
		-- Nothing to glow if the wall's already finished (its dirt overlay is gone).
		if self.cleaned or not self.decal then
			return
		end
		-- buffer.create zero-inits, so already-clean pixels stay transparent with no write.
		local glowBuffer = buffer.create(IMAGE_SIZE * IMAGE_SIZE * 4)
		local dirt = self.pixels
		for i = 0, IMAGE_SIZE * IMAGE_SIZE - 1 do
			local o = i * 4
			local a = buffer.readu8(dirt, o + 3)
			if a ~= 0 then
				local r = buffer.readu8(dirt, o)
				local g = buffer.readu8(dirt, o + 1)
				local b = buffer.readu8(dirt, o + 2)
				buffer.writeu8(glowBuffer, o, r + math.floor((GLOW_R - r) * GLOW_BLEND + 0.5))
				buffer.writeu8(glowBuffer, o + 1, g + math.floor((GLOW_G - g) * GLOW_BLEND + 0.5))
				buffer.writeu8(glowBuffer, o + 2, b + math.floor((GLOW_B - b) * GLOW_BLEND + 0.5))
				buffer.writeu8(glowBuffer, o + 3, a)
			end
		end

		self.glowBuffer = glowBuffer
		self.image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, glowBuffer)
		self.glowing = true
	else
		self.glowBuffer = nil
		self.glowing = false
		-- Restore the true dirt look (image survives until destroy(); decal may already be gone
		-- on a wall that finished, in which case this upload is simply invisible).
		if self.image then
			self.image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, self.pixels)
		end
	end
end

function CleanableSurface.destroy(self: CleanableSurface)
	-- Drop the reveal glow first (no-op if it isn't up) so nothing tries to re-upload after.
	self:setGlow(false)
	if self.decal then
		self.decal:Destroy()
	end
	if self.image then
		self.image:Destroy()
	end
end

return CleanableSurface
