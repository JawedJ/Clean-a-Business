--!strict

-- Plays the shared UI sound effects for the local player:
--   * UIClick   on every GuiButton press, anywhere in PlayerGui.
--   * UIHOVER_2 when the pointer enters any button in the HUD's "Buttons" frame.
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
-- Only buttons under a frame with this name (the HUD's main button cluster) play the hover
-- sound; every button still plays the click.
local HOVER_FRAME_NAME = "Buttons"

local UiSoundController = {}

-- Roblox's default mobile controls (jump button, thumbstick) live under a
-- ScreenGui named "TouchGui" in PlayerGui. Those are GuiButtons too, but they
-- aren't real UI clicks -- don't play the click sound for them.
local function isTouchControl(button: GuiButton): boolean
	local ancestor = button.Parent
	while ancestor do
		if ancestor.Name == "TouchGui" and ancestor:IsA("ScreenGui") then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

-- Whether the button sits under a frame named HOVER_FRAME_NAME -- the HUD's main button
-- cluster, whose buttons all get the hover sound.
local function isInHoverFrame(button: GuiButton): boolean
	local ancestor = button.Parent
	while ancestor do
		if ancestor.Name == HOVER_FRAME_NAME and ancestor:IsA("GuiObject") then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

local function wireButton(button: GuiButton)
	if isTouchControl(button) then
		return
	end

	button.Activated:Connect(function()
		SoundManager.playOneShot(CLICK_SOUND)
	end)
	if isInHoverFrame(button) then
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
