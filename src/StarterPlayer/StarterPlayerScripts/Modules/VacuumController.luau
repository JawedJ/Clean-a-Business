--!strict

-- Vacuum INPUT + cosmetic feedback only. When the vacuum is equipped and the player clicks a web,
-- this fires the click to the server and shows a billboard progress bar over the web. It does NOT
-- decide when (or whether) the web is cleaned -- WebCleaningService runs the authoritative UseTime
-- timer, validates ownership, and hides the model. The bar is purely visual: it animates for the
-- same UseTime and is torn down early if the server removes/hides the model.
--
-- A direct mirror of BroomController: the vacuum click starts a server-authoritative UseTime timer
-- and shows a cosmetic bar, just like the broom on a stain. A web may be a single BasePart or a
-- Model (WebResolver returns whichever sits in the CleanableWebs folder), so the aim resolves the
-- hit geometry to that web and the bar anchors to a part of it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local WebResolver = require(ReplicatedStorage.SharedModules.WebResolver)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

local CleanWeb = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanWeb") :: RemoteEvent

local TOOL_ID = ToolConfig.vacuum.UniqueID

-- How long after the cosmetic bar ends we wait for the server's WebCleaned before assuming the
-- click was rejected and making the web clickable again. Generous vs. ping so a merely-late
-- confirmation doesn't reopen the phantom-reclean window.
local SERVER_CONFIRM_GRACE = 2

-- Live vacuum stats for this player, read fresh so tool upgrades take effect immediately, falling
-- back to the static ToolConfig default.
local function getRange(): number
	return DataService:get({ "Inventory", TOOL_ID, "Range" }) or ToolConfig[TOOL_ID].Range
end

-- Duration of the cosmetic progress bar. Read from the same per-player source the server uses (the
-- vacuum Item's UseTime) so the bar mirrors the server's timer.
local function getUseTime(): number
	return DataService:get({ "Inventory", TOOL_ID, "UseTime" }) or ToolConfig[TOOL_ID].UseTime
end

local localPlayer = Players.LocalPlayer

local VacuumController = {}

local equippedTool: Tool? = nil
local boundTools: { [Tool]: boolean } = {}
-- Only one web can be cleaned at a time; clicks are ignored until it finishes.
local busy = false

-- Webs this client has already begun cleaning on the CURRENT job. A web is cleaned once per job
-- (the server enforces this too), then hidden -- but there's a brief window after our cosmetic
-- timer ends (busy clears) and before the server's WebCleaned arrives where the web is still
-- clickable. Re-clicking it there would start a phantom clean (bar + looping audio + a full
-- UseTime lockout) on a doomed web. Tracking what we've started, and refusing to restart it,
-- closes that window. Cleared whenever the active job changes, since re-accepting a job restores --
-- and makes cleanable again -- the same instances. Mirrors BroomController.startedClean.
local startedClean: { [Instance]: boolean } = {}

-- Looping vacuum sound played for the duration of a clean. Built in init so its clone is
-- preloaded during the startup window.
local vacuumSound: SoundManager.SustainedSound? = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Cleanable spills sit ON the surfaces webs cling to; their query-only hitboxes would otherwise
-- block the vacuum ray from reaching a web behind/near them. Collect every business's CleanableSpills
-- folder so the aim ray can exclude them (exactly like the broom does for stains).
local spillFolders: { Instance } = {}
local function watchSpillFolders()
	task.spawn(function()
		local businesses = Workspace:WaitForChild(Config.BusinessesFolderName)
		local function consider(desc: Instance)
			if desc:IsA("Folder") and desc.Name == Config.SpillsFolderName and not table.find(spillFolders, desc) then
				table.insert(spillFolders, desc)
			end
		end
		for _, desc in businesses:GetDescendants() do
			consider(desc)
		end
		businesses.DescendantAdded:Connect(consider)
	end)
end

-- Raycast from the mouse into the world, ignoring the player's own character and every spill (so a
-- spill's hitbox can't shadow a web sitting near it).
local function aim(): RaycastResult?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mouse.X, mouse.Y)
	local exclude: { Instance } = { localPlayer.Character :: Instance }
	for _, folder in spillFolders do
		table.insert(exclude, folder)
	end
	rayParams.FilterDescendantsInstances = exclude
	return Workspace:Raycast(ray.Origin, ray.Direction * getRange(), rayParams)
