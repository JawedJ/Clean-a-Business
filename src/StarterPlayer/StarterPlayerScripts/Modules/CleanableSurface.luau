--!nonstrict

-- The dirt overlays for one cleanable BasePart.
--
-- A wall gets ONE overlay PER TEXTURED FACE: every distinct face the part has a Texture on
-- gets its own EditableImage + SurfaceGui, so a part textured on more than one side (a
-- free-standing pillar, a divider visible from both rooms) is dirty on every side the map
-- author textured rather than only the first one found. The map author still controls it
-- purely by texturing the visible sides -- no matter how the part was oriented when the map
-- was built. A wall with no Texture at all falls back to a single overlay on the Left face.
-- Each face's (u,v) axis mapping and brush radius scaling follow that face's own choice, so
-- erasing always tracks the brush whichever side is being washed.
--
-- The part is still ONE cleanable wall, not one per side: progress is aggregated across its
-- faces (dirtyTotal is the per-face total times the face count) so a two-sided wall is half
-- done when one side is clean, and it completes -- for the completion bar, the server's wall
-- tally and the "how many left" readout alike -- only once the whole thing is washed.
--
-- Performance contract (this is the whole reason past attempts went choppy):
--   * The pixel data lives in ONE persistent buffer PER FACE, allocated once at construct.
--   * Erasing mutates that buffer IN PLACE, then does a single WritePixelsBuffer.
--   * There is ZERO per-frame heap allocation, so there is no GC churn to build
--     up over time. The cost of cleaning is constant, not growing.
--   * A stroke only ever touches ONE face -- the one whose plane the sprayed point lies on
--     (pickOverlay) -- so a multi-face wall costs exactly as much per clean as a one-face
--     wall did. Only construction and the reveal glow scale with the face count.
--   * Every surface starts from the SAME dirt image, so the initial pixels and
--     dirty-pixel count are computed ONCE (getTemplate) and cloned per face.
--     Construction therefore does no per-surface DrawImage / ReadPixelsBuffer and
--     no per-surface counting loop -- just a buffer copy + one upload per face.
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
-- These are the SURFACEGUI canvas orientation for each face (right x up = outward
-- normal), so the painted pixels line up with what the SurfaceGui displays. The side
-- faces share the Decal texture frame (anchored on the known-good Left case), but the
-- SurfaceGui canvas on Top/Bottom is rotated 90 degrees relative to a Decal's -- on Top
-- the canvas up points toward -X (verified live: with the old decal-frame Top map the
-- erase tracked 90 degrees off the aim). Bottom mirrors Top by symmetry but is untested
-- (no overlay is authored on a downward face). uComp/vComp also drive the brush-radius
-- scaling, since a world-space circle becomes an ellipse on a non-square face.
local FACE_MAPS = {
	[Enum.NormalId.Left] = { uComp = "Z", uSign = 1, vComp = "Y", vSign = 1 },
	[Enum.NormalId.Right] = { uComp = "Z", uSign = -1, vComp = "Y", vSign = 1 },
	[Enum.NormalId.Front] = { uComp = "X", uSign = -1, vComp = "Y", vSign = 1 },
	[Enum.NormalId.Back] = { uComp = "X", uSign = 1, vComp = "Y", vSign = 1 },
	[Enum.NormalId.Top] = { uComp = "Z", uSign = -1, vComp = "X", vSign = -1 },
	[Enum.NormalId.Bottom] = { uComp = "Z", uSign = 1, vComp = "X", vSign = -1 },
}

-- Which local axis each face's PLANE sits on, and at which end of it (+/- half the part's
-- size on that axis). Only used to route a stroke to the face it landed on -- see pickOverlay.
local FACE_AXES = {
	[Enum.NormalId.Left] = { axis = "X", sign = -1 },
	[Enum.NormalId.Right] = { axis = "X", sign = 1 },
	[Enum.NormalId.Front] = { axis = "Z", sign = -1 },
	[Enum.NormalId.Back] = { axis = "Z", sign = 1 },
	[Enum.NormalId.Top] = { axis = "Y", sign = 1 },
	[Enum.NormalId.Bottom] = { axis = "Y", sign = -1 },
}

-- Used when a wall has no Texture to point us at a face (preserves the old behaviour).
local DEFAULT_FACE = Enum.NormalId.Left

-- How closely a raycast normal must line up with a face's outward normal to count as a hit
-- ON that face (rather than on an edge or the back). 0.99 is ~8 degrees of slop.
local FACE_NORMAL_TOLERANCE = 0.99

