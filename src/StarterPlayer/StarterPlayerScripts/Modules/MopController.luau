--!strict

-- Mop INPUT + the client-driven spill clean. Unlike the broom (whose clean is a fixed server
-- timer) the mop works like the pressure washer's wall wash: the CLIENT drives it. While the mop
-- is equipped and the player HOLDS click on a cleanable spill, each frame we fade that spill's
-- Transparency toward 1 by the mop's Power (per second) and grow a billboard bar over it showing
-- how close it is to fully faded. When a spill reaches Transparency 1 we hide it locally
-- (SpillVisibility), count it toward the local completion bar (JobController), and tell the server
-- (CleanSpill) so it can pay the reward and record the spill toward authoritative completion.
--
-- Spills are SHARED and visible to everyone (like stains), but you can only clean the business
-- whose job you hold; off-job clicks do nothing. Releasing click (or looking away) PAUSES a
-- spill mid-fade -- its progress persists until the job is (re)accepted, which resets every spill
-- dirty again (SpillVisibility) for the redo.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local SpillResolver = require(ReplicatedStorage.SharedModules.SpillResolver)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

local JobController = require(script.Parent.JobController)
local SpillVisibility = require(script.Parent.SpillVisibility)

local CleanSpill = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanSpill") :: RemoteEvent

local TOOL_ID = ToolConfig.mop.UniqueID

local localPlayer = Players.LocalPlayer

-- Live mop stats for this player, read fresh so tool upgrades take effect immediately, falling
-- back to the static ToolConfig default.
local function getRange(): number
	return DataService:get({ "Inventory", TOOL_ID, "Range" }) or ToolConfig[TOOL_ID].Range
end

-- Transparency added per second while cleaning; higher = faster fade (see ToolConfig.mop.Power).
local function getPower(): number
	return DataService:get({ "Inventory", TOOL_ID, "Power" }) or ToolConfig[TOOL_ID].Power
end

-- Touch-only devices clean continuously while equipped (they can't hold-to-clean and drag to
-- look at once), aiming from the crosshair -- mirroring the pressure washer's mobile handling.
local IS_MOBILE = UserInputService.TouchEnabled
	and not UserInputService.KeyboardEnabled
	and not UserInputService.MouseEnabled
	and not UserInputService.GamepadEnabled

local MopController = {}

local equippedTool: Tool? = nil
local boundTools: { [Tool]: boolean } = {}
local firing = false

-- The Transparency a spill's parts fade UP to before it's finished. At this point the spill is
-- counted as cleaned and hidden (see completeSpill), so it fades most of the way out, then pops.
local MAX_TRANSPARENCY = 0.48

-- Per-spill fade progress (0..1) on the CURRENT job, and the base (authored) Transparency of each
-- of a spill's parts, snapshotted the first time we touch it so re-aiming continues from where it
-- paused. Both cleared whenever the active job changes (SpillVisibility resets the spills dirty).
local progress: { [Model]: number } = {}
local bases: { [Model]: { [BasePart]: number } } = {}
-- Spills already fully mopped this job, so a late frame can't re-fire the clean.
local doneSpills: { [Model]: boolean } = {}

-- Persistent billboard bar per spill the player has started mopping. Created the first time they
-- clean a spill and kept for the rest of the job -- it does NOT disappear when they release or
-- look away (only cleared when the active job changes). Its fill is refreshed as progress changes.
local bars: { [Model]: { gui: BillboardGui, fill: Frame } } = {}

-- Looping mop sound, played only while actively fading a spill. Built in init so its clone is
-- preloaded during the startup window. `soundOn` tracks state so we only start/stop on a change.
local mopSound: SoundManager.SustainedSound? = nil
local soundOn = false

local function setMopSound(on: boolean)
	if on == soundOn then
		return
	end
	soundOn = on
	if not mopSound then
		return
	end
	if on then
		mopSound.start()
	else
		mopSound.stop()
	end
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Raycast from the aim point into the world, ignoring the player's own character (which includes
-- the equipped, floating mop). On mobile aim from the screen centre (crosshair), not the last tap.
local function aim(): RaycastResult?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local point = if IS_MOBILE then cam.ViewportSize / 2 else UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(point.X, point.Y)
	rayParams.FilterDescendantsInstances = { localPlayer.Character :: Instance }
	return Workspace:Raycast(ray.Origin, ray.Direction * getRange(), rayParams)
end

