--!strict

-- Server authority for the upgrades shop (PlayerGui.ScreenGui.UpgradesFrame, driven by the
-- client's UpgradesUiController). Owns the two shop actions, both re-validated here so a
-- client can never grant itself an item or a level it didn't earn:
--
--   * PurchaseItem(uniqueId) -- unlock a not-yet-owned tool: if the player can afford its
--     catalog Cost, deduct that Cost and add the item to their Inventory (Unlocked, Level 0).
--     ToolService picks the new inventory item up and grants its physical Tool.
--   * UpgradeItem(uniqueId)  -- level an owned tool up by one (up to ItemUpgrades.MAX_LEVEL):
--     charge the shared upgrade cost and apply the item's per-level Range/Radius steps. All the
--     upgrade math (cost curve, stat steps, cap) lives in the shared ItemUpgrades module so the
--     client's display and this authority can't disagree.
--
-- The shop is priced in GEMS (not Cash): both actions charge the cost against the player's Gems
-- balance. All state changes go through DataService so they replicate to the client, which repaints
-- the slot (button image + labels) off the Inventory/Gems change.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local ItemUpgrades = require(ReplicatedStorage.SharedModules.ItemUpgrades)
local InventoryManager = require(script.Parent.InventoryManager)
local TutorialService = require(script.Parent.TutorialService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PurchaseItem = Remotes:WaitForChild("PurchaseItem") :: RemoteEvent
local UpgradeItem = Remotes:WaitForChild("UpgradeItem") :: RemoteEvent

local ShopService = {}

-- The player's Inventory record for `uniqueId`, or nil if they have no entry for it.
local function getOwnedItem(player: Player, uniqueId: string)
	local inventory = DataService:get(player, { "Inventory" })
	if type(inventory) ~= "table" then
		return nil
	end
	local item = inventory[uniqueId]
	return if type(item) == "table" then item else nil
end

-- Unlock a not-yet-owned tool, charging its catalog Cost. Ignores bad ids, already-owned
-- items, and players who can't afford it.
local function onPurchase(player: Player, uniqueId: unknown)
	if type(uniqueId) ~= "string" then
		return
	end
	local def = ToolConfig[uniqueId]
	if not def then
		return
	end
	-- The tutorial opens the shop for exactly one purchase (the broom, step 11); everything else is
	-- refused for its duration.
	if not TutorialService.canPurchaseTool(player, uniqueId) then
		return
	end

	local owned = getOwnedItem(player, uniqueId)
	if owned and owned.Unlocked then
		return -- already owns it
	end

	local cost = def.Cost
	local gems = DataService:get(player, { "Gems" })
	if type(gems) ~= "number" or gems < cost then
		return -- can't afford it
	end

	-- Deduct the cost, then grant the item. The server handles one remote event at a time and
	-- neither call yields, so there's no partial-purchase race between the two.
	DataService:update(player, { "Gems" }, function(current: number?)
		return (current or 0) - cost
	end)

	-- Clone the catalog definition (shared table) so we never mutate the config, and mark it
	-- owned at Level 0. ToolService grants the physical Tool off the resulting Inventory change.
	local item = table.clone(def)
	item.Unlocked = true
	item.Equipped = false
	item.Level = 0
	InventoryManager.addItem(player, item)

	-- Buying the broom is what ends the tutorial's last interactive step (and lifts its
	-- restrictions). A no-op for any other purchase.
	TutorialService.notifyToolPurchased(player, uniqueId)
end

-- Level an owned tool up by one, charging the shared upgrade cost and applying its per-level
-- Range/Radius steps. Ignores bad ids, unowned items, items at the cap, and players who can't
-- afford the next level.
local function onUpgrade(player: Player, uniqueId: unknown)
	if type(uniqueId) ~= "string" then
		return
	end
	if not ToolConfig[uniqueId] then
		return
	end
	-- No tutorial step asks for an upgrade, so upgrading is off for its whole duration.
	if not TutorialService.canUpgradeTool(player) then
		return
	end

	local item = getOwnedItem(player, uniqueId)
	if not item or not item.Unlocked then
		return -- doesn't own it
	end
	if not ItemUpgrades.canUpgrade(item) then
		return -- maxed or not upgradeable
	end

	local cost = ItemUpgrades.getUpgradeCost(item)
	local gems = DataService:get(player, { "Gems" })
	if type(gems) ~= "number" or gems < cost then
		return -- can't afford it
	end

	-- Deduct the cost, then write the upgraded item (level + stat steps). Neither call yields
	-- and the server handles one event at a time, so there's no partial-upgrade race.
	DataService:update(player, { "Gems" }, function(current: number?)
		return (current or 0) - cost
	end)
	DataService:update(player, { "Inventory", uniqueId }, function(current)
		return ItemUpgrades.applyUpgrade(current)
	end)
end

function ShopService.init()
	PurchaseItem.OnServerEvent:Connect(onPurchase)
	UpgradeItem.OnServerEvent:Connect(onUpgrade)
end

return ShopService
