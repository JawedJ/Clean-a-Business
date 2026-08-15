--!strict

-- The standalone "play together" button (PlayerGui.ScreenGui.PlayTogetherFrame.PlayTogetherBtn):
-- the way into the party screens. Pressing it opens the party you're in, or the create/browse choice
-- if you aren't in one -- PartyUiController owns both, and everything past that first press. This
-- controller owns only the two rules the BUTTON has:
--
--   * the whole frame is shown exactly when the HUD clusters are, which it has to be TOLD (it's
--     authored as a direct child of the ScreenGui, so no cluster hides it for us -- the same reason
--     ShopUiController hides its ShopAlternateBtn). That's a job's whole duration AND the finished
--     job's summary afterwards: the button comes back on the GoHome that dismisses the summary, not
--     the earlier moment the job ended, so it can't pop up over the summary. JobUiController owns
--     that hold, so this follows it through onHudVisibilityChanged rather than re-deriving it from
--     the ActiveJob attribute, which would come back a screen too early.
--   * clicking it does nothing for the tutorial's duration -- no step invites it, and the onboarding
--     flow shouldn't be interruptible by it.
--
-- The ScreenGui is re-cloned on every respawn, so we re-bind to the fresh instances each time one
-- appears (same pattern as MissingHighlightController).

local Players = game:GetService("Players")

local JobUiController = require(script.Parent.JobUiController)
local PartyUiController = require(script.Parent.PartyUiController)
local TutorialState = require(script.Parent.TutorialState)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local FRAME_NAME = "PlayTogetherFrame"
local BUTTON_NAME = "PlayTogetherBtn"

local PlayTogetherController = {}

-- The currently bound frame, refreshed each time the ScreenGui is (re)bound.
local frame: Frame? = nil

-- Show the frame exactly when the HUD clusters show, which JobUiController decides (a job hides it,
-- and it stays hidden through the finished job's summary until GoHome). Guards the post-respawn gap
-- before anything is bound.
local function applyHudVisibility()
	local current = frame
	if current and current.Parent then
		current.Visible = JobUiController.isHudVisible()
	end
end

local function onActivated()
	-- Locked for the tutorial's duration: a click is simply swallowed.
	if TutorialState.isRestricting() then
		return
	end
	PartyUiController.openEntry()
end

local function bind(screenGui: Instance)
	local playFrame = screenGui:WaitForChild(FRAME_NAME) :: Frame
	local button = playFrame:WaitForChild(BUTTON_NAME) :: ImageButton

	frame = playFrame
	button.Activated:Connect(onActivated)

	applyHudVisibility()
end

function PlayTogetherController.init()
	-- Fires immediately with the current state, and on every flip after -- including the GoHome that
	-- releases the summary hold, which is the moment the HUD comes back.
	JobUiController.onHudVisibilityChanged(applyHudVisibility)

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
