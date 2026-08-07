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
--
-- A request the player can't afford isn't just refused: we remember what they were reaching for
-- (pendingIntents) and prompt SHORTFALL_PRODUCT_ID, the "buy it with Robux instead" developer
-- product. If they go through with it, PurchaseService's receipt dispatcher hands the receipt back
-- here and we grant that remembered buy/upgrade outright, charging no gems. One product covers
-- every slot, so the intent -- not the product id -- is what decides which item is granted.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local ItemUpgrades = require(ReplicatedStorage.SharedModules.ItemUpgrades)
local InventoryManager = require(script.Parent.InventoryManager)
local PurchaseService = require(script.Parent.PurchaseService)
local TutorialService = require(script.Parent.TutorialService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PurchaseItem = Remotes:WaitForChild("PurchaseItem") :: RemoteEvent
local UpgradeItem = Remotes:WaitForChild("UpgradeItem") :: RemoteEvent

-- The single "can't afford it? buy it with Robux" developer product, shared by every slot and
-- both actions.
local SHORTFALL_PRODUCT_ID = 3641546067

local ShopService = {}

-- What each player was last prompted for, so the receipt knows what to hand over. Overwritten by
-- each new prompt (the last one they were shown is the one they're paying for) and cleared once
-- granted or when they leave.
type Intent = { action: "buy" | "upgrade", uniqueId: string }
local pendingIntents: { [Player]: Intent } = {}

-- The player's Inventory record for `uniqueId`, or nil if they have no entry for it.
local function getOwnedItem(player: Player, uniqueId: string)
	local inventory = DataService:get(player, { "Inventory" })
	if type(inventory) ~= "table" then
		return nil
	end
	local item = inventory[uniqueId]
	return if type(item) == "table" then item else nil
end

-- Remember what `player` is reaching for and put the Robux product in front of them. Called only
-- once a request has passed every check except affordability, so whatever comes back on the receipt
-- was a legitimate request when prompted -- and is checked again before it's granted.
--
-- Never offered during the tutorial: its one scripted purchase (the broom) is meant to be paid for
-- in gems, and nothing else is buyable then anyway.
local function promptShortfallPurchase(player: Player, action: "buy" | "upgrade", uniqueId: string)
	if TutorialService.isActive(player) then
		return
	end
	pendingIntents[player] = { action = action, uniqueId = uniqueId }
	MarketplaceService:PromptProductPurchase(player, SHORTFALL_PRODUCT_ID)
end

-- Add an unowned tool to the player's inventory at Level 0. The gem cost (if any) is charged by
-- the caller -- the Robux path grants the same item without one.
local function grantItem(player: Player, uniqueId: string, def)
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

-- Apply one level's worth of upgrade to an owned item. The gem cost (if any) is charged by the
-- caller, as with grantItem.
local function grantUpgrade(player: Player, uniqueId: string)
	DataService:update(player, { "Inventory", uniqueId }, function(current)
		return ItemUpgrades.applyUpgrade(current)
	end)
end

-- Unlock a not-yet-owned tool, charging its catalog Cost. Ignores bad ids and already-owned
-- items; a player short on gems is offered the Robux product instead.
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
		-- Short on gems: offer the same unlock for Robux rather than refusing outright.
		promptShortfallPurchase(player, "buy", uniqueId)
		return
	end

	-- Deduct the cost, then grant the item. The server handles one remote event at a time and
	-- neither call yields, so there's no partial-purchase race between the two.
	DataService:update(player, { "Gems" }, function(current: number?)
		return (current or 0) - cost
	end)
	grantItem(player, uniqueId, def)
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
		-- Short on gems: offer the same level for Robux rather than refusing outright.
		promptShortfallPurchase(player, "upgrade", uniqueId)
		return
	end

	-- Deduct the cost, then write the upgraded item (level + stat steps). Neither call yields
	-- and the server handles one event at a time, so there's no partial-upgrade race.
	DataService:update(player, { "Gems" }, function(current: number?)
		return (current or 0) - cost
	end)
	grantUpgrade(player, uniqueId)
end

-- Deliver a paid-for shortfall purchase: hand over whatever the buyer was last prompted for, free
-- of gems. Re-validates the intent (they may have bought or maxed the item with gems in the
-- meantime) and always acknowledges the receipt either way -- a re-delivered receipt finds no
-- pending intent and must not be retried forever, and clearing the intent on the first grant is
-- what keeps a re-delivery from granting twice.
local function onShortfallPurchase(player: Player): boolean
	local intent = pendingIntents[player]
	pendingIntents[player] = nil
	if not intent then
		return true
	end

	local uniqueId = intent.uniqueId
	local def = ToolConfig[uniqueId]
	if not def then
		return true
	end

	if intent.action == "buy" then
		local owned = getOwnedItem(player, uniqueId)
		if owned and owned.Unlocked then
			return true -- already got it another way
		end
		grantItem(player, uniqueId, def)
	else
		local item = getOwnedItem(player, uniqueId)
		if not item or not item.Unlocked or not ItemUpgrades.canUpgrade(item) then
			return true -- no longer upgradeable (unowned, or maxed since the prompt)
		end
		grantUpgrade(player, uniqueId)
	end

	return true
end

function ShopService.init()
	PurchaseItem.OnServerEvent:Connect(onPurchase)
	UpgradeItem.OnServerEvent:Connect(onUpgrade)
	PurchaseService.register(SHORTFALL_PRODUCT_ID, onShortfallPurchase)
	-- An intent belongs to a single session's prompt; don't let it outlive the player.
	Players.PlayerRemoving:Connect(function(player)
		pendingIntents[player] = nil
	end)
end

return ShopService
