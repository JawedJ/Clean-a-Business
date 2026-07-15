--!strict

-- Drives the skills UI (PlayerGui.ScreenGui: Buttons3.ASkillsButton + SkillsDisplay). The
-- ASkillsButton toggles the SkillsDisplay open/closed with the SAME slide + expand animation as
-- the job board / upgrades shop / settings tab (via the shared ExclusivePanels coordinator, so
-- opening it closes whichever of those was open, and vice versa); the frame's ExitButton closes it.
--
-- The frame's ScrollingFrame holds one ImageLabel per skill (Skill1..Skill5), each tagged with a
-- "SkillName" attribute naming the skill it buys (see SkillsConfig). Per skill we paint:
--   * GemAmt  -- "💎<abbrev>" price of the NEXT level (purple gradient), or "MAXED" at the cap.
--   * Circle1..Circle5 -- one filled (yellow) per level bought; the rest keep their authored colour.
--   * BuyButton -- clicking buys the next level: if the player can afford it (checked client-side
--     from their Gems) we fire PurchaseSkill and play the purchase SFX; if not we play the
--     PurchaseFailed SFX and fire nothing. A maxed skill is a silent no-op. The server (SkillsService)
--     re-validates and is authoritative; we just fire the request and repaint off the data change.
--
-- The frame's UnlockAllButton prompts a Robux product that maxes every skill at once. It hides
-- once they're ALL maxed -- the product would grant nothing at that point, so it must not be
-- sellable.
--
-- Like the other HUD controllers, the ScreenGui is re-cloned into PlayerGui on every respawn, so we
-- re-bind to the fresh instances each time one appears. The ASkillsButton lives in the Buttons3
-- cluster, which hides during a job, so the frame also snaps hidden (and refuses to open) mid-job.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local SkillsConfig = require(ReplicatedStorage.SharedModules.SkillsConfig)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local ExclusivePanels = require(script.Parent.ExclusivePanels)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PurchaseSkill = Remotes:WaitForChild("PurchaseSkill") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Stable name this panel registers under with ExclusivePanels (only one exclusive panel is open
-- at a time; opening this closes the job board / shop / settings first, and vice versa).
local PANEL_NAME = "Skills"
local SKILL_NAME_ATTRIBUTE = "SkillName"
-- Gem emoji prefixed to every price (skills cost Gems) -- e.g. "💎100k".
local GEM_ICON = "💎"
-- How many level pips each skill row shows (== the level cap).
local CIRCLE_COUNT = SkillsConfig.MAX_LEVEL
-- Colour a Circle pip takes for each level the player has bought.
local FILLED_COLOR = Color3.fromRGB(255, 221, 0)
-- Price-label tints by affordability, matching the upgrades shop: pink when the player can afford
-- the next level, red when they can't. The gem icon + number share the tint (a UIGradient tints
-- the whole label -- including the emoji, which a RichText TextColor does not). See applyPriceTint.
local AFFORDABLE_COLOR = Color3.fromRGB(255, 90, 200)
local UNAFFORDABLE_COLOR = Color3.fromRGB(255, 76, 76)
local AFFORDABLE_GRADIENT = ColorSequence.new(AFFORDABLE_COLOR)
local RED_GRADIENT = ColorSequence.new(UNAFFORDABLE_COLOR)
-- Feedback SFX played on the buy click, predicted client-side from the player's Gems: a buy we
-- expect to succeed plays PURCHASE_SOUND, one they can't afford plays PURCHASE_FAILED_SOUND.
local PURCHASE_SOUND = "Purchase"
local PURCHASE_FAILED_SOUND = "PurchaseFailed"
-- Robux dev product the UnlockAllButton prompts: maxes every skill (granted server-side in
-- SkillsService via ProcessReceipt).
local UNLOCK_ALL_PRODUCT_ID = 3609731896

local SkillsUiController = {}

