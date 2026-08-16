--!strict

-- Custom hotbar/inventory that replaces Roblox's default Backpack UI. The HUD's
-- ScreenGui.Inventory frame holds ImageButton1..ImageButton5, one per tool slot. A slot's
-- button is shown only if the player owns an item whose SlotNumber matches it; clicking
-- the button -- or pressing that number key -- equips that slot's Tool.
--
-- HANDS ARE NEVER EMPTY ON A JOB. Pressing/clicking a slot equips it, swapping out whatever was
-- held; pressing the slot that's already in hand does nothing (it used to put the tool away, which
-- left the player standing in a job holding nothing). A job STARTS with the pressure washer out.
--
-- The single exception is CARRYING a piece of cleanable garbage: that's hands-full, so
-- GarbageCarryController unequips on pickup -- and this module puts the tool back the moment the
-- piece leaves the player's hands, whichever way it leaves them (fed to the shredder, dropped, the
-- drop button, the job ending). The tool that comes back is the last one they chose, so a player
-- who was mopping goes back to mopping rather than to the washer.
--
-- Tools are the physical Tool instances the server grants into the Backpack (ToolService),
-- each tagged with a ToolId attribute (== the Item's UniqueID). We map slot -> UniqueID
-- from the player's Inventory data, then resolve the matching Tool by that attribute.
--
-- The inventory is only shown while the player holds a job (keyed off the ActiveJob
-- attribute, like the rest of the HUD): the job starts -> the frame appears with nothing in
-- hand; the job ends -> the frame hides and any held tool is unequipped.
--
-- The default Backpack CoreGui is disabled so its hotbar + number-key toggle can't fight
-- this one. Like the other HUD controllers, the ScreenGui is re-cloned into PlayerGui on
-- every respawn, so we re-bind to the fresh Inventory frame each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local GarbageCarryController = require(script.Parent.GarbageCarryController)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local INVENTORY_FRAME_NAME = "Inventory"
local BUTTON_PREFIX = "ImageButton"
local TOOL_ID_ATTRIBUTE = "ToolId"
local SLOT_COUNT = 5

-- What a job starts in the player's hands, and what they fall back to if the tool they last held
-- can't be found.
local DEFAULT_TOOL_ID = ToolConfig.pressureWasher.UniqueID

-- Restoring a tool is RETRIED for a moment rather than tried once: ToolService grants the Tools
-- into the Backpack, and a job start (or a respawn) can beat that replication -- at which point
-- findTool comes up empty and the player would be left holding nothing, the one state a job
-- isn't allowed to be in.
local EQUIP_RETRIES = 15
local EQUIP_RETRY_INTERVAL = 0.2

-- How long after a tool leaves the player's hands we wait before deciding they shouldn't be empty-
-- handed. Long enough for a pickup's round trip to land (that's a legitimate reason to be holding
-- nothing), short enough that a refused one isn't left standing there.
local EMPTY_HANDS_GRACE_SECONDS = 1

-- Top-row number keys 1..5 -> slot number.
local SLOT_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
}

local InventoryController = {}

type SlotInfo = { id: string, name: string }

-- slot number -> owned item's { UniqueID, Name }, rebuilt whenever the inventory changes.
local slotInfo: { [number]: SlotInfo } = {}
-- The ToolId the player last had in hand, so putting a carried piece of garbage down gives them
-- back the tool they were using rather than the job's default.
local lastToolId: string? = nil
-- The Inventory frame + its buttons for the currently bound ScreenGui, refreshed each respawn.
local inventoryFrame: Frame? = nil
local slotButtons: { [number]: ImageButton } = {}

-- Does the local player currently hold a job? Drives whether the inventory is shown.
local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Rebuild the slot map from the player's Inventory: keep only owned + Unlocked items that
-- declare a SlotNumber.
local function rebuildSlots()
	table.clear(slotInfo)
	local inventory = DataService:get({ "Inventory" })
	if type(inventory) ~= "table" then
		return
	end
	for uniqueId, item in inventory do
		if type(item) == "table" and item.Unlocked and type(item.SlotNumber) == "number" then
			slotInfo[item.SlotNumber] = { id = uniqueId, name = item.Name }
		end
	end
