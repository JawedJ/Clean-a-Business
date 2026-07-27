--!strict

-- The game's single MarketplaceService.ProcessReceipt owner. Only one ProcessReceipt callback can
-- exist per game, so every developer-product grant routes through here instead of each service
-- claiming the callback for itself (which would silently clobber the others).
--
-- A service delivers its product by registering a handler keyed on the product id:
--
--     PurchaseService.register(SOME_PRODUCT_ID, function(player)
--         grantTheThing(player)
--         return true -- granted; return false to have Roblox retry the receipt later
--     end)
--
-- The handler runs only after the buyer's data is loaded (this waits on it), and inside a pcall,
-- so a service handler never has to repeat that boilerplate. It should be idempotent: a receipt can
-- be re-delivered (e.g. the server restarted before it was acknowledged), and returning true again
-- must not double-grant.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local PurchaseService = {}

-- productId -> grant handler. Returns true when the product was delivered (receipt acknowledged),
-- false to leave it unprocessed so Roblox retries. May yield.
local handlers: { [number]: (player: Player) -> boolean } = {}

-- Register the grant handler for `productId`. Errors on a duplicate so two services can't silently
-- fight over the same product.
function PurchaseService.register(productId: number, handler: (player: Player) -> boolean)
	assert(handlers[productId] == nil, "PurchaseService handler already registered for product " .. tostring(productId))
	handlers[productId] = handler
end

-- The one receipt callback. Resolves the buyer and their registered handler, runs it once their
-- data is loaded, and acknowledges the receipt only if it granted cleanly. An unknown product or a
-- buyer who has left is left unprocessed so Roblox re-delivers later.
local function processReceipt(receiptInfo: { PlayerId: number, ProductId: number }): Enum.ProductPurchaseDecision
	local handler = handlers[receiptInfo.ProductId]
	if not handler then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Buyer left before we could grant; Roblox re-delivers when they're next in-game.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local ok, granted = pcall(function()
		DataService:waitForData(player)
		return handler(player)
	end)

	return if ok and granted
		then Enum.ProductPurchaseDecision.PurchaseGranted
		else Enum.ProductPurchaseDecision.NotProcessedYet
end

function PurchaseService.init()
	MarketplaceService.ProcessReceipt = processReceipt
end

return PurchaseService