-- Reads a named component off a Vector3 (Size or a local point).
local function comp(v: Vector3, axis: string): number
	if axis == "X" then
		return v.X
	elseif axis == "Y" then
		return v.Y
	end
	return v.Z
end

-- Every face the overlay should live on: the face of each of the part's Textures (the visible
-- sides the map author textured), de-duplicated so two Textures stacked on one face still
-- yield a single overlay. Falls back to { Left } for a part with no Texture at all.
local function overlayFaces(part: BasePart): { Enum.NormalId }
	local faces: { Enum.NormalId } = {}
	local seen: { [Enum.NormalId]: boolean } = {}
	for _, child in part:GetChildren() do
		if child:IsA("Texture") and not seen[child.Face] then
			seen[child.Face] = true
			table.insert(faces, child.Face)
		end
	end
	if #faces == 0 then
		table.insert(faces, DEFAULT_FACE)
	end
	return faces
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
-- every FACE starts from. Yields on the first call while the dirt asset loads.
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

-- One face's worth of overlay: its own image, SurfaceGui and pixel buffer. A wall has one of
-- these per textured face, all feeding the wall's aggregate cleanedCount/dirtyTotal.
export type FaceOverlay = {
	face: Enum.NormalId,
	faceMap: { uComp: string, uSign: number, vComp: string, vSign: number },
	image: EditableImage,
	gui: SurfaceGui,
	pixels: buffer,
	-- Reveal-glow display buffer (built lazily by setGlow, dropped when the glow ends).
	-- It's a recolored copy of this face's dirt pixels -- still-dirty pixels pushed toward
	-- neon yellow, cleaned pixels left transparent -- uploaded to the SAME dirt image while
	-- the glow is on (no second overlay, so nothing z-fights). Its alpha is zeroed in
	-- lockstep with the dirt by `stamp`, so the glow shrinks as the player cleans.
	glowBuffer: buffer?,
}

export type CleanableSurface = typeof(setmetatable(
	{} :: {
		part: BasePart,
		-- One entry per textured face, in the order the Textures were found.
		faces: { FaceOverlay },
		-- Summed across every face, so the wall completes only when the WHOLE part is washed.
		dirtyTotal: number,
		cleanedCount: number,
		threshold: number,
		cleaned: boolean,
		glowing: boolean,
		onCleaned: (() -> ())?,
		onProgress: (() -> ())?,
	},
	CleanableSurface
))

-- The fraction of dirt that must be erased before this surface counts as clean.
-- Defaults to the shared Config.CompletionThreshold, but a part can override it with
-- an optional "Percentage" attribute. The attribute may be authored as a 0-1 fraction
-- (e.g. 0.9) or a 0-100 percentage (e.g. 90); values > 1 are treated as a percentage.
-- A Percentage authored as a STRING attribute ("87" instead of 87) used to fall through to the
-- default silently, which reads in game as "the override just doesn't work". We accept a numeric
-- string and warn, so the wall behaves as authored AND the mistype is visible in the output.
local function resolveThreshold(part: BasePart): number
	local pct = part:GetAttribute("Percentage")
	if pct == nil then
		return Config.CompletionThreshold
	end

	local number = if typeof(pct) == "number" then pct else tonumber(pct)
	if not number then
		warn(
			`[CleanableSurface] {part:GetFullName()} has a non-numeric Percentage attribute `
				.. `({typeof(pct)} {pct}); falling back to the default threshold.`
		)
		return Config.CompletionThreshold
	end
	if typeof(pct) ~= "number" then
		warn(
			`[CleanableSurface] {part:GetFullName()} has Percentage authored as a {typeof(pct)}, `
				.. `not a number -- change the attribute's type in Studio.`
		)
	end

	local fraction = if number > 1 then number / 100 else number
	return math.clamp(fraction, 0, 1)
end

-- Build the overlay for ONE face: a persistent pixel buffer cloned off the shared dirt
-- template, an EditableImage holding it, and the SurfaceGui that shows it on that face.
local function buildOverlay(part: BasePart, face: Enum.NormalId, template: buffer): FaceOverlay
	-- Persistent working copy: clone the shared template (a fast buffer copy, not a
	-- per-face DrawImage + read-back), then upload it once.
	local pixels = buffer.create(IMAGE_SIZE * IMAGE_SIZE * 4)
	buffer.copy(pixels, 0, template, 0, buffer.len(template))

	local image = AssetService:CreateEditableImage({ Size = SIZE_VEC })
	image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, pixels)

	-- SurfaceGui instead of a Decal: the engine culls Decals by projected screen size
	-- scaled with graphics quality, so ground overlays vanished at grazing camera angles
	-- -- worst on mobile / in triangle-heavy areas where adaptive quality drops. SurfaceGuis
	-- render in the UI pass and are never quality-culled (and can't z-fight the wall's own
	-- coplanar Texture either). LightInfluence 1 keeps the dirt lit like a decal was.
	-- One per face, and each sits on a different side, so a multi-sided wall's overlays
	-- never overlap.
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(IMAGE_SIZE, IMAGE_SIZE)
	gui.LightInfluence = 1
	gui.AlwaysOnTop = false

	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.ImageContent = Content.fromObject(image)
	label.Parent = gui

	gui.Parent = part

	return {
		face = face,
		faceMap = FACE_MAPS[face],
		image = image,
		gui = gui,
		pixels = pixels,
		glowBuffer = nil,
	}
