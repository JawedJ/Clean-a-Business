--!strict

-- The HUD's drop button (PlayerGui.ScreenGui.DropButton): lets go of the piece of garbage the player
-- is carrying.
--
-- TOUCH ONLY. It's the only way to let go on touch -- a tap never drops, since the movement stick and
-- the camera pan region arrive at GarbageCarryController as ordinary unprocessed touches (see
-- TOUCH_CAN_DROP there). A mouse has no such problem: a click already drops, so on desktop the button
-- would be a second way to do what the click does, taking up HUD space for nothing. Same device test
-- as GarbageCarryController's IS_MOBILE, so the two agree on who needs it.
--
-- It shows exactly while our own hands are full, which is only ever DURING a job: garbage can't be
-- picked up without one, and a job ending clears the carry (GarbageCarryController drops everything
-- on the ActiveJob attribute changing), so the same signal that empties our hands hides the button.
-- We don't watch the job attribute ourselves -- one owner of "am I carrying" is enough, and deriving
-- it twice is how the two ends drift apart.
--
-- The button is authored a direct child of the ScreenGui, so no HUD cluster hides it for us; its
-- Visible is ours alone. The ScreenGui is re-cloned on every respawn, so we re-bind to the fresh
-- instances each time one appears (same pattern as PlayTogetherController).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local GarbageCarryController = require(script.Parent.GarbageCarryController)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local BUTTON_NAME = "DropButton"

-- Touch-only devices, matching GarbageCarryController's IS_MOBILE exactly: a device with a keyboard,
-- mouse or gamepad has a real drop input already, so it doesn't get the button.
local IS_MOBILE = UserInputService.TouchEnabled
	and not UserInputService.KeyboardEnabled
	and not UserInputService.MouseEnabled
	and not UserInputService.GamepadEnabled

local DropButtonController = {}

-- The currently bound button, refreshed each time the ScreenGui is (re)bound.
local button: GuiButton? = nil

local function applyVisibility()
	local current = button
	if current and current.Parent then
		current.Visible = IS_MOBILE and GarbageCarryController.isCarrying()
	end
end

local function bind(screenGui: Instance)
	local found = screenGui:WaitForChild(BUTTON_NAME)
	if not found:IsA("GuiButton") then
		warn("[DropButtonController] ScreenGui." .. BUTTON_NAME .. " is not a button")
		return
	end

	-- HUD controls in this place are commonly authored Active = false, which swallows Activated
	-- (the button visibly presses and nothing happens). Turn it on rather than relying on the
	-- authored value.
	found.Active = true
	button = found
	found.Activated:Connect(function()
		-- Harmless with empty hands, and the server still decides -- we only ask.
		GarbageCarryController.drop()
	end)

	applyVisibility()
end

function DropButtonController.init()
	-- Fires immediately with the current state, and on every flip after.
	GarbageCarryController.onCarryingChanged(applyVisibility)

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

return DropButtonController