-- Current top-level UI elements, refreshed each time the ScreenGui is (re)bound (the ScreenGui is
-- re-cloned each respawn, so these can't be captured once).
local skillsFrame: Frame? = nil
local scrollingFrame: Instance? = nil
-- The Robux "unlock all" button, hidden once every skill is maxed (nothing left to buy).
local unlockAllButton: ImageButton? = nil
-- Drives the frame's open/close (slide + expand) animation; rebuilt per bind alongside the frame.
local skillsPanel: UiAnimations.Panel? = nil
-- Authored BackgroundColor3 of each Circle pip, captured the first time we fill it so an unfilled
-- pip restores the designer's colour instead of a baked-in yellow. Cleared per bind so a fresh
-- clone is captured pristine rather than reusing a previous respawn's (possibly filled) entry.
local originalCircleColors: { [Instance]: Color3 } = {}
-- The buy-feedback SFX currently playing, keyed by sound name, so a rapid repeat of the SAME sound
-- cuts its previous clone instead of stacking (see playFeedback).
local feedbackSounds: { [string]: Sound } = {}

-- Play a buy feedback one-shot, first killing any still-playing clone of the SAME sound so rapid
-- repeats of it don't stack, while leaving any other feedback sound playing. Destroy() both stops
-- and removes the previous clone, and is safe even if it already ended on its own.
local function playFeedback(soundName: string)
	local existing = feedbackSounds[soundName]
	if existing then
		existing:Destroy()
	end
	local sound = SoundManager.playOneShot(soundName)
	if sound then
		feedbackSounds[soundName] = sound
		sound.Ended:Once(function()
			if feedbackSounds[soundName] == sound then
				feedbackSounds[soundName] = nil
			end
		end)
	else
		feedbackSounds[soundName] = nil
	end
end

-- Whether the player can currently afford `cost`, read fresh from their replicated Gems.
local function canAfford(cost: number): boolean
	local gems = DataService:get({ "Gems" })
	return type(gems) == "number" and gems >= cost
end

-- The player's current level in `skillName` (0 if unset / not yet reconciled).
local function getLevel(skillName: string): number
	local level = DataService:get({ "Skills", skillName })
	return if type(level) == "number" then level else 0
end

-- Whether every skill is already at the cap -- i.e. the "unlock all" product has nothing left to
-- grant, so offering it would take Robux for nothing.
local function allSkillsMaxed(): boolean
	for skillName in SkillsConfig.Skills do
		if SkillsConfig.canUpgrade(getLevel(skillName)) then
			return false
		end
	end
	return true
end

-- Whether the local player currently holds a job (the Buttons3 cluster -- including the
-- ASkillsButton -- hides while on one, so the frame must hide/refuse to open then too).
local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Tint a price label pink/red by affordability. The GemAmt labels ship without a UIGradient, so
-- add one on first sight (a flat gradient tints emoji + number alike, unlike TextColor3). Passing
-- nil leaves the label untinted (the MAX case isn't a purchase).
local function applyPriceTint(label: TextLabel, forced: ColorSequence?)
	local gradient = label:FindFirstChildOfClass("UIGradient")
	if not gradient then
		if forced == nil then
			return
		end
		gradient = Instance.new("UIGradient")
		gradient.Parent = label
	end
	gradient.Enabled = forced ~= nil
	if forced then
		gradient.Color = forced
	end
end

-- Paint one skill row (Skill ImageLabel) from the player's current level: price/label, the filled
-- pips, all off live data. Skips rows without a SkillName attribute or naming an unknown skill.
local function renderSkill(row: Instance)
	local skillName = row:GetAttribute(SKILL_NAME_ATTRIBUTE)
	if type(skillName) ~= "string" or not SkillsConfig.isSkill(skillName) then
		return
	end
	local level = getLevel(skillName)

	-- Price of the next level, tinted pink when affordable / red when not (like the upgrades shop),
	-- or "MAX" once at the cap.
	local gemAmt = row:FindFirstChild("GemAmt")
	if gemAmt and gemAmt:IsA("TextLabel") then
		if SkillsConfig.canUpgrade(level) then
			local cost = SkillsConfig.getCost(level)
			gemAmt.Text = GEM_ICON .. NumberFormat.abbreviate(cost)
			applyPriceTint(gemAmt, if canAfford(cost) then AFFORDABLE_GRADIENT else RED_GRADIENT)
		else
			gemAmt.Text = "MAX"
			applyPriceTint(gemAmt, nil)
		end
	end

	-- One filled pip per level bought; the rest restore their authored colour.
	for i = 1, CIRCLE_COUNT do
		local circle = row:FindFirstChild("Circle" .. i)
		if circle and circle:IsA("GuiObject") then
			if not originalCircleColors[circle] then
				originalCircleColors[circle] = circle.BackgroundColor3
			end
			circle.BackgroundColor3 = if i <= level then FILLED_COLOR else originalCircleColors[circle]
		end
	end
end

-- Act on a BuyButton click: buy the next level if the skill isn't maxed. Predicted client-side from
-- the player's Gems so we can play instant audio -- a buy we expect to succeed fires the request
-- (the server re-validates) and plays the purchase sound; one they can't afford plays the failure
-- sound and fires nothing. A maxed skill is a silent no-op.
local function onBuy(skillName: string)
	local level = getLevel(skillName)
	if not SkillsConfig.canUpgrade(level) then
		return -- maxed
	end
	if canAfford(SkillsConfig.getCost(level)) then
		PurchaseSkill:FireServer(skillName)
		playFeedback(PURCHASE_SOUND)
	else
		playFeedback(PURCHASE_FAILED_SOUND)
	end
end

-- Repaint every skill row, and hide the "unlock all" button once there's nothing left for it to
-- unlock. Guards the post-respawn gap before anything is bound.
local function renderSkills()
	local scroll = scrollingFrame
	if scroll then
		for _, child in scroll:GetChildren() do
			if child:IsA("ImageLabel") then
				renderSkill(child)
			end
		end
	end
	local button = unlockAllButton
	if button and button.Parent then
		button.Visible = not allSkillsMaxed()
	end
end

-- Toggle the frame open/closed via the shared coordinator (closing any other open panel first).
-- No-op while on a job -- the Buttons3 cluster is hidden then.
local function togglePanel()
	if hasActiveJob() then
		return
	end
	ExclusivePanels.toggle(PANEL_NAME)
end

-- Snap the frame hidden if a job starts with it open (the Buttons3 cluster hides mid-job, so the
-- frame must not linger over the job UI). Guards the gap before anything is bound.
local function applyActiveJobState()
	local panel = skillsPanel
	local frame = skillsFrame
	if hasActiveJob() and panel and frame and frame.Parent then
		panel:hideInstant()
		ExclusivePanels.markHidden(PANEL_NAME)
	end
end

-- Resolve one ScreenGui's skills elements, wire the buttons, then paint the rows + apply current
-- state. Yields on WaitForChild for a fresh clone.
local function bind(screenGui: Instance)
	local buttons3 = screenGui:WaitForChild("Buttons3")
	local skillsButton = buttons3:WaitForChild("ASkillsButton") :: ImageButton
	local frame = screenGui:WaitForChild("SkillsDisplay") :: Frame
	local exitButton = frame:WaitForChild("ExitButton") :: ImageButton
	local unlockAll = frame:WaitForChild("UnlockAllButton") :: ImageButton
	local scroll = frame:WaitForChild("ScrollingFrame")

	-- Drop the previous clone's captured pip colours so this fresh clone is captured pristine.
	table.clear(originalCircleColors)

	local panel = UiAnimations.Panel.new(frame)
	skillsFrame = frame
	scrollingFrame = scroll
	skillsPanel = panel
	unlockAllButton = unlockAll
	frame.Visible = false

	-- Register with the coordinator so open/close is sequenced against the other panels; it
	-- repaints the rows (beforeOpen) right before showing.
	ExclusivePanels.register(PANEL_NAME, panel, renderSkills)

	skillsButton.Activated:Connect(togglePanel)
	-- Grow the close button on hover, like the HUD's cluster buttons (its hover sound is wired
	-- centrally in UiSoundController).
	UiAnimations.hoverGrow(exitButton)
	exitButton.Activated:Connect(function()
		ExclusivePanels.close(PANEL_NAME)
	end)

	-- Prompt the Robux "unlock all skills" dev product; the server maxes every skill on receipt, and
	-- the resulting Skills change repaints the rows (circles fill, prices flip to MAX) and hides this
	-- button. Maxed is re-checked here too: the button hides on the same data, but a purchase prompt
	-- that grants nothing is worth guarding against directly rather than trusting Visible.
	UiAnimations.hoverGrow(unlockAll)
	unlockAll.Activated:Connect(function()
		if allSkillsMaxed() then
			return
		end
		MarketplaceService:PromptProductPurchase(localPlayer, UNLOCK_ALL_PRODUCT_ID)
	end)

	-- Wire each row's BuyButton once per bind (a fresh clone each respawn, so no stacking). The
	-- handler re-derives the level from live data, so it stays correct as rows repaint.
	for _, child in scroll:GetChildren() do
		if child:IsA("ImageLabel") then
			local skillName = child:GetAttribute(SKILL_NAME_ATTRIBUTE)
			local buyButton = child:FindFirstChild("BuyButton")
			if type(skillName) == "string" and buyButton and buyButton:IsA("ImageButton") then
				local name = skillName
				buyButton.Activated:Connect(function()
					onBuy(name)
				end)
			end
		end
	end

	renderSkills()
	applyActiveJobState()
end

function SkillsUiController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Persistent subscriptions; each reads whichever elements are currently bound. Gems is watched
	-- so a price flips to affordable the moment the balance allows (and the row repaints after a buy).
	DataService:getChangedSignal({ "Skills" }):Connect(renderSkills)
	DataService:getChangedSignal({ "Gems" }):Connect(renderSkills)
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

return SkillsUiController
