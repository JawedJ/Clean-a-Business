--!strict

-- Client-side class for one cleanable surface.
-- Builds a dirt overlay (EditableImage on a SurfaceGui) on each cleanable FACE of
-- the part and erases it as the player cleans. Pixel data is CLIENT-ONLY and never
-- replicated. When a face reaches SNAP_THRESHOLD coverage it snaps fully clean
-- (dirty -> clean flip). The whole surface is `cleaned` once every face is clean,
-- at which point the caller reports completion to the server.
--
-- Supported faces are FLAT Front/Back (span local X horizontal, Y vertical). The
-- horizontal axis is mirrored between the two faces because they point opposite
-- ways; if the Back face cleans mirrored, swap the u handling in mapUV.

local AssetService = game:GetService("AssetService")

local IMAGE_SIZE = 128
local SNAP_THRESHOLD = 0.9
-- Cleaning brush is a thin rectangle, sized in STUDS (consistent across all faces).
local BRUSH_WORLD_WIDTH = 1.5 -- size along the face's horizontal (right) axis
local BRUSH_WORLD_HEIGHT = 0.3 -- size along the face's vertical (up) axis -- thin

-- Dirt texture. Must be an asset you / the place owner own -- EditableImage refuses
-- assets you lack permission for. Loaded once and baked into the dirt buffer.
local DIRT_TEXTURE = "rbxassetid://103902021413603"

-- Fallback look if the texture fails to load: procedural granite-style grain.
local DIRT_COLOR = Color3.fromRGB(48, 28, 12)
local GRAIN_RANGE = 18 -- +/- brightness of the fine grain
local LIGHT_FLECK_CHANCE = 0.03 -- portion of pixels that are bright flecks
local DARK_FLECK_CHANCE = 0.05 -- portion of pixels that are dark flecks

-- Faces that get a dirt overlay. Default is Front/Back; parts with the
-- `CleanAllSides` attribute set to true use all six faces instead.
local DEFAULT_FACES: { Enum.NormalId } = { Enum.NormalId.Front, Enum.NormalId.Back }
local ALL_FACES: { Enum.NormalId } = {
	Enum.NormalId.Front,
	Enum.NormalId.Back,
	Enum.NormalId.Top,
	Enum.NormalId.Bottom,
	Enum.NormalId.Left,
	Enum.NormalId.Right,
}

-- Object-space axes per face: `right` = direction of increasing image U,
-- `up` = direction that maps to the TOP of the image (v = 0). Front/Back/Left/Right
-- are confirmed; Top/Bottom are derived -- if a horizontal surface cleans rotated
-- or mirrored, tweak its entry here.
local FACE_AXES: { [Enum.NormalId]: { right: Vector3, up: Vector3 } } = {
	[Enum.NormalId.Front] = { right = Vector3.new(-1, 0, 0), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Back] = { right = Vector3.new(1, 0, 0), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Right] = { right = Vector3.new(0, 0, -1), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Left] = { right = Vector3.new(0, 0, 1), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Top] = { right = Vector3.new(0, 0, -1), up = Vector3.new(-1, 0, 0) },
	[Enum.NormalId.Bottom] = { right = Vector3.new(0, 0, -1), up = Vector3.new(1, 0, 0) },
}

type FaceData = {
	face: Enum.NormalId,
	gui: SurfaceGui,
	imageLabel: ImageLabel,
	image: EditableImage,
	totalPixels: number,
	erasedPixels: number,
}

local CleanableSurface = {}
CleanableSurface.__index = CleanableSurface

export type CleanableSurface = typeof(setmetatable(
	{} :: {
		part: BasePart,
		faces: { [Enum.NormalId]: FaceData },
		remaining: number,
		cleaned: boolean,
	},
	CleanableSurface
))

-- The dirt RGBA buffer (from the texture, or granite fallback), built once and
-- reused for every face. Each face gets its own pixel copy on write, so erasing
-- stays independent.
local dirtBuffer: buffer? = nil

-- Procedural granite-grain buffer in DIRT_COLOR (fallback look).
local function buildGraniteBuffer(): buffer
	local baseR = math.round(DIRT_COLOR.R * 255)
	local baseG = math.round(DIRT_COLOR.G * 255)
	local baseB = math.round(DIRT_COLOR.B * 255)

	local buf = buffer.create(IMAGE_SIZE * IMAGE_SIZE * 4)
	local rng = Random.new()
	for i = 0, IMAGE_SIZE * IMAGE_SIZE - 1 do
		local roll = rng:NextNumber()
		local offset: number
		if roll < LIGHT_FLECK_CHANCE then
			offset = rng:NextNumber(40, 90) -- bright mineral flecks
		elseif roll < LIGHT_FLECK_CHANCE + DARK_FLECK_CHANCE then
			offset = -rng:NextNumber(20, 40) -- dark flecks
		else
			offset = rng:NextNumber(-GRAIN_RANGE, GRAIN_RANGE) -- fine grain
		end

		local b = i * 4
		buffer.writeu8(buf, b, math.clamp(baseR + offset, 0, 255))
		buffer.writeu8(buf, b + 1, math.clamp(baseG + offset, 0, 255))
		buffer.writeu8(buf, b + 2, math.clamp(baseB + offset, 0, 255))
		buffer.writeu8(buf, b + 3, 255)
	end
	return buf
