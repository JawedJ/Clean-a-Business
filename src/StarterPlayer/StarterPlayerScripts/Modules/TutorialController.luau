--!strict

-- The onboarding tutorial's client half: it RENDERS the step the server says the player is on, and
-- applies that step's UI locks. It decides nothing about progression -- TutorialService owns the
-- step number (see TutorialConfig for why) and publishes it on the player's TutorialStep attribute.
-- This module reacts to that attribute changing and does four things per step:
--
--   * Types the step's line into TutorialGui.TutorialText, one character at a time, each with a
--     click of the TypingAudio SFX.
--   * Points a scrolling-arrow Beam from the player at whatever the step wants them to walk to --
--     a plot button's Interact pad, a warehouse board's hitbox, the shredder's mouth, or the
--     nearest piece of garbage still left in the job they're on.
--   * Shows the step's TutorialGui overlay (the Wash / Unlock button highlights).
--   * Narrows the UI down to what the step needs, through TutorialState: which panel may be
--     opened, whether it may be closed again, whether the job board scrolls, and which tool may be
--     bought. Everything the step doesn't name is locked. The server enforces the same rules for
--     real; these just stop the UI offering an action that would be refused.
--
-- Two steps can only be seen to finish from here -- a text-only step serving out its hold, and the
-- job board actually appearing on screen -- and those are reported back over TutorialEvent, tagged
-- with the step number so a late report can't skip the server ahead.
--
-- Nothing here persists past the tutorial: when the server clears the attributes, every lock is
-- dropped, the beam and overlays go away, and the label hides. A player who rejoins mid-tutorial
-- never re-enters this state at all (TutorialService marks it done at the start), so there's no
-- path where a lock outlives a session.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local ShredderResolver = require(ReplicatedStorage.SharedModules.ShredderResolver)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local TutorialConfig = require(ReplicatedStorage.SharedModules.TutorialConfig)

local GarbageVisibility = require(script.Parent.GarbageVisibility)
local JobUiController = require(script.Parent.JobUiController)
local TutorialState = require(script.Parent.TutorialState)
local UpgradesUiController = require(script.Parent.UpgradesUiController)

local TutorialEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("TutorialEvent") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- The job board's scrolling list, frozen (and scrolled back to the top) while the tutorial has the
-- board open, so the player can only reach the first row -- the one the highlight is pointing at.
local JOB_SCROLL_NAME = "ScrollingFrame"
local WAREHOUSE_NAME = "Warehouse"

-- How much closer (studs) another piece of garbage has to be before the beam gives up on the one
-- it's already pointing at. Without it the arrow would swap pieces -- and so rebuild the whole beam
-- -- every time the player's wandering changed which of two nearby pieces ranked first.
local BEAM_GARBAGE_STICKINESS = 6

local TutorialController = {}

-- TutorialGui elements, resolved once (the GUI is authored ResetOnSpawn = false, so unlike the
-- main HUD it is NOT re-cloned on respawn and these stay valid for the session).
local tutorialGui: ScreenGui? = nil
local textLabel: TextLabel? = nil
-- Every overlay under TutorialGui by name, so a step can show its one and we can blank the rest
-- without knowing which was up.
local highlights: { [string]: GuiObject } = {}

-- The step currently being rendered, or nil when the tutorial isn't running.
local activeStep: TutorialConfig.Step? = nil

-- Bumped every time a new step starts typing. The typewriter coroutine captures the value and
-- stops the moment it no longer matches, so a step change mid-type (or the tutorial ending) can
-- never leave two coroutines writing to the same label.
local typeToken = 0

-- Step numbers we've already reported finishing, so a re-render (or the board being seen open on
-- two consecutive frames) can't fire the same report twice.
local reported: { [number]: boolean } = {}

-- The beam and its two attachments, plus the part it's currently aimed at so we can tell when the
-- target has changed (or gone away) and needs rebuilding.
local beam: Beam? = nil
local originAttachment: Attachment? = nil
local targetAttachment: Attachment? = nil
local beamTargetPart: BasePart? = nil

-- The piece of garbage the "Garbage" beam settled on, kept between frames so it can stay on it (see
-- BEAM_GARBAGE_STICKINESS). Never needs clearing: it's only ever compared by identity against the
-- pieces still live in GarbageVisibility, so once the piece is shredded this stops matching anything
-- by itself and the next frame picks afresh.
local beamGarbagePart: BasePart? = nil

-- === TutorialGui ====================================================================

