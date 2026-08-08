--!strict

-- Drives the Robux store UI (PlayerGui.ScreenGui: HUD.AllButtons.Buttons2.StoreButton + ShopUI).
-- The StoreButton toggles ShopUI open/closed with the SAME slide + expand animation as the job
-- board / upgrades shop / skills / settings (via the shared ExclusivePanels coordinator, so opening
-- it closes whichever of those was open, and vice versa); the frame's ExitButton closes it.
--
-- MainFrame.ScrollingFrame holds one ImageLabel per offer, named after the offer it sells (see the
-- shared ShopProducts catalog -- "25kCashFrame", "SpeedFrame", ...). Every label on them is
-- authored static, so there is nothing to repaint: this controller only wires each frame's BuyBtn
-- to raise that offer's purchase prompt -- a gamepass prompt or a developer-product one, per the
-- catalog, since the wrong prompt simply errors. A dev product is preceded by firing the offer's
-- name over the ShopIntent remote, which is what tells the server WHICH offer a shared product id
-- is paying for; a gamepass needs no such hint. Its one piece of polish is
-- coupling each frame's PriceTxt_STATIC to that button's hover grow, since the price is authored as
-- the button's sibling and so wouldn't otherwise move with it.
--
-- A click is refused, with no prompt, when the offer would grant nothing -- every skill already
-- maxed, the permanent perk already owned, every tool already unlocked and maxed. The server's
-- grants are idempotent, so this isn't about correctness: it's about never taking Robux for a
-- purchase that changes nothing. The server re-validates and is authoritative either way.
--
-- Like the other HUD controllers, the ScreenGui is re-cloned into PlayerGui on every respawn, so we
-- re-bind to the fresh instances each time one appears. The StoreButton lives in the Buttons2
-- cluster, which hides during a job, so the frame also snaps hidden (and refuses to open) mid-job.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local ItemUpgrades = require(ReplicatedStorage.SharedModules.ItemUpgrades)
local ShopProducts = require(ReplicatedStorage.SharedModules.ShopProducts)
local SkillsConfig = require(ReplicatedStorage.SharedModules.SkillsConfig)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local ExclusivePanels = require(script.Parent.ExclusivePanels)
local TutorialState = require(script.Parent.TutorialState)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShopIntent = Remotes:WaitForChild("ShopIntent") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Stable name this panel registers under with ExclusivePanels (only one exclusive panel is open at
-- a time; opening this closes the job board / upgrades shop / skills / settings first, and vice versa).
local PANEL_NAME = "Store"
-- A second store button, authored as a standalone child of the ScreenGui rather than inside a HUD
-- cluster. Opens the same panel as the StoreButton; unlike it, nothing else hides it during a job,
-- so this controller does (see applyActiveJobState).
local ALTERNATE_BUTTON_NAME = "ShopAlternateBtn"
-- The one button on each offer frame; its name is the same on every one.
local BUY_BUTTON_NAME = "BuyBtn"
-- The Robux price authored over that button, as its SIBLING -- so it needs coupling to the
-- button's hover grow to move with it (see the bind loop).
local PRICE_LABEL_NAME = "PriceTxt_STATIC"

local ShopUiController = {}

