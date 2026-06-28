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
local EXIT_FIRST_PERSON_DISTANCE = 1.4
local DOT_SIZE = 12

local Crosshair = {}

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
	dot.Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE)
	dot.BackgroundColor3 = Color3.new(1, 1, 1)
	dot.BorderSizePixel = 0
	dot.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	return gui, dot
end

function Crosshair.init()
	local gui = buildGui()
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	local firstPerson = false

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
		gui.Enabled = firstPerson
		UserInputService.MouseIconEnabled = not firstPerson
	end)
end

return Crosshair
