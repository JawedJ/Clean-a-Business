--!strict

-- Owns the lifetime of every CleanableSurface on the client: builds one for each
-- tagged part (and any added later), tears them down when untagged, and reports
-- completion to the server. The controller looks surfaces up here via getSurface.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local CleanableSurface = require(script.Parent.CleanableSurface)
local DataService = require(ReplicatedStorage.Packages.DataService).client

local CleanSurface = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanSurface") :: RemoteEvent

local SURFACE_TAG = Config.SurfaceTag

local SurfaceManager = {}

local surfaces: { [BasePart]: CleanableSurface.CleanableSurface } = {}

-- True if this part was already cleaned in a previous session (per saved data).
local function isAlreadyCleaned(part: BasePart): boolean
	local businessId = part:GetAttribute(Config.BusinessIdAttribute)
	local surfaceId = part:GetAttribute(Config.SurfaceIdAttribute)
	if type(businessId) ~= "string" or type(surfaceId) ~= "string" then
		return false
	end
	local cleanedParts = DataService:get({ "BusinessList", businessId, "CleanedParts" })
	return cleanedParts ~= nil and cleanedParts[surfaceId] == true
end

local function addSurface(inst: Instance)
	if not inst:IsA("BasePart") or surfaces[inst] then
		return
	end
	-- Already cleaned in saved data: leave the part bare, never build the overlay.
	if isAlreadyCleaned(inst) then
		return
	end
	local surface = CleanableSurface.new(inst)
	surface.onCleaned = function()
		CleanSurface:FireServer(inst)
	end
	surfaces[inst] = surface
end

local function removeSurface(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	local surface = surfaces[inst]
	if surface then
		surface:destroy()
		surfaces[inst] = nil
	end
end

function SurfaceManager.getSurface(part: BasePart): CleanableSurface.CleanableSurface?
	return surfaces[part]
end

function SurfaceManager.init()
	for _, inst in CollectionService:GetTagged(SURFACE_TAG) do
		addSurface(inst)
	end
	CollectionService:GetInstanceAddedSignal(SURFACE_TAG):Connect(addSurface)
	CollectionService:GetInstanceRemovedSignal(SURFACE_TAG):Connect(removeSurface)
end

return SurfaceManager