local function bindGui(gui: ScreenGui)
	tutorialGui = gui
	textLabel = gui:FindFirstChild(TutorialConfig.TextLabelName) :: TextLabel?
	highlights = {}
	for _, child in gui:GetChildren() do
		if child:IsA("GuiObject") and child ~= textLabel then
			highlights[child.Name] = child
		end
	end
end

-- Show only `name`'s overlay (or none, when nil). Called on every step change and whenever the
-- panel a highlight is waiting on opens or closes.
local function showHighlight(name: string?)
	for highlightName, element in highlights do
		element.Visible = highlightName == name
	end
end

-- === Highlight placement ============================================================

-- The control a highlight should sit on, or nil if that panel isn't built yet. Rows and slots are
-- matched on the tagging attribute their own controllers use, not on order, so a reordered board
-- or shop still finds the right one.
local function resolveHighlightTarget(spec: TutorialConfig.HighlightTarget): GuiObject?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local screenGui = playerGui and playerGui:FindFirstChild(SCREEN_GUI_NAME)
	local frame = screenGui and screenGui:FindFirstChild(spec.frame)
	local container = frame and frame:FindFirstChild(spec.container)
	if not container then
		return nil
	end
	for _, child in container:GetChildren() do
		if child:GetAttribute(spec.attribute) == spec.id then
			local button = child:FindFirstChild(spec.button)
			return if button and button:IsA("GuiObject") then button :: GuiObject else nil
		end
	end
	return nil
end

-- Centre a highlight on its target control, keeping the highlight's own authored size.
--
-- Done by nudging its Position by the gap between the two centres ON SCREEN, rather than
-- converting the target's absolute position into the overlay's coordinate space. The overlay is in
-- a different ScreenGui, so a coordinate conversion would have to account for that GUI's inset and
-- canvas origin; a delta in absolute pixels is the same number in either GUI's offsets, so this
-- needs to know nothing about either. One frame's nudge lands it exactly, and re-running keeps it
-- there as the panel animates open, the window resizes, or the row is rebuilt.
local function trackHighlight(name: string)
	local element = highlights[name]
	local spec = TutorialConfig.HighlightTargets[name]
	if not element or not spec then
		return
	end
	local target = resolveHighlightTarget(spec)
	-- Not laid out yet (panel never opened this session): nothing meaningful to measure against.
	if not target or target.AbsoluteSize.X <= 0 or element.AbsoluteSize.X <= 0 then
		return
	end

	local delta = (target.AbsolutePosition + target.AbsoluteSize * 0.5)
		- (element.AbsolutePosition + element.AbsoluteSize * 0.5)
	-- Already there; don't rewrite Position (and dirty the layout) every single frame.
	if delta.Magnitude < 0.5 then
		return
	end

	local position = element.Position
	element.Position = UDim2.new(
		position.X.Scale,
		position.X.Offset + delta.X,
		position.Y.Scale,
		position.Y.Offset + delta.Y
	)
end

-- === Typewriter =====================================================================

-- Type `text` into the label a character at a time, clicking TypingAudio for each, then run
-- `onFinished`. Superseded immediately by the next call (see typeToken). Iterates UTF-8 code
-- points rather than bytes so a multi-byte character is never split into garbage mid-type.
local function typeText(text: string, onFinished: (() -> ())?)
	typeToken += 1
	local token = typeToken

	local label = textLabel
	if not label then
		return
	end
	label.Text = ""
	label.Visible = true

	task.spawn(function()
		local shown = ""
		for _, code in utf8.codes(text) do
			-- A newer step (or the end of the tutorial) has taken over: stop writing.
			if typeToken ~= token then
				return
			end
			shown ..= utf8.char(code)
			label.Text = shown
			SoundManager.playOneShot(TutorialConfig.TypingSound)
			task.wait(TutorialConfig.SecondsPerCharacter)
		end
		if typeToken ~= token then
			return
		end
		if onFinished then
			onFinished()
		end
	end)
end

-- === Reporting ======================================================================

-- Tell the server a step we're rendering has finished, once. The step number goes with it so the
-- server can drop a report that no longer matches the step it has us on.
local function report(reportName: string, stepNumber: number)
	if reported[stepNumber] then
		return
	end
	reported[stepNumber] = true
	TutorialEvent:FireServer(reportName, stepNumber)
end

-- === Beam ===========================================================================

