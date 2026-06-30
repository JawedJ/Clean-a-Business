--!strict

-- Floating reward text + cash chime. When the server grants a tool reward it fires
-- RewardPopup with (xp, cash); for each positive amount we spawn a small "+N XP!" /
-- "+N Cash!" label at a random spot near the crosshair, tilted up to 10 degrees
-- either way, that drifts upward and fades out, and on a cash gain we play a short
-- reward sound. Purely cosmetic, fire-and-forget.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

local RewardPopup = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RewardPopup") :: RemoteEvent

-- Cash gains play a quick chime: just the first slice of the Reward sound.
local CASH_SOUND = "Reward"
local CASH_SOUND_DURATION = 0.55

local localPlayer = Players.LocalPlayer

-- Bright aqua for XP, bright green for Cash.
local XP_COLOR = Color3.fromRGB(45, 205, 255)
local CASH_COLOR = Color3.fromRGB(70, 230, 95)

local TEXT_SIZE = 20
local MAX_TILT = 10 -- degrees of random rotation, either direction

-- Random spawn box around screen center (scale). Centered slightly above true
-- center so popups sit around the crosshair rather than under it.
local CENTER_Y = 0.48
local SPREAD_X = 0.06
local SPREAD_Y = 0.05

local RISE = 0.07 -- how far up (scale) a popup drifts before it's gone
local LIFETIME = 0.9 -- seconds from spawn to fully faded

local RewardPopupController = {}

local gui: ScreenGui? = nil

-- Random scale position inside the spawn box near the crosshair.
local function randomPosition(): (number, number)
	local x = 0.5 + (math.random() * 2 - 1) * SPREAD_X
	local y = CENTER_Y + (math.random() * 2 - 1) * SPREAD_Y
	return x, y
end

-- Spawn one floating label and animate it; it cleans itself up.
local function spawnPopup(text: string, color: Color3)
	local parent = gui
	if not parent then
		return
	end

	local x, y = randomPosition()

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(x, y)
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextSize = TEXT_SIZE
	label.Text = text
	label.TextColor3 = color
	label.Rotation = (math.random() * 2 - 1) * MAX_TILT

	-- Dark outline so the text stays readable over any background.
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Transparency = 0.1
	stroke.Parent = label

	label.Parent = parent

	local tweenInfo = TweenInfo.new(LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(label, tweenInfo, {
		Position = UDim2.fromScale(x, y - RISE),
		TextTransparency = 1,
	}):Play()
	TweenService:Create(stroke, tweenInfo, { Transparency = 1 }):Play()

	Debris:AddItem(label, LIFETIME)
end

function RewardPopupController.init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RewardPopups"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 10
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	gui = screenGui

	RewardPopup.OnClientEvent:Connect(function(xp: number, cash: number)
		if xp > 0 then
			spawnPopup(string.format("+%d XP!", xp), XP_COLOR)
		end
		if cash > 0 then
			spawnPopup(string.format("+%d Cash!", cash), CASH_COLOR)
			SoundManager.playOneShot(CASH_SOUND, { duration = CASH_SOUND_DURATION })
		end
	end)
end

return RewardPopupController