end

-- Find the granted Tool for a ToolId in the player's Backpack or hand, or nil.
local function findTool(toolId: string): Tool?
	local backpack = localPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, tool in backpack:GetChildren() do
			if tool:IsA("Tool") and tool:GetAttribute(TOOL_ID_ATTRIBUTE) == toolId then
				return tool
			end
		end
	end
	local character = localPlayer.Character
	if character then
		for _, tool in character:GetChildren() do
			if tool:IsA("Tool") and tool:GetAttribute(TOOL_ID_ATTRIBUTE) == toolId then
				return tool
			end
		end
	end
	return nil
end

-- Put a ToolId in the player's hands, remembering it as what they're holding. False if there's no
-- character yet or the Tool hasn't been granted -- the caller decides whether to retry.
local function equipToolId(toolId: string): boolean
	local character = localPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") :: Humanoid? else nil
	if not character or not humanoid then
		return false
	end
	local tool = findTool(toolId)
	if not tool then
		return false
	end
	-- Already in hand: nothing to do but remember it (re-equipping would flicker the tool).
	if tool.Parent ~= character then
		humanoid:EquipTool(tool)
	end
	lastToolId = toolId
	return true
end

-- Give the player their tool back: the one they last chose, else the job's default. No-op off a job
-- (nothing should be in hand there) or while carrying garbage (hands are full by design). Keeps
-- trying for a moment -- see EQUIP_RETRIES.
local function restoreTool()
	task.spawn(function()
		for _ = 1, EQUIP_RETRIES do
			-- Re-checked every pass: the job can end, or a piece be picked up, while we're waiting on
			-- a Tool to replicate.
			if not hasActiveJob() or GarbageCarryController.isCarrying() then
				return
			end
			local wanted = lastToolId or DEFAULT_TOOL_ID
			-- The remembered tool first; the default covers one that's somehow gone (an item reset).
			if equipToolId(wanted) or (wanted ~= DEFAULT_TOOL_ID and equipToolId(DEFAULT_TOOL_ID)) then
				return
			end
			task.wait(EQUIP_RETRY_INTERVAL)
		end
	end)
end

-- Is anything in the player's hands right now? (An equipped Tool is parented to the character.)
local function holdingTool(): boolean
	local character = localPlayer.Character
	return character ~= nil and character:FindFirstChildOfClass("Tool") ~= nil
end

-- Belt and braces for the empty-handed rule. GarbageCarryController unequips as it ASKS to pick a
-- piece up, so a request the server refuses (a party member got there first) leaves the player
-- holding nothing with no carry state to come back from. So whenever a tool leaves their hands we
-- look again a moment later: still on a job, still no garbage, still nothing in hand -> give it
-- back. The grace is what lets the ordinary pickup through -- by then the carry has been confirmed.
local function watchCharacter(character: Model)
	character.ChildRemoved:Connect(function(child)
		if not child:IsA("Tool") then
			return
		end
		task.delay(EMPTY_HANDS_GRACE_SECONDS, function()
			if hasActiveJob() and not GarbageCarryController.isCarrying() and not holdingTool() then
				restoreTool()
			end
		end)
	end)
end

-- Equip the tool in `slot`. Pressing the slot already in hand does NOT put it away: a job is never
-- held empty-handed (see the header).
local function selectSlot(slot: number)
	-- Only usable while on a job. Off-job (in the plot/lobby, e.g. right after GoHome) the
	-- ActiveJob attribute is already cleared, so a stray number-key press here would
	-- otherwise strand a tool in hand with nothing left to unequip it (stow already ran).
	if not hasActiveJob() then
		return
	end
	local info = slotInfo[slot]
	if not info then
		return
	end
	-- Picking a slot while carrying garbage is allowed: equipping a tool is one of the ways to let
	-- go of a piece (GarbageCarryController drops it on Equipped), so the two can't overlap.
	equipToolId(info.id)
end

-- Put away whatever tool is in hand. Used when a job ends.
local function unequipTools()
	local character = localPlayer.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if humanoid then
		humanoid:UnequipTools()
	end
