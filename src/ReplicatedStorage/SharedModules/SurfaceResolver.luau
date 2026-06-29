--!strict

-- Resolves a cleanable wall BasePart to the identity used for saving its cleaned
-- state. Walls live at:
--   Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableWalls.<part>
-- so the businessId is the business folder's name and the surfaceId is the wall
-- part's name. Returns nil for anything that is not a wall sitting in that exact
-- hierarchy. Shared so the client (overlay) and server (save validation) agree on
-- what counts as a cleanable wall.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

export type SurfaceIdentity = {
	plot: Instance,
	businessId: string,
	surfaceId: string,
}

local SurfaceResolver = {}

-- Returns inst only if it exists and has the given name, else nil.
local function named(inst: Instance?, name: string): Instance?
	if inst and inst.Name == name then
		return inst
	end
	return nil
end

function SurfaceResolver.resolve(part: BasePart): SurfaceIdentity?
	local wallsFolder = named(part.Parent, Config.WallsFolderName)
	if not wallsFolder then
		return nil
	end
	local cleanables = named(wallsFolder.Parent, Config.CleanablesFolderName)
	if not cleanables then
		return nil
	end
	local businessFolder = cleanables.Parent
	if not businessFolder then
		return nil
	end
	local businessesFolder = named(businessFolder.Parent, Config.BusinessesFolderName)
	if not businessesFolder then
		return nil
	end
	-- The plot is whatever holds Businesses, and it must be a top-level plot.
	local plot = businessesFolder.Parent
	if not plot or plot.Parent ~= Workspace then
		return nil
	end

	return {
		plot = plot,
		businessId = businessFolder.Name,
		surfaceId = part.Name,
	}
end

return SurfaceResolver
