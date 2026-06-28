--!strict

-- Server side of cleaning. The cleanable parts (Workspace.CleanableWalls) and the
-- Pressure Washer tool (StarterPack) live in the Studio place, not in code.
-- This service receives "this surface is clean" reports and saves them per player
-- under BusinessList[BusinessId].CleanedParts[SurfaceId] via DataService.
--
-- The dirt overlay is an EditableImage built entirely on the client, so the
-- server never touches pixel data.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).server

local CleanSurface = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanSurface") :: RemoteEvent

local CleaningService = {}

function CleaningService.init()
	CleanSurface.OnServerEvent:Connect(function(player, surface)
		if typeof(surface) ~= "Instance" or not surface:IsA("BasePart") then
			return
		end
		if not CollectionService:HasTag(surface, Config.SurfaceTag) then
			return
		end

		local businessId = surface:GetAttribute(Config.BusinessIdAttribute)
		local surfaceId = surface:GetAttribute(Config.SurfaceIdAttribute)
		if type(businessId) ~= "string" or type(surfaceId) ~= "string" then
			return
		end

		-- Only save against a business the player actually has.
		if not DataService:get(player, { "BusinessList", businessId }) then
			return
		end

		DataService:set(player, { "BusinessList", businessId, "CleanedParts", surfaceId }, true)
	end)
end

return CleaningService
