--!strict

-- Drives the job board UI (PlayerGui.ScreenGui: Buttons.JobButton + JobFrame). The JobButton
-- toggles the JobFrame; the frame's ExitButton closes it. The frame's ScrollingFrame
-- holds one TaskDesign per business, each tagged with a "BusinessId" attribute: a row
-- shows its WashButton if the local player has that business Unlocked, or its
-- LockedButton if not. Pressing Wash accepts that business's job (AcceptJob), which the
-- server confirms by publishing the businessId on the ActiveJob attribute.
--
-- While a job is active the whole job UI hides (the Buttons frame + JobFrame) -- you can't
-- start another until this one finishes. When the job completes the server clears ActiveJob
-- and the Buttons frame returns. So visibility of the job UI is driven off that one attribute,
-- exactly like JobController drives the overlays.
--
-- Unlock state comes from DataService and is re-read whenever BusinessList changes or the
-- frame is opened, so unlocking a business flips its row from Locked to Wash live.
--
-- Like the other HUD controllers, the ScreenGui is re-cloned into PlayerGui on every
-- respawn, so we re-bind to the fresh instances each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local ExclusivePanels = require(script.Parent.ExclusivePanels)

local AcceptJob = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AcceptJob") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Stable name this panel registers under with ExclusivePanels (only one exclusive panel is
-- open at a time; opening this closes the upgrades shop first, and vice versa).
local PANEL_NAME = "JobBoard"
local BUSINESS_ID_ATTRIBUTE = "BusinessId"
-- Keyboard shortcut that toggles the board, same as clicking the JobButton.
local TOGGLE_KEY = Enum.KeyCode.B
-- UI click sound played for the keyboard shortcut (the JobButton gets it automatically
-- from UiSoundController's per-GuiButton wiring; the key press doesn't).
local CLICK_SOUND = "UIClick"
-- The stacked HUD clusters (top-to-bottom: Button1, Buttons2, Buttons3) open up around whichever
-- one a button is hovered in: frames above it slide up by this much, frames below slide down, and
-- the hovered one holds. Y scale, so it tracks the screen at any resolution.
local CLUSTER_HOVER_SPREAD = 0.003

local JobUiController = {}

-- Current top-level UI elements, refreshed each time the ScreenGui is (re)bound. All HUD
-- cluster frames (Button1: JobButton + UpgradesButton; Buttons2; Buttons3) hide during a job, so
-- no HUD buttons show mid-job.
local buttonsFrame: Frame? = nil
local buttons2Frame: Frame? = nil
local buttons3Frame: Frame? = nil
local jobFrame: Frame? = nil
-- Drives the board's open/close (slide + expand) animation; rebuilt per bind alongside
-- jobFrame since the ScreenGui is re-cloned each respawn.
local jobPanel: UiAnimations.Panel? = nil

-- One refresher per TaskDesign row, rebuilt on each bind; re-evaluates its lock state.
local taskRefreshers: { () -> () } = {}

-- True while a finished job's JobSummary is up: the ActiveJob attribute has cleared, but we
-- keep the whole job UI hidden (the board button must NOT pop back over the summary) until the
-- player leaves the summary via GoHome, which calls releaseSummaryHold. See JobSummaryController.
local summaryHold = false

-- Whether the local player currently holds a job (drives whole-UI visibility).
local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- BusinessList only holds records for businesses the player has, so index it defensively:
-- a not-yet-unlocked business simply has no entry (and so counts as locked).
local function isUnlocked(businessId: string): boolean
	local list = DataService:get({ "BusinessList" })
	local record = if type(list) == "table" then list[businessId] else nil
	return type(record) == "table" and record.Unlocked == true
end

local function refreshTasks()
	for _, refresh in taskRefreshers do
		refresh()
	end
end

-- Show/hide the whole job UI off the ActiveJob attribute: hidden while on a job, back
-- when it clears (job finished). While the summary hold is up the button stays hidden too --
-- the finished job's summary owns the screen until GoHome. Guards the post-respawn gap before
-- anything is bound.
local function applyActiveJobState()
	local active = hasActiveJob()
	local visible = not active and not summaryHold
	local buttons = buttonsFrame
	if buttons and buttons.Parent then
		buttons.Visible = visible
	end
	local buttons2 = buttons2Frame
	if buttons2 and buttons2.Parent then
		buttons2.Visible = visible
	end
	local buttons3 = buttons3Frame
	if buttons3 and buttons3.Parent then
		buttons3.Visible = visible
	end
	local frame = jobFrame
	local panel = jobPanel
	if active and frame and frame.Parent and panel then
		panel:hideInstant()
		ExclusivePanels.markHidden(PANEL_NAME)
	end
end

-- ActiveJob flipped: a job starting clears any summary hold; a job ending enters one (its
-- summary is now showing) so the board button stays hidden until GoHome releases it.
local function onActiveJobChanged()
	summaryHold = not hasActiveJob()
	applyActiveJobState()
end

