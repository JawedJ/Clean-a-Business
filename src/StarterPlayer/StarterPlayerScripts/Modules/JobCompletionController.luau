--!strict

-- Drives the job completion HUD (PlayerGui.ScreenGui.JobCompletion): a progress bar
-- (CompletionBar.Fillable) that fills as the local player cleans the active job's
-- cleanables, a CompletionBar.PercentageLabel showing the same 0..100%, and a FinishEarly
-- button -- mirrored by the H key -- that stops the job immediately for a prorated share of
-- the reward.
--
-- The whole frame shows only while a job is active: it's the counterpart to the job board,
-- which hides during a job. Visibility is driven off the ActiveJob attribute, the same
-- signal JobController/JobUiController use.
--
-- Progress comes from JobController.onProgressChanged (fired by the active JobClient on each
-- clean). The reward math for finishing early is the SERVER's job -- FinishEarly just fires
-- the remote; the server pays the prorated reward off its own authoritative progress and
-- ends the job, which clears ActiveJob and hides this frame.
--
-- Like the other HUD controllers the ScreenGui is re-cloned on every respawn, so we re-bind
-- to the fresh instances each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local JobController = require(script.Parent.JobController)

local FinishEarly = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FinishEarly") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Keyboard shortcut that finishes the job early, same as clicking the FinishEarly button.
local FINISH_KEY = Enum.KeyCode.H
-- UI click sound for the keyboard shortcut (the button gets it from UiSoundController's
-- per-GuiButton wiring; the key press doesn't).
local CLICK_SOUND = "UIClick"
-- Quick slide of the fill bar toward its new value on each clean.
local FILL_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local JobCompletionController = {}

-- Current HUD elements, refreshed each time the ScreenGui is (re)bound.
local frame: Frame? = nil
local fill: Frame? = nil
local percentageLabel: TextLabel? = nil

-- The fill tween in flight, so a newer clean can supersede it.
local fillTween: Tween? = nil

local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Paint the bar + label to `fraction` (0..1). `animate` tweens the fill (a clean) vs.
-- snapping it (initial show). Guards the post-respawn gap before anything is bound.
local function render(fraction: number, animate: boolean)
	fraction = math.clamp(fraction, 0, 1)
	local bar = fill
	if bar then
		if fillTween then
			fillTween:Cancel()
			fillTween = nil
		end
		local target = UDim2.new(fraction, 0, 1, 0)
		if animate then
			local tween = TweenService:Create(bar, FILL_TWEEN, { Size = target })
			fillTween = tween
			tween:Play()
		else
			bar.Size = target
		end
	end
	if percentageLabel then
		percentageLabel.Text = string.format("%d%%", math.floor(fraction * 100))
	end
end

-- Current completion of the active job (0 if there's none, or it hasn't loaded yet).
local function currentFraction(): number
	local job = JobController.getJob()
	return if job then job:getCompletion() else 0
end

-- Show the frame while on a job, hide it otherwise; snap the bar to the current progress
-- when (re)showing so it reads accurately right away (e.g. after a respawn mid-job).
local function applyActiveJobState()
	local root = frame
	if not root or not root.Parent then
		return
	end
	local active = hasActiveJob()
	root.Visible = active
	if active then
		render(currentFraction(), false)
	end
end

-- Ask the server to end the current job early (prorated reward). No-op if not on a job.
-- Returns whether it fired (so the key path can play its click). The server clears
-- ActiveJob on success, which hides this frame via applyActiveJobState.
local function requestFinishEarly(): boolean
	if not hasActiveJob() then
		return false
	end
	FinishEarly:FireServer()
	return true
end

local function bind(screenGui: Instance)
	local root = screenGui:WaitForChild("JobCompletion") :: Frame
	local bar = root:WaitForChild("CompletionBar")
	local finishButton = root:WaitForChild("FinishEarly") :: ImageButton

	frame = root
	fill = bar:WaitForChild("Fillable") :: Frame
	percentageLabel = bar:WaitForChild("PercentageLabel") :: TextLabel

	finishButton.Activated:Connect(requestFinishEarly)

	applyActiveJobState()
end

function JobCompletionController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Persistent subscriptions; each reads whichever elements are currently bound.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(applyActiveJobState)
	JobController.onProgressChanged(function(fraction)
		render(fraction, true)
	end)

	-- FINISH_KEY finishes the job early just like the button. Ignore it when the keystroke
	-- was already consumed by the game (e.g. typing in a TextBox).
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == FINISH_KEY and requestFinishEarly() then
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

return JobCompletionController
