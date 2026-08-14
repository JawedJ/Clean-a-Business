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
local FRAME_BUDGET = 0.001
-- Same idea for the reveal glow: toggling it on a wall is a full-image recolor + upload, so
-- applying it to every wall in one frame hitches. We drain the walls under this budget so the
-- glow flips on/off in a fast wave across a couple frames instead of one synchronous stall.
local GLOW_FRAME_BUDGET = 0.0005

local SurfaceManager = {}

local surfaces: { [BasePart]: CleanableSurface.CleanableSurface } = {}
local buildQueue: { BasePart } = {}
local queued: { [BasePart]: boolean } = {}

-- Desired glow state for the current job's walls, reconciled onto each surface by processGlow
-- under GLOW_FRAME_BUDGET. glowPending stays true until every surface matches glowTarget.
local glowTarget = false
local glowPending = false

-- Connections watching the current job's CleanableWalls folder, dropped on `clear`.
local watchConns: { RBXScriptConnection } = {}
-- Called with the wall part when one is fully cleaned (set by buildWalls per job).
local onWallCleaned: ((BasePart) -> ())? = nil
-- Called (no args) whenever any wall's clean amount changes, so the completion UI can track
-- the wash live -- read the aggregate back via getCleanedWallAmount. Set by buildWalls.
local onWallProgress: (() -> ())? = nil

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
	surface.onProgress = function()
		if onWallProgress then
			onWallProgress()
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

-- Replay a party member's erase stroke on OUR overlay for `part`, so a wall washed by anyone on a
-- shared job comes clean on every member's screen (and moves every member's completion bar). The
-- stroke arrives via the WallStroke remote, batched and validated by the server; JobController
-- routes it here. Identical to what the local washer does -- the surface can't tell the difference,
-- which is exactly why the images stay in step.
--
-- Silently ignored for a wall we haven't built an overlay for yet (still in the build queue) or one
-- that's already finished here. The queue drains within a frame or two of the job starting, long
-- before anyone has erased anything worth relaying.
function SurfaceManager.applyRemoteStroke(part: BasePart, to: Vector3, from: Vector3?, radius: number?)
	local surface = surfaces[part]
	if surface and not surface.cleaned then
		surface:clean(to, from, radius)
	end
end

-- Long-lived drainer: whenever the desired glow state differs from what's applied, flip a
-- few walls per frame until they all match, so a reveal never recolors + re-uploads every
-- wall's image in one hitchy frame. setGlow no-ops on walls already at the target, so a
-- partial pass just resumes where the budget ran out.
local function processGlow()
	while true do
		if not glowPending then
			RunService.Heartbeat:Wait()
		else
			glowPending = false
			local target = glowTarget
			local startClock = os.clock()
			for _, surface in surfaces do
				if surface.glowing ~= target then
					surface:setGlow(target)
					if (os.clock() - startClock) >= GLOW_FRAME_BUDGET then
						glowPending = true -- more walls to flip; finish next frame
						break
					end
				end
			end
			if glowPending then
				RunService.Heartbeat:Wait()
			end
		end
	end
end

-- Turn the "what's left" reveal glow on or off across every built wall of the current job.
-- The flip is applied lazily by processGlow (a few walls per frame) rather than all at once,
-- so a big job doesn't stall a frame. Each surface glows only its still-dirty pixels (see
-- CleanableSurface.setGlow); finished walls are skipped. Walls still queued for their overlay
-- aren't built yet, so they won't glow -- but the queue drains within a frame or two of the
-- job starting, long before a mid-job player asks what's left.
function SurfaceManager.setWallsGlow(enabled: boolean)
	glowTarget = enabled
	glowPending = true
end

-- Total wall progress of the current job, in whole-wall units (a half-cleaned wall counts
-- 0.5, a finished one 1). Sums the built surfaces' fractions; walls not yet built count 0.
-- Divide by the job's wall count (JobClient) for a 0..1 completion that moves mid-wall.
function SurfaceManager.getCleanedWallAmount(): number
	local amount = 0
	for _, surface in surfaces do
		if surface.cleaned then
			amount += 1
		else
			amount += math.clamp(surface.cleanedCount / surface.dirtyTotal, 0, 1)
		end
	end
	return amount
end

-- How many of the current job's walls are FULLY cleaned (whole walls only -- a half-washed
-- wall counts 0, unlike getCleanedWallAmount). Subtract from the job's wall count (JobClient)
-- for the "how many are left" readout; walls not yet built count as uncleaned, which is what
-- the player sees.
function SurfaceManager.getCleanedWallCount(): number
	local count = 0
	for _, surface in surfaces do
		if surface.cleaned then
			count += 1
		end
	end
	return count
end

-- Tear down the current job's overlays: stop watching the walls folder, destroy every
-- overlay, drop anything still queued, and forget the completion callback.
function SurfaceManager.clear()
	for _, conn in watchConns do
		conn:Disconnect()
	end
	table.clear(watchConns)
	onWallCleaned = nil
	onWallProgress = nil

	for part, surface in surfaces do
		surface:destroy()
		surfaces[part] = nil
	end
	table.clear(buildQueue)
	table.clear(queued)
	-- Drop any in-flight glow flip so it can't chase the next job's freshly built walls.
	glowTarget = false
	glowPending = false
end

-- Build overlays for every wall in `wallsFolder` (and any added later), reporting each
-- finished wall to `cleanedCallback` and every change in clean amount to `progressCallback`
-- (read the aggregate via getCleanedWallAmount). Replaces whatever was being tracked before.
function SurfaceManager.buildWalls(
	wallsFolder: Instance,
	cleanedCallback: (BasePart) -> (),
	progressCallback: (() -> ())?
)
	SurfaceManager.clear()
	onWallCleaned = cleanedCallback
	onWallProgress = progressCallback
	for _, inst in wallsFolder:GetChildren() do
		addSurface(inst)
	end
	table.insert(watchConns, wallsFolder.ChildAdded:Connect(addSurface))
	table.insert(watchConns, wallsFolder.ChildRemoved:Connect(removeSurface))
end

function SurfaceManager.init()
	task.spawn(processQueue)
	task.spawn(processGlow)
end

return SurfaceManager