end

function CleanableSurface.new(part: BasePart): CleanableSurface
	local template, dirtyPerFace = getTemplate()

	local faces: { FaceOverlay } = {}
	for _, face in overlayFaces(part) do
		table.insert(faces, buildOverlay(part, face, template))
	end

	return setmetatable({
		part = part,
		faces = faces,
		-- Every face starts from the same template, so the wall's total dirt is just the
		-- per-face count times however many faces it carries.
		dirtyTotal = dirtyPerFace * #faces,
		cleanedCount = 0,
		threshold = resolveThreshold(part),
		cleaned = false,
		glowing = false,
		onCleaned = nil,
		onProgress = nil,
	}, CleanableSurface)
end

-- Which face a stroke landed on: the one whose PLANE the stroke lies nearest to. A sprayed
-- point sits on the face it hit (distance ~0) and the part's full depth away from the opposite
-- one, so the nearest plane is unambiguous for the two-sided walls this exists for.
--
-- BOTH ends of the stroke are considered, and the closest match across the two wins, because a
-- seam bridge hands us one point that is NOT on this part: washing across a seam calls the new
-- part with the previous point on the old one, and the old part with the new point on the new
-- one. Whichever end is genuinely on this part is the one sitting on a face plane, so taking
-- the minimum picks the right face in both directions.
--
-- Short-circuited for the single-face case, which is still the overwhelming majority of walls.
local function pickOverlay(self: CleanableSurface, worldPos: Vector3, fromWorldPos: Vector3?): FaceOverlay
	local faces = self.faces
	if #faces == 1 then
		return faces[1]
	end

	local cf = self.part.CFrame
	local size = self.part.Size
	local lp = cf:PointToObjectSpace(worldPos)
	local lpFrom = if fromWorldPos then cf:PointToObjectSpace(fromWorldPos) else nil

	local best, bestDist = faces[1], math.huge
	for _, overlay in faces do
		local a = FACE_AXES[overlay.face]
		local plane = a.sign * comp(size, a.axis) * 0.5
		local dist = math.abs(comp(lp, a.axis) - plane)
		if lpFrom then
			dist = math.min(dist, math.abs(comp(lpFrom, a.axis) - plane))
		end
		if dist < bestDist then
			best, bestDist = overlay, dist
		end
	end
	return best
end

-- True if `worldNormal` (a raycast hit normal on this part) points along ANY of the faces
-- this surface has an overlay on -- i.e. the hit landed where dirt actually is, rather than
-- on an edge or an untextured side. Callers use it to reject strokes that would erase nothing.
function CleanableSurface.facesNormal(self: CleanableSurface, worldNormal: Vector3): boolean
	local cf = self.part.CFrame
	for _, overlay in self.faces do
		local faceNormal = cf:VectorToWorldSpace(Vector3.fromNormalId(overlay.face))
		if worldNormal:Dot(faceNormal) >= FACE_NORMAL_TOLERANCE then
			return true
		end
	end
	return false
end