end

-- Loads the dirt texture and bakes it into an IMAGE_SIZE buffer. Falls back to
-- procedural granite if the asset can't be loaded. Yields.
local function buildDirtBuffer(): buffer
	local ok, src = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(DIRT_TEXTURE))
	end)
	if not ok or not src then
		warn("[CleanableSurface] dirt texture load failed; using granite fallback:", src)
		return buildGraniteBuffer()
	end

	local temp = AssetService:CreateEditableImage({ Size = Vector2.new(IMAGE_SIZE, IMAGE_SIZE) })
	local scale = Vector2.new(IMAGE_SIZE / src.Size.X, IMAGE_SIZE / src.Size.Y)
	temp:DrawImageTransformed(
		Vector2.new(IMAGE_SIZE / 2, IMAGE_SIZE / 2),
		scale,
		0,
		src,
		{ CombineType = Enum.ImageCombineType.Overwrite }
	)
	return temp:ReadPixelsBuffer(Vector2.zero, Vector2.new(IMAGE_SIZE, IMAGE_SIZE))
end

local function ensureDirtBuffer(): buffer
	local existing = dirtBuffer
	if existing then
		return existing
	end
	local built = buildDirtBuffer()
	dirtBuffer = built
	return built
end

-- Preloads the dirt buffer (yields). Call once before building any surfaces.
function CleanableSurface.preload()
	ensureDirtBuffer()
end

-- Paints dirt onto a fresh (transparent) EditableImage.
local function paintDirt(image: EditableImage)
	image:WritePixelsBuffer(Vector2.zero, Vector2.new(IMAGE_SIZE, IMAGE_SIZE), ensureDirtBuffer())
end

local function makeFace(part: BasePart, face: Enum.NormalId): FaceData
	local gui = Instance.new("SurfaceGui")
	gui.Name = "DirtOverlay_" .. face.Name
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.Parent = part

	local imageLabel = Instance.new("ImageLabel")
	imageLabel.Name = "Dirt"
	imageLabel.BackgroundTransparency = 1
	imageLabel.Size = UDim2.fromScale(1, 1)
	imageLabel.Parent = gui

	-- A fresh EditableImage starts fully transparent; paint mottled dirt onto it.
	local image = AssetService:CreateEditableImage({ Size = Vector2.new(IMAGE_SIZE, IMAGE_SIZE) })
	paintDirt(image)
	imageLabel.ImageContent = Content.fromObject(image)

	return {
		face = face,
		gui = gui,
		imageLabel = imageLabel,
		image = image,
		totalPixels = IMAGE_SIZE * IMAGE_SIZE,
		erasedPixels = 0,
	}
end

function CleanableSurface.new(part: BasePart): CleanableSurface
	local faceList: { Enum.NormalId } = if part:GetAttribute("CleanAllSides") == true then ALL_FACES else DEFAULT_FACES
	local faces: { [Enum.NormalId]: FaceData } = {}
	for _, face in faceList do
		faces[face] = makeFace(part, face)
	end
	return setmetatable({
		part = part,
		faces = faces,
		remaining = #faceList,
		cleaned = false,
	}, CleanableSurface)
end

-- Which face of the part does this world-space hit normal belong to?
local function faceFromNormal(part: BasePart, worldNormal: Vector3): Enum.NormalId
	local n = part.CFrame:VectorToObjectSpace(worldNormal)
	local ax, ay, az = math.abs(n.X), math.abs(n.Y), math.abs(n.Z)
	if ax >= ay and ax >= az then
		return if n.X >= 0 then Enum.NormalId.Right else Enum.NormalId.Left
	elseif ay >= az then
		return if n.Y >= 0 then Enum.NormalId.Top else Enum.NormalId.Bottom
	else
		return if n.Z >= 0 then Enum.NormalId.Back else Enum.NormalId.Front
	end
end

-- Face dimensions in studs along its right (width) and up (height) axes.
local function faceDimensions(part: BasePart, face: Enum.NormalId): (number, number)
	local axes = assert(FACE_AXES[face], "no axes for face")
	local size = part.Size
	local right, up = axes.right, axes.up
	local width = math.abs(right.X) * size.X + math.abs(right.Y) * size.Y + math.abs(right.Z) * size.Z
	local height = math.abs(up.X) * size.X + math.abs(up.Y) * size.Y + math.abs(up.Z) * size.Z
	return width, height
