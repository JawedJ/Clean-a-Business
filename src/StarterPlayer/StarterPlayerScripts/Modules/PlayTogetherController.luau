--!strict

-- The standalone "play together" button (PlayerGui.ScreenGui.PlayTogetherFrame.PlayTogetherBtn).
-- The button has no action wired to it yet; this controller owns the two rules it already needs:
--
--   * the whole frame hides while the local player is on a job, so it doesn't sit over the job UI
--     (it's authored as a direct child of the ScreenGui, so no HUD cluster hides it for us -- the
--     same reason ShopUiController hides its ShopAlternateBtn), and
--   * clicking it does nothing for the tutorial's duration -- no step invites it, and the onboarding
--     flow shouldn't be interruptible by it once it does something.
--
-- When the button gains its real behaviour, put it in onActivated below the guard; both rules then
-- apply to it for free.
--
-- The ScreenGui is re-cloned on every respawn, so we re-bind to the fresh instances each time one
-- appears (same pattern as MissingHighlightController).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

local TutorialState = require(script.Parent.TutorialState)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local FRAME_NAME = "PlayTogetherFrame"
local BUTTON_NAME = "PlayTogetherBtn"

local PlayTogetherController = {}

-- The currently bound frame, refreshed each time the ScreenGui is (re)bound.
local frame: Frame? = nil

local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Hide the frame while a job runs, show it otherwise. Guards the post-respawn gap before anything
-- is bound.
local function applyActiveJobState()
	local current = frame
	if current and current.Parent then
		current.Visible = not hasActiveJob()
	end
end

local function onActivated()
	-- Locked for the tutorial's duration: a click is simply swallowed.
	if TutorialState.isRestricting() then
		return
	end
	-- Nothing wired yet -- the button's real action goes here.
end

local function bind(screenGui: Instance)
	local playFrame = screenGui:WaitForChild(FRAME_NAME) :: Frame
	local button = playFrame:WaitForChild(BUTTON_NAME) :: ImageButton

	frame = playFrame
	button.Activated:Connect(onActivated)

	applyActiveJobState()
end

function PlayTogetherController.init()
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(applyActiveJobState)

	local playerGui = localPlayer:WaitForChild("PlayerGui")
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

return PlayTogetherController
