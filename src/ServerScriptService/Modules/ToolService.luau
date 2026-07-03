--!strict

-- Grants each player their owned tools as physical Backpack Tools. The Tool instances
-- live in ReplicatedStorage.Items (authored in Studio); each is tied to an inventory item
-- by its ToolId attribute (== the Item's UniqueID). StarterPack is empty, so this is the
-- only path tools reach players: on every spawn we clone each owned+Unlocked item's Tool
-- into the fresh Backpack, and we also grant live when a new item is unlocked mid-session.
--
-- Owned/equipped *state* still lives in DataTemplate.Inventory; this only mirrors owned
-- items into Tool instances. Equipping itself is driven client-side by InventoryController.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local ToolService = {}

local ITEMS_FOLDER = ReplicatedStorage:WaitForChild("Items")
local TOOL_ID_ATTRIBUTE = "ToolId"

-- ToolId -> Tool template, built once from the Items folder.
local toolTemplates: { [string]: Tool } = {}
for _, inst in ITEMS_FOLDER:GetChildren() do
	if inst:IsA("Tool") then
		local id = inst:GetAttribute(TOOL_ID_ATTRIBUTE)
		if type(id) == "string" then
			toolTemplates[id] = inst
		end
	end
end

-- Does the player already hold a Tool for this ToolId (in the Backpack or in hand)?
local function playerHasTool(player: Player, toolId: string): boolean
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, tool in backpack:GetChildren() do
			if tool:IsA("Tool") and tool:GetAttribute(TOOL_ID_ATTRIBUTE) == toolId then
				return true
			end
		end
	end
	local character = player.Character
	if character then
		for _, tool in character:GetChildren() do
			if tool:IsA("Tool") and tool:GetAttribute(TOOL_ID_ATTRIBUTE) == toolId then
				return true
			end
		end
	end
	return false
end

-- Clone one item's Tool into the player's Backpack, unless it has no template or the
-- player already holds it (keeps this safe to call repeatedly).
local function grantTool(player: Player, toolId: string)
	local template = toolTemplates[toolId]
	if not template or playerHasTool(player, toolId) then
		return
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end
	template:Clone().Parent = backpack
end

-- Grant a Tool for every owned + Unlocked inventory item (idempotent).
local function grantOwnedTools(player: Player)
	local inventory = DataService:get(player, { "Inventory" })
	if type(inventory) ~= "table" then
		return
	end
	for uniqueId, item in inventory do
		if type(item) == "table" and item.Unlocked then
			grantTool(player, uniqueId)
		end
	end
end

local function onCharacterAdded(player: Player)
	-- The fresh character's Backpack may not exist the instant CharacterAdded fires.
	player:WaitForChild("Backpack")
	grantOwnedTools(player)
end

local function setupPlayer(player: Player)
	-- Inventory can't be read until the player's data has loaded.
	DataService:waitForData(player)

	player.CharacterAdded:Connect(function()
		onCharacterAdded(player)
	end)
	if player.Character then
		onCharacterAdded(player)
	end

	-- Grant live when the inventory gains a newly unlocked item (harmless if nothing new).
	DataService:getChangedSignal(player, { "Inventory" }):Connect(function()
		grantOwnedTools(player)
	end)
end

function ToolService.init()
	for _, player in Players:GetPlayers() do
		task.spawn(setupPlayer, player)
	end
	Players.PlayerAdded:Connect(function(player)
		setupPlayer(player)
	end)
end

return ToolService