-- Called when the player leaves the JobSummary via GoHome: end the hold and let the board
-- button (and B shortcut) come back.
function JobUiController.releaseSummaryHold()
	summaryHold = false
	applyActiveJobState()
end

-- Toggle the board open/closed via the shared coordinator (so opening it closes the upgrades
-- shop first, and vice versa). Shared by the JobButton and the TOGGLE_KEY shortcut. No-op
-- (returns false) while on a job, during the summary hold, or before anything is bound; returns
-- true when it actually toggled, so the key path can play its click. The board's contents are
-- refreshed via the coordinator's beforeOpen (refreshTasks) right before it opens.
local function toggleBoard(): boolean
	if hasActiveJob() or summaryHold then
		return false
	end
	return ExclusivePanels.toggle(PANEL_NAME)
end

-- Wire one TaskDesign row and return its refresher, or nil if it isn't a real row
-- (skips the UIListLayout/constraints, which carry no BusinessId + buttons).
local function bindTask(row: Instance): (() -> ())?
	local businessId = row:GetAttribute(BUSINESS_ID_ATTRIBUTE)
	if type(businessId) ~= "string" then
		return nil
	end
	local wash = row:FindFirstChild("WashButton") :: ImageButton?
	local locked = row:FindFirstChild("LockedButton") :: ImageButton?
	if not wash or not locked then
		return nil
	end
	local washButton, lockedButton = wash, locked

	local function refresh()
		local unlocked = isUnlocked(businessId)
		washButton.Visible = unlocked
		lockedButton.Visible = not unlocked
	end

	washButton.Activated:Connect(function()
		if not isUnlocked(businessId) or hasActiveJob() then
			return
		end
		-- On success the server sets ActiveJob, which hides the whole job UI via
		-- applyActiveJobState -- so there's nothing to close here.
		AcceptJob:FireServer(businessId)
	end)

	refresh()
	return refresh
end

-- Resolve one ScreenGui's job elements, wire the buttons + rows, then apply current
-- state (lock rows + active-job visibility). Yields on WaitForChild for a fresh clone.
local function bind(screenGui: Instance)
	local button1 = screenGui:WaitForChild("Button1")
	local buttons2 = screenGui:WaitForChild("Buttons2")
	local buttons3 = screenGui:WaitForChild("Buttons3")
	local button = button1:WaitForChild("JobButton") :: ImageButton
	local frame = screenGui:WaitForChild("JobFrame") :: Frame
	local exitButton = frame:WaitForChild("ExitButton") :: ImageButton
	local scroll = frame:WaitForChild("ScrollingFrame")

	local panel = UiAnimations.Panel.new(frame)
	buttonsFrame = button1 :: Frame
	buttons2Frame = buttons2 :: Frame
	buttons3Frame = buttons3 :: Frame
	jobFrame = frame
	jobPanel = panel
	frame.Visible = false

	-- Register with the coordinator so open/close is sequenced against the other panels; it
	-- refreshes the task rows (beforeOpen) right before showing.
	ExclusivePanels.register(PANEL_NAME, panel, refreshTasks)

	button.Activated:Connect(toggleBoard)

	-- Every button in every HUD cluster gets the same hover polish as the JobButton: a center
	-- grow that also pushes its row-neighbours aside (via the shared grid's padding) so the
	-- growing button keeps a constant gap instead of overlapping them.
	UiAnimations.hoverGrowCluster(button1 :: GuiObject)
	UiAnimations.hoverGrowCluster(buttons2 :: GuiObject)
	UiAnimations.hoverGrowCluster(buttons3 :: GuiObject)

	-- While a button in one cluster is hovered, push the others away from it (clusters above slide
	-- up, those below slide down) so the stack opens up around the hovered one.
	UiAnimations.spreadStackOnHover({
		button1 :: GuiObject,
		buttons2 :: GuiObject,
		buttons3 :: GuiObject,
	}, CLUSTER_HOVER_SPREAD)

	-- Grow the close button on hover, like the cluster buttons above (its hover sound is wired
	-- centrally in UiSoundController).
	UiAnimations.hoverGrow(exitButton)
	exitButton.Activated:Connect(function()
		ExclusivePanels.close(PANEL_NAME)
	end)

	taskRefreshers = {}
	for _, child in scroll:GetChildren() do
		local refresh = bindTask(child)
		if refresh then
			table.insert(taskRefreshers, refresh)
		end
	end

	applyActiveJobState()
end

function JobUiController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Persistent subscriptions; each reads whichever elements/rows are currently bound.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(onActiveJobChanged)
	DataService:getChangedSignal({ "BusinessList" }):Connect(refreshTasks)

	-- TOGGLE_KEY opens/closes the board just like the JobButton. Ignore it when the
	-- keystroke was already consumed by the game (e.g. typing in a TextBox).
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == TOGGLE_KEY and toggleBoard() then
			SoundManager.playOneShot(CLICK_SOUND)
		end
	end)

	local function onChild(child: Instance)
		if child.Name == SCREEN_GUI_NAME then
			task.spawn(bind, child)
		end
	end
	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
	playerGui.ChildAdded:Connect(onChild)
end

return JobUiController
