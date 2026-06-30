--!strict

-- Resolves a clicked stain Hitbox part to its (businessId, surfaceId) identity.
-- Cleanable stains live in the shared business buildings at:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableDecals.<model>
-- where <model> has a child BasePart named HitboxName and a SurfaceIdAttribute
-- attribute. The businessId is the business folder's name and the surfaceId is the
-- model's attribute value. Returns nil for anything that is not a stain hitbox
-- sitting in that exact hierarchy. Shared so the client (controller) and server
-- (clean validation) agree on what counts as a cleanable stain.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

export type DecalIdentity = {
	businessId: string,
	surfaceId: string,
	model: Model,
}

local DecalResolver = {}

-- Returns inst only if it exists and has the given name, else nil.
local function named(inst: Instance?, name: string): Instance?
	if inst and inst.Name == name then
		return inst
	end
	return nil
end

-- Resolve from the clicked Hitbox part. Also accepts the stain Model directly.
function DecalResolver.resolve(part: Instance): DecalIdentity?
	-- Accept either the Hitbox part or the model itself.
	local model: Instance?
	if part:IsA("BasePart") and part.Name == Config.HitboxName then
		model = part.Parent
	elseif part:IsA("Model") then
		model = part
	end
	if not model or not model:IsA("Model") then
		return nil
	end

	local surfaceId = model:GetAttribute(Config.SurfaceIdAttribute)
	if type(surfaceId) ~= "string" then
		return nil
	end

	local decalsFolder = named(model.Parent, Config.DecalsFolderName)
	if not decalsFolder then
		return nil
	end
	local cleanables = named(decalsFolder.Parent, Config.CleanablesFolderName)
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

return DecalResolver
