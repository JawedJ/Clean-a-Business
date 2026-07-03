--!strict

-- Pins the local player's camera to first person for the duration of a job and puts it
-- back when the job ends. Driven by the same ActiveJob attribute as the rest of the job
-- client: job start = attribute set, job finish/switch = attribute cleared.
--
-- Off a job we hold CameraMinZoomDistance at IDLE_MIN_ZOOM (third person only). On a job
-- we pin min = max = FIRST_PERSON_ZOOM so they can't zoom out. On finish we simply RAISE
-- the min back to IDLE_MIN_ZOOM and leave it there -- the camera clamps its zoom up to the
-- new min on the next render and stays. The earlier approach snapped a distance for a frame
-- then dropped the min back to first-person range, which raced the camera's own clamp and
-- left the player stuck full-screen; never lowering the min below IDLE_MIN_ZOOM off a job
-- makes that impossible.
--
-- The zoom-out is DELAYED: when a job ends we hold first person for UNLOCK_DELAY seconds
-- before pulling the camera back, so the finish reads (and the pull-back lines up with the
-- server sending the player home) rather than snapping to third person the instant the job
-- clears. Starting another job during that window cancels the pending zoom-out (tracked by
-- a generation token) so a job switch stays seamlessly in first person.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

local localPlayer = Players.LocalPlayer

-- Roblox's minimum (first-person) zoom distance in studs; pinning min = max = this
-- forces first person with no room to zoom out.
local FIRST_PERSON_ZOOM = 0.5

-- Min zoom (studs) held whenever the player is NOT on a job. Keeps them in third person off
-- the clock, and -- because we never drop the min below this off a job -- the camera can
-- always clamp itself out of first person, so a finished job can't leave them stuck.
local IDLE_MIN_ZOOM = 10

-- Seconds we stay in first person after a job ends before zooming the camera back out.
-- Matches the server's delay before it teleports the player home, so the two coincide.
local UNLOCK_DELAY = 1

-- Tap this to toggle the mouse free while first-person-locked on a job (and again to
-- re-lock it). Only active during a job, since that's the only time we force first person.
local FREE_MOUSE_KEY = Enum.KeyCode.V
local FREE_MOUSE_BIND = "JobFreeMouse"

local JobCameraController = {}

-- The player's normal max zoom, captured once before we ever touch the bounds, so we can
-- restore it when a job ends (a job pins max = FIRST_PERSON_ZOOM to force first person).
local savedMax = 128

-- Whether we're currently pinned to first person for a job.
local locked = false

-- Bumped on every lock/unlock request so a pending delayed zoom-out can tell it's been
-- superseded (a new job started during the hold) and abort instead of pulling the camera.
local unlockGen = 0

-- Whether the player has freed their mouse (via FREE_MOUSE_KEY) during the current job.
local mouseFreed = false

-- Free (or re-lock) the cursor while in first person. First person forces MouseBehavior
-- to LockCenter every frame via the camera, so to keep it free we re-assert Default each
-- frame *after* the camera runs (Camera priority + 1) rather than setting it once. We
-- also show the mouse icon, which the Crosshair hides in first person for its center dot.
local function setMouseFreed(freed: boolean)
	if freed == mouseFreed then
		return
	end
	mouseFreed = freed
	if freed then
		UserInputService.MouseIconEnabled = true
		RunService:BindToRenderStep(FREE_MOUSE_BIND, Enum.RenderPriority.Camera.Value + 1, function()
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end)
	else
		RunService:UnbindFromRenderStep(FREE_MOUSE_BIND)
		-- Re-locking mid-job: hide the cursor again so the crosshair reads. When the job
		-- is ending (`locked` already cleared), leave it for Crosshair's third-person swap.
		if locked then
			UserInputService.MouseIconEnabled = false
		end
	end
end

local function lock()
	unlockGen += 1 -- supersede any pending delayed zoom-out (e.g. switching straight into a job)
	if locked then
		return -- already on a job
	end
	locked = true
	-- Equal min/max leaves no room to zoom out, forcing (and holding) first person.
	localPlayer.CameraMinZoomDistance = FIRST_PERSON_ZOOM
	localPlayer.CameraMaxZoomDistance = FIRST_PERSON_ZOOM
end

-- Immediately return the camera to the idle third-person state.
local function unlock()
	locked = false
	-- Job's over: stop holding the cursor free (third person frees it anyway).
	setMouseFreed(false)
	-- Back to third person: reopen the max, then raise the min above first-person range and
	-- LEAVE it there. Set max first so min <= max stays valid coming out of the job's 0.5
	-- pin. The camera clamps its zoom up to IDLE_MIN_ZOOM on the next render; because we
	-- never lower the min again off a job, it can't slip back into first person.
	localPlayer.CameraMaxZoomDistance = savedMax
	localPlayer.CameraMinZoomDistance = IDLE_MIN_ZOOM
end

-- The job ended. If we were on one, hold first person for UNLOCK_DELAY before zooming out,
-- so the finish reads and the pull-back coincides with the server's teleport home. A new
-- job starting during the hold bumps unlockGen and cancels this. If we weren't on a job
-- (e.g. the initial sync at startup), just settle into the idle state now.
local function scheduleUnlock()
	unlockGen += 1
	if not locked then
		unlock()
		return
	end
	local gen = unlockGen
	task.delay(UNLOCK_DELAY, function()
		if gen == unlockGen then
			unlock()
		end
	end)
end

local function sync()
	if type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string" then
		lock()
	else
		scheduleUnlock()
	end
end

function JobCameraController.init()
	-- Capture the normal max once, before the first job can pin it, so unlock restores it.
	savedMax = localPlayer.CameraMaxZoomDistance

	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(sync)

	-- Toggle the mouse free/locked with FREE_MOUSE_KEY, but only while on a job (`locked`).
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or input.KeyCode ~= FREE_MOUSE_KEY then
			return
		end
		if locked then
			setMouseFreed(not mouseFreed)
		end
	end)

	sync()
end

return JobCameraController
