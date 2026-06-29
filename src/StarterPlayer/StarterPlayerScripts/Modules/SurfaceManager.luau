--!strict

-- Owns the lifetime of every CleanableSurface on the client. Cleanable walls are
-- the BaseParts under the local player's assigned plot:
--   Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableWalls
-- It builds one CleanableSurface per wall (and any added later), tears them down
-- when removed, and reports completion to the server. The controller looks
-- surfaces up here via getSurface.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local SurfaceResolver = require(ReplicatedStorage.SharedModules.SurfaceResolver)
local CleanableSurface = require(script.Parent.CleanableSurface)
local DataService = require(ReplicatedStorage.Packages.DataService).client

local CleanSurface = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanSurface") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SurfaceManager = {}

local surfaces: { [BasePart]: CleanableSurface.CleanableSurface } = {}

-- True if this wall was already cleaned in a previous session (per saved data).
local function isAlreadyCleaned(identity: SurfaceResolver.SurfaceIdentity): boolean
	local cleanedParts = DataService:get({ "BusinessList", identity.businessId, "CleanedParts" })
	return cleanedParts ~= nil and cleanedParts[identity.surfaceId] == true
end

local function addSurface(inst: Instance)
	if not inst:IsA("BasePart") or surfaces[inst] then
		return
	end
	local identity = SurfaceResolver.resolve(inst)
	if not identity then
		return
	end
	-- Already cleaned in saved data: leave the wall bare, never build the overlay.
	if isAlreadyCleaned(identity) then
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

-- Build/track every wall inside one CleanableWalls folder.
local function watchWalls(wallsFolder: Instance)
	for _, inst in wallsFolder:GetChildren() do
		addSurface(inst)
	end
	wallsFolder.ChildAdded:Connect(addSurface)
	wallsFolder.ChildRemoved:Connect(removeSurface)
end

-- Find the CleanableWalls folder for one business and start watching it. Uses
-- WaitForChild since a business spawned at runtime replicates as a subtree and
-- ChildAdded can fire before its descendants arrive.
local function watchBusiness(businessFolder: Instance)
	local cleanables = businessFolder:WaitForChild(Config.CleanablesFolderName, 10)
	local walls = cleanables and cleanables:WaitForChild(Config.WallsFolderName, 10)
	if walls then
		watchWalls(walls)
	end
end

-- Block until the server has assigned this player a plot, then return it.
local function getAssignedPlot(): Instance
	local plotName = localPlayer:GetAttribute(Config.PlotAttribute)
	while type(plotName) ~= "string" do
		localPlayer:GetAttributeChangedSignal(Config.PlotAttribute):Wait()
		plotName = localPlayer:GetAttribute(Config.PlotAttribute)
	end
	return Workspace:WaitForChild(plotName)
end

function SurfaceManager.init()
	local plot = getAssignedPlot()
	local businesses = plot:WaitForChild(Config.BusinessesFolderName)
	for _, businessFolder in businesses:GetChildren() do
		watchBusiness(businessFolder)
	end
	-- Businesses unlocked/added to the plot later become cleanable too.
	businesses.ChildAdded:Connect(watchBusiness)
end

return SurfaceManager
