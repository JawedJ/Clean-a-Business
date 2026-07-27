--!strict

-- Drives the offline-earnings claim screen (PlayerGui.ScreenGui.AfkEarnings). The server
-- (AfkEarningsService) computes what the player earned while away and, if it's worth showing, fires
-- ShowAfkEarnings with the gem amount and seconds away; we then open the panel with the shared
-- slide+expand animation and fill in:
--   * OfflineTimeTxt -- "You were offline for <d>d <h>h <m>m and earned..." (the authored format).
--   * GemAmtTxt      -- the reward, run through the number formatter.
--
-- This is a MODAL with no exit button: while it's up, ExclusivePanels is locked so no other menu
-- can open, and it stays up until the player deals with it via one of its two buttons:
-- Either button showers gems into the HUD counter as it closes (the shared GemBurst effect, which
-- the Company UI's 24-hour earnings purchase plays too).
--   * ClaimButton  -- claims the shown amount (fires ClaimAfkEarnings) and always closes the panel.
--   * DoubleButton -- prompts the Robux DOUBLE_PRODUCT_ID; the server grants 2x on receipt. The
--     panel closes only if that purchase goes through (else it stays open to try again).
--
-- The reward stays "outstanding" on the client until a button resolves it, so if the ScreenGui is
-- re-cloned (respawn) while it's still up, it re-opens on the fresh clone rather than being lost.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local ExclusivePanels = require(script.Parent.ExclusivePanels)
local GemBurst = require(script.Parent.GemBurst)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShowAfkEarnings = Remotes:WaitForChild("ShowAfkEarnings") :: RemoteEvent
local ClaimAfkEarnings = Remotes:WaitForChild("ClaimAfkEarnings") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Robux dev product the Double button buys (granted server-side in AfkEarningsService).
local DOUBLE_PRODUCT_ID = 3611857315

local AfkEarningsController = {}

-- Current elements, refreshed each time the ScreenGui is (re)bound (it's re-cloned per respawn).
local afkFrame: Frame? = nil
local offlineTimeLabel: TextLabel? = nil
local gemAmtLabel: TextLabel? = nil
local afkPanel: UiAnimations.Panel? = nil

-- The outstanding reward, held until a button resolves it: `active` means the screen should be up
-- (drives a re-open after a respawn), and gems/away are what to display.
local active = false
local rewardGems = 0
local rewardSeconds = 0

-- "You were offline for 3d 5h 12m and earned..." -- the authored OfflineTimeTxt format. Always
-- shows all three units (matching the design), from the ACTUAL seconds away (uncapped).
local function formatOfflineTime(seconds: number): string
	local days = math.floor(seconds / 86400)
	local hours = math.floor(seconds % 86400 / 3600)
	local minutes = math.floor(seconds % 3600 / 60)
	return string.format("You were offline for %dd %dh %dm and earned...", days, hours, minutes)
end

-- Open the panel on the currently-bound ScreenGui if the reward is still outstanding, filling in the
-- time + gem labels and locking every other menu out. A no-op until something is bound (bind() calls
-- this again once it is) -- so it works whether the remote arrives before or after the ScreenGui.
local function tryShow()
	local panel = afkPanel
	local frame = afkFrame
	if not active or not panel or not frame or not frame.Parent then
		return
	end
	if offlineTimeLabel then
		offlineTimeLabel.Text = formatOfflineTime(rewardSeconds)
	end
	if gemAmtLabel then
		gemAmtLabel.Text = NumberFormat.abbreviate(rewardGems)
	end
	ExclusivePanels.setLocked(true)
	-- Pop in with no open animation (design choice); the close animation still plays on claim.
	panel:showInstant()
end

-- Close the panel and release the lock, marking the reward resolved so it won't re-open on respawn.
-- Fires the shared gem burst -- both buttons resolve through here, so it plays for claim and double
-- alike.
local function closeAfk()
	active = false
	ExclusivePanels.setLocked(false)
	GemBurst.play()
	local panel = afkPanel
	if panel then
		panel:close()
	end
end

-- Server says this session has an offline reward to claim: remember it and show the screen.
local function onShow(gems: number, secondsAway: number)
	if type(gems) ~= "number" or type(secondsAway) ~= "number" then
		return
	end
	active = true
	rewardGems = gems
	rewardSeconds = secondsAway
	tryShow()
end

-- Resolve one ScreenGui's AfkEarnings elements, wire the two buttons, and (re-)show if a reward is
-- still outstanding. Yields on WaitForChild for a fresh clone.
local function bind(screenGui: Instance)
	local frame = screenGui:WaitForChild("AfkEarnings") :: Frame
	local mainFrame = frame:WaitForChild("MainFrame")
	local claimButton = mainFrame:WaitForChild("ClaimButton") :: ImageButton
	local doubleButton = mainFrame:WaitForChild("DoubleButton") :: ImageButton

	local panel = UiAnimations.Panel.new(frame)
	afkFrame = frame
	offlineTimeLabel = mainFrame:WaitForChild("OfflineTimeTxt") :: TextLabel
	gemAmtLabel = mainFrame:WaitForChild("GemAmtTxt") :: TextLabel
	afkPanel = panel
	-- Authored Visible; snap it hidden so it only appears when a reward is shown.
	panel:hideInstant()

	-- Claim always closes; the server grants the shown amount off ClaimAfkEarnings.
	claimButton.Activated:Connect(function()
		if not active then
			return
		end
		ClaimAfkEarnings:FireServer()
		SoundManager.playOneShot("Sparkle")
		closeAfk()
	end)
	-- Double prompts the product; the panel closes only once the purchase succeeds (handled by the
	-- PromptProductPurchaseFinished listener), staying open if the player cancels.
	doubleButton.Activated:Connect(function()
		if not active then
			return
		end
		MarketplaceService:PromptProductPurchase(localPlayer, DOUBLE_PRODUCT_ID)
	end)

	tryShow()
end

function AfkEarningsController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	ShowAfkEarnings.OnClientEvent:Connect(onShow)

	-- A successful Double purchase closes the panel (the server grants 2x on receipt). A cancelled
	-- one leaves it up. Connected once here rather than per-bind so it never stacks.
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(_userId, productId, isPurchased)
		if productId == DOUBLE_PRODUCT_ID and isPurchased and active then
			closeAfk()
		end
	end)

	local function onChild(child: Instance)
		if child.Name == SCREEN_GUI_NAME then
			task.spawn(bind, child)
		end
	end
	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
	playerGui.ChildAdded:Connect(onChild)
end

return AfkEarningsController
