--!strict

-- Drives the pressure washer: detects when the tool is equipped + firing,
-- raycasts from the mouse each frame, and tells the aimed CleanableSurface to
-- erase. Only the FRONT face of a surface is cleanable.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(game.ReplicatedStorage.SharedModules.CleaningConfig)
local ToolConfig = require(game.ReplicatedStorage.SharedModules.ToolConfig)
local DataService = require(game.ReplicatedStorage.Packages.DataService).client
local CleanableSurface = require(script.Parent.CleanableSurface)

type Surface = CleanableSurface.CleanableSurface

local TOOL_ID = ToolConfig.pressureWasher.UniqueID
local MAX_BRIDGE_DIST = Config.MaxBridgeWorldDistance

-- Live cleaning range (studs) for this player, read fresh so tool upgrades take
-- effect immediately. Falls back to the static ToolConfig default if the player's
-- inventory value isn't available yet.
local function getRange(): number
	return DataService:get({ "Inventory", TOOL_ID, "Range" }) or ToolConfig[TOOL_ID].Range
end

-- Live brush radius (studs) for this player, same fresh-read + fallback as range.
local function getRadius(): number
	return DataService:get({ "Inventory", TOOL_ID, "Radius" }) or ToolConfig[TOOL_ID].Radius
end

-- Only this slice of PressureAudio is looped while firing (seconds).
local SOUND_SECTION_START = 1
local SOUND_SECTION_END = 2.5

local localPlayer = Players.LocalPlayer

-- 2D firing sound (cloned from ReplicatedStorage.Audios.PressureAudio), looped over
-- the [START, END] slice by resetting its TimePosition each frame while playing.
local fireSound: Sound? = nil

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

-- Clone the firing sound once (2D, looped). No-op if the asset is missing.
local function setupSound()
	if fireSound then
		return
	end
	local audios = ReplicatedStorage:FindFirstChild("Audios")
	local template = audios and audios:FindFirstChild("PressureAudio")
	if template and template:IsA("Sound") then
		local s = template:Clone()
		s.Looped = true -- safety net; the slice is enforced per-frame below
		s.Parent = SoundService
		-- Decode the audio now (during the startup window) so the first Play() mid-game
		-- doesn't trigger a one-off decode job spike.
		task.spawn(function()
			pcall(function()
				game:GetService("ContentProvider"):PreloadAsync({ s })
			end)
		end)
		fireSound = s
	end
end

local function startSound()
	local s = fireSound
	if s and not s.IsPlaying then
		s.TimePosition = SOUND_SECTION_START
		s:Play()
	end
end

local function stopSound()
	local s = fireSound
	if s and s.IsPlaying then
		s:Stop()
	end
end

-- Keep playback inside the [START, END] slice while firing.
local function maintainSound()
	local s = fireSound
	if s and s.IsPlaying and (s.TimePosition >= SOUND_SECTION_END or s.TimePosition < SOUND_SECTION_START) then
		s.TimePosition = SOUND_SECTION_START
	end
end


local function bindTool(tool: Tool)
	tool.Equipped:Connect(function()
		equippedTool = tool
	end)
	tool.Activated:Connect(function()
		if equippedTool == tool then
			firing = true
			startSound()
		end
	end)
	tool.Deactivated:Connect(function()
		firing = false
		resetStroke()
		stopSound()
	end)
	tool.Unequipped:Connect(function()
		if equippedTool == tool then
			equippedTool = nil
			firing = false
			resetStroke()
			stopSound()
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
	return Workspace:Raycast(ray.Origin, ray.Direction * getRange(), rayParams)
end

local function onHeartbeat()
	if not firing then
		return
	end
	maintainSound()

	local gs = getSurface
	if not gs then
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

	-- Bridge from the previous hit so fast strokes leave no holes -- including
	-- across the seam between two adjacent parts. Skip the bridge if the aim
	-- jumped too far (a genuine teleport to a different wall), so we don't smear
	-- an unrelated surface.
	local fromPos: Vector3? = nil
	if not missedLast and lastWorldPos and (result.Position - lastWorldPos).Magnitude <= MAX_BRIDGE_DIST then
		fromPos = lastWorldPos
	end

	local radius = getRadius()

	-- When the stroke crossed onto a new part, also extend the part we just left
	-- toward this hit so its edge by the seam gets cleaned too.
	if fromPos and lastSurface and lastSurface ~= surface and not lastSurface.cleaned then
		lastSurface:clean(result.Position, fromPos, radius)
	end

	surface:clean(result.Position, fromPos, radius)

	lastSurface = surface
	lastWorldPos = result.Position
	missedLast = false

	if surface.cleaned then
		resetStroke()
	end
end

function PressureWasherController.init(surfaceGetter: (BasePart) -> Surface?)
	getSurface = surfaceGetter

	setupSound()

	watch(localPlayer)
	localPlayer.CharacterAdded:Connect(watch)
	if localPlayer.Character then
		watch(localPlayer.Character)
	end

	RunService.Heartbeat:Connect(onHeartbeat)
end

return PressureWasherController
