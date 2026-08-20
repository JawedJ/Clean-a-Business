--!strict

-- Owns every piece of cleanable garbage the LOCAL player can see and touch. Unlike the other
-- cleanables, garbage MOVES -- and that is why it can't be the shared, server-replicated instance
-- the walls, stains, spills and webs are.
--
-- THE PROBLEM. Two players (or two parties) can work the same building at the same time. A shared
-- instance has ONE position for the whole server, so one player carrying a piece drags it out from
-- under everyone else's run, and one player starting a job resets pieces mid-run for the others.
-- The rest of the cleanables dodge this by never moving: the instance is shared and each client
-- merely hides or shows its own view of it.
--
-- THE ANSWER. The server's authored pieces are never seen and never move -- they're the template.
-- Every client hides them all off-world, and when a job starts, CLONES this business's pieces into
-- the very same CleanableGarbage folder they came from. A clone exists only on this machine, so it
-- is this session's own garbage: carrying it, dropping it and resetting it are invisible to every
-- other session, and a job start rebuilds the whole set at their authored positions -- which is
-- exactly the fresh slate re-accepting a job gives the stains and webs.
--
-- Cloning them IN PLACE (rather than into some local folder) is what keeps GarbageResolver working
-- unchanged: a clone sits at the same path, under the same business, carrying the same SurfaceId, so
-- every other system resolves it exactly as it would have resolved the original.
--
-- A party still sees each other's carries: the carrier relays its piece's CFrame and the other
-- members drive their OWN clone of the same surfaceId from it (see GarbageCarryController).

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local GarbageResolver = require(ReplicatedStorage.SharedModules.GarbageResolver)

local GarbageVisibility = {}

-- Collision group the clones live in: everything as normal EXCEPT characters, so a piece can never
-- push a player around or be stood on. Registered in the place (and re-asserted by
-- GarbageCarryService), so it's available to set from here.
local GARBAGE_GROUP = "CleanableGarbage"

-- Marks an instance as one of our local clones, so the scan below never mistakes one for an authored
-- piece and counts or hides it.
local CLONE_ATTRIBUTE = "LocalGarbageClone"

-- Off-world holder for the authored pieces. Its Parent stays nil so its contents aren't rendered or
-- raycastable; this module's reference keeps them alive as the templates we clone from.
local holder = Instance.new("Folder")
holder.Name = "AuthoredGarbage"

-- Every authored piece we've seen -> where it came from, which business it belongs to, and the
-- CFrame it was authored at (its "home", read before anything could move it).
type Authored = { parent: Instance, businessId: string, surfaceId: string, home: CFrame }
local authored: { [Instance]: Authored } = {}
local counts: { [string]: number } = {}

-- The business whose clones are currently live, or nil (none): the clones by surfaceId, and where
-- each of them belongs (copied off its template, so a reset needs no lookup back through `authored`).
local activeBusinessId: string? = nil
local clones: { [string]: PVInstance } = {}
local cloneHome: { [string]: CFrame } = {}

