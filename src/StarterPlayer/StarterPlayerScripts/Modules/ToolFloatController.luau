--!strict

-- Makes an equipped tool float in front of the player's right shoulder and point
-- wherever the player is looking, instead of being gripped in the hand.
--
-- The tools are still normal Roblox Tools equipped via Humanoid:EquipTool, so all of
-- the input/cleaning logic (Tool.Equipped/Activated/Unequipped in the Broom and Pressure
-- Washer controllers, and the washer's own spray-attachment aiming) is untouched. This
-- controller only changes how the Handle is POSITIONED:
--
--   1. On equip we destroy the RightGrip weld the engine creates, so the Handle stops
--      being welded to the hand and the arm falls back to its normal idle pose.
--   2. We weld the Handle to the HumanoidRootPart ourselves and drive that weld's C0
--      every frame so the Handle sits at a fixed offset off the right shoulder.
--   3. Each frame we raycast from the camera through the aim point and orient the Handle
--      to look at the hit, so it physically points where the player is aiming.
--
-- Tools are equipped only in first person (which auto-turns the character), so we orient
-- the Handle purely toward the world-space look target and ignore body facing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local ToolFloatController = {}

-- Where the Handle floats, in the HumanoidRootPart's local space:
--   +X = right, +Y = up, -Z = forward (Roblox parts look down -Z).
-- The HRP origin sits at the torso centre, so this is offset out to the right shoulder
-- and a bit forward. Per-tool since models differ; falls back to DEFAULT_SHOULDER_OFFSET.
local SHOULDER_OFFSET: { [string]: Vector3 } = {
	startingBroom = Vector3.new(1.25, 0.8, 0),
}
local DEFAULT_SHOULDER_OFFSET = Vector3.new(1.25, 1.0, -0.75)

-- Per-tool twist applied AFTER the look CFrame, to align the Handle's modelled "forward"
-- with the aim direction. Identity assumes the Handle already looks down its own -Z.
-- If a tool points sideways/up when floating, add an entry keyed by its ToolId, e.g.
--   ["pressureWasher"] = CFrame.Angles(0, math.rad(90), 0),
local HANDLE_AIM_OFFSET: { [string]: CFrame } = {
	-- The broom's Handle is modelled pointing along its own +X, so without a twist it aims
	-- 90° to the right. Yaw it back so the broom's length points down the aim direction.
	startingBroom = CFrame.Angles(0, math.rad(90), 0),
}
local DEFAULT_AIM_OFFSET = CFrame.identity

-- The point on the Handle (in its own oriented space; +Z = back, since the tool looks
-- down -Z toward the target) that stays pinned at the shoulder anchor as the tool aims.
-- Rotation happens ABOUT this point, so pushing it toward the rear of the model makes
-- aiming down swing only the FRONT down instead of spinning the whole model about its
-- centre. Increase Z until the back sits still. Per-tool since models differ in length;
-- falls back to DEFAULT_PIVOT.
local HANDLE_PIVOT: { [string]: Vector3 } = {
	-- The broom points along its own +X (see HANDLE_AIM_OFFSET), so its "back" is -X, not
	-- +Z. Pin along -X to match, otherwise the default +Z pivot lands sideways and shoves
	-- the broom off to the left.
	startingBroom = Vector3.new(-2, 0, 0),
}
local DEFAULT_PIVOT = Vector3.new(0, 0, 2)

-- How far out the aim ray reaches when nothing is hit (studs). Only sets the direction
-- the Handle points; it doesn't gate any cleaning.
local AIM_RANGE = 500

-- How far the Handle may tilt up/down from horizontal when aiming (radians). Aiming
-- steeply up or down is clamped to this so the tool never points near-vertical.
local MAX_PITCH = math.rad(90)

local TOOL_ID_ATTRIBUTE = "ToolId"
local GRIP_WELD_NAME = "RightGrip"
local FLOAT_WELD_NAME = "ToolFloatWeld"

-- Touch-only devices aim from the screen centre (crosshair) rather than the last tap.
local IS_MOBILE = UserInputService.TouchEnabled
	and not UserInputService.KeyboardEnabled
	and not UserInputService.MouseEnabled
	and not UserInputService.GamepadEnabled

-- Currently floating tool + its Handle and the weld we drive. Nil when nothing is equipped.
local currentTool: Tool? = nil
local currentHandle: BasePart? = nil
local floatWeld: Weld? = nil
-- Watches the character for the engine re-adding a RightGrip while we're floating.
local gripWatch: RBXScriptConnection? = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- World position the player is aiming at: the raycast hit under the crosshair/mouse, or a
-- point far out along the ray when nothing is hit.
local function aimTarget(): Vector3?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local point = if IS_MOBILE then cam.ViewportSize / 2 else UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(point.X, point.Y)
	rayParams.FilterDescendantsInstances = { localPlayer.Character :: Instance }
	local result = Workspace:Raycast(ray.Origin, ray.Direction * AIM_RANGE, rayParams)
	if result then
		return result.Position
	end
	return ray.Origin + ray.Direction * AIM_RANGE
end

-- Direction the tool should point. Its YAW is locked to the body's horizontal facing (in
-- first person the character auto-turns to the look direction), so the tool never skews
-- sideways/inward from the right-shoulder offset. Only the up/down PITCH tracks the aim,
-- clamped to MAX_PITCH. Returns a unit forward vector with zero roll.
local function aimForwardDirection(origin: Vector3, target: Vector3, bodyLook: Vector3): Vector3
	local flatForward = Vector3.new(bodyLook.X, 0, bodyLook.Z)
	flatForward = if flatForward.Magnitude > 1e-4 then flatForward.Unit else Vector3.zAxis
	local dir = target - origin
	local flatDist = Vector3.new(dir.X, 0, dir.Z).Magnitude
	local pitch = math.clamp(math.atan2(dir.Y, flatDist), -MAX_PITCH, MAX_PITCH)
	return flatForward * math.cos(pitch) + Vector3.yAxis * math.sin(pitch)
