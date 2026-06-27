--!strict

-- Server service that owns the player Inventory domain.
-- All reads/writes flow through DataService so changes replicate to the client.
-- Call init() once from Main before using.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local DataTemplate = require(ReplicatedStorage.SharedModules.DataTemplate)

local InventoryManager = {}

function InventoryManager.init()
	-- Reserved for setup (event connections, etc.). Nothing needed yet.
end

-- Adds (or overwrites) an item in the player's inventory, keyed by its UniqueID.
function InventoryManager.addItem(player: Player, item: DataTemplate.Item)
	DataService:set(player, { "Inventory", item.UniqueID }, item)
end

-- Returns the player's full inventory table, keyed by UniqueID.
function InventoryManager.getInventory(player: Player): { [string]: DataTemplate.Item }
	return DataService:get(player, { "Inventory" })
end

return InventoryManager
