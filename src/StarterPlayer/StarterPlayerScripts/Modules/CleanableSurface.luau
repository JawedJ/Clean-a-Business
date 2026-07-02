--!nonstrict

-- One dirt overlay for one cleanable BasePart's LEFT face.
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
		pixels: buffer,
		dirtyTotal: number,
		cleanedCount: number,
		cleaned: boolean,
		onCleaned: (() -> ())?,
		onProgress: (() -> ())?,
	},
	CleanableSurface
))

function CleanableSurface.new(part: BasePart): CleanableSurface
	local template, dirtyTotal = getTemplate()

	-- Persistent working copy: clone the shared template (a fast buffer copy, not a
	-- per-surface DrawImage + read-back), then upload it once.
	local pixels = buffer.create(IMAGE_SIZE * IMAGE_SIZE * 4)
	buffer.copy(pixels, 0, template, 0, buffer.len(template))

	local image = AssetService:CreateEditableImage({ Size = SIZE_VEC })
	image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, pixels)

	local decal = Instance.new("Decal")
	decal.Face = Enum.NormalId.Left
	decal.TextureContent = Content.fromObject(image)
	decal.Parent = part

	return setmetatable({
		part = part,
		image = image,
		decal = decal,
		pixels = pixels,
		dirtyTotal = dirtyTotal,
		cleanedCount = 0,
		cleaned = false,
		onCleaned = nil,
		onProgress = nil,
	}, CleanableSurface)
end

-- World point -> pixel coordinates on the left face (spans local Z and Y).
local function worldToPixel(self: CleanableSurface, worldPos: Vector3): (number, number)
	local lp = self.part.CFrame:PointToObjectSpace(worldPos)
	local u = lp.Z / self.part.Size.Z + 0.5
	local v = 0.5 - lp.Y / self.part.Size.Y
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

	-- Circle in world space -> ellipse in pixel space on non-square parts.
	-- Left face spans local Z (depth, u) and local Y (height, v). Computed per
	-- call so the radius can change with tool upgrades.
	local r = worldRadius or Config.BrushWorldRadius
	local rx = r / self.part.Size.Z * IMAGE_SIZE
	local ry = r / self.part.Size.Y * IMAGE_SIZE

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

	-- Single full upload. Constant cost, zero allocation.
	self.image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, self.pixels)

	-- Mark done first so onProgress sees the final state (a finished wall reads as fully
	-- clean, not stuck at the ~0.99 threshold), then report progress, then completion.
	local justCleaned = false
	if self.cleanedCount / self.dirtyTotal >= Config.CompletionThreshold then
		self.cleaned = true
		self.decal:Destroy()
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

function CleanableSurface.destroy(self: CleanableSurface)
	if self.decal then
		self.decal:Destroy()
	end
	if self.image then
		self.image:Destroy()
	end
end

return CleanableSurface
