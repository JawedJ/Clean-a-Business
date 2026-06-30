--!strict

-- Drives the pressure washer: detects when the tool is equipped + firing,
-- raycasts from the mouse each frame, and tells the aimed CleanableSurface to
-- erase. Only the FRONT face of a surface is cleanable.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(game.ReplicatedStorage.SharedModules.CleaningConfig)
local ToolConfig = require(game.ReplicatedStorage.SharedModules.ToolConfig)
local DataService = require(game.ReplicatedStorage.Packages.DataService).client
local SoundManager = require(game.ReplicatedStorage.SharedModules.SoundManager)
local CleanableSurface = require(script.Parent.CleanableSurface)

type Surface = CleanableSurface.CleanableSurface

local CleanProgress = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanProgress") :: RemoteEvent

local TOOL_ID = ToolConfig.pressureWasher.UniqueID
local MAX_BRIDGE_DIST = Config.MaxBridgeWorldDistance

-- How often (seconds) we tell the server we're actively cleaning. Kept below the
-- server's reward cooldown so a fresh report is always waiting when it expires;
-- the server is the authority on the actual once-per-second payout.
local PROGRESS_REPORT_INTERVAL = 0.5

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

-- 2D firing sound: a sustained, slice-looped handle owned by SoundManager. Built
-- in init so its clone is preloaded during the startup window.
local fireSound: SoundManager.SustainedSound? = nil

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

-- os.clock() of the last CleanProgress report, for client-side throttling.
local lastProgressReport = 0

local function resetStroke()
	lastSurface = nil
	lastWorldPos = nil
	missedLast = true
end

local function startSound()
	if fireSound then
		fireSound.start()
	end
end

local function stopSound()
	if fireSound then
		fireSound.stop()
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

	local erasedBefore = surface.cleanedCount
	surface:clean(result.Position, fromPos, radius)

	-- Only report when dirt actually came off (the player is genuinely modifying the
	-- image, not aiming at already-clean pixels), throttled to keep traffic low. The
	-- server re-validates and enforces the real once-per-second reward.
	if surface.cleanedCount > erasedBefore then
		local now = os.clock()
		if now - lastProgressReport >= PROGRESS_REPORT_INTERVAL then
			lastProgressReport = now
			CleanProgress:FireServer(part)
		end
	end

	lastSurface = surface
	lastWorldPos = result.Position
	missedLast = false

	if surface.cleaned then
		resetStroke()
	end
end

function PressureWasherController.init(surfaceGetter: (BasePart) -> Surface?)
	getSurface = surfaceGetter

	fireSound = SoundManager.createSustained("PressureAudio", {
		loopStart = SOUND_SECTION_START,
		loopEnd = SOUND_SECTION_END,
	})

	watch(localPlayer)
	localPlayer.CharacterAdded:Connect(watch)
	if localPlayer.Character then
		watch(localPlayer.Character)
	end

	RunService.Heartbeat:Connect(onHeartbeat)
end

return PressureWasherController