-- Current top-level UI elements, refreshed each time the ScreenGui is (re)bound (the ScreenGui is
-- re-cloned each respawn, so these can't be captured once).
local shopFrame: Frame? = nil
-- Drives the frame's open/close (slide + expand) animation; rebuilt per bind alongside the frame.
local shopPanel: UiAnimations.Panel? = nil
-- The second, standalone store button (see ALTERNATE_BUTTON_NAME). Held so the active-job state can
-- hide it: it sits outside the HUD clusters, so nothing else does that for it.
local alternateButton: ImageButton? = nil

-- Whether the local player currently holds a job (the Buttons2 cluster -- including the
-- StoreButton -- hides while on one, so the frame must hide/refuse to open then too).
local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- One ShopBoosts field from the player's replicated profile, or `fallback` before it has landed.
-- Mirrors the server's ShopPerks defaults so an unbought perk reads the same on both sides.
local function getBoost(field: string, fallback: number): number
	local value = DataService:get({ "ShopBoosts", field })
	return if type(value) == "number" then value else fallback
end

-- Whether every skill is already at the cap -- i.e. the skills pack has nothing left to grant.
-- Same check the SkillsDisplay's own "unlock all" button hides itself on.
local function allSkillsMaxed(): boolean
	for skillName in SkillsConfig.Skills do
		local level = DataService:get({ "Skills", skillName })
		if SkillsConfig.canUpgrade(if type(level) == "number" then level else 0) then
			return false
		end
	end
	return true
end

-- Whether every catalog tool is already unlocked AND at its upgrade cap -- i.e. the starter pack
-- has nothing left to grant.
local function starterPackExhausted(): boolean
	local inventory = DataService:get({ "Inventory" })
	if type(inventory) ~= "table" then
		return false
	end
	for uniqueId in ToolConfig do
		local item = inventory[uniqueId]
		if type(item) ~= "table" or item.Unlocked ~= true or ItemUpgrades.canUpgrade(item) then
			return false
		end
	end
	return true
end

-- Whether prompting `offer` would actually give the player something. The permanent perks are the
-- interesting cases: they're worth buying exactly once, so once the profile already carries them
-- (or the equivalent from a bigger grant) the click stops leading to a Robux prompt. Currency packs
-- are always worth buying.
local function isWorthBuying(offer: ShopProducts.Offer): boolean
	if offer.cashMultiplier and getBoost("CashMultiplier", 1) >= offer.cashMultiplier then
		return false
	end
	if offer.gemMultiplier and getBoost("GemMultiplier", 1) >= offer.gemMultiplier then
		return false
	end
	if offer.speedBonus and getBoost("SpeedBonus", 0) >= offer.speedBonus then
		return false
	end
	if offer.skills and allSkillsMaxed() then
		return false
	end
	if offer.starterPack and starterPackExhausted() then
		return false
	end
	return true
end

-- Act on a BuyBtn click: put the right Robux prompt in front of the player. Refused silently when
-- the offer would grant nothing, and for the tutorial's duration -- its one scripted purchase is
-- meant to be paid for in gems, and the server refuses Robux fallbacks then too.
--
-- Gamepasses and developer products take different prompts (the wrong one just errors out), and
-- only a dev product needs the intent: a gamepass grants everything sold on it, so there's nothing
-- for the server to disambiguate. See ShopProducts.
local function onBuy(frameName: string, offer: ShopProducts.Offer)
	if TutorialState.isRestricting() then
		return
	end
	if not isWorthBuying(offer) then
		return
	end
	if ShopProducts.isGamePass(offer.productId) then
		MarketplaceService:PromptGamePassPurchase(localPlayer, offer.productId)
		return
	end
	-- Tell the server WHICH offer this is before prompting -- the product id alone can't say, since
	-- several offers share one.
	ShopIntent:FireServer(frameName)
	MarketplaceService:PromptProductPurchase(localPlayer, offer.productId)
end

-- Toggle the frame open/closed via the shared coordinator (closing any other open panel first).
-- No-op while on a job -- the Buttons2 cluster is hidden then.
local function togglePanel()
	if hasActiveJob() then
		return
	end
	ExclusivePanels.toggle(PANEL_NAME)
end

-- Show or hide the standalone alternate button. It's there to sell the starter pack, so it goes
-- away for good once that pack has nothing left to give -- the same condition that stops its click
-- from prompting, so the button can never be a dead end. It also hides during a job, matching the
-- HUD clusters (which something else hides) and the panel itself. Guards the gap before any bind.
local function refreshAlternateButton()
	local button = alternateButton
	if button and button.Parent then
		button.Visible = not hasActiveJob() and not starterPackExhausted()
	end
end

-- Snap the frame hidden if a job starts with it open (the Buttons2 cluster hides mid-job, so the
-- frame must not linger over the job UI). Guards the gap before anything is bound.
local function applyActiveJobState()
	local panel = shopPanel
	local frame = shopFrame
	if hasActiveJob() and panel and frame and frame.Parent then
		panel:hideInstant()
		ExclusivePanels.markHidden(PANEL_NAME)
	end
	refreshAlternateButton()
end

-- Resolve one ScreenGui's store elements and wire the buttons. Yields on WaitForChild for a fresh
-- clone. Nothing to paint -- every label on the offers is authored static.
local function bind(screenGui: Instance)
	local buttons2 = screenGui:WaitForChild("HUD"):WaitForChild("AllButtons"):WaitForChild("Buttons2")
	local storeButton = buttons2:WaitForChild("StoreButton") :: ImageButton
	local frame = screenGui:WaitForChild("ShopUI") :: Frame
	local mainFrame = frame:WaitForChild("MainFrame")
	local exitButton = mainFrame:WaitForChild("ExitButton") :: ImageButton
	local scroll = mainFrame:WaitForChild("ScrollingFrame")
	local altButton = screenGui:WaitForChild(ALTERNATE_BUTTON_NAME) :: ImageButton

	-- The panel animates the whole ShopUI (MainFrame and its scroll ride along inside it), matching
	-- how the other boards animate their outermost frame.
	local panel = UiAnimations.Panel.new(frame)
	shopFrame = frame
	shopPanel = panel
	alternateButton = altButton
	frame.Visible = false

	-- Register with the coordinator so open/close is sequenced against the other panels. No
	-- beforeOpen: there is nothing to refresh.
	ExclusivePanels.register(PANEL_NAME, panel)

	-- Both entry points behave identically: the alternate button is a second way to the same panel,
	-- so it toggles rather than only opening (a player who opened it from here can close it here).
	storeButton.Activated:Connect(togglePanel)
	altButton.Activated:Connect(togglePanel)
	exitButton.Activated:Connect(function()
		ExclusivePanels.close(PANEL_NAME)
	end)

	-- Wire each offer's BuyBtn once per bind (a fresh clone each respawn, so no stacking). The
	-- handler re-derives what's worth buying from live data, so it stays correct as the profile
	-- changes. Frames the catalog doesn't know about are left inert rather than prompting something
	-- arbitrary.
	for _, child in scroll:GetChildren() do
		if child:IsA("ImageLabel") then
			local offer = ShopProducts.get(child.Name)
			local buyButton = child:FindFirstChild(BUY_BUTTON_NAME)
			if offer and buyButton and buyButton:IsA("ImageButton") then
				local frameName = child.Name
				buyButton.Activated:Connect(function()
					onBuy(frameName, offer)
				end)
				-- PriceTxt_STATIC is layered OVER the BuyBtn as a SIBLING, so it sits outside the
				-- button's hover UIScale and wouldn't grow with it -- couple it so the price grows
				-- in lockstep, same as the skills rows' GemAmt. Only the scale is driven; the
				-- label's authored text is never touched.
				local priceLabel = child:FindFirstChild(PRICE_LABEL_NAME)
				if priceLabel and priceLabel:IsA("GuiObject") then
					UiAnimations.coupleHoverScale(buyButton, priceLabel)
				end
			end
		end
	end

	applyActiveJobState()
end

function ShopUiController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(applyActiveJobState)
	-- The alternate button sells the starter pack, so it must vanish the moment that pack lands --
	-- which shows up here as the Inventory change the grant makes (and again on the next join, since
	-- the same data drives the check).
	DataService:getChangedSignal({ "Inventory" }):Connect(refreshAlternateButton)

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

return ShopUiController