end

-- The engine welds the Handle to the hand via a Weld named "RightGrip" on equip. Destroy
-- any that target our Handle so the hand lets go and the arm returns to its idle pose.
local function destroyGripWelds(handle: BasePart)
	local character = localPlayer.Character
	if not character then
		return
	end
	for _, desc in character:GetDescendants() do
		if desc:IsA("Weld") and desc.Name == GRIP_WELD_NAME and (desc.Part0 == handle or desc.Part1 == handle) then
			desc:Destroy()
		end
	end
end

-- The floating tool sits out in front of the character, so its parts must not collide with
-- the world/character, and must be massless so their offset weight doesn't drag the
-- character's physics around.
local function makeNonCollidable(tool: Tool)
	for _, desc in tool:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.CanCollide = false
			desc.Massless = true
		end
	end
end

local function tearDown()
	if gripWatch then
		gripWatch:Disconnect()
		gripWatch = nil
	end
	if floatWeld then
		floatWeld:Destroy()
		floatWeld = nil
	end
	currentTool = nil
	currentHandle = nil
end

local function onEquipped(tool: Tool)
	local character = localPlayer.Character
	if not character then
		return
	end
	local handle = tool:FindFirstChild("Handle")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (handle and handle:IsA("BasePart")) or not (rootPart and rootPart:IsA("BasePart")) then
		return
	end

	-- Replace anything left over from a previous tool before wiring the new one.
	tearDown()
	currentTool = tool
	currentHandle = handle

	makeNonCollidable(tool)

	-- Weld the Handle to the torso; we drive C0 each frame to place + aim it.
	local weld = Instance.new("Weld")
	weld.Name = FLOAT_WELD_NAME
	weld.Part0 = rootPart
	weld.Part1 = handle
	weld.C1 = CFrame.identity
	weld.Parent = handle
	floatWeld = weld

	-- Drop the engine's hand grip now, and keep dropping it if it comes back while equipped.
	destroyGripWelds(handle)
	gripWatch = character.DescendantAdded:Connect(function(desc)
		if desc:IsA("Weld") and desc.Name == GRIP_WELD_NAME and (desc.Part0 == handle or desc.Part1 == handle) then
			desc:Destroy()
		end
	end)
end

local function onUnequipped(tool: Tool)
	if currentTool == tool then
		tearDown()
	end
end

-- Per frame: place the Handle off the right shoulder, oriented to look at the aim target.
local function onRenderStepped()
	local weld = floatWeld
	local handle = currentHandle
	local tool = currentTool
	if not weld or not handle or not tool then
		return
	end
	local anchor = weld.Part0
	if not anchor then
		return
	end

	local target = aimTarget()
	if not target then
		return
	end

	local toolId = tool:GetAttribute(TOOL_ID_ATTRIBUTE) :: string
	local shoulderWorld = anchor.CFrame * (SHOULDER_OFFSET[toolId] or DEFAULT_SHOULDER_OFFSET)
	local aimOffset = HANDLE_AIM_OFFSET[toolId] or DEFAULT_AIM_OFFSET
	local pivot = HANDLE_PIVOT[toolId] or DEFAULT_PIVOT
	-- Yaw-locked to body facing, pitch tracks the aim (clamped): no sideways/inward curve.
	local forward = aimForwardDirection(shoulderWorld, target, anchor.CFrame.LookVector)
	-- Pin `pivot` (a point on the Handle) at shoulderWorld and rotate the model about it,
	-- so aiming swings the front of the tool while the pivot point stays put.
	local desired = CFrame.lookAt(shoulderWorld, shoulderWorld + forward) * aimOffset * CFrame.new(-pivot)

	-- Weld: Part0.CFrame * C0 = Handle.CFrame (C1 is identity). Solve C0 for the pose we want.
	weld.C0 = anchor.CFrame:Inverse() * desired
end

-- Bind every Tool we see so this works no matter which tool the player equips.
local boundTools: { [Tool]: boolean } = {}

local function bindTool(tool: Tool)
	tool.Equipped:Connect(function()
		onEquipped(tool)
	end)
	tool.Unequipped:Connect(function()
		onUnequipped(tool)
	end)
end

local function tryBind(inst: Instance)
	if inst:IsA("Tool") and inst:GetAttribute(TOOL_ID_ATTRIBUTE) ~= nil and not boundTools[inst] then
		boundTools[inst] = true
		bindTool(inst)
	end
end

local function watch(root: Instance)
	root.DescendantAdded:Connect(tryBind)
	for _, d in root:GetDescendants() do
		tryBind(d)
	end
end

function ToolFloatController.init()
	watch(localPlayer)
	localPlayer.CharacterAdded:Connect(function(character)
		-- The fresh character has no floating tool yet; drop stale state from the old one.
		tearDown()
		watch(character)
	end)
	if localPlayer.Character then
		watch(localPlayer.Character)
	end

	RunService.RenderStepped:Connect(onRenderStepped)
end

return ToolFloatController
