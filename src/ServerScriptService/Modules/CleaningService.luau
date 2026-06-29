--!strict

-- Server side of cleaning. Cleanable walls live in the Studio place under each
-- plot: Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableWalls. The
-- Pressure Washer tool (StarterPack) likewise lives in the place, not in code.
-- This service receives "this surface is clean" reports, verifies the wall is on
-- the player's assigned plot and a business they own, then saves it under
-- BusinessList[businessId].CleanedParts[surfaceId] via DataService.
--
-- The dirt overlay is an EditableImage built entirely on the client, so the
-- server never touches pixel data.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local SurfaceResolver = require(ReplicatedStorage.SharedModules.SurfaceResolver)
local PlotService = require(script.Parent.PlotService)

local CleanSurface = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanSurface") :: RemoteEvent

local CleaningService = {}

function CleaningService.init()
	CleanSurface.OnServerEvent:Connect(function(player, surface)
		if typeof(surface) ~= "Instance" or not surface:IsA("BasePart") then
			return
		end

		local identity = SurfaceResolver.resolve(surface)
		if not identity then
			return
		end

		-- The wall must be on the plot this player was assigned.
		if identity.plot ~= PlotService.getPlot(player) then
			return
		end

		-- ...and belong to a business the player actually has.
		if not DataService:get(player, { "BusinessList", identity.businessId }) then
			return
		end

		DataService:set(player, { "BusinessList", identity.businessId, "CleanedParts", identity.surfaceId }, true)
	end)
end

return CleaningService