end

-- Map a world-space hit point to image [0,1] UV for the given face.
local function mapUV(part: BasePart, worldPos: Vector3, face: Enum.NormalId): (number, number)
	local axes = assert(FACE_AXES[face], "no axes for face")
	local lp = part.CFrame:PointToObjectSpace(worldPos)
	local width, height = faceDimensions(part, face)
	local u = (lp:Dot(axes.right) + width * 0.5) / width
	local v = (height * 0.5 - lp:Dot(axes.up)) / height -- v = 0 at the top
	return u, v
end

-- Erases the thin-rectangle brush on whichever face the hit belongs to. If
-- `fromWorldPos` is given (a continuous stroke), the brush is stamped along the
-- segment between the two points so fast mouse movement leaves no gaps.
function CleanableSurface.erase(
	self: CleanableSurface,
	worldPos: Vector3,
	worldNormal: Vector3,
	fromWorldPos: Vector3?
)
	if self.cleaned then
		return
	end

	local face = faceFromNormal(self.part, worldNormal)
	local data = self.faces[face]
	if not data then
		-- This face isn't managed (not cleanable) or is already fully cleaned.
		return
	end

	-- Brush half-extents in pixels (consistent world size regardless of face size).
	local width, height = faceDimensions(self.part, face)
	local hw = math.max(0.5, (BRUSH_WORLD_WIDTH * 0.5) / width * IMAGE_SIZE)
	local hh = math.max(0.5, (BRUSH_WORLD_HEIGHT * 0.5) / height * IMAGE_SIZE)

	-- Stroke endpoints in pixel space (start defaults to end = a single stamp).
	local u1, v1 = mapUV(self.part, worldPos, face)
	local cx1 = math.clamp(u1 * (IMAGE_SIZE - 1), 0, IMAGE_SIZE - 1)
	local cy1 = math.clamp(v1 * (IMAGE_SIZE - 1), 0, IMAGE_SIZE - 1)
	local cx0, cy0 = cx1, cy1
	if fromWorldPos then
		local u0, v0 = mapUV(self.part, fromWorldPos, face)
		cx0 = math.clamp(u0 * (IMAGE_SIZE - 1), 0, IMAGE_SIZE - 1)
		cy0 = math.clamp(v0 * (IMAGE_SIZE - 1), 0, IMAGE_SIZE - 1)
	end

	-- One read/write over the bounding box covering the whole swept stroke.
	local bx0 = math.max(0, math.floor(math.min(cx0, cx1) - hw))
	local by0 = math.max(0, math.floor(math.min(cy0, cy1) - hh))
	local bx1 = math.min(IMAGE_SIZE - 1, math.ceil(math.max(cx0, cx1) + hw))
	local by1 = math.min(IMAGE_SIZE - 1, math.ceil(math.max(cy0, cy1) + hh))
	local w = bx1 - bx0 + 1
	local h = by1 - by0 + 1
	if w <= 0 or h <= 0 then
		return
	end

	local region = data.image:ReadPixelsBuffer(Vector2.new(bx0, by0), Vector2.new(w, h))

	-- Stamp the rectangle along the segment at sub-brush spacing (no gaps on fast swipes).
	local dcx = cx1 - cx0
	local dcy = cy1 - cy0
	local dist = math.sqrt(dcx * dcx + dcy * dcy)
	local steps = math.clamp(math.ceil(dist / math.min(hw, hh)), 1, 256)
	for s = 0, steps do
		local t = s / steps
		local cx = cx0 + dcx * t
		local cy = cy0 + dcy * t
		local rx0 = math.max(bx0, math.floor(cx - hw))
		local ry0 = math.max(by0, math.floor(cy - hh))
		local rx1 = math.min(bx1, math.ceil(cx + hw))
		local ry1 = math.min(by1, math.ceil(cy + hh))
		for py = ry0, ry1 do
			local rowBase = (py - by0) * w
			for px = rx0, rx1 do
				local alphaIndex = (rowBase + (px - bx0)) * 4 + 3
				if buffer.readu8(region, alphaIndex) ~= 0 then
					data.erasedPixels += 1
					buffer.writeu8(region, alphaIndex, 0)
				end
			end
		end
	end

	data.image:WritePixelsBuffer(Vector2.new(bx0, by0), Vector2.new(w, h), region)

	if data.erasedPixels / data.totalPixels >= SNAP_THRESHOLD then
		-- Face fully clean: destroy the overlay. This reveals the clean part and,
		-- once the FaceData is dropped, frees the EditableImage memory.
		data.gui:Destroy()
		self.faces[face] = nil
		self.remaining -= 1
		if self.remaining <= 0 then
			self.cleaned = true
		end
	end
end

return CleanableSurface
