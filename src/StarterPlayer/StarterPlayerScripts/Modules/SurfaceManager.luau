--!strict

-- Owns the lifetime of every CleanableSurface on the client. Cleanable walls are
-- the BaseParts under the local player's assigned plot:
--   Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableWalls
-- It builds one CleanableSurface per wall (and any added later), tears them down
-- when removed, and reports completion to the server. The controller looks
-- surfaces up here via getSurface.
--
-- Building an overlay is main-thread work (EditableImage create + upload), so
-- when a business spawns its walls are not built all at once: they're queued and
-- drained under a small per-frame time budget, spreading the cost across frames
-- so a burst of walls never stalls a frame.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local SurfaceResolver = require(ReplicatedStorage.SharedModules.SurfaceResolver)
local CleanableSurface = require(script.Parent.CleanableSurface)
local VfxManager = require(ReplicatedStorage.SharedModules.VfxManager)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local DataService = require(ReplicatedStorage.Packages.DataService).client

-- Sound played when the local player finishes cleaning a wall.
local COMPLETION_SOUND = "PressureCompletionAudio"

local CleanSurface = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanSurface") :: RemoteEvent

local localPlayer = Players.LocalPlayer

-- Seconds of overlay-building allowed per frame before yielding to the next one.
local FRAME_BUDGET = 0.002

local SurfaceManager = {}

local surfaces: { [BasePart]: CleanableSurface.CleanableSurface } = {}
local buildQueue: { BasePart } = {}
local queued: { [BasePart]: boolean } = {}

-- True if this wall was already cleaned in a previous session (per saved data).
local function isAlreadyCleaned(identity: SurfaceResolver.SurfaceIdentity): boolean
	local cleanedParts = DataService:get({ "BusinessList", identity.businessId, "CleanedParts" })
	return cleanedParts ~= nil and cleanedParts[identity.surfaceId] == true
end

-- Actually create the overlay for a wall (the expensive, main-thread part).
local function buildSurface(part: BasePart)
	if surfaces[part] then
		return
	end
	-- Re-resolve at build time: the part may have moved/left the queue meanwhile.
	local identity = SurfaceResolver.resolve(part)
	if not identity or isAlreadyCleaned(identity) then
		return
	end
	local surface = CleanableSurface.new(part)
	surface.onCleaned = function()
		CleanSurface:FireServer(part)
		VfxManager.cleanPop(part)
		SoundManager.playOneShot(COMPLETION_SOUND)
	end
	surfaces[part] = surface
end

-- Queue a wall for building, after cheap checks so we never queue non-walls.
local function addSurface(inst: Instance)
	if not inst:IsA("BasePart") or surfaces[inst] or queued[inst] then
		return
	end
	local identity = SurfaceResolver.resolve(inst)
	if not identity or isAlreadyCleaned(identity) then
		return
	end
	queued[inst] = true
	table.insert(buildQueue, inst)
end

local function removeSurface(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	queued[inst] = nil -- cancel a pending build if it hasn't run yet
	local surface = surfaces[inst]
	if surface then
		surface:destroy()
		surfaces[inst] = nil
	end
end

-- Long-lived drainer: each frame, build queued walls until the budget is spent.
local function processQueue()
	while true do
		if #buildQueue == 0 then
			RunService.Heartbeat:Wait()
		else
			local startClock = os.clock()
			repeat
				local part = table.remove(buildQueue)
				-- queued[part] is cleared by removeSurface if the wall went away.
				if part and queued[part] then
					queued[part] = nil
					buildSurface(part)
				end
			until #buildQueue == 0 or (os.clock() - startClock) >= FRAME_BUDGET
			RunService.Heartbeat:Wait()
		end
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
	task.spawn(processQueue)

	local plot = getAssignedPlot()
	local businesses = plot:WaitForChild(Config.BusinessesFolderName)
	for _, businessFolder in businesses:GetChildren() do
		watchBusiness(businessFolder)
	end
	-- Businesses unlocked/added to the plot later become cleanable too.
	businesses.ChildAdded:Connect(watchBusiness)
end

return SurfaceManager