-- REVEAL GLOW (driven by MissingHighlightController, alongside the walls' per-pixel glow). The walls
-- recolor their own dirt pixels; a piece of garbage is ordinary geometry, so it gets a whole-piece
-- Highlight in the same neon yellow instead.
--
-- ALWAYS ON TOP, unlike the white hover outline (see HoverHighlight, which argues -- rightly, for a
-- hover -- that an outline hanging through a wall reads as a bug). The reveal is the opposite case:
-- the piece it exists to find is the one you already walked past, which is by definition the one
-- behind the desk, so an occluded glow would light up only the garbage you could see anyway. It's
-- also on a timer, so the see-through window is a deliberate, brief ability rather than the norm.
--
-- One Highlight per live piece. The engine only renders ~31 at once, so if a business is ever
-- authored with substantially more garbage than that, the excess simply won't glow -- at which point
-- this wants to become a recolor of the parts rather than more Highlights.
local GLOW_COLOR = Color3.fromRGB(255, 234, 0)
-- Tint rather than paint: the piece stays recognisable through the glow.
local GLOW_FILL_TRANSPARENCY = 0.5
local GLOW_HIGHLIGHT_NAME = "GarbageRevealGlow"

-- Whether the glow is currently up, and the live Highlight of each glowing piece by surfaceId.
local glowing = false
local glowHighlights: { [string]: Highlight } = {}

-- Light one piece up. The Highlight is parented to the CLONE, so destroying the piece takes its glow
-- with it; the table is only so a piece leaving the job can drop its glow explicitly.
local function addGlow(surfaceId: string, piece: PVInstance)
	if glowHighlights[surfaceId] then
		return
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = GLOW_HIGHLIGHT_NAME
	highlight.FillColor = GLOW_COLOR
	highlight.OutlineColor = GLOW_COLOR
	highlight.FillTransparency = GLOW_FILL_TRANSPARENCY
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = piece
	highlight.Parent = piece
	glowHighlights[surfaceId] = highlight
end

local function removeGlow(surfaceId: string)
	local highlight = glowHighlights[surfaceId]
	if highlight then
		highlight:Destroy()
		glowHighlights[surfaceId] = nil
	end
end

-- Build this session's own copy of one authored piece, at the position it was authored at. The clone
-- is unanchored and solid against the building (so a carried piece can't be walked through a wall,
-- and a dropped one falls and settles), but never collides with a character.
local function cloneOne(template: Instance, info: Authored)
	local clone = template:Clone()
	clone:SetAttribute(CLONE_ATTRIBUTE, true)
	for _, part in GarbageResolver.getParts(clone) do
		part.Anchored = false
		part.CanCollide = true
		part.CollisionGroup = GARBAGE_GROUP
	end
	;(clone :: PVInstance):PivotTo(info.home)
	clone.Parent = info.parent
	clones[info.surfaceId] = clone :: PVInstance
	cloneHome[info.surfaceId] = info.home

	-- A piece that streamed in mid-reveal joins the glow, rather than being the one piece left dark.
	if glowing then
		addGlow(info.surfaceId, clone :: PVInstance)
	end
end

-- True if `inst` is an authored piece: a direct child of a CleanableGarbage folder that isn't one of
-- our own clones.
local function isAuthoredRoot(inst: Instance): boolean
	local parent = inst.Parent
	return parent ~= nil and parent.Name == Config.GarbageFolderName and inst:GetAttribute(CLONE_ATTRIBUTE) == nil
end

-- Inspect an instance: if it's an authored piece, record it (position included), count it once, and
-- take it off-world. Used on the initial scan and on stream-ins.
local function consider(inst: Instance)
	if authored[inst] or not isAuthoredRoot(inst) then
		return
	end
	local identity = GarbageResolver.resolve(inst)
	if not identity or identity.garbage ~= inst then
		return
	end
	local parent = inst.Parent
	if not parent then
		return
	end

	authored[inst] = {
		parent = parent,
		businessId = identity.businessId,
		surfaceId = identity.surfaceId,
		home = (inst :: PVInstance):GetPivot(),
	}
	counts[identity.businessId] = (counts[identity.businessId] or 0) + 1
	inst.Parent = holder

	-- A piece that replicated in after this business's job had already started still belongs to the
	-- run in progress, so give it its clone now rather than leaving a hole until the next job.
	if identity.businessId == activeBusinessId then
		cloneOne(inst, authored[inst])
	end
end

-- Number of pieces of cleanable garbage a business has (for completion % / UI).
function GarbageVisibility.getGarbageCount(businessId: string): number
	return counts[businessId] or 0
end

local function destroyClones()
	for _, clone in clones do
		clone:Destroy()
	end
	table.clear(clones)
	table.clear(cloneHome)
	-- The Highlights went with the pieces they were parented to. Dropping the flag too means a job
	-- swap mid-reveal starts its fresh set of pieces unglowed, whichever order the teardown runs in.
	table.clear(glowHighlights)
	glowing = false
end

-- This session's copy of a whole business's garbage.
local function buildClones(businessId: string)
	for template, info in authored do
		if info.businessId == businessId then
			cloneOne(template, info)
		end
	end
end

-- Swap this client over to a business's garbage: throw away the previous job's clones and build a
-- fresh set. Pass nil for "no job" (no garbage at all). Because every clone is rebuilt at its
-- authored position, starting a job is also what resets the garbage.
function GarbageVisibility.setActiveBusiness(businessId: string?)
	activeBusinessId = businessId
	destroyClones()
	if businessId then
		buildClones(businessId)
	end
end

-- This session's clone of a given piece, or nil if it isn't part of the active job.
function GarbageVisibility.getPiece(surfaceId: string): PVInstance?
	return clones[surfaceId]
end

-- Where a piece was authored, so a reset can put it back.
function GarbageVisibility.getHome(surfaceId: string): CFrame?
	return cloneHome[surfaceId]
end

-- Turn the "what's left" reveal glow on or off across every piece of garbage still in the job. The
-- counterpart to SurfaceManager.setWallsGlow; both are driven together by MissingHighlightController.
-- Pieces are few enough to flip in one go (a job's worth is tens, not the walls' hundreds of faces),
-- and a piece that's picked up, shredded or streamed in while it's on keeps up by itself.
function GarbageVisibility.setGlow(enabled: boolean)
	if glowing == enabled then
		return
	end
	glowing = enabled

	if enabled then
		for surfaceId, piece in clones do
			addGlow(surfaceId, piece)
		end
	else
		for _, highlight in glowHighlights do
			highlight:Destroy()
		end
		table.clear(glowHighlights)
	end
end

-- Every live clone, keyed by surfaceId (for the idle reset sweep).
function GarbageVisibility.getPieces(): { [string]: PVInstance }
	return clones
end

-- Drop a single piece out of the world once it's been cleaned. A clone is ours to destroy, unlike
-- the shared instances the other cleanables have to reparent.
function GarbageVisibility.hideOne(surfaceId: string)
	local clone = clones[surfaceId]
	if clone then
		clone:Destroy() -- takes any reveal glow parented to it with it
		clones[surfaceId] = nil
		glowHighlights[surfaceId] = nil
	end
end

-- Hand a piece over to somebody else: it stops being one of the job's pieces (so nothing carries,
-- hovers or idle-resets it any more) but is NOT destroyed -- the caller owns the instance from here
-- and must destroy it. Used by GarbageShredController, which needs the clone to stay in the world
-- for the length of the disposal animation while being untouchable by everything else.
function GarbageVisibility.takePiece(surfaceId: string): PVInstance?
	local clone = clones[surfaceId]
	clones[surfaceId] = nil
	cloneHome[surfaceId] = nil
	-- The piece isn't "left to clean" any more, so it hands over WITHOUT the reveal glow riding along
	-- into the disposal animation.
	removeGlow(surfaceId)
	return clone
end

function GarbageVisibility.init()
	-- Don't block the caller: the Businesses folder may not exist/replicate yet.
	task.spawn(function()
		local businesses = Workspace:WaitForChild(Config.BusinessesFolderName)
		for _, desc in businesses:GetDescendants() do
			consider(desc)
		end
		businesses.DescendantAdded:Connect(consider)
	end)
end

return GarbageVisibility
