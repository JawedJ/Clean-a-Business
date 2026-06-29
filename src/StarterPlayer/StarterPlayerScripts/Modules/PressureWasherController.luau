--!strict

-- Drives the pressure washer: detects when the tool is equipped + firing,
-- raycasts from the mouse each frame, and tells the aimed CleanableSurface to
-- erase. Only the FRONT face of a surface is cleanable.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(game.ReplicatedStorage.SharedModules.CleaningConfig)
local CleanableSurface = require(script.Parent.CleanableSurface)

type Surface = CleanableSurface.CleanableSurface

local TOOL_ID = Config.ToolId
local RANGE = Config.Range

local localPlayer = Players.LocalPlayer

local PressureWasherController = {}

local getSurface: ((BasePart) -> Surface?)? = nil
local firing = false
local equippedTool: Tool? = nil
local boundTools: { [Tool]: boolean } = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Stroke state, so we can bridge between consecutive cleaning frames.
local lastSurface: Surface? = nil
local lastWorldPos: Vector3? = nil
local missedLast = true

local function resetStroke()
	lastSurface = nil
	lastWorldPos = nil
	missedLast = true
end


local function bindTool(tool: Tool)
	tool.Equipped:Connect(function()
		equippedTool = tool
	end)
	tool.Activated:Connect(function()
		if equippedTool == tool then
			firing = true
		end
	end)
	tool.Deactivated:Connect(function()
		firing = false
		resetStroke()
	end)
	tool.Unequipped:Connect(function()
		if equippedTool == tool then
			equippedTool = nil
			firing = false
			resetStroke()
		end
	end)
end

local function tryBind(inst: Instance)
	if inst:IsA("Tool") and inst:GetAttribute("ToolId") == TOOL_ID and not boundTools[inst] then
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

local function aim(): RaycastResult?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mouse.X, mouse.Y)
	rayParams.FilterDescendantsInstances = { localPlayer.Character :: Instance }
	return Workspace:Raycast(ray.Origin, ray.Direction * RANGE, rayParams)
end

local function onHeartbeat()
	local gs = getSurface
	if not firing or not gs then
		return
	end

	local result = aim()
	if not result then
		resetStroke()
		return
	end

	local part = result.Instance
	if not part or not part:IsA("BasePart") then
		resetStroke()
		return
	end

	-- Only walls on the local player's plot have a surface registered here.
	local surface = gs(part)
	if not surface or surface.cleaned then
		resetStroke()
		return
	end

	-- Left face only: its world normal is the part's negated RightVector.
	if result.Normal:Dot(-part.CFrame.RightVector) < 0.99 then
		resetStroke()
		return
	end

	-- Only bridge when we cleaned the same surface last frame.
	local fromPos = if not missedLast and lastSurface == surface then lastWorldPos else nil
	surface:clean(result.Position, fromPos)

	lastSurface = surface
	lastWorldPos = result.Position
	missedLast = false

	if surface.cleaned then
		resetStroke()
	end
end

function PressureWasherController.init(surfaceGetter: (BasePart) -> Surface?)
	getSurface = surfaceGetter

	watch(localPlayer)
	localPlayer.CharacterAdded:Connect(watch)
	if localPlayer.Character then
		watch(localPlayer.Character)
	end

	RunService.Heartbeat:Connect(onHeartbeat)
end

return PressureWasherController