local function destroyBeam()
	if beam then
		beam:Destroy()
		beam = nil
	end
	if originAttachment then
		originAttachment:Destroy()
		originAttachment = nil
	end
	if targetAttachment then
		targetAttachment:Destroy()
		targetAttachment = nil
	end
	beamTargetPart = nil
end

-- A piece of garbage as something the beam can end on: the piece itself when it's a bare part, else
-- the model's primary part (or any part of it, for a model authored without one).
local function garbagePart(piece: PVInstance): BasePart?
	if piece:IsA("BasePart") then
		return piece
	end
	local model = piece :: Model
	local part: Instance? = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	return if part and part:IsA("BasePart") then part else nil
end

-- The piece of the current job's remaining garbage to point at: the nearest one to the player, but
-- STICKY -- the piece already being pointed at keeps the beam unless it's gone (shredded, or the job
-- ended) or another is meaningfully closer. The set comes from GarbageVisibility, which holds only
-- what's still in the world to clean, so a shredded piece drops out of the running by itself.
local function resolveGarbageTarget(root: BasePart): BasePart?
	local nearest: BasePart? = nil
	local nearestDistance = math.huge
	local currentDistance: number? = nil

	for _, piece in GarbageVisibility.getPieces() do
		local part = garbagePart(piece)
		if part then
			local distance = (part.Position - root.Position).Magnitude
			-- Matched by identity against a LIVE piece, so a stale beamGarbagePart can never win.
			if part == beamGarbagePart then
				currentDistance = distance
			end
			if distance < nearestDistance then
				nearest = part
				nearestDistance = distance
			end
		end
	end

	if currentDistance and currentDistance <= nearestDistance + BEAM_GARBAGE_STICKINESS then
		return beamGarbagePart
	end
	beamGarbagePart = nearest
	return nearest
end

-- Whatever the step's beam target names, or nil if any link isn't there yet. Resolved lazily every
-- frame the beam is wanted, exactly like the warehouse proximity hitboxes, so a plot assigned or a
-- building streamed in late just starts working.
--
-- Two kinds hang off the JOB rather than the plot, so they're answered first and never touch it: a
-- player being walked to the shredder or to a piece of garbage is stood inside the business.
local function resolveBeamTarget(target: TutorialConfig.BeamTarget, root: BasePart): BasePart?
	if target.kind == "Garbage" or target.kind == "Shredder" then
		local businessId = localPlayer:GetAttribute(Config.ActiveJobAttribute)
		if type(businessId) ~= "string" then
			return nil -- between jobs: nothing to point into
		end
		if target.kind == "Garbage" then
			return resolveGarbageTarget(root)
		end
		local shredder = ShredderResolver.find(businessId)
		-- p1, the mouth -- the end the player has to walk their armful to.
		return if shredder then shredder.entry else nil
	end

	local plotName = localPlayer:GetAttribute(Config.PlotAttribute)
	if type(plotName) ~= "string" then
		return nil
	end
	local plotsFolder = Workspace:FindFirstChild(Config.PlotsFolderName)
	local plot = plotsFolder and plotsFolder:FindFirstChild(plotName)
	if not plot then
		return nil
	end

	local part: Instance? = nil
	if target.kind == "PlotButton" then
		local buttons = plot:FindFirstChild(Config.PlotButtonsFolderName)
		local button = target.name and buttons and buttons:FindFirstChild(target.name)
		part = button and button:FindFirstChild(Config.PlotButtonInteractPartName, true)
	else
		local warehouse = plot:FindFirstChild(WAREHOUSE_NAME)
		local board = target.name and warehouse and warehouse:FindFirstChild(target.name)
		local union = board and target.union and board:FindFirstChild(target.union)
		part = union and union:FindFirstChild(Config.HitboxName)
	end

	return if part and part:IsA("BasePart") then part :: BasePart else nil
end