-- World point -> pixel coordinates on `overlay`'s face. Each face resolved its own u/v axes
-- at construct time (overlay.faceMap); u spans uComp, v spans vComp.
local function worldToPixel(self: CleanableSurface, overlay: FaceOverlay, worldPos: Vector3): (number, number)
	local lp = self.part.CFrame:PointToObjectSpace(worldPos)
	local f = overlay.faceMap
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
-- (rx, ry) on `overlay`, in place.
local function stamp(self: CleanableSurface, overlay: FaceOverlay, cxf: number, cyf: number, rx: number, ry: number)
	local pixels = overlay.pixels
	-- If the reveal glow is up, zero its alpha in lockstep so the yellow shrinks with the dirt
	-- (same buffer layout, so the same alpha offset applies to both).
	local glowBuffer = overlay.glowBuffer

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
--
-- The stroke goes to the ONE face it landed on (pickOverlay), so a multi-face wall costs no
-- more per clean than a single-face one. Bridging around the corner between two faces of the
-- same part isn't attempted: they meet at a right angle, so a stroke that rounds a corner
-- simply picks up on the new face at the aim point, exactly as it does when it crosses onto a
-- neighbouring part.
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
	local overlay = pickOverlay(self, worldPos, fromWorldPos)

	-- Circle in world space -> ellipse in pixel space on non-square parts. The
	-- overlay face's u axis spans local uComp and its v axis spans vComp; scale the
	-- radius by each so the brush stays a world-space circle. Computed per call so
	-- the radius can change with tool upgrades.
	local f = overlay.faceMap
	local size = self.part.Size
	local r = worldRadius or Config.BrushWorldRadius
	local rx = r / comp(size, f.uComp) * IMAGE_SIZE
	local ry = r / comp(size, f.vComp) * IMAGE_SIZE

	local cx, cy = worldToPixel(self, overlay, worldPos)
	if fromWorldPos then
		local fx, fy = worldToPixel(self, overlay, fromWorldPos)
		local dx, dy = cx - fx, cy - fy
		local dist = math.sqrt(dx * dx + dy * dy)
		local minR = math.min(rx, ry)
		local steps = math.clamp(math.ceil(dist / (minR * 0.5)), 1, 256)
		for i = 1, steps do
			local t = i / steps
			stamp(self, overlay, fx + dx * t, fy + dy * t, rx, ry)
		end
	else
		stamp(self, overlay, cx, cy, rx, ry)
	end

	-- Single full upload of the ONE face that changed. Constant cost, zero allocation. While
	-- the reveal glow is up we show the recolored buffer (stamp kept its alpha in step with
	-- the dirt); otherwise plain dirt.
	overlay.image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, overlay.glowBuffer or overlay.pixels)

	-- Mark done first so onProgress sees the final state (a finished wall reads as fully
	-- clean, not stuck at the ~0.99 threshold), then report progress, then completion.
	local justCleaned = false
	if self.cleanedCount / self.dirtyTotal >= self.threshold then
		self.cleaned = true
		-- The whole part is done: every face's overlay comes down together.
		for _, o in self.faces do
			o.gui:Destroy()
		end
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

-- Toggle the reveal glow. It recolors the still-dirty pixels of the wall's OWN dirt images
-- toward neon yellow and uploads that to the existing dirt overlays -- there is no extra
-- overlay, so nothing z-fights (two coplanar decals rendered unreliably: some walls showed no
-- glow, others lit up whole). Each face's `pixels` stays the untouched source of truth; on
-- enable we build a recolored copy (`glowBuffer`) PER FACE whose alpha `stamp` keeps in step
-- with the dirt so the yellow shrinks live as the player cleans. On disable (or when the wall
-- finishes) we re-upload the plain dirt and drop the buffers.
--
-- This is the one operation that scales with the face count -- a full recolor + upload each --
-- which is why SurfaceManager drains it under a frame budget rather than flipping every wall
-- at once.
function CleanableSurface.setGlow(self: CleanableSurface, enabled: boolean)
	if self.glowing == enabled then
		return
	end

	if enabled then
		-- Nothing to glow if the wall's already finished (its dirt overlays are gone).
		if self.cleaned then
			return
		end
		for _, overlay in self.faces do
			-- buffer.create zero-inits, so already-clean pixels stay transparent with no write.
			local glowBuffer = buffer.create(IMAGE_SIZE * IMAGE_SIZE * 4)
			local dirt = overlay.pixels
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

			overlay.glowBuffer = glowBuffer
			overlay.image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, glowBuffer)
		end
		self.glowing = true
	else
		self.glowing = false
		for _, overlay in self.faces do
			overlay.glowBuffer = nil
			-- Restore the true dirt look (the images survive until destroy(); the SurfaceGuis
			-- may already be gone on a wall that finished, in which case this upload is
			-- simply invisible).
			if overlay.image then
				overlay.image:WritePixelsBuffer(Vector2.zero, SIZE_VEC, overlay.pixels)
			end
		end
	end
end

function CleanableSurface.destroy(self: CleanableSurface)
	-- Drop the reveal glow first (no-op if it isn't up) so nothing tries to re-upload after.
	self:setGlow(false)
	for _, overlay in self.faces do
		if overlay.gui then
			overlay.gui:Destroy()
		end
		if overlay.image then
			overlay.image:Destroy()
		end
	end
	table.clear(self.faces)
end

return CleanableSurface
