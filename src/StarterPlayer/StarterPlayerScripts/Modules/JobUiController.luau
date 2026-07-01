--!strict

-- Drives the job board UI (PlayerGui.ScreenGui: JobButton + JobFrame). The JobButton
-- toggles the JobFrame; the frame's ExitButton closes it. The frame's ScrollingFrame
-- holds one TaskDesign per business, each tagged with a "BusinessId" attribute: a row
-- shows its WashButton if the local player has that business Unlocked, or its
-- LockedButton if not. Pressing Wash accepts that business's job (AcceptJob), which the
-- server confirms by publishing the businessId on the ActiveJob attribute.
--
-- While a job is active the whole job UI hides (JobButton + JobFrame) -- you can't start
-- another until this one finishes. When the job completes the server clears ActiveJob and
-- the JobButton returns. So visibility of the job UI is driven off that one attribute,
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
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local AcceptJob = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AcceptJob") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local BUSINESS_ID_ATTRIBUTE = "BusinessId"
-- Keyboard shortcut that toggles the board, same as clicking the JobButton.
local TOGGLE_KEY = Enum.KeyCode.B
-- UI click sound played for the keyboard shortcut (the JobButton gets it automatically
-- from UiSoundController's per-GuiButton wiring; the key press doesn't).
local CLICK_SOUND = "UIClick"

local JobUiController = {}

-- Current top-level UI elements, refreshed each time the ScreenGui is (re)bound.
local jobButton: ImageButton? = nil
local jobFrame: Frame? = nil
-- Drives the board's open/close (slide + expand) animation; rebuilt per bind alongside
-- jobFrame since the ScreenGui is re-cloned each respawn.
local jobPanel: UiAnimations.Panel? = nil

-- One refresher per TaskDesign row, rebuilt on each bind; re-evaluates its lock state.
local taskRefreshers: { () -> () } = {}

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
-- when it clears (job finished). Guards the post-respawn gap before anything is bound.
local function applyActiveJobState()
	local active = hasActiveJob()
	local button = jobButton
	if button and button.Parent then
		button.Visible = not active
	end
	local frame = jobFrame
	local panel = jobPanel
	if active and frame and frame.Parent and panel then
		panel:hideInstant()
	end
end

-- Toggle the board open/closed. Shared by the JobButton and the TOGGLE_KEY shortcut.
-- No-op (returns false) while on a job (the whole UI is hidden then) or before anything
-- is bound; returns true when it actually toggled, so the key path can play its click.
local function toggleBoard(): boolean
	local frame = jobFrame
	local panel = jobPanel
	if not frame or not frame.Parent or not panel or panel:isAnimating() or hasActiveJob() then
		return false
	end
	if frame.Visible then
		panel:close()
	else
		refreshTasks() -- pick up any unlocks since it was last shown
		panel:open()
	end
	return true
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
	local button = screenGui:WaitForChild("JobButton") :: ImageButton
	local frame = screenGui:WaitForChild("JobFrame") :: Frame
	local exitButton = frame:WaitForChild("ExitButton") :: ImageButton
	local scroll = frame:WaitForChild("ScrollingFrame")

	jobButton = button
	jobFrame = frame
	jobPanel = UiAnimations.Panel.new(frame)
	frame.Visible = false

	button.Activated:Connect(toggleBoard)
	UiAnimations.hoverGrow(button)

	exitButton.Activated:Connect(function()
		if jobPanel then
			jobPanel:close()
		end
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
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(applyActiveJobState)
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
