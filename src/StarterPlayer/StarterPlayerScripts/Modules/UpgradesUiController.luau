--!strict

-- Drives the upgrades/shop UI (PlayerGui.ScreenGui: Buttons.UpgradesButton + UpgradesFrame).
-- The UpgradesButton toggles the UpgradesFrame open/closed (same slide + expand animation as
-- the job board); the frame's ExitButton closes it.
--
-- The frame's Slots frame holds one ImageLabel per tool, each tagged with a "UniqueID"
-- attribute (== the Item's UniqueID). Each slot is painted from the player's own copy of that
-- item (DataService.Inventory) when they own it, otherwise from the static catalog
-- (ToolConfig) so not-yet-owned tools still show their stats. Per slot we set:
--   * Cost   -- "Cost: 💎<abbrev>" (the item's price / upgrade price, in Gems; purple if
--     affordable). Hidden once the item is maxed -- there's no price left to show.
--   * Range  -- "Range: <studs>"  (optional label; hidden if the item has no Range)
--   * Radius -- "Radius: <n.n>"   (optional label; hidden if the item has no Radius)
--   * UseTime -- "Time: <n.n>s"     (optional label; hidden if the item has no UseTime)
--   * TextInfo.Level  -- "Level <current>/<max>"
--   * TextInfo.Owned? -- shown only if the player owns the item
--   * InteractButton -- its image + click action depend on state: BUY when not owned (click
--     fires PurchaseItem), UPGRADE when owned below the cap (click fires UpgradeItem), or MAX
--     when owned at the cap (click does nothing). The server (ShopService) re-validates and is
--     authoritative; we just fire the request and repaint off the resulting data change.
--
-- Like the other HUD controllers, the ScreenGui is re-cloned into PlayerGui on every respawn,
-- so we re-bind to the fresh instances each time one appears. While a job is active the whole
-- Buttons frame hides (JobUiController), so we also snap the panel hidden if a job starts with
-- it open, and refuse to open it mid-job.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local DataTemplate = require(ReplicatedStorage.SharedModules.DataTemplate)
local ItemUpgrades = require(ReplicatedStorage.SharedModules.ItemUpgrades)
local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local ExclusivePanels = require(script.Parent.ExclusivePanels)
local TutorialState = require(script.Parent.TutorialState)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PurchaseItem = Remotes:WaitForChild("PurchaseItem") :: RemoteEvent
local UpgradeItem = Remotes:WaitForChild("UpgradeItem") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local INTERACT_BUTTON_NAME = "InteractButton"
-- InteractButton images per state: buy (not owned), upgrade (owned, below cap), max (owned, at
-- cap). Set on each render; the matching click action is decided live in onInteract.
local BUY_IMAGE = "rbxassetid://110464713650126"
local UPGRADE_IMAGE = "rbxassetid://135186205507719"
local MAX_IMAGE = "rbxassetid://107751883089715"
-- Cost label tints (the shop is priced in GEMS): pink when the player can afford the
-- buy/upgrade, red when they can't. MAXED slots aren't a purchase and keep the authored colour.
-- See applyCostGradient.
local AFFORDABLE_COLOR = Color3.fromRGB(255, 90, 200)
local UNAFFORDABLE_COLOR = Color3.fromRGB(255, 76, 76)
-- Gem emoji prefixed to every cost amount (the shop costs Gems, not Cash) -- e.g. "Cost: 💎1.2k".
local GEM_ICON = "💎"
-- Feedback SFX played on the interact click, predicted client-side from the player's cash: a
-- buy/upgrade the client expects to succeed plays PURCHASE_SOUND, one it can't afford plays
-- PURCHASE_FAILED_SOUND. Only one plays at a time (see playFeedback).
local PURCHASE_SOUND = "Purchase"
local PURCHASE_FAILED_SOUND = "PurchaseFailed"
-- Stable name this panel registers under with ExclusivePanels (only one exclusive panel is
-- open at a time; opening this closes the job board first, and vice versa).
local PANEL_NAME = "Upgrades"
local UNIQUE_ID_ATTRIBUTE = "UniqueID"
-- Level cap shown in the "Level x/MAX" label, shared with the server via ItemUpgrades so the
-- display denominator and the upgrade gating never disagree.
local MAX_LEVEL = ItemUpgrades.MAX_LEVEL

local UpgradesUiController = {}

-- Current top-level UI elements, refreshed each time the ScreenGui is (re)bound (the ScreenGui
-- is re-cloned each respawn, so these can't be captured once).
local upgradesFrame: Frame? = nil
local slotsContainer: Instance? = nil
-- Drives the frame's open/close (slide + expand) animation; rebuilt per bind alongside the frame.
local upgradesPanel: UiAnimations.Panel? = nil
-- The interact-feedback SFX currently playing, keyed by sound name. Only a rapid repeat of the
-- SAME sound cuts off its previous clone; two DIFFERENT feedback sounds (e.g. purchase then
-- fail) are left to overlap rather than cutting each other off.
local feedbackSounds: { [string]: Sound } = {}

-- Play a buy/upgrade feedback one-shot, first killing any still-playing clone of the SAME sound
-- so rapid repeats of it don't stack -- while leaving any other feedback sound playing. Destroy()
-- both stops and removes the previous clone, and is safe even if it already ended on its own.
local function playFeedback(soundName: string)
	local existing = feedbackSounds[soundName]
	if existing then
		existing:Destroy()
	end
	local sound = SoundManager.playOneShot(soundName)
	if sound then
		feedbackSounds[soundName] = sound
		-- Drop our reference once it ends on its own, unless a newer repeat has already replaced it.
		sound.Ended:Once(function()
			if feedbackSounds[soundName] == sound then
				feedbackSounds[soundName] = nil
			end
		end)
	else
		feedbackSounds[soundName] = nil
	end
end

-- Whether the player can currently afford `cost`, read fresh from their replicated Gems (the
-- shop is priced in Gems, not Cash).
local function canAfford(cost: number): boolean
	local gems = DataService:get({ "Gems" })
	return type(gems) == "number" and gems >= cost
end

-- Flat gradients swapped onto a cost label by affordability. The cost text is coloured by a
-- UIGradient (a 2-colour ColorSequence), so tinting TextColor3 would do nothing -- we replace the
-- whole gradient instead: pink when the player can afford the slot, red when they can't.
local AFFORDABLE_GRADIENT = ColorSequence.new(AFFORDABLE_COLOR)
local RED_GRADIENT = ColorSequence.new(UNAFFORDABLE_COLOR)

-- Authored gradient of each cost label's UIGradient, captured the first time we tint it so we can
-- restore the designer's colours on a MAXED slot (not a purchase) -- never baking a tint in
-- permanently. Strong-keyed and cleared at the start of every bind: a weak table would let a live
-- (but only-weakly-referenced) gradient's entry GC mid-session, after which the next capture would
-- read the tinted colour back as the "original" and stick it forever. Clearing per bind drops the
-- previous respawn's clones instead, and the fresh clone is captured pristine.
local originalGradients: { [Instance]: ColorSequence } = {}

-- Force a cost label's gradient to `forced`, or restore its authored gradient when `forced` is nil
-- (MAXED slots). No-op if the label has no UIGradient (nothing meaningful to tint).
local function applyCostGradient(costLabel: TextLabel, forced: ColorSequence?)
	local gradient = costLabel:FindFirstChildOfClass("UIGradient")
	if not gradient then
		return
	end
	if not originalGradients[gradient] then
		originalGradients[gradient] = gradient.Color
	end
	gradient.Color = forced or originalGradients[gradient]
end

-- Whether the local player currently holds a job (the whole Buttons frame -- including the
-- UpgradesButton -- hides while on one, so the shop must hide/refuse to open then too).
local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Paint one slot from the player's owned item (if any) or the static catalog otherwise. Skips
-- rows that carry no UniqueID (layout/constraint children) or name a tool we don't know.
local function renderSlot(slot: Instance)
	local uniqueId = slot:GetAttribute(UNIQUE_ID_ATTRIBUTE)
	if type(uniqueId) ~= "string" then
		return
	end

	-- The player's own copy is the source of truth once owned (it carries their Level and any
	-- leveled-up stats); fall back to the catalog for tools they haven't bought yet.
	local inventory = DataService:get({ "Inventory" })
	local ownedItem = if type(inventory) == "table" and type(inventory[uniqueId]) == "table"
		then inventory[uniqueId]
		else nil
	local owned = ownedItem ~= nil and ownedItem.Unlocked == true
	local data: DataTemplate.Item? = ownedItem or ToolConfig[uniqueId]
	if not data then
		return
	end
	local item = data :: DataTemplate.Item
	-- Only an owned item carries a meaningful level; an unowned catalog entry reads as 0.
	local level = if owned and type(item.Level) == "number" then item.Level else 0

	-- Cost: the purchase price when unowned, the next upgrade's price when owned + upgradeable,
	-- or hidden entirely once at the cap. Priced in Gems -- "Cost: 💎1.2k" style, purple when affordable.
	local costLabel = slot:FindFirstChild("Cost")
	if costLabel and costLabel:IsA("TextLabel") then
		if not owned then
			costLabel.Text = "Cost: " .. GEM_ICON .. NumberFormat.abbreviate(item.Cost)
			applyCostGradient(costLabel, if canAfford(item.Cost) then AFFORDABLE_GRADIENT else RED_GRADIENT)
			costLabel.Visible = true
		elseif ItemUpgrades.canUpgrade(item) then
			local cost = ItemUpgrades.getUpgradeCost(item)
			costLabel.Text = "Cost: " .. GEM_ICON .. NumberFormat.abbreviate(cost)
			applyCostGradient(costLabel, if canAfford(cost) then AFFORDABLE_GRADIENT else RED_GRADIENT)
			costLabel.Visible = true
		else
			-- Maxed: nothing left to buy, so the price line just goes away. Restore the authored
			-- colour too, so a later re-show never inherits a stale pink/red tint.
			applyCostGradient(costLabel, nil)
			costLabel.Visible = false
		end
	end

	-- Range/Radius are optional per item: show the label with the value when present, hide it
	-- otherwise (a broom has no Radius, for instance).
	local rangeLabel = slot:FindFirstChild("Range")
	if rangeLabel and rangeLabel:IsA("TextLabel") then
		local range = item.Range
		if range then
			rangeLabel.Text = string.format("Range: %d", range)
			rangeLabel.Visible = true
		else
			rangeLabel.Visible = false
		end
	end

	local radiusLabel = slot:FindFirstChild("Radius")
	if radiusLabel and radiusLabel:IsA("TextLabel") then
		local radius = item.Radius
		if radius then
			radiusLabel.Text = string.format("Radius: %.1f", radius)
			radiusLabel.Visible = true
		else
			radiusLabel.Visible = false
		end
	end

	local useTimeLabel = slot:FindFirstChild("UseTime")
	if useTimeLabel and useTimeLabel:IsA("TextLabel") then
		local useTime = item.UseTime
		if useTime then
			useTimeLabel.Text = string.format("Time: %.1fs", useTime)
			useTimeLabel.Visible = true
		else
			useTimeLabel.Visible = false
		end
	end

	-- Power is the mop's fade rate (Transparency/sec). Optional per item, shown/hidden like the
	-- other stat labels (only the mop has it).
	local powerLabel = slot:FindFirstChild("Power")
	if powerLabel and powerLabel:IsA("TextLabel") then
		local power = item.Power
		if power then
			powerLabel.Text = string.format("Power: %.2f", power)
			powerLabel.Visible = true
		else
			powerLabel.Visible = false
		end
	end

	local textInfo = slot:FindFirstChild("TextInfo")
	if textInfo then
		local levelLabel = textInfo:FindFirstChild("Level")
		if levelLabel and levelLabel:IsA("TextLabel") then
			levelLabel.Text = string.format("Level %d/%d", level, MAX_LEVEL)
		end

		-- "Owned?" (literal name) shows only when the player owns the item.
		local ownedLabel = textInfo:FindFirstChild("Owned?")
		if ownedLabel and ownedLabel:IsA("TextLabel") then
			ownedLabel.Visible = owned
		end
	end

	-- InteractButton image reflects the action a click will take: buy it, upgrade it, or
	-- nothing (maxed). The click handler (wired once in bind) re-derives this same state.
	local interactButton = slot:FindFirstChild(INTERACT_BUTTON_NAME)
	if interactButton and interactButton:IsA("ImageButton") then
		if not owned then
			interactButton.Image = BUY_IMAGE
		elseif ItemUpgrades.canUpgrade(item) then
			interactButton.Image = UPGRADE_IMAGE
		else
			interactButton.Image = MAX_IMAGE
		end
	end
end

-- Act on an InteractButton click: buy the tool if unowned, upgrade it if owned below the cap,
-- or do nothing if it's maxed. The outcome is predicted client-side from the player's cash so
-- we can play instant audio feedback -- a buy/upgrade we expect to succeed fires the request
-- (the server re-validates cash/ownership/level) and plays the purchase sound; one they can't
-- afford plays the failure sound and fires nothing. A maxed slot is a silent no-op.
local function onInteract(uniqueId: string)
	local inventory = DataService:get({ "Inventory" })
	local item = if type(inventory) == "table" and type(inventory[uniqueId]) == "table"
		then inventory[uniqueId]
		else nil
	local owned = item ~= nil and item.Unlocked == true

	if not owned then
		-- Buy: the price comes from the catalog (the player has no copy yet).
		local def = ToolConfig[uniqueId]
		if not def then
			return
		end
		-- The tutorial opens this shop for one specific tool; every other slot is inert for the
		-- duration. Silent -- not even the failure sound -- so a locked slot reads as "not yet"
		-- rather than "you can't afford it". The server refuses these independently.
		if not TutorialState.isToolAllowed(uniqueId) then
			return
		end
		if canAfford(def.Cost) then
			PurchaseItem:FireServer(uniqueId)
			playFeedback(PURCHASE_SOUND)
		else
			playFeedback(PURCHASE_FAILED_SOUND)
		end
		return
	end

	-- Owned: upgrade if it isn't maxed. A maxed slot does nothing (no sound).
	if not ItemUpgrades.canUpgrade(item) then
		return
	end
	-- No tutorial step asks for an upgrade, so they're inert for its duration (server agrees).
	if not TutorialState.areUpgradesAllowed() then
		return
	end
	if canAfford(ItemUpgrades.getUpgradeCost(item)) then
		UpgradeItem:FireServer(uniqueId)
		playFeedback(PURCHASE_SOUND)
	else
		playFeedback(PURCHASE_FAILED_SOUND)
	end
end

-- Repaint every slot. Guards the post-respawn gap before anything is bound.
local function renderSlots()
	local slots = slotsContainer
	if not slots then
		return
	end
	for _, child in slots:GetChildren() do
		if child:IsA("ImageLabel") then
			renderSlot(child)
		end
	end
end

-- Snap the panel hidden if a job starts with it open (the Buttons frame hides mid-job, so the
-- shop must not linger over the job UI). Guards the gap before anything is bound.
local function applyActiveJobState()
	local panel = upgradesPanel
	local frame = upgradesFrame
	if hasActiveJob() and panel and frame and frame.Parent then
		panel:hideInstant()
		ExclusivePanels.markHidden(PANEL_NAME)
	end
end

-- Toggle the shop open/closed via the shared coordinator (so opening it closes the job board
-- first, and vice versa). No-op while on a job -- the whole Buttons frame is hidden then.
local function togglePanel()
	if hasActiveJob() then
		return
	end
	ExclusivePanels.toggle(PANEL_NAME)
end

-- Open the shop from a non-button trigger (the warehouse UpgradesBoard proximity hitbox),
-- routed through the same coordinator as the UpgradesButton so it still closes the job board
-- first. No-op (returns false) while on a job, matching togglePanel's gating. Unlike togglePanel
-- this never closes an already-open shop -- re-entering the hitbox shouldn't flap it shut.
function UpgradesUiController.openShop(): boolean
	if hasActiveJob() then
		return false
	end
	return ExclusivePanels.open(PANEL_NAME)
end

-- Close the shop from the same proximity trigger (walking out of the hitbox), routed through
-- the coordinator so its open-panel bookkeeping stays in sync.
function UpgradesUiController.closeShop()
	ExclusivePanels.close(PANEL_NAME)
end

-- Whether the shop frame is currently shown -- lets the proximity trigger skip a redundant
-- close when the shop isn't up (e.g. the player closed it via Exit and is still inside).
function UpgradesUiController.isShopVisible(): boolean
	local frame = upgradesFrame
	return frame ~= nil and frame.Parent ~= nil and frame.Visible
end

-- Resolve one ScreenGui's upgrades elements, wire the buttons, then paint the slots + apply
-- current state. Yields on WaitForChild for a fresh clone.
local function bind(screenGui: Instance)
	local button1 = screenGui:WaitForChild("HUD"):WaitForChild("AllButtons"):WaitForChild("Button1")
	local upgradesButton = button1:WaitForChild("UpgradesButton") :: ImageButton
	local frame = screenGui:WaitForChild("UpgradesFrame") :: Frame
	local exitButton = frame:WaitForChild("ExitButton") :: ImageButton
	local slots = frame:WaitForChild("Slots")

	-- Drop the previous clone's captured gradients so this fresh clone is captured pristine (see
	-- originalGradients) rather than reusing a possibly-reddened entry.
	table.clear(originalGradients)

	local panel = UiAnimations.Panel.new(frame)
	upgradesFrame = frame
	slotsContainer = slots
	upgradesPanel = panel
	frame.Visible = false

	-- Register with the coordinator so open/close is sequenced against the other panels; it
	-- refreshes the slots (beforeOpen) right before showing.
	ExclusivePanels.register(PANEL_NAME, panel, renderSlots)

	upgradesButton.Activated:Connect(togglePanel)
	exitButton.Activated:Connect(function()
		ExclusivePanels.close(PANEL_NAME)
	end)

	-- Wire each slot's InteractButton once per bind (a fresh clone each respawn, so no stacking).
	-- The handler re-derives the action from live data, so it stays correct as slots repaint.
	for _, child in slots:GetChildren() do
		if child:IsA("ImageLabel") then
			local uniqueId = child:GetAttribute(UNIQUE_ID_ATTRIBUTE)
			local interactButton = child:FindFirstChild(INTERACT_BUTTON_NAME)
			if type(uniqueId) == "string" and interactButton and interactButton:IsA("ImageButton") then
				local id = uniqueId
				interactButton.Activated:Connect(function()
					onInteract(id)
				end)
			end
		end
	end

	renderSlots()
	applyActiveJobState()
end

function UpgradesUiController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Persistent subscriptions; each reads whichever elements are currently bound. Gems is
	-- watched too so the cost labels re-tint (purple/red) the moment the player can or can't
	-- afford a slot, without needing an Inventory change.
	DataService:getChangedSignal({ "Inventory" }):Connect(renderSlots)
	DataService:getChangedSignal({ "Gems" }):Connect(renderSlots)
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(applyActiveJobState)

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

return UpgradesUiController
