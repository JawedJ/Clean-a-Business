--!strict

-- Pins the local player's camera to first person for the duration of a job and puts it
-- back when the job ends. Driven by the same ActiveJob attribute as the rest of the job
-- client: job start = attribute set, job finish/switch = attribute cleared.
--
-- On start we remember the player's zoom bounds and how far they were zoomed out, then
-- pin the camera to first person (min = max = FIRST_PERSON_ZOOM) so they can't zoom out.
-- On finish we snap back to the remembered zoom and reopen the original bounds, leaving
-- the camera exactly where it was and free to zoom again.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

local localPlayer = Players.LocalPlayer

-- Roblox's minimum (first-person) zoom distance in studs; pinning min = max = this
-- forces first person with no room to zoom out.
local FIRST_PERSON_ZOOM = 0.5

-- Tap this to toggle the mouse free while first-person-locked on a job (and again to
-- re-lock it). Only active during a job, since that's the only time we force first person.
local FREE_MOUSE_KEY = Enum.KeyCode.V
local FREE_MOUSE_BIND = "JobFreeMouse"

local JobCameraController = {}

-- Camera state saved when a job starts, restored when it ends. nil = not locked.
local saved: { min: number, max: number, zoom: number }? = nil

-- Whether the player has freed their mouse (via FREE_MOUSE_KEY) during the current job.
local mouseFreed = false

-- Current third-person zoom distance (camera-to-focus), used to restore it later.
local function currentZoom(): number
	local camera = Workspace.CurrentCamera
	if not camera then
		return localPlayer.CameraMaxZoomDistance
	end
	return (camera.CFrame.Position - camera.Focus.Position).Magnitude
end

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
		-- is ending (`saved` already cleared), leave it for Crosshair's third-person swap.
		if saved then
			UserInputService.MouseIconEnabled = false
		end
	end
end

local function lock()
	if saved then
		return -- already locked
	end
	saved = {
		min = localPlayer.CameraMinZoomDistance,
		max = localPlayer.CameraMaxZoomDistance,
		zoom = currentZoom(),
	}
	-- Equal min/max leaves no room to zoom out, forcing (and holding) first person.
	localPlayer.CameraMinZoomDistance = FIRST_PERSON_ZOOM
	localPlayer.CameraMaxZoomDistance = FIRST_PERSON_ZOOM
end

local function unlock()
	local state = saved
	if not state then
		return
	end
	saved = nil
	-- Job's over: stop holding the cursor free (third person frees it anyway).
	setMouseFreed(false)
	-- Snap back to the remembered zoom by pinning min = max = it for one frame, then
	-- reopen the original bounds -- otherwise the camera stays stuck at first person
	-- until the player scrolls out themselves.
	local restoreZoom = math.clamp(state.zoom, state.min, state.max)
	localPlayer.CameraMinZoomDistance = restoreZoom
	localPlayer.CameraMaxZoomDistance = restoreZoom
	RunService.Heartbeat:Wait()
	-- Guard against a new job starting during that one-frame wait (which re-locks).
	if saved then
		return
	end
	localPlayer.CameraMinZoomDistance = state.min
	localPlayer.CameraMaxZoomDistance = state.max
end

local function sync()
	if type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string" then
		lock()
	else
		unlock()
	end
end

function JobCameraController.init()
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(sync)

	-- Toggle the mouse free/locked with FREE_MOUSE_KEY, but only while on a job (`saved`).
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or input.KeyCode ~= FREE_MOUSE_KEY then
			return
		end
		if saved then
			setMouseFreed(not mouseFreed)
		end
	end)

	sync()
end

return JobCameraController
