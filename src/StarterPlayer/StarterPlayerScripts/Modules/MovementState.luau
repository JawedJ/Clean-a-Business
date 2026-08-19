--!strict

-- Is the local player standing still, or moving? The one definition of the two states the job rigs
-- animate on, shared by the first-person arms (ViewmodelController) and by the full-body rig
-- everyone else sees (JobRigController) -- so the hands on screen can never disagree with the body
-- they belong to.

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer

-- Below this ground speed (studs/s) the player counts as standing still. Just above zero so being
-- nudged, or sliding to a halt, doesn't twitch the walk animation on.
local STILL_SPEED = 0.5

local MovementState = {}

export type State = "idle" | "walk"

-- The local character's current state. "idle" whenever there's no character to read (mid-respawn),
-- which is also what it should animate as.
function MovementState.get(): State
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not (root and root:IsA("BasePart")) then
		return "idle"
	end
	-- Ground speed only: falling, or riding a lift, isn't walking.
	local velocity = root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	-- MoveDirection as well as speed, so being shoved around while standing still stays idle.
	if speed < STILL_SPEED or humanoid.MoveDirection.Magnitude < 0.1 then
		return "idle"
	end
	return "walk"
end

return MovementState
