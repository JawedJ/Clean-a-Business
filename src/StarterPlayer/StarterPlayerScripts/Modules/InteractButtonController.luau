--!strict

-- The HUD's interact button (PlayerGui.ScreenGui.InteractButton): the touch player's hands. It has
-- exactly two states, and its image says which one it's in:
--
--   * hands EMPTY, crosshair on a piece in pickup range -- the pick-up image; a press takes THAT
--     piece (GarbageCarryController.pickup()). Players are locked to first person with a custom
--     crosshair for the whole job, so "what the button takes" is always the centre of the screen.
--     Note this is the crosshair, NOT the white outline: the outline also offers the nearest piece
--     in reach when you're not aiming at anything, and the button must never take something the
--     player didn't point at.
--   * holding ANYTHING -- the drop image; a press lets go of the lot.
--
-- Neither -- empty hands, crosshair on nothing -- and it's hidden, so it only ever appears when
-- there's something for it to do.
--
-- The second state wins the moment the player's hands stop being empty, even though they may still
-- have room for another piece or two (Config.GarbageCarryLimit). That's deliberate: on touch, the
-- way to pick garbage up is to TAP the piece itself, so the button is free to be the one thing a tap
-- can't do. Making it pick up while the player had an armful would also make it the button that
-- can't put anything down -- exactly when they most need to.
--
-- TOUCH ONLY. Dropping is the reason it has to exist: a tap never drops, since the movement stick and
-- the camera pan region arrive at GarbageCarryController as ordinary unprocessed touches (see
-- TOUCH_CAN_DROP there). A mouse has no such problem -- a click both picks up and drops -- so on
-- desktop the button would be a second way to do what the click does, taking up HUD space for
-- nothing. Same device test as GarbageCarryController's IS_MOBILE, so the two agree on who needs it.
--
-- Both states only ever happen DURING a job: garbage can't be picked up or aimed at without one, and
-- a job ending clears the carry and the aim both (GarbageCarryController drops everything on the
-- ActiveJob attribute changing), so the same signals that empty our hands hide the button. We don't
-- watch the job attribute ourselves -- one owner of "am I carrying" is enough, and deriving it twice
-- is how the two ends drift apart.
--
-- The button is authored a direct child of the ScreenGui, so no HUD cluster hides it for us; its
-- Visible is ours alone. The ScreenGui is re-cloned on every respawn, so we re-bind to the fresh
-- instances each time one appears (same pattern as PlayTogetherController).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local GarbageCarryController = require(script.Parent.GarbageCarryController)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local BUTTON_NAME = "InteractButton"

local PICKUP_IMAGE = "rbxassetid://91988864416199"
local DROP_IMAGE = "rbxassetid://139219716783183"

-- Touch-only devices, matching GarbageCarryController's IS_MOBILE exactly: a device with a keyboard,
-- mouse or gamepad has real pick-up and drop inputs already, so it doesn't get the button.
local IS_MOBILE = UserInputService.TouchEnabled
	and not UserInputService.KeyboardEnabled
	and not UserInputService.MouseEnabled
	and not UserInputService.GamepadEnabled

local InteractButtonController = {}

-- The currently bound button, refreshed each time the ScreenGui is (re)bound.
local button: GuiButton? = nil

-- Carrying wins over aiming: with anything in hand, "drop" is the only thing a press could sensibly
-- mean -- picking the next piece up is the tap on that piece (see the header).
local function refresh()
	local current = button
	if not current or not current.Parent then
		return
	end

	-- Anything at all in hand, not a full armful: see the header.
	local carrying = GarbageCarryController.isCarrying()
	local show = IS_MOBILE and (carrying or GarbageCarryController.hasAimTarget())
	current.Visible = show
	if show and current:IsA("ImageButton") then
		current.Image = if carrying then DROP_IMAGE else PICKUP_IMAGE
	end
end

local function bind(screenGui: Instance)
	local found = screenGui:WaitForChild(BUTTON_NAME)
	if not found:IsA("GuiButton") then
		warn("[InteractButtonController] ScreenGui." .. BUTTON_NAME .. " is not a button")
		return
	end

	-- HUD controls in this place are commonly authored Active = false, which swallows Activated
	-- (the button visibly presses and nothing happens). Turn it on rather than relying on the
	-- authored value.
	found.Active = true
	button = found
	found.Activated:Connect(function()
		-- Both halves are harmless in the wrong state, and the server still decides -- we only ask.
		if GarbageCarryController.isCarrying() then
			GarbageCarryController.drop()
		else
			GarbageCarryController.pickup()
		end
	end)

	refresh()
end

function InteractButtonController.init()
	-- Each fires immediately with the current state, and on every flip after.
	GarbageCarryController.onCarryingChanged(refresh)
	GarbageCarryController.onAimChanged(refresh)

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

return InteractButtonController
