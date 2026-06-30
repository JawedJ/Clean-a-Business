--!strict

-- The wall-overlay ENGINE. Builds and tears down one CleanableSurface (dirt overlay) per
-- cleanable wall, and reports completion. It is driven by JobClient -- it no longer
-- decides which business is active: JobClient calls `buildWalls` with the current job's
-- CleanableWalls folder (and a callback for finished walls) and `clear` when the job ends.
-- One job's walls are tracked at a time.
--
-- Cleanable walls are the BaseParts in:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableWalls
-- The overlay is a per-client EditableImage layered on the shared wall, so other players'
-- cleaning never affects this client's overlay. Nothing is saved -- jobs are per-session.
--
-- Building an overlay is main-thread work (EditableImage create + upload), so walls are
-- queued and drained under a small per-frame time budget, spreading the cost across
-- frames so a burst of walls never stalls a frame.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SurfaceResolver = require(ReplicatedStorage.SharedModules.SurfaceResolver)
local CleanableSurface = require(script.Parent.CleanableSurface)
local VfxManager = require(ReplicatedStorage.SharedModules.VfxManager)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

-- Sound played when the local player finishes cleaning a wall.
local COMPLETION_SOUND = "PressureCompletionAudio"

-- Seconds of overlay-building allowed per frame before yielding to the next one.
local FRAME_BUDGET = 0.002

local SurfaceManager = {}

local surfaces: { [BasePart]: CleanableSurface.CleanableSurface } = {}
local buildQueue: { BasePart } = {}
local queued: { [BasePart]: boolean } = {}

-- Connections watching the current job's CleanableWalls folder, dropped on `clear`.
local watchConns: { RBXScriptConnection } = {}
-- Called with the wall part when one is fully cleaned (set by buildWalls per job).
local onWallCleaned: ((BasePart) -> ())? = nil

-- Actually create the overlay for a wall (the expensive, main-thread part).
local function buildSurface(part: BasePart)
	if surfaces[part] then
		return
	end
	-- Re-resolve at build time: the part may have moved/left the queue meanwhile.
	if not SurfaceResolver.resolve(part) then
		return
	end
	local surface = CleanableSurface.new(part)
	surface.onCleaned = function()
		VfxManager.cleanPop(part)
		SoundManager.playOneShot(COMPLETION_SOUND)
		if onWallCleaned then
			onWallCleaned(part)
		end
	end
	surfaces[part] = surface
end

-- Queue a wall for building, after a cheap check so we never queue non-walls.
local function addSurface(inst: Instance)
	if not inst:IsA("BasePart") or surfaces[inst] or queued[inst] then
		return
	end
	if not SurfaceResolver.resolve(inst) then
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
				-- queued[part] is cleared by removeSurface/clear if the wall went away.
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

-- Tear down the current job's overlays: stop watching the walls folder, destroy every
-- overlay, drop anything still queued, and forget the completion callback.
function SurfaceManager.clear()
	for _, conn in watchConns do
		conn:Disconnect()
	end
	table.clear(watchConns)
	onWallCleaned = nil

	for part, surface in surfaces do
		surface:destroy()
		surfaces[part] = nil
	end
	table.clear(buildQueue)
	table.clear(queued)
end

-- Build overlays for every wall in `wallsFolder` (and any added later), reporting each
-- finished wall to `cleanedCallback`. Replaces whatever was being tracked before.
function SurfaceManager.buildWalls(wallsFolder: Instance, cleanedCallback: (BasePart) -> ())
	SurfaceManager.clear()
	onWallCleaned = cleanedCallback
	for _, inst in wallsFolder:GetChildren() do
		addSurface(inst)
	end
	table.insert(watchConns, wallsFolder.ChildAdded:Connect(addSurface))
	table.insert(watchConns, wallsFolder.ChildRemoved:Connect(removeSurface))
end

function SurfaceManager.init()
	task.spawn(processQueue)
end

return SurfaceManager