-- Build the beam between the character and `targetPart`. The arrow texture is tiled along it and
-- scrolled from Attachment0 (the player) toward Attachment1 (the target), so the arrows always
-- read as pointing the way to walk.
local function buildBeam(root: BasePart, targetPart: BasePart)
	destroyBeam()

	local origin = Instance.new("Attachment")
	origin.Name = "TutorialBeamOrigin"
	origin.Position = Vector3.new(0, TutorialConfig.BeamPlayerHeight, 0)
	origin.Parent = root

	local destination = Instance.new("Attachment")
	destination.Name = "TutorialBeamTarget"
	destination.Parent = targetPart
	-- Set the WORLD position rather than a local offset: the buttons and board hitboxes are
	-- authored at whatever orientation suits the plot, so a local +Y offset would tilt with the
	-- part instead of lifting the beam's end straight up off the floor.
	destination.WorldPosition = targetPart.Position + Vector3.new(0, TutorialConfig.BeamTargetHeight, 0)

	local newBeam = Instance.new("Beam")
	newBeam.Name = "TutorialBeam"
	newBeam.Attachment0 = origin
	newBeam.Attachment1 = destination
	newBeam.Texture = TutorialConfig.BeamTexture
	newBeam.TextureMode = Enum.TextureMode.Wrap
	newBeam.TextureLength = TutorialConfig.BeamTextureLength
	newBeam.TextureSpeed = TutorialConfig.BeamTextureSpeed
	newBeam.Color = ColorSequence.new(TutorialConfig.BeamColor)
	newBeam.LightEmission = 1
	newBeam.FaceCamera = true
	newBeam.Width0 = TutorialConfig.BeamWidth
	newBeam.Width1 = TutorialConfig.BeamWidth
	-- A straight run between the two points; the default curve would bow it away from the target.
	newBeam.CurveSize0 = 0
	newBeam.CurveSize1 = 0
	newBeam.Parent = root

	beam = newBeam
	originAttachment = origin
	targetAttachment = destination
	beamTargetPart = targetPart
end

-- Keep the beam matching the current step, every frame: no target (or no character / plot yet)
-- tears it down, a new or replaced target rebuilds it. Rebuilding rather than re-pointing covers
-- the respawn case for free -- the old attachment died with the old character, so the beam is
-- simply built again on the new one.
local function stepBeam()
	local step = activeStep
	local target = step and step.beam
	if not target then
		if beam then
			destroyBeam()
		end
		return
	end

	-- The root comes first here because the "Garbage" target is resolved RELATIVE to it (nearest
	-- piece to the player), not just used as the beam's near end.
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		if beam then
			destroyBeam()
		end
		return
	end

	local targetPart = resolveBeamTarget(target, root)
	if not targetPart then
		if beam then
			destroyBeam()
		end
		return
	end

	-- Still pointing at the same part from the same (living) character: nothing to do.
	if beam and beamTargetPart == targetPart and originAttachment and originAttachment.Parent == root then
		return
	end
	buildBeam(root, targetPart)
end

-- === Job board scroll lock ==========================================================

-- Freeze or release the job board's list. Freezing also scrolls it back to the top, so the row the
-- WashButtonHighlight is pointing at is the one on screen. Re-applied per frame from stepUi
-- because the whole HUD ScreenGui is re-cloned on respawn -- a fresh clone comes back scrollable.
local function applyJobScrollLock(locked: boolean)
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local screenGui = playerGui and playerGui:FindFirstChild(SCREEN_GUI_NAME)
	local jobFrame = screenGui and screenGui:FindFirstChild("JobFrame")
	local scroll = jobFrame and jobFrame:FindFirstChild(JOB_SCROLL_NAME)
	if not scroll or not scroll:IsA("ScrollingFrame") then
		return
	end
	if scroll.ScrollingEnabled ~= not locked then
		scroll.ScrollingEnabled = not locked
		if locked then
			scroll.CanvasPosition = Vector2.zero
		end
	end
end

-- === Per-frame step upkeep ==========================================================

-- The parts of a step that depend on live UI state rather than the step change itself: the beam's
-- target, the scroll lock surviving a respawn, the panel-gated highlight, and noticing that the
-- job board has come up on screen (which is what ends the OpenJobBoard step).
local function stepUi()
	local step = activeStep
	stepBeam()
	if not step then
		return
	end

	applyJobScrollLock(step.lockJobScroll == true)

	-- Whether the step's panel is currently up, asked of whichever controller owns it.
	local panelOpen = false
	if step.panel == "JobBoard" then
		panelOpen = JobUiController.isBoardVisible()
	elseif step.panel == "Upgrades" then
		panelOpen = UpgradesUiController.isShopVisible()
	end

	-- A highlight that waits on its panel (the Unlock one) tracks the panel opening and closing;
	-- the rest are simply shown for the whole step by enterStep.
	if step.highlight and step.highlightNeedsPanel then
		showHighlight(if panelOpen then step.highlight else nil)
	end

	-- Keep the overlay parked on the control it points at. Done whether or not it's visible yet, so
	-- it's already in the right place the frame it appears rather than flashing at its authored spot
	-- for one frame first.
	if step.highlight then
		trackHighlight(step.highlight)
	end

	-- A BoardOpen step ends when the board is actually on the player's screen, however they opened it.
	if step.advance == "BoardOpen" and panelOpen then
		report(TutorialConfig.Report.BoardOpened, step.number)
	end
