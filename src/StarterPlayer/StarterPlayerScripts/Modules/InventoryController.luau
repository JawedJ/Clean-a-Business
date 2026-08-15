--!strict

-- Custom hotbar/inventory that replaces Roblox's default Backpack UI. The HUD's
-- ScreenGui.Inventory frame holds ImageButton1..ImageButton5, one per tool slot. A slot's
-- button is shown only if the player owns an item whose SlotNumber matches it; clicking
-- the button -- or pressing that number key -- equips that slot's Tool.
--
-- Slots toggle: pressing/clicking a slot that isn't in hand equips it (swapping out whatever
-- was held), and pressing/clicking the slot that IS in hand unequips it, leaving the player
-- empty-handed. A job starts with nothing equipped.
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
local DataService = require(ReplicatedStorage.Packages.DataService).client

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local INVENTORY_FRAME_NAME = "Inventory"
local BUTTON_PREFIX = "ImageButton"
local TOOL_ID_ATTRIBUTE = "ToolId"
local SLOT_COUNT = 5

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

-- Toggle the tool in `slot`: equip it, or unequip it if it's already in hand.
local function toggleSlot(slot: number)
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
	local character = localPlayer.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid then
		return
	end
	local tool = findTool(info.id)
	if not tool then
		return
	end
	-- Already equipped (parented to the character) -> put it away, holding nothing.
	if tool.Parent == character then
		humanoid:UnequipTools()
		return
	end
	humanoid:EquipTool(tool)
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

-- React to a job starting: show the inventory, with nothing in hand -- the player picks a
-- slot themselves (the unequip covers a tool carried over from a previous job). On a job ENDING we
-- deliberately leave the hotbar up and the tool in hand -- the JobSummary is showing and the
-- player is still "in the job" until they choose. The stow (hide + unequip) is deferred to
-- GoHome, via stow(); PlayAgain just starts another job and comes back through here.
local function onActiveJobChanged()
	if hasActiveJob() then
		applyInventoryVisible()
		unequipTools()
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
				toggleSlot(slot)
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

	-- Show/hide + auto-equip/unequip as the player enters and leaves a job.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(onActiveJobChanged)

	-- Number keys toggle their slot, unless the keystroke was consumed elsewhere (a TextBox).
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		local slot = SLOT_KEYS[input.KeyCode]
		if slot then
			toggleSlot(slot)
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