local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- A part in the spill to anchor the billboard bar to (PrimaryPart if set, else any BasePart).
local function anchorPart(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

-- Floating progress bar above a spill. Returns the gui and its fill frame.
local function makeProgressBar(adornee: BasePart): (BillboardGui, Frame)
	local gui = Instance.new("BillboardGui")
	gui.Name = "MopProgress"
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
	fill.BackgroundColor3 = Color3.fromRGB(90, 160, 230)
	fill.BorderSizePixel = 0
	fill.Parent = bg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	gui.Parent = adornee
	return gui, fill
end

-- The persistent bar for a spill, creating it the first time the player mops that spill. Returns
-- nil only if the spill has no part to anchor to.
local function ensureBar(model: Model): Frame?
	local existing = bars[model]
	if existing then
		return existing.fill
	end
	local anchor = anchorPart(model)
	if not anchor then
		return nil
	end
	local gui, fill = makeProgressBar(anchor)
	bars[model] = { gui = gui, fill = fill }
	return fill
end

-- Destroy every spill bar (on a job change -- the spills reset dirty for the redo).
local function clearAllBars()
	for _, bar in bars do
		bar.gui:Destroy()
	end
	table.clear(bars)
end

-- Snapshot a spill's parts' current (authored) Transparency the first time we touch it, so the
-- fade lerps from the real starting look no matter what each part started at.
local function baseFor(model: Model): { [BasePart]: number }
	local existing = bases[model]
	if existing then
		return existing
	end
	local snap: { [BasePart]: number } = {}
	for _, desc in model:GetDescendants() do
		-- Skip the invisible aim helper: it's only there for the ray to hit, so fading it is
		-- pointless (and would make a visible hitbox flicker away with the spill). Also skip parts
		-- already at/above the target transparency -- there's nothing to fade, and lerping would
		-- wrongly make them MORE opaque.
		if desc:IsA("BasePart") and desc.Name ~= Config.HitboxName and desc.Transparency < MAX_TRANSPARENCY then
			snap[desc] = desc.Transparency
		end
	end
	bases[model] = snap
	return snap
end

-- Apply fade `p` (0..1) to every part of the spill: Transparency lerps base -> MAX_TRANSPARENCY.
local function applyFade(model: Model, p: number)
	for part, base in baseFor(model) do
		if part.Parent then
			part.Transparency = base + (MAX_TRANSPARENCY - base) * p
		end
	end
end

-- Finish a spill (its fade reached MAX_TRANSPARENCY): hide it locally, count it toward the
-- completion bar, tell the server, and drop its (now full) bar along with the spill.
local function completeSpill(model: Model)
	doneSpills[model] = true
	progress[model] = 1
	JobController.onSpillCleaned(model)
	CleanSpill:FireServer(model)
	local bar = bars[model]
	if bar then
		bar.gui:Destroy()
		bars[model] = nil
	end
end

-- Per frame while holding click: fade the spill under the aim, updating its persistent bar. The
-- bar is NOT torn down when the player releases or looks away -- once they've started a spill its
-- bar stays until the spill is finished (destroyed here) or the job changes (clearAllBars).
local function onHeartbeat(dt: number)
	if not firing or equippedTool == nil or not hasActiveJob() then
		setMopSound(false)
		return
	end

	local result = aim()
	if not result then
		setMopSound(false)
		return
	end
	local identity = SpillResolver.resolve(result.Instance)
	-- Only spills of the business whose job we hold, and not already finished this job.
	if
		not identity
		or identity.businessId ~= localPlayer:GetAttribute(Config.ActiveJobAttribute)
		or doneSpills[identity.model]
	then
		setMopSound(false)
		return
	end
	local model = identity.model

	-- Actively mopping a spill now: keep the loop playing.
	setMopSound(true)

	-- Create the spill's bar on first contact, then keep it up for the rest of the job.
	local fill = ensureBar(model)

	-- Advance the fade by Power per second and apply it.
	local p = math.clamp((progress[model] or 0) + getPower() * dt, 0, 1)
	progress[model] = p
	applyFade(model, p)
	if fill then
		fill.Size = UDim2.fromScale(p, 1)
	end

	if p >= 1 then
		completeSpill(model)
	end
end

local function startFiring()
	firing = true
end

local function stopFiring()
	firing = false
	setMopSound(false)
end

local function bindTool(tool: Tool)
	tool.Equipped:Connect(function()
		equippedTool = tool
		-- Mobile cleans continuously while equipped + on a job (see IS_MOBILE); desktop/console
		-- wait for a hold.
		if IS_MOBILE then
			startFiring()
		end
	end)
	tool.Activated:Connect(function()
		if IS_MOBILE then
			return -- taps are look/aim gestures on touch; firing is tied to equip
		end
		if equippedTool == tool then
			startFiring()
		end
	end)
	tool.Deactivated:Connect(function()
		if IS_MOBILE then
			return
		end
		stopFiring()
	end)
	tool.Unequipped:Connect(function()
		if equippedTool == tool then
			equippedTool = nil
			stopFiring()
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

function MopController.init()
	-- Short looping swish played while actively mopping a spill (see setMopSound).
	mopSound = SoundManager.createSustained("MopNoise")

	-- Whenever the job changes (loading a new job, or the current one ending), undo every fade we
	-- applied this job so the spills are visually dirty again for the next run, then drop our
	-- per-spill state. We restore the transparency here -- from the base snapshots we took -- rather
	-- than relying on SpillVisibility, so a mop-faded spill is guaranteed reset even if its
	-- visibility tracking misses it. applyFade(_, 0) sets each faded part back to its base.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(function()
		for model in bases do
			applyFade(model, 0)
		end
		table.clear(progress)
		table.clear(bases)
		table.clear(doneSpills)
		clearAllBars()
	end)

	watch(localPlayer)
	localPlayer.CharacterAdded:Connect(watch)
	if localPlayer.Character then
		watch(localPlayer.Character)
	end

	RunService.Heartbeat:Connect(onHeartbeat)
end

return MopController
