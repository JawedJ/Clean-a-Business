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

-- Every live clone, keyed by surfaceId (for the idle reset sweep).
function GarbageVisibility.getPieces(): { [string]: PVInstance }
	return clones
end

-- Drop a single piece out of the world once it's been cleaned. (Unused until the disposal half of
-- the mechanic lands -- a clone is ours to destroy, unlike the shared instances the other cleanables
-- have to reparent.)
function GarbageVisibility.hideOne(surfaceId: string)
	local clone = clones[surfaceId]
	if clone then
		clone:Destroy()
		clones[surfaceId] = nil
	end
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
