--!strict

-- Resolves a clicked web (or any part of it) to its (businessId, surfaceId) identity. Cleanable
-- webs live in the shared business buildings at:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableWebs.<web>
-- where <web> is the direct child of the CleanableWebs folder carrying a SurfaceIdAttribute
-- attribute. A web may be authored either as a single BasePart (the mesh itself IS the target) or
-- as a Model grouping several parts -- both work: we climb from the hit instance up to whichever
-- one sits directly in the CleanableWebs folder and read the surfaceId off it. The businessId is
-- the business folder's name. Returns nil for anything not sitting in that exact hierarchy.
-- Shared so the client (VacuumController / WebVisibility) and server (clean validation) agree on
-- what counts as a cleanable web.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

export type WebIdentity = {
	businessId: string,
	surfaceId: string,
	-- The web instance itself -- a BasePart or a Model, whichever is authored directly in the
	-- CleanableWebs folder. Reparented wholesale to hide/show it (WebVisibility).
	web: Instance,
}

local WebResolver = {}

-- Returns inst only if it exists and has the given name, else nil.
local function named(inst: Instance?, name: string): Instance?
	if inst and inst.Name == name then
		return inst
	end
	return nil
end

-- Resolve from a hit part anywhere inside the web, or the web instance itself. Climbs to the
-- instance sitting directly in a CleanableWebs folder.
function WebResolver.resolve(part: Instance): WebIdentity?
	-- Find the web: the ancestor (or self) whose Parent is a CleanableWebs folder.
	local web: Instance? = nil
	local current: Instance? = part
	while current do
		local parent = current.Parent
		if parent and parent.Name == Config.WebsFolderName then
			web = current
			break
		end
		current = parent
	end
	if not web or not (web:IsA("BasePart") or web:IsA("Model")) then
		return nil
	end

	local surfaceId = web:GetAttribute(Config.SurfaceIdAttribute)
	-- Accept a number too (an id authored as a numeric attribute); normalise to a string key.
	if type(surfaceId) == "number" then
		surfaceId = tostring(surfaceId)
	end
	if type(surfaceId) ~= "string" then
		return nil
	end

	local websFolder = named(web.Parent, Config.WebsFolderName)
	if not websFolder then
		return nil
	end
	local cleanables = named(websFolder.Parent, Config.CleanablesFolderName)
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
		web = web,
	}
end

return WebResolver
