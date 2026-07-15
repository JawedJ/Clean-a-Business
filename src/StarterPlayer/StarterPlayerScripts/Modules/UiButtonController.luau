--!strict

-- Gives every button in the game its shared polish, for the local player:
--   * UIClick on press -- except the shop's InteractButton, which plays its own purchase/fail
--     SFX (so it isn't doubled up).
--   * The hover sound on pointer-enter.
--   * A hover grow (UiAnimations.hoverGrow) -- except the HUD's button clusters, whose buttons
--     share a UIGridLayout and so need the grid-aware variant JobUiController attaches instead.
--
-- Buttons are discovered by scanning PlayerGui once and then watching DescendantAdded, so UI
-- cloned in later (e.g. the ScreenGui re-added on each respawn, or dynamically built rows) is
-- wired automatically -- no per-button hookup elsewhere. This is the ONE place button hover
-- polish is applied; controllers should not attach their own.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local localPlayer = Players.LocalPlayer

local CLICK_SOUND = "UIClick"
local HOVER_SOUND = "UIHover"
-- Skip past the hover sound's quiet lead-in so it reads instantly on hover.
local HOVER_START = 0.140
-- The HUD's main button clusters. Their buttons share a UIGridLayout, which never reflows to make
-- room for a grow, so JobUiController attaches the grid-aware hoverGrowInGrid (it also widens the
-- grid's padding to keep neighbour gaps constant). Skipped here so they aren't wired twice.
local CLUSTER_FRAME_NAMES = { Button1 = true, Buttons2 = true, Buttons3 = true }
-- The shop's InteractButton is skipped for the generic click sound: it already plays its own
-- purchase/fail SFX (UpgradesUiController), so a click here would just overlap them.
local INTERACT_BUTTON_NAME = "InteractButton"

local UiButtonController = {}

-- Roblox's default mobile controls (jump button, thumbstick) live under a
-- ScreenGui named "TouchGui" in PlayerGui. Those are GuiButtons too, but they
-- aren't real UI -- no click sound, no hover polish.
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

-- Whether the button sits under one of the HUD's cluster frames (see CLUSTER_FRAME_NAMES).
local function isInButtonCluster(button: GuiButton): boolean
	local ancestor = button.Parent
	while ancestor do
		if CLUSTER_FRAME_NAMES[ancestor.Name] and ancestor:IsA("GuiObject") then
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

	button.MouseEnter:Connect(function()
		SoundManager.playOneShot(HOVER_SOUND, { startTime = HOVER_START })
	end)

	if not isInButtonCluster(button) then
		UiAnimations.hoverGrow(button)
	end
end

function UiButtonController.init()
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

return UiButtonController
