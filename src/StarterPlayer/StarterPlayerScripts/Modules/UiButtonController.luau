--!strict

-- Gives every button in the game its shared polish, for the local player:
--   * UIClick on press -- except the shop's InteractButton, which plays its own purchase/fail
--     SFX (so it isn't doubled up).
--   * The hover sound on pointer-enter.
--   * A hover grow (UiAnimations.hoverGrow) -- except the HUD's button clusters, whose buttons
--     share a UIGridLayout and so need the grid-aware variant JobUiController attaches instead.
--
-- Some ScreenGuis are skipped entirely -- see UNPOLISHED_SCREEN_GUIS.
--
-- Buttons are discovered by scanning PlayerGui once and then watching DescendantAdded, so UI
-- cloned in later (e.g. the ScreenGui re-added on each respawn, or dynamically built rows) is
-- wired automatically -- no per-button hookup elsewhere. This is the ONE place button hover
-- polish is applied; controllers should not attach their own.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TutorialConfig = require(ReplicatedStorage.SharedModules.TutorialConfig)

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
-- The pressure washer's WashButton lives in here, and it isn't a button in the sense this module
-- means: it's a HELD trigger that doubles as a look joystick (WashJoystickController). The grow would
-- fight it outright -- hoverGrow re-anchors the button and scales it, and the joystick drives that
-- same Position every frame -- and the click/hover sounds would blip on every spray.
local JOYSTICK_FRAME_NAME = "JoystickRange"

local UiButtonController = {}

-- ScreenGuis whose buttons get NO polish at all -- not the click, not the hover sound, not the
-- grow:
--   * TouchGui   -- Roblox's default mobile controls (jump button, thumbstick). GuiButtons, but
--     not our UI.
--   * TutorialGui -- its "buttons" aren't buttons. They're big dimming overlays that darken the
--     screen around whatever the tutorial wants you looking at, authored as ImageButtons only
--     because that's the class the art needed. They're Active = false so clicks fall through to
--     the real button underneath, and polishing them would put a click sound and a hover grow on
--     a backdrop.
local UNPOLISHED_SCREEN_GUIS = { TouchGui = true, [TutorialConfig.GuiName] = true }

local function isUnpolished(button: GuiButton): boolean
	local ancestor = button.Parent
	while ancestor do
		if UNPOLISHED_SCREEN_GUIS[ancestor.Name] and ancestor:IsA("ScreenGui") then
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
	if isUnpolished(button) then
		return
	end
	-- The wash joystick gets nothing at all (see JOYSTICK_FRAME_NAME).
	local parent = button.Parent
	if parent and parent.Name == JOYSTICK_FRAME_NAME then
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
