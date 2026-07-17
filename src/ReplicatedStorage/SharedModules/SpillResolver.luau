--!strict

-- Resolves a mopped spill part (or the spill Model itself) to its (businessId, surfaceId)
-- identity. Cleanable spills live in the shared business buildings at:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableSpills.<model>
-- where <model> carries a SurfaceIdAttribute attribute. The businessId is the business
-- folder's name and the surfaceId is the model's attribute value. Returns nil for anything
-- that is not a spill sitting in that exact hierarchy. Shared so the client (MopController /
-- SpillVisibility) and server (clean validation) agree on what counts as a cleanable spill.
--
-- Mirrors DecalResolver, but spills have NO Hitbox child -- the mop ray can hit any BasePart
-- in the model, so we walk up from the hit part to the enclosing spill Model.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

export type SpillIdentity = {
	businessId: string,
	surfaceId: string,
	model: Model,
}

local SpillResolver = {}

-- Returns inst only if it exists and has the given name, else nil.
local function named(inst: Instance?, name: string): Instance?
	if inst and inst.Name == name then
		return inst
	end
	return nil
end

-- Resolve from a hit BasePart anywhere inside the spill, or the spill Model directly.
function SpillResolver.resolve(part: Instance): SpillIdentity?
	-- Accept the model itself, or any descendant part -- climb to the model sitting directly
	-- in a CleanableSpills folder.
	local model: Instance? = nil
	if part:IsA("Model") then
		model = part
	else
		local current: Instance? = part
		while current do
			local parent = current.Parent
			if parent and parent.Name == Config.SpillsFolderName and current:IsA("Model") then
				model = current
				break
			end
			current = parent
		end
	end
	if not model or not model:IsA("Model") then
		return nil
	end

	local surfaceId = model:GetAttribute(Config.SpillSurfaceIdAttribute)
	-- Accept a number too: an id like 123213 authored as a NumberValue-style attribute still
	-- identifies the spill uniquely; normalise to a string for the dedupe key.
	if type(surfaceId) == "number" then
		surfaceId = tostring(surfaceId)
	end
	if type(surfaceId) ~= "string" then
		return nil
	end

	local spillsFolder = named(model.Parent, Config.SpillsFolderName)
	if not spillsFolder then
		return nil
	end
	local cleanables = named(spillsFolder.Parent, Config.CleanablesFolderName)
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
		model = model,
	}
end

return SpillResolver
