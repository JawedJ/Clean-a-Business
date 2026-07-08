--!strict

-- Plays the shared UI sound effects for the local player:
--   * UIClick   on every GuiButton press, anywhere in PlayerGui -- except the shop's
--     InteractButton, which plays its own purchase/fail SFX (so it isn't doubled up).
--   * UIHOVER_2 when the pointer enters any button in the HUD's cluster frames, or any panel
--     ExitButton (the job board / upgrades close buttons).
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
-- Buttons under a frame with one of these names (the HUD's main button clusters) play the
-- hover sound; every button still plays the click.
local HOVER_FRAME_NAMES = { Button1 = true, Buttons2 = true, Buttons3 = true }
-- Panel close buttons (job board, upgrades shop) also play the hover sound, even though they
-- sit outside the button cluster. Matched by name so any panel's ExitButton is covered.
local EXIT_BUTTON_NAME = "ExitButton"
-- The shop's InteractButton is skipped for the generic click sound: it already plays its own
-- purchase/fail SFX (UpgradesUiController), so a click here would just overlap them.
local INTERACT_BUTTON_NAME = "InteractButton"

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

-- Whether the button sits under one of the HOVER_FRAME_NAMES frames -- the HUD's main button
-- clusters, whose buttons all get the hover sound.
local function isInHoverFrame(button: GuiButton): boolean
	local ancestor = button.Parent
	while ancestor do
		if HOVER_FRAME_NAMES[ancestor.Name] and ancestor:IsA("GuiObject") then
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

	-- Skip the generic click for the shop's InteractButton -- it has its own purchase/fail SFX.
	if button.Name ~= INTERACT_BUTTON_NAME then
		button.Activated:Connect(function()
			SoundManager.playOneShot(CLICK_SOUND)
		end)
	end
	if isInHoverFrame(button) or button.Name == EXIT_BUTTON_NAME then
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
