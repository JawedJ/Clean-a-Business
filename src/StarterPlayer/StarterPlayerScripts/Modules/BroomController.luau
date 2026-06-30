--!strict

-- Broom INPUT + cosmetic feedback only. When the broom is equipped and the player
-- clicks a stain's Hitbox, this fires the click to the server and shows a billboard
-- progress bar over the stain. It does NOT decide when (or whether) the stain is
-- cleaned -- DecalCleaningService runs the authoritative UseTime timer, validates
-- ownership, and deletes the model. The bar is purely visual: it animates for the
-- same UseTime and is torn down early if the server removes the model.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local DecalResolver = require(ReplicatedStorage.SharedModules.DecalResolver)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

local CleanDecal = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanDecal") :: RemoteEvent

local TOOL_ID = ToolConfig.startingBroom.UniqueID

-- Live broom stats for this player, read fresh so tool upgrades take effect
-- immediately, falling back to the static ToolConfig default.
local function getRange(): number
	return DataService:get({ "Inventory", TOOL_ID, "Range" }) or ToolConfig[TOOL_ID].Range
end

-- Duration of the cosmetic progress bar. Read from the same per-player source the
-- server uses (the broom Item's UseTime) so the bar mirrors the server's timer.
local function getUseTime(): number
	return DataService:get({ "Inventory", TOOL_ID, "UseTime" }) or ToolConfig[TOOL_ID].UseTime
end

local localPlayer = Players.LocalPlayer

local BroomController = {}

local equippedTool: Tool? = nil
local boundTools: { [Tool]: boolean } = {}
-- Only one stain can be cleaned at a time; clicks are ignored until it finishes.
local busy = false

-- Looping brush sound played for the duration of a clean. Built in init so its
-- clone is preloaded during the startup window.
local brushSound: SoundManager.SustainedSound? = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Raycast from the mouse into the world, ignoring the player's own character.
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

-- Floating progress bar above a stain. Returns the gui and its fill frame.
local function makeProgressBar(adornee: BasePart): (BillboardGui, Frame)
	local gui = Instance.new("BillboardGui")
	gui.Name = "BroomProgress"
	gui.Size = UDim2.fromOffset(120, 14)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = adornee

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	bg.BackgroundTransparency = 0.3
	bg.BorderSizePixel = 0
	bg.Parent = gui

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 6)
	bgCorner.Parent = bg

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(90, 200, 90)
	fill.BorderSizePixel = 0
	fill.Parent = bg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	gui.Parent = adornee
	return gui, fill
end

-- Send the click to the server and animate the cosmetic progress bar. The server
-- decides if/when the stain is actually cleaned. The local `busy` gate only stops
-- the player from stacking bars; the server independently enforces one-at-a-time.
local function startClean(model: Model, hitbox: BasePart)
	if busy then
		return
	end
	busy = true

	CleanDecal:FireServer(model)

	local gui, fill = makeProgressBar(hitbox)

	-- Snapshot the timer for this one clean so the bar's full duration is stable.
	local useTime = getUseTime()

	if brushSound then
		brushSound.start()
	end

	task.spawn(function()
		local elapsed = 0
		while elapsed < useTime do
			local dt = RunService.Heartbeat:Wait()
			-- The server deletes the model on completion; if it's already gone (or the
			-- plot reset), stop early.
			if not model.Parent then
				break
			end
			elapsed += dt
			fill.Size = UDim2.fromScale(math.clamp(elapsed / useTime, 0, 1), 1)
		end

		if brushSound then
			brushSound.stop()
		end
		gui:Destroy()
		busy = false
	end)
end

-- Handle a broom click: clean the stain under the cursor, if any is in range.
local function onClick()
	local result = aim()
	if not result then
		return
	end
	local identity = DecalResolver.resolve(result.Instance)
	if not identity then
		return
	end
	local hitbox = identity.model:FindFirstChild(Config.HitboxName)
	if hitbox and hitbox:IsA("BasePart") then
		startClean(identity.model, hitbox)
	end
end

local function bindTool(tool: Tool)
	tool.Equipped:Connect(function()
		equippedTool = tool
	end)
	tool.Activated:Connect(function()
		if equippedTool == tool then
			onClick()
		end
	end)
	tool.Unequipped:Connect(function()
		if equippedTool == tool then
			equippedTool = nil
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

function BroomController.init()
	brushSound = SoundManager.createSustained("BrushAudio")

	watch(localPlayer)
	localPlayer.CharacterAdded:Connect(watch)
	if localPlayer.Character then
		watch(localPlayer.Character)
	end
end

return BroomController