end

-- Set a button's first TextLabel (if any) to the item's name, so the label matches the
-- slot's actual item rather than the placeholder text authored in Studio.
local function labelButton(button: ImageButton, name: string)
	local label = button:FindFirstChildWhichIsA("TextLabel", true)
	if label then
		label.Text = name
	end
end

-- Show a slot's button only if the player owns that slot's item, and label it to match.
local function refreshButtons()
	for slot = 1, SLOT_COUNT do
		local button = slotButtons[slot]
		if button then
			local info = slotInfo[slot]
			button.Visible = info ~= nil
			if info then
				labelButton(button, info.name)
			end
		end
	end
end

-- Show the inventory only while the player holds a job. Guards the post-respawn gap
-- before anything is bound.
local function applyInventoryVisible()
	local frame = inventoryFrame
	if frame then
		frame.Visible = hasActiveJob()
	end
end

-- React to a job starting: show the inventory and hand the player their PRESSURE WASHER, so they
-- start the job holding something rather than empty-handed. Every job starts this way, previous
-- job's choice included -- the washer is the tool the job is introduced with.
--
-- On a job ENDING we deliberately leave the hotbar up and the tool in hand -- the JobSummary is
-- showing and the player is still "in the job" until they choose. The stow (hide + unequip) is
-- deferred to GoHome, via stow(); PlayAgain just starts another job and comes back through here.
local function onActiveJobChanged()
	if hasActiveJob() then
		applyInventoryVisible()
		lastToolId = DEFAULT_TOOL_ID
		restoreTool()
	end
end

-- Player left the JobSummary via GoHome: now hide the hotbar and put the tool away (the
-- teardown that used to fire the instant a job ended).
function InventoryController.stow()
	local frame = inventoryFrame
	if frame then
		frame.Visible = false
	end
	unequipTools()
end

local function bind(screenGui: Instance)
	local frame = screenGui:WaitForChild(INVENTORY_FRAME_NAME) :: Frame
	inventoryFrame = frame
	table.clear(slotButtons)

	for slot = 1, SLOT_COUNT do
		local button = frame:FindFirstChild(BUTTON_PREFIX .. slot)
		if button and button:IsA("ImageButton") then
			slotButtons[slot] = button
			button.Activated:Connect(function()
				selectSlot(slot)
			end)
		end
	end

	refreshButtons()
	applyInventoryVisible()
end

-- Kill Roblox's default Backpack GUI so its hotbar + number-key toggle can't conflict with
-- ours. It can reject the call very early in startup, so retry a bounded number of times.
local function disableDefaultBackpack()
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end)
		if ok then
			return
		end
		task.wait(0.1)
	end
end

function InventoryController.init()
	task.spawn(disableDefaultBackpack)

	rebuildSlots()

	-- Keep the slot map + button visibility current as the inventory changes (unlocks).
	DataService:getChangedSignal({ "Inventory" }):Connect(function()
		rebuildSlots()
		refreshButtons()
	end)

	-- Show/hide + auto-equip as the player enters and leaves a job.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(onActiveJobChanged)

	-- Carrying a piece of garbage is the one thing that empties the player's hands, so letting go is
	-- what puts the tool back. Fires immediately with the current state too, which is harmless: off a
	-- job restoreTool does nothing.
	GarbageCarryController.onCarryingChanged(function(carrying)
		if not carrying then
			restoreTool()
		end
	end)

	-- A respawn mid-job sends every Tool back to the Backpack; the job is still running, so put one
	-- back in their hands rather than leaving them empty-handed until they press a slot.
	localPlayer.CharacterAdded:Connect(function(character)
		watchCharacter(character)
		restoreTool()
	end)
	if localPlayer.Character then
		watchCharacter(localPlayer.Character)
	end

	-- Number keys toggle their slot, unless the keystroke was consumed elsewhere (a TextBox).
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		local slot = SLOT_KEYS[input.KeyCode]
		if slot then
			selectSlot(slot)
		end
	end)

	local playerGui = localPlayer:WaitForChild("PlayerGui")
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

return InventoryController
