--!strict

-- Shows a white dot in the center of the screen while the player is in first
-- person, and hides the default mouse icon so the dot reads as the crosshair.
-- In third person the dot is hidden and the normal cursor returns (needed for
-- clicking surfaces).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

-- Camera-to-head distance thresholds for first-person detection. We use a
-- hysteresis band so the camera lagging behind the head during movement can't
-- briefly flip the state (which would flicker the cursor on and off).
local ENTER_FIRST_PERSON_DISTANCE = 1.0
local EXIT_FIRST_PERSON_DISTANCE = 2.0

-- The dot is sized as a fraction of the viewport HEIGHT, not in fixed pixels: a flat pixel size is
-- a different thing entirely on a phone than on a desktop monitor -- the same 12px dot that reads
-- right on a laptop is a speck on a high-resolution phone screen. Height rather than width because
-- height is the axis that varies least between a monitor and a handset held sideways.
--
-- Scale alone would stretch the dot with the aspect ratio, so a UIAspectRatioConstraint holds it
-- square (a UICorner then makes it round -- an oval crosshair is very obvious). The size is clamped
-- in pixels at both ends so it can't vanish on a small screen or turn into a blob on a huge one.
local DOT_HEIGHT_SCALE = 0.011
local DOT_MIN_PIXELS = 6
local DOT_MAX_PIXELS = 18

local Crosshair = {}

-- The crosshair ScreenGui + current state, lifted to module scope so setSuppressed can drive
-- them alongside the first-person render loop.
local gui: ScreenGui? = nil
local firstPerson = false
-- When true, the dot is force-hidden (and the cursor shown) even in first person -- used by
-- the JobSummary so its buttons aren't blocked by the centered dot.
local suppressed = false

-- Apply the current state: the dot shows only in first person AND while not suppressed; the
-- mouse icon is the inverse so the cursor returns whenever the dot is hidden.
local function apply()
	local g = gui
	if not g then
		return
	end
	local show = firstPerson and not suppressed
	g.Enabled = show
	UserInputService.MouseIconEnabled = not show
end

-- Force the crosshair off (or release it) regardless of first-person state.
function Crosshair.setSuppressed(value: boolean)
	if suppressed == value then
		return
	end
	suppressed = value
	apply()
end

local function buildGui(): (ScreenGui, Frame)
	local gui = Instance.new("ScreenGui")
	gui.Name = "Crosshair"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = false

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	-- Height drives the size; the aspect constraint below turns that into a square.
	dot.Size = UDim2.fromScale(DOT_HEIGHT_SCALE, DOT_HEIGHT_SCALE)
	dot.BackgroundColor3 = Color3.new(1, 1, 1)
	dot.BorderSizePixel = 0
	dot.Parent = gui

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.DominantAxis = Enum.DominantAxis.Height
	aspect.AspectType = Enum.AspectType.ScaleWithParentSize
	aspect.Parent = dot

	local sizeLimits = Instance.new("UISizeConstraint")
	sizeLimits.MinSize = Vector2.new(DOT_MIN_PIXELS, DOT_MIN_PIXELS)
	sizeLimits.MaxSize = Vector2.new(DOT_MAX_PIXELS, DOT_MAX_PIXELS)
	sizeLimits.Parent = dot

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	return gui, dot
end

function Crosshair.init()
	local builtGui = buildGui()
	builtGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	gui = builtGui

	-- Resolve to first person below the enter threshold and back to third person
	-- only above the (larger) exit threshold; in the band between, hold state.
	local function resolveFirstPerson(): boolean
		local camera = workspace.CurrentCamera
		local character = LocalPlayer.Character
		local head = character and character:FindFirstChild("Head") :: BasePart?
		if not head or not camera then
			return false
		end
		local distance = (camera.CFrame.Position - head.Position).Magnitude
		if firstPerson then
			return distance < EXIT_FIRST_PERSON_DISTANCE
		end
		return distance < ENTER_FIRST_PERSON_DISTANCE
	end

	RunService.RenderStepped:Connect(function()
		local nowFirstPerson = resolveFirstPerson()
		if nowFirstPerson == firstPerson then
			return
		end
		firstPerson = nowFirstPerson
		apply()
	end)
end

return Crosshair
