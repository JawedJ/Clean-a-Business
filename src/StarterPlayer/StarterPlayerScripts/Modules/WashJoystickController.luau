--!strict

-- The touch WashButton (PlayerGui.ScreenGui.JoystickRange.WashButton): the pressure washer's
-- trigger. Held, it sprays; released, it stops.
--
-- TOUCH ONLY, and shown only while the pressure washer is equipped -- it's the one tool that needs
-- it. Desktop/console fire by holding the mouse button / trigger, so the control would be dead
-- weight there. The washer used to fire continuously the whole time it was equipped on touch,
-- because a tap is a look/aim gesture and couldn't also mean "fire"; this button is what replaced
-- that (see PressureWasherController.setFiring).
--
-- IT DOESN'T SINK THE TOUCH. The button is deliberately left Active = FALSE -- the opposite of every
-- other control in this place, which is forced Active = true so clicks register. An active GuiButton
-- swallows the touch it's under, and the default camera's pan region only ever sees touches the GUI
-- didn't take: holding the trigger would freeze the camera, so the player couldn't spray and look at
-- the same time -- exactly the problem this button exists to solve. Inactive, the touch falls
-- straight through to the pan region and the swipe still turns the camera, so we pick it up
-- ourselves off UserInputService and hit-test it against the button (GetGuiObjectsAtPosition, which
-- handles the GUI inset and the button's visibility for us -- a hidden button is never under the
-- touch). Nothing here writes to the camera; the default camera is the only thing that moves it.
--
-- The knob still slides: it follows the thumb inside JoystickRange (clamped to the room left in the
-- ring) and snaps back to its authored position the moment the thumb lifts, so the control reads as
-- the stick the art makes it look like. It's tracked by InputObject identity, so a second finger
-- elsewhere on the screen (jump, the movement stick) can't move it or steal its release.
-- UiButtonController deliberately gives this button no polish at all -- see the JoystickRange skip
-- there.
--
-- The ScreenGui is re-cloned on every respawn, so we re-bind to the fresh instances each time one
-- appears (same pattern as InteractButtonController).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local PressureWasherController = require(script.Parent.PressureWasherController)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local RANGE_NAME = "JoystickRange"
local BUTTON_NAME = "WashButton"

-- Touch-only devices, matching PressureWasherController's IS_MOBILE exactly.
local IS_MOBILE = UserInputService.TouchEnabled
	and not UserInputService.KeyboardEnabled
	and not UserInputService.MouseEnabled
	and not UserInputService.GamepadEnabled

local WashJoystickController = {}

-- The currently bound control, refreshed each time the ScreenGui is (re)bound.
local range: GuiObject? = nil
local button: GuiButton? = nil
-- The knob's authored position, captured on bind: where it sits at rest and snaps back to.
local restPosition = UDim2.new()

-- The touch currently holding the knob (identity, not just "a touch"), and where on screen it went
-- down. The knob moves relative to the PRESS point rather than the ring's centre, so it doesn't jump
-- under the thumb the instant it's grabbed off-centre.
local activeTouch: InputObject? = nil
local pressOrigin = Vector2.zero

local playerGui: PlayerGui? = nil

-- How far (pixels) the knob may travel from rest: the room left inside the ring once the knob's own
-- size is taken out of it. The narrower axis wins, so the travel is a circle rather than an oval.
local function travelRadius(): number
	local ring, knob = range, button
	if not ring or not knob then
		return 0
	end
	local room = (ring.AbsoluteSize - knob.AbsoluteSize) / 2
	return math.max(math.min(room.X, room.Y), 0)
end

-- Put the knob back where it was authored.
local function recentre()
	local knob = button
	if knob then
		knob.Position = restPosition
	end
end

-- Follow the thumb, clamped to the ring.
local function moveKnob(position: Vector2)
	local knob = button
	if not knob then
		return
	end
	local radius = travelRadius()
	if radius <= 0 then
		return
	end

	local delta = position - pressOrigin
	if delta.Magnitude > radius then
		delta = delta.Unit * radius
	end
	knob.Position = restPosition + UDim2.fromOffset(delta.X, delta.Y)
end

local function release()
	activeTouch = nil
	recentre()
	PressureWasherController.setFiring(false)
end

-- Is this touch on the knob? Asked of the GUI itself rather than compared against AbsolutePosition:
-- that keeps us honest about the GUI inset, and a button that's hidden (washer not equipped) simply
-- isn't there to be hit.
local function isOnKnob(position: Vector2): boolean
	local gui, knob = playerGui, button
	if not gui or not knob then
		return false
	end
	for _, object in gui:GetGuiObjectsAtPosition(position.X, position.Y) do
		if object == knob then
			return true
		end
	end
	return false
end

local function applyVisibility()
	local ring = range
	if ring and ring.Parent then
		ring.Visible = IS_MOBILE and PressureWasherController.isEquipped()
	end
	-- Put the washer away mid-hold (or lose it to a respawn) and the thumb is still down on a button
	-- that's no longer there: let go for it.
	if activeTouch and not PressureWasherController.isEquipped() then
		release()
	end
end

local function bind(screenGui: Instance)
	local ring = screenGui:WaitForChild(RANGE_NAME)
	local knob = ring:WaitForChild(BUTTON_NAME)
	if not ring:IsA("GuiObject") or not knob:IsA("GuiButton") then
		warn("[WashJoystickController] " .. RANGE_NAME .. "/" .. BUTTON_NAME .. " is not a button in a frame")
		return
	end

	range = ring
	button = knob
	restPosition = knob.Position
	-- See the header: inactive ON PURPOSE, so the touch passes through to the camera's pan region.
	knob.Active = false

	applyVisibility()
end

function WashJoystickController.init()
	-- Fires immediately with the current state, and on every flip after.
	PressureWasherController.onEquippedChanged(applyVisibility)

	-- Everything below is the control itself, which only touch gets. We still BIND on every platform:
	-- the frame is authored Visible, so somebody has to turn it off on desktop (applyVisibility, from
	-- bind).
	if IS_MOBILE then
		-- All three on the SERVICE, not the button, which isn't listening for input at all (see the
		-- header): the press has to be hit-tested, a thumb that slides off the knob must keep dragging
		-- it, and a release anywhere has to end the hold.
		UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch or activeTouch then
				return
			end
			local position = Vector2.new(input.Position.X, input.Position.Y)
			if not isOnKnob(position) then
				return
			end
			activeTouch = input
			pressOrigin = position
			PressureWasherController.setFiring(true)
		end)
		UserInputService.InputChanged:Connect(function(input)
			if input == activeTouch then
				moveKnob(Vector2.new(input.Position.X, input.Position.Y))
			end
		end)
		local function onEnded(input: InputObject)
			if input == activeTouch then
				release()
			end
		end
		UserInputService.InputEnded:Connect(onEnded)
		-- A touch the engine takes away mid-drag (a call, the app backgrounding) never reaches
		-- InputEnded.
		UserInputService.TouchEnded:Connect(onEnded)
	end

	local gui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
	playerGui = gui
	local function onChild(child: Instance)
		if child.Name == SCREEN_GUI_NAME then
			task.spawn(bind, child)
		end
	end
	for _, child in gui:GetChildren() do
		onChild(child)
	end
	gui.ChildAdded:Connect(onChild)
end

return WashJoystickController
