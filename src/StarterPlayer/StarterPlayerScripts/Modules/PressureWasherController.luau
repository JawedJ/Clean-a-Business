--!strict

-- Client controller for the Pressure Washer tool.
-- While equipped and the mouse is held, raycasts at the aimed point each frame and
-- erases the dirt overlay on any tagged CleanableSurface, gated by an ammo/water tank.
-- When a surface snaps clean, reports completion to the server (which owns the save).
--
-- Dirt overlays are created for every tagged surface so they start dirty. Only the
-- aimed surface is updated per frame (one EditableImage write/frame, per the design).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CleanableSurface = require(script.Parent:WaitForChild("CleanableSurface"))
local ToolConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("ToolConfig"))

local CONFIG = ToolConfig.pressureWasher
local SURFACE_TAG = "CleanableSurface"
local TOOL_NAME = CONFIG.Name
local RANGE = assert(CONFIG.Range, "pressureWasher config missing Range")
local MAX_AMMO = assert(CONFIG.MaxAmmo, "pressureWasher config missing MaxAmmo")
local AMMO_PER_STEP = assert(CONFIG.AmmoPerStep, "pressureWasher config missing AmmoPerStep")
local REGEN_PER_SEC = assert(CONFIG.RegenPerSec, "pressureWasher config missing RegenPerSec")

local player = Players.LocalPlayer

local PressureWasherController = {}

local cleanRemote: RemoteEvent
local equippedTool: Tool? = nil
local firing = false
local ammo = MAX_AMMO
local surfaces: { [BasePart]: CleanableSurface.CleanableSurface } = {}
local hookedTools: { [Tool]: boolean } = {}

-- Previous frame's cleaning hit, used to draw a continuous stroke (no gaps).
local lastHitPos: Vector3? = nil
local lastHitPart: BasePart? = nil
local lastHitNormal: Vector3? = nil

-- Tolerate a few frames where the aim ray slips off the surface (common while moving the
-- camera near an edge) before breaking the stroke, so the stroke bridges back gap-free.
local missFrames = 0
local MAX_MISS_FRAMES = 4

local function endStroke()
	lastHitPos = nil
	lastHitPart = nil
	lastHitNormal = nil
	missFrames = 0
end

-- A frame that didn't land on a cleanable surface. Keep the stroke alive briefly so a
-- momentary slip off the part doesn't start a fresh (gapped) stamp on return.
local function softMiss()
	missFrames += 1
	if missFrames > MAX_MISS_FRAMES then
		endStroke()
	end
end

local function getSurface(part: BasePart): CleanableSurface.CleanableSurface
	local existing = surfaces[part]
	if existing then
		return existing
	end
	-- TODO: skip / pre-snap if this surface is already cleaned in replicated save data.
	local created = CleanableSurface.new(part)
	surfaces[part] = created
	return created
end

local function aim(): RaycastResult?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	if player.Character then
		table.insert(filter, player.Character)
	end
	params.FilterDescendantsInstances = filter

	return Workspace:Raycast(ray.Origin, ray.Direction * RANGE, params)
end

local function fireStep()
	local result = aim()
	if not result then
		softMiss()
		return
	end
	local hit = result.Instance
	if not hit or not hit:IsA("BasePart") or not CollectionService:HasTag(hit, SURFACE_TAG) then
		softMiss()
		return
	end

	local surface = getSurface(hit)
	if surface.cleaned then
		endStroke()
		return
	end

	missFrames = 0
	ammo = math.max(0, ammo - AMMO_PER_STEP)

	-- Continue the stroke from last frame's hit whenever we were already cleaning this
	-- same part. This fills the gap between frames so fast sweeps leave no missed strips.
	local fromPos: Vector3? = nil
	if lastHitPart == hit then
		fromPos = lastHitPos
	end

	surface:erase(result.Position, result.Normal, fromPos)

	-- If we swept onto a different face of the same part this frame, also extend the
	-- stroke on the face we just left (up to the shared edge) so crossing an edge fast
	-- doesn't leave a missed strip behind on the previous face.
	if fromPos and lastHitNormal and lastHitNormal:Dot(result.Normal) < 0.99 then
		surface:erase(result.Position, lastHitNormal, fromPos)
	end

	lastHitPos = result.Position
	lastHitPart = hit
	lastHitNormal = result.Normal

	if surface.cleaned then
		cleanRemote:FireServer(hit)
		endStroke()
	end
end

local function hookTool(inst: Instance)
	if not inst:IsA("Tool") or inst.Name ~= TOOL_NAME or hookedTools[inst] then
		return
	end
	hookedTools[inst] = true
	inst.Equipped:Connect(function()
		equippedTool = inst
	end)
	inst.Unequipped:Connect(function()
		if equippedTool == inst then
			equippedTool = nil
			firing = false
		end
	end)
end

function PressureWasherController.init()
	cleanRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanSurface") :: RemoteEvent

	-- Load the dirt texture once before any surface overlay is built.
	CleanableSurface.preload()

	-- Build dirt overlays for current + future tagged surfaces (handles streaming).
	for _, inst in CollectionService:GetTagged(SURFACE_TAG) do
		if inst:IsA("BasePart") then
			getSurface(inst)
		end
	end
	CollectionService:GetInstanceAddedSignal(SURFACE_TAG):Connect(function(inst)
		if inst:IsA("BasePart") then
			getSurface(inst)
		end
	end)

	-- Track tool equip/unequip (backpack + character, existing + future).
	local backpack = player:WaitForChild("Backpack")
	for _, child in backpack:GetChildren() do
		hookTool(child)
	end
	backpack.ChildAdded:Connect(hookTool)

	local function onCharacter(character: Model)
		for _, child in character:GetChildren() do
			hookTool(child)
		end
		character.ChildAdded:Connect(hookTool)
	end
	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)

	-- Mouse hold = firing.
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			firing = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			firing = false
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		if firing and equippedTool and ammo > 0 then
			fireStep()
		else
			endStroke() -- not cleaning this frame; next stroke starts fresh
			ammo = math.min(MAX_AMMO, ammo + REGEN_PER_SEC * dt)
		end
	end)
end

return PressureWasherController
