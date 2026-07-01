--!strict

-- Plays the shared UI sound effects for the local player:
--   * UIClick   on every GuiButton press, anywhere in PlayerGui.
--   * UIHOVER_2 when the pointer enters the JobButton.
-- Buttons are discovered by scanning PlayerGui once and then watching DescendantAdded,
-- so UI cloned in later (e.g. the ScreenGui re-added on each respawn, or dynamically
-- built rows) is wired automatically -- no per-button hookup elsewhere.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

local localPlayer = Players.LocalPlayer

local CLICK_SOUND = "UIClick"
local HOVER_SOUND = "UIHover"
-- Skip past the hover sound's quiet lead-in so it reads instantly on hover.
local HOVER_START = 0.140
-- Only this button plays the hover sound; every button still plays the click.
local HOVER_BUTTON_NAME = "JobButton"

local UiSoundController = {}

local function wireButton(button: GuiButton)
	button.Activated:Connect(function()
		SoundManager.playOneShot(CLICK_SOUND)
	end)
	if button.Name == HOVER_BUTTON_NAME then
		button.MouseEnter:Connect(function()
			SoundManager.playOneShot(HOVER_SOUND, { startTime = HOVER_START })
		end)
	end
end

function UiSoundController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	for _, descendant in playerGui:GetDescendants() do
		if descendant:IsA("GuiButton") then
			wireButton(descendant)
		end
	end
	playerGui.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("GuiButton") then
			wireButton(descendant)
		end
	end)
end

return UiSoundController