end

-- === Step changes ===================================================================

-- Narrow the UI to what this step needs. Read as an allow-list: the step's panel is the only one
-- that opens, its tool the only one that can be bought, and nothing else is permitted -- so a
-- panel or purchase path added later is locked during the tutorial by default. The closing step
-- lifts the lot (see Step.unrestricted).
local function applyRestrictions(step: TutorialConfig.Step)
	if step.unrestricted then
		TutorialState.clear()
		return
	end

	local openable: { [string]: boolean } = {}
	local pinned: { [string]: boolean } = {}
	if step.panel then
		openable[step.panel] = true
		if step.panelCloseLocked then
			pinned[step.panel] = true
		end
	end

	TutorialState.setOpenAllowed(openable)
	TutorialState.setCloseLocked(pinned)
	-- nil here means "no tool at all", which is what every step but the broom one wants.
	TutorialState.setToolAllowed(step.tool)
	TutorialState.setUpgradesAllowed(false)
end

-- Render a step: lock the UI down for it, show its overlay, and start typing. A text-only step
-- reports itself finished after the hold; the rest end on something stepUi or the server sees.
local function enterStep(step: TutorialConfig.Step)
	activeStep = step
	applyRestrictions(step)

	-- A panel-gated highlight is left to stepUi, which shows it only while that panel is open.
	showHighlight(if step.highlight and not step.highlightNeedsPanel then step.highlight else nil)

	local text = localPlayer:GetAttribute(TutorialConfig.TextAttribute)
	typeText(if type(text) == "string" then text else step.text, function()
		if step.advance == "Text" then
			task.wait(TutorialConfig.TextHoldSeconds)
			-- Superseded while we held (shouldn't happen for a text step, but the hold is a yield).
			if activeStep ~= step then
				return
			end
			-- The closing line has nothing after it, so it clears itself off the screen at the end
			-- of its own hold rather than lingering until the server's acknowledgement lands.
			if step.number >= TutorialConfig.StepCount and textLabel then
				textLabel.Visible = false
			end
			report(TutorialConfig.Report.TextDone, step.number)
		elseif step.hideTextAfter then
			task.wait(step.hideTextAfter)
			-- The step ended while we waited: the label now belongs to whatever came next (which
			-- has already made it visible again), so leave it alone.
			if activeStep ~= step then
				return
			end
			if textLabel then
				textLabel.Visible = false
			end
		end
	end)
end

-- The tutorial state ended (or was never running): drop every lock and clear the screen. Bumping
-- typeToken stops any in-flight typewriter before it can write to the label we're hiding.
local function exitTutorial()
	activeStep = nil
	typeToken += 1
	TutorialState.clear()
	destroyBeam()
	showHighlight(nil)
	applyJobScrollLock(false)
	if textLabel then
		textLabel.Visible = false
		textLabel.Text = ""
	end
end

-- The server moved us to a new step, or ended the tutorial.
local function onStepChanged()
	if localPlayer:GetAttribute(TutorialConfig.ActiveAttribute) ~= true then
		exitTutorial()
		return
	end
	local number = localPlayer:GetAttribute(TutorialConfig.StepAttribute)
	local step = if type(number) == "number" then TutorialConfig.get(number) else nil
	if not step then
		exitTutorial()
		return
	end
	if activeStep and activeStep.number == step.number then
		return -- already rendering it (e.g. the text attribute landing after the step number)
	end
	enterStep(step)
end

function TutorialController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	bindGui(playerGui:WaitForChild(TutorialConfig.GuiName) :: ScreenGui)

	-- Start hidden; a step is what puts anything on screen. This also covers the overwhelmingly
	-- common case of a returning player, for whom the tutorial never runs at all.
	showHighlight(nil)
	if textLabel then
		textLabel.Visible = false
	end

	localPlayer:GetAttributeChangedSignal(TutorialConfig.StepAttribute):Connect(onStepChanged)
	localPlayer:GetAttributeChangedSignal(TutorialConfig.ActiveAttribute):Connect(onStepChanged)

	RunService.Heartbeat:Connect(stepUi)

	-- The server may have set the first step before this ran (it starts the tutorial as soon as the
	-- profile loads, which can beat client init), so pick up whatever is already there.
	onStepChanged()
end

return TutorialController
