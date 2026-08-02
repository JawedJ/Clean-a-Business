--!strict

-- Swings the camera round to match the way PlotService pointed the character on a player's
-- first-ever spawn (see the AimSpawnCamera remote there).
--
-- The server can turn the CHARACTER, but the camera belongs to the client: the default camera
-- keeps whatever yaw it already had, so without this a brand-new player stands facing their
-- warehouse while looking off in some unrelated direction.
--
-- Getting the default camera to accept a new yaw takes a specific dance. In Custom mode the
-- PlayerModule rewrites Camera.CFrame every frame, so writing to it is ignored. Dropping to
-- Scriptable takes the module out of the loop, and when control is handed back it re-seeds its
-- yaw/pitch from whatever pose it finds -- so the pose we leave behind is the one it keeps.
-- Everything after that (mouse look, zoom, follow) behaves exactly as normal.
--
-- Fires once, on the first spawn only. Respawns never reach here, because the server only sends
-- the remote for the first-spawn placement.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local AimSpawnCamera = Remotes:WaitForChild("AimSpawnCamera") :: RemoteEvent

local player = Players.LocalPlayer

-- Where the camera sits relative to the character while it looks along the given direction:
-- back along it, and up a little. Roughly the default third-person framing, so handing control
-- back doesn't visibly snap.
local CAMERA_DISTANCE = 14
local CAMERA_HEIGHT = 5

-- Eye-ish height above the root part to aim at, so the character isn't centred on the horizon.
local FOCUS_HEIGHT = 1.5

-- Longest we'll wait for the local character to exist. The remote is sent the moment the server
-- has placed the character, which can beat the client's own replication of it.
local CHARACTER_TIMEOUT = 5

local FirstSpawnCameraController = {}

-- The local HumanoidRootPart, waiting up to CHARACTER_TIMEOUT for it to replicate. nil if the
-- character never turned up (they left, or died instantly) -- in which case there's nothing to
-- frame and we simply skip.
local function waitForRoot(): BasePart?
	local deadline = os.clock() + CHARACTER_TIMEOUT
	while os.clock() < deadline do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root
		end
		task.wait()
	end
	return nil
end

local function onAim(direction: unknown)
	if typeof(direction) ~= "Vector3" then
		return
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-4 then
		return
	end
	flat = flat.Unit

	local root = waitForRoot()
	local camera = workspace.CurrentCamera
	if not root or not camera then
		return
	end

	local focus = root.Position + Vector3.new(0, FOCUS_HEIGHT, 0)
	local from = focus - flat * CAMERA_DISTANCE + Vector3.new(0, CAMERA_HEIGHT, 0)

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(from, focus)
	-- One frame with the module out of the way, so the pose is what it reads on the way back in.
	task.wait()
	camera.CameraType = Enum.CameraType.Custom

	-- Re-point the subject in case dropping to Scriptable left it stale; without a subject the
	-- restored Custom camera has nothing to follow.
	local humanoid = root.Parent and (root.Parent :: Instance):FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
end

function FirstSpawnCameraController.init()
	AimSpawnCamera.OnClientEvent:Connect(function(direction: unknown)
		task.spawn(onAim, direction)
	end)
end

return FirstSpawnCameraController