end

-- Floating progress bar above a web. Returns the gui and its fill frame.
local function makeProgressBar(adornee: BasePart): (BillboardGui, Frame)
	local gui = Instance.new("BillboardGui")
	gui.Name = "VacuumProgress"
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
	fill.BackgroundColor3 = Color3.fromRGB(190, 130, 230)
	fill.BorderSizePixel = 0
	fill.Parent = bg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	gui.Parent = adornee
	return gui, fill
end

-- A part of the web to anchor the billboard bar to: the web itself if it's a BasePart, else any
-- BasePart inside the Model.
local function anchorPart(web: Instance): BasePart?
	if web:IsA("BasePart") then
		return web
	end
	if web:IsA("Model") then
		if web.PrimaryPart then
			return web.PrimaryPart
		end
		return web:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- Send the click to the server and animate the cosmetic progress bar. The server decides if/when
-- the web is actually cleaned. The local `busy` gate only stops the player from stacking bars; the
-- server independently enforces one-at-a-time.
local function startClean(web: Instance, anchor: BasePart)
	if busy or startedClean[web] then
		return
	end
	busy = true
	startedClean[web] = true

	CleanWeb:FireServer(web)

	local gui, fill = makeProgressBar(anchor)

	-- Snapshot the timer for this one clean so the bar's full duration is stable.
	local useTime = getUseTime()

	if vacuumSound then
		vacuumSound.start()
	end

	task.spawn(function()
		local elapsed = 0
		while elapsed < useTime do
			local dt = RunService.Heartbeat:Wait()
			-- The server hides the web on completion; if it's already gone (or the job reset),
			-- stop early.
			if not web.Parent then
				break
			end
			elapsed += dt
			fill.Size = UDim2.fromScale(math.clamp(elapsed / useTime, 0, 1), 1)
		end

		if vacuumSound then
			vacuumSound.stop()
		end
		gui:Destroy()
		busy = false

		-- Safety net: if the server rejected this click (it can race the previous clean's
		-- completion and be dropped), no WebCleaned ever arrives and the startedClean entry would
		-- brick this web for the rest of the job. Once the server has had ample time to confirm,
		-- forget the web so it's clickable again. Harmless when the clean DID succeed: the confirmed
		-- web is hidden off-world by then and can't be hit by the aim raycast anyway.
		task.delay(SERVER_CONFIRM_GRACE, function()
			startedClean[web] = nil
		end)
	end)
end

-- Handle a vacuum click: clean the web under the cursor, if any is in range.
local function onClick()
	local result = aim()
	if not result then
		return
	end
	local identity = WebResolver.resolve(result.Instance)
	if not identity then
		return
	end
	-- Webs are shared and visible to everyone, but you can only clean the business whose job you
	-- currently hold. Skip (no remote, no cosmetic bar) otherwise -- the server would reject it
	-- anyway, and the bar would just mislead.
	if localPlayer:GetAttribute(Config.ActiveJobAttribute) ~= identity.businessId then
		return
	end
	local anchor = anchorPart(identity.web)
	if anchor then
		startClean(identity.web, anchor)
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

function VacuumController.init()
	vacuumSound = SoundManager.createSustained("VacuumAudio")

	-- Start collecting spill folders so the aim ray can pass through spills to the webs near them.
	watchSpillFolders()

	-- Re-accepting a job restores its webs (the same model instances) as cleanable again, so forget
	-- which webs we've cleaned whenever the active job changes.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(function()
		table.clear(startedClean)
	end)

	watch(localPlayer)
	localPlayer.CharacterAdded:Connect(watch)
	if localPlayer.Character then
		watch(localPlayer.Character)
	end
end

return VacuumController
