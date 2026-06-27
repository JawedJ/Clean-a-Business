--!strict

-- Server service that owns surface-cleaning completion.
-- Clients erase pixels locally (never replicated); when a surface snaps clean the
-- client fires CleanSurface. The server validates and writes the per-surface
-- completion boolean through DataService, which replicates it back. Only this
-- boolean is ever saved/replicated -- never pixel data.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local SURFACE_TAG = "CleanableSurface"

local CleaningService = {}

local cleanRemote: RemoteEvent

local function onCleanSurface(player: Player, surface: unknown)
	if typeof(surface) ~= "Instance" or not surface:IsA("BasePart") then
		return
	end
	if not CollectionService:HasTag(surface, SURFACE_TAG) then
		return
	end

	local businessId = surface:GetAttribute("BusinessId")
	local surfaceId = surface:GetAttribute("SurfaceId")
	if type(businessId) ~= "string" or type(surfaceId) ~= "string" then
		return
	end

	-- Must be a real business in this player's data.
	local business = DataService:get(player, { "BusinessList", businessId })
	if not business then
		return
	end

	DataService:set(player, { "BusinessList", businessId, "CleanedParts", surfaceId }, true)
end

function CleaningService.init()
	cleanRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanSurface") :: RemoteEvent
	cleanRemote.OnServerEvent:Connect(onCleanSurface)
end

return CleaningService
