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
--   3. Each frame we orient the Handle along the camera's look DIRECTION, so it physically
--      points where the player is aiming. (We use the direction, not a raycast hit point, so
--      the aim doesn't jump as the crosshair crosses surfaces at different depths.)
--
-- Tools are equipped only in first person (which auto-turns the character), so we orient
-- the Handle purely toward the look direction and ignore body facing. Yaw and pitch both
-- follow the aim; only roll (the Z-axis) is locked so the Handle never tilts sideways.

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
	-- Same as the default, pulled 1 stud closer to the player (Z: -0.75 -> 0.25).
	mop = Vector3.new(1.65, 1.45, 0.25),
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
	-- The mop shows the same 90°-to-the-right lean; yaw it back the same way.
	mop = CFrame.Angles(0, math.rad(90), 0),
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
	-- The mop uses the same yaw offset as the broom, so its "back" is likewise along -X;
	-- pin there so the default +Z pivot doesn't rotate onto -X and shove it into the left arm.
	mop = Vector3.new(-2, 0, 0),
}
local DEFAULT_PIVOT = Vector3.new(0, 0, 2)

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

-- The DIRECTION the player is aiming, plus the camera's right vector.
--
-- We deliberately point the Handle along the camera ray's *direction* rather than toward a
-- raycast HIT point. Aiming at the hit point looks correct until you sweep across surfaces at
-- different depths: because the shoulder anchor is offset from the camera, the direction from
-- it to the hit point depends on the hit's distance (parallax), so the tool jumps whenever the
-- ray snaps between a near and a far surface, and swings wildly when aimed at nearby ground.
-- A direction is depth-independent, so the aim stays smooth. camRight is returned as a stable
-- yaw reference for when the aim points straight up/down (see aimOrientation).
local function aimDirection(): (Vector3?, Vector3?)
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil, nil
	end
	local point = if IS_MOBILE then cam.ViewportSize / 2 else UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(point.X, point.Y)
	return ray.Direction.Unit, cam.CFrame.RightVector
end

-- Orientation for the Handle at `origin` aiming toward `target`. Both YAW and PITCH track the
-- aim (pitch clamped to MAX_PITCH); roll (the Z-axis, the tool's own look axis) is locked to
-- zero at every pitch.
--
-- We build the rotation basis by hand rather than using CFrame.lookAt: lookAt derives its up
-- vector from the aim direction, so when you aim straight up or down (forward ∥ world up) it
-- hits a gimbal singularity and the Handle rolls/flips unpredictably. Here the RIGHT vector is
-- derived from the horizontal (yaw) direction alone, so it stays horizontal — and therefore
-- roll stays zero — no matter how steeply the tool pitches, even pointing straight down.
local function aimOrientation(origin: Vector3, lookDir: Vector3, camRight: Vector3): CFrame
	local flat = Vector3.new(lookDir.X, 0, lookDir.Z)
	local pitch = math.clamp(math.atan2(lookDir.Y, flat.Magnitude), -MAX_PITCH, MAX_PITCH)
	-- Yaw reference: the aim's horizontal direction, falling back to the camera's ground-forward
	-- (worldUp × camRight) when aiming straight up/down, where `flat` collapses to ~zero.
	local flatForward = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.yAxis:Cross(camRight).Unit
	local forward = flatForward * math.cos(pitch) + Vector3.yAxis * math.sin(pitch)
	-- Right depends only on the yaw direction, never on pitch, so it can't go singular.
	local right = flatForward:Cross(Vector3.yAxis)
	local up = right:Cross(forward)
	-- fromMatrix(pos, right, up) => LookVector = forward, with the horizontal right vector.
	return CFrame.fromMatrix(origin, right, up)
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

	local lookDir, camRight = aimDirection()
	if not lookDir or not camRight then
		return
	end

	local toolId = tool:GetAttribute(TOOL_ID_ATTRIBUTE) :: string
	local shoulderWorld = anchor.CFrame * (SHOULDER_OFFSET[toolId] or DEFAULT_SHOULDER_OFFSET)
	local aimOffset = HANDLE_AIM_OFFSET[toolId] or DEFAULT_AIM_OFFSET
	local pivot = HANDLE_PIVOT[toolId] or DEFAULT_PIVOT
	-- Yaw + pitch both track the aim (pitch clamped); roll stays locked at zero.
	local orientation = aimOrientation(shoulderWorld, lookDir, camRight)
	-- Pin `pivot` (a point on the Handle) at shoulderWorld and rotate the model about it,
	-- so aiming swings the front of the tool while the pivot point stays put.
	local desired = orientation * aimOffset * CFrame.new(-pivot)

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
