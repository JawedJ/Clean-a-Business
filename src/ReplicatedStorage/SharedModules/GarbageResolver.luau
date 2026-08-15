--!strict

-- Resolves a clicked/hovered piece of garbage (or any part of it) to its (businessId, surfaceId)
-- identity. Cleanable garbage lives in the shared business buildings at:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableGarbage.<garbage>
-- where <garbage> is the direct child of the CleanableGarbage folder carrying a
-- GarbageSurfaceIdAttribute attribute. Like a web it may be authored either as a single BasePart
-- (a mesh/part IS the target) or as a Model grouping several parts -- both work: we climb from the
-- hit instance up to whichever one sits directly in the CleanableGarbage folder and read the
-- surfaceId off it. The businessId is the business folder's name. Returns nil for anything not
-- sitting in that exact hierarchy.
--
-- Shared so the client (GarbageCarryController / GarbageVisibility) and the server
-- (GarbageCarryService's pickup validation) agree on what counts as carryable garbage.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

export type GarbageIdentity = {
	businessId: string,
	surfaceId: string,
	-- The garbage instance itself -- a BasePart or a Model, whichever is authored directly in the
	-- CleanableGarbage folder. This is what gets carried (and, later, cleaned).
	garbage: Instance,
}

local GarbageResolver = {}

-- Returns inst only if it exists and has the given name, else nil.
local function named(inst: Instance?, name: string): Instance?
	if inst and inst.Name == name then
		return inst
	end
	return nil
end

-- Resolve from a hit part anywhere inside the garbage, or the garbage instance itself. Climbs to
-- the instance sitting directly in a CleanableGarbage folder.
function GarbageResolver.resolve(part: Instance): GarbageIdentity?
	-- Find the garbage: the ancestor (or self) whose Parent is a CleanableGarbage folder.
	local garbage: Instance? = nil
	local current: Instance? = part
	while current do
		local parent = current.Parent
		if parent and parent.Name == Config.GarbageFolderName then
			garbage = current
			break
		end
		current = parent
	end
	if not garbage or not (garbage:IsA("BasePart") or garbage:IsA("Model")) then
		return nil
	end

	local surfaceId = garbage:GetAttribute(Config.GarbageSurfaceIdAttribute)
	-- Accept a number too (ids are authored numerically today); normalise to a string key.
	if type(surfaceId) == "number" then
		surfaceId = tostring(surfaceId)
	end
	if type(surfaceId) ~= "string" then
		return nil
	end

	local garbageFolder = named(garbage.Parent, Config.GarbageFolderName)
	if not garbageFolder then
		return nil
	end
	local cleanables = named(garbageFolder.Parent, Config.CleanablesFolderName)
	if not cleanables then
		return nil
	end
	local businessFolder = cleanables.Parent
	if not businessFolder then
		return nil
	end
	-- The Businesses folder must be a direct child of Workspace (the shared buildings).
	local businessesFolder = named(businessFolder.Parent, Config.BusinessesFolderName)
	if not businessesFolder or businessesFolder.Parent ~= Workspace then
		return nil
	end

	return {
		businessId = businessFolder.Name,
		surfaceId = surfaceId,
		garbage = garbage,
	}
end

-- Where the garbage sits in the world: a BasePart's own position, or a Model's pivot. Used by both
-- sides for the pickup range check, so they measure the same point.
function GarbageResolver.getPosition(garbage: Instance): Vector3?
	if garbage:IsA("BasePart") then
		return garbage.Position
	end
	if garbage:IsA("Model") then
		return garbage:GetPivot().Position
	end
	return nil
end

-- Every BasePart of a piece of garbage (the part itself, or a Model's parts).
function GarbageResolver.getParts(garbage: Instance): { BasePart }
	local parts: { BasePart } = {}
	if garbage:IsA("BasePart") then
		table.insert(parts, garbage)
	end
	for _, desc in garbage:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	return parts
end

return GarbageResolver
