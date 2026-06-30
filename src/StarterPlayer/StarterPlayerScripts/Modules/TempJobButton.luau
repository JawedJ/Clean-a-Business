--!strict

-- TEMPORARY. A throwaway on-screen button that accepts the McDonalds job, so the
-- job/teleport/clean flow can be exercised before the real job-board UI exists.
-- Builds its own ScreenGui at runtime (nothing to author in Studio). Delete this
-- module (and its init in Main.client) once the real job board is in.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AcceptJob = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AcceptJob") :: RemoteEvent

-- Which job this temp button starts.
local BUSINESS_ID = "mcDonalds"

local localPlayer = Players.LocalPlayer

local TempJobButton = {}

function TempJobButton.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "TempJobButton"
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local button = Instance.new("TextButton")
	button.Name = "StartMcDonaldsJob"
	button.Size = UDim2.fromOffset(200, 50)
	button.Position = UDim2.new(0.5, 0, 1, -24)
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.BackgroundColor3 = Color3.fromRGB(220, 60, 40)
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.Text = "Start McDonalds Job"
	button.AutoButtonColor = true
	button.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	button.Activated:Connect(function()
		AcceptJob:FireServer(BUSINESS_ID)
	end)

	screen.Parent = playerGui
end

return TempJobButton
