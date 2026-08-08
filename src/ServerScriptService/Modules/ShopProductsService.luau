--!strict

-- Server authority for the Robux store (PlayerGui.ScreenGui.ShopUI, driven by the client's
-- ShopUiController). Delivers every offer in the shared ShopProducts catalog:
--
--   * Cash / gem packs -- credited RAW, straight to the balance. Deliberately not routed through
--     ProgressionService: a paid 100k pack must pay exactly 100k, not 100k inflated by the buyer's
--     Greed/Hoarding skill or by the store's own 2x multiplier (which they may also have bought).
--     Same reasoning as GemProductsService's claim.
--   * 2x Cash / 2x Gems -- a PERMANENT multiplier written to the profile (ShopPerks), applied by
--     ProgressionService to every later award.
--   * Speed -- a PERMANENT +studs/sec walk-speed bonus (ShopPerks), applied by SkillsService
--     free-roam and by JobServer on the job, and reasserted here at once so it takes effect
--     without waiting for a respawn.
--   * Starter pack -- unlocks every tool in ToolConfig and maxes each one's upgrade level.
--
-- TWO DELIVERY PATHS
--
-- DEV PRODUCTS (the currency packs and the speed perk) arrive as receipts through PurchaseService's
-- single dispatcher. Several offers share a product id (see ShopProducts), so the id alone can't
-- say what to grant: the client fires the frame name it clicked over the ShopIntent remote just
-- before prompting, we remember that per product id, and the receipt grants it. An intent recorded
-- for one product never shadows another's, so prompting two different offers in a row can't cross
-- their grants. The intent is cleared once granted, so a re-delivered receipt (server restarted
-- before it was acknowledged) finds none -- and falls back to ShopProducts.DevProductFallbacks for
-- that product rather than swallowing the purchase.
--
-- GAMEPASSES (the 2x multipliers and the starter pack) have no receipt: they're owned, permanently,
-- and the grant has to be re-derived from that ownership rather than from a one-off event. So they
-- are delivered TWICE over, from both directions:
--   * PromptGamePassPurchaseFinished -- the moment the player buys one, so the perk lands at once.
--   * a join sweep (UserOwnsGamePassAsync per pass) -- which also covers a pass bought on the
--     website, one bought while the server was down, and simply every session after the first.
-- The join sweep is what makes ownership and perks impossible to drift apart, and it only works
-- because every grant is idempotent (ShopPerks writes "at least this much"; the starter pack skips
-- a tool that's already unlocked and maxed). A gamepass grants the UNION of every offer sold on it
-- -- see the note in ShopProducts on why an intent can't be used here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local DataTemplate = require(ReplicatedStorage.SharedModules.DataTemplate)
local ItemUpgrades = require(ReplicatedStorage.SharedModules.ItemUpgrades)
local ShopProducts = require(ReplicatedStorage.SharedModules.ShopProducts)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)

local InventoryManager = require(script.Parent.InventoryManager)
local PurchaseService = require(script.Parent.PurchaseService)
local ShopPerks = require(script.Parent.ShopPerks)
local SkillsService = require(script.Parent.SkillsService)
local TutorialService = require(script.Parent.TutorialService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShopIntent = Remotes:WaitForChild("ShopIntent") :: RemoteEvent

local ShopProductsService = {}

-- Which offer each player last reached for, keyed by product id so two offers sharing an id are
-- the only ones that can overwrite each other. Cleared on grant and when the player leaves -- an
-- intent belongs to a single session's prompt.
local pendingIntents: { [Player]: { [number]: string } } = {}

-- Credit a currency directly, bypassing ProgressionService's skill multipliers (see the header).
local function credit(player: Player, field: string, amount: number)
	if amount <= 0 then
		return
	end
	DataService:update(player, { field }, function(current: number?)
		return (current or 0) + amount
	end)
end

-- Unlock every catalog tool and take each to ItemUpgrades.MAX_LEVEL, applying the per-level
-- Range/Radius/UseTime/Power steps one level at a time so a maxed bought tool is identical to one
-- levelled up by hand. Starts from the player's own copy when they have one, so a partly-upgraded
-- tool is topped up rather than reset.
--
-- Idempotent, and cheaply so: a tool that's already unlocked and already maxed is skipped without
-- a write at all. That matters because this runs on EVERY join of a pass owner (see the header) --
-- it must not churn out four inventory writes, and the replication they'd cause, for no change.
local function grantStarterPack(player: Player)
	local inventory = DataService:get(player, { "Inventory" })
	local owned = if type(inventory) == "table" then inventory else {}

	for uniqueId, def in ToolConfig do
		local existing = owned[uniqueId]
		if type(existing) == "table" and existing.Unlocked == true and not ItemUpgrades.canUpgrade(existing) then
			continue -- already unlocked and maxed; nothing this pass can add
		end
		-- Their own copy carries the level and levelled-up stats they've already paid for; the
		-- catalog entry is the starting point for a tool they've never owned.
		local item: DataTemplate.Item = if type(existing) == "table"
			then table.clone(existing)
			else table.clone(def)
		item.Unlocked = true
		-- Leave Equipped alone for a tool they already had; a newly granted one starts unequipped.
		item.Equipped = type(existing) == "table" and existing.Equipped == true
		while ItemUpgrades.canUpgrade(item) do
			item = ItemUpgrades.applyUpgrade(item)
		end
		-- ToolService grants the physical Tool off the resulting Inventory change.
		InventoryManager.addItem(player, item)
		-- Buying the broom is what ends the tutorial's last interactive step; a no-op for the
		-- others (and for a player not in the tutorial).
		TutorialService.notifyToolPurchased(player, uniqueId)
	end
end

-- Hand over one offer. Every branch is safe to run twice except the flat currency packs (see the
-- header on re-delivered receipts).
local function grantOffer(player: Player, offer: ShopProducts.Offer)
	if offer.cash then
		credit(player, "Cash", offer.cash)
	end
	if offer.gems then
		credit(player, "Gems", offer.gems)
	end
	if offer.cashMultiplier then
		ShopPerks.grantCashMultiplier(player, offer.cashMultiplier)
	end
	if offer.gemMultiplier then
		ShopPerks.grantGemMultiplier(player, offer.gemMultiplier)
	end
	if offer.speedBonus then
		ShopPerks.grantSpeedBonus(player, offer.speedBonus)
		-- Take effect now rather than on the next respawn. Mid-job this still lands: the write
		-- re-fires JobServer's pinned-speed guard, which recomputes its own target off the same
		-- bonus.
		SkillsService.refreshWalkSpeed(player)
	end
	if offer.starterPack then
		grantStarterPack(player)
	end
end

-- Remember which offer `player` is about to be prompted for. Validated against the catalog (a
-- client can name any string) and stored under the offer's OWN product id, so a forged frame name
-- can only ever redirect a purchase of the product that frame actually sells. Offers granted
-- elsewhere -- the skills pack, which is SkillsService's product -- record nothing; there's no
-- handler here to read it.
local function onIntent(player: Player, frameName: unknown)
	if type(frameName) ~= "string" then
		return
	end
	local offer = ShopProducts.get(frameName)
	if not offer or not ShopProducts.DevProductFallbacks[offer.productId] then
		return
	end
	local intents = pendingIntents[player] or {}
	pendingIntents[player] = intents
	intents[offer.productId] = frameName
end

-- Deliver a paid-for product: grant whatever the buyer last reached for on this product id, or the
-- product's fallback offer if no intent survived (see the header). Always acknowledges the receipt
-- -- a purchase that reached here was paid for, and leaving it unprocessed would retry it forever.
local function onReceipt(player: Player, productId: number): boolean
	local intents = pendingIntents[player]
	local frameName = if intents then intents[productId] else nil
	if intents then
		intents[productId] = nil
	end

	local offer = ShopProducts.get(frameName or ShopProducts.DevProductFallbacks[productId] or "")
	if offer and offer.productId == productId then
		grantOffer(player, offer)
	end
	return true
end

-- Hand over everything a gamepass is worth: every offer sold on it, since ownership is a single
-- permanent boolean that can't distinguish them (see ShopProducts). Safe to run repeatedly -- which
-- is the whole point, as both the purchase hook and every join call it.
local function grantPass(player: Player, passId: number)
	for _, offer in ShopProducts.offersFor(passId) do
		grantOffer(player, offer)
	end
end

-- Bring `player`'s perks in line with the gamepasses they actually own. Run on every join, so a
-- pass bought on the website, bought while the server was down, or simply bought in an earlier
-- session all land the same way. Yields (a web call per pass, plus the profile), so callers spawn it.
--
-- A failed ownership check is warned and SKIPPED rather than treated as "doesn't own it": the
-- alternative -- revoking on a network blip -- would be far worse, and the next join retries anyway.
local function applyOwnedPasses(player: Player)
	DataService:waitForData(player)
	for passId in ShopProducts.GamePasses do
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if not ok then
			warn(string.format("[ShopProductsService] gamepass %d ownership check failed for %s: %s", passId, player.Name, tostring(owns)))
		elseif owns and player.Parent then
			grantPass(player, passId)
		end
	end
end

function ShopProductsService.init()
	ShopIntent.OnServerEvent:Connect(onIntent)

	-- One receipt handler per DEV PRODUCT this service owns. DevProductFallbacks is that list: the
	-- skills pack's product is absent because SkillsService already registers it (only one handler
	-- per product is allowed), and the gamepasses are absent because they have no receipts at all.
	for productId in ShopProducts.DevProductFallbacks do
		PurchaseService.register(productId, function(player)
			return onReceipt(player, productId)
		end)
	end

	-- A gamepass bought in-game, granted the moment it completes so the perk doesn't wait for a
	-- rejoin. Ownership is authoritative here (Roblox tells us it was purchased), so there's no
	-- ownership call to make. Passes we don't sell are ignored.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
		if wasPurchased and ShopProducts.GamePasses[passId] then
			grantPass(player, passId)
		end
	end)

	-- The other half: reconcile owned passes on every join. Spawned so the ownership web calls never
	-- block PlayerAdded, and run for players already in (this service inits during startup).
	local function sweep(player: Player)
		task.spawn(applyOwnedPasses, player)
	end
	Players.PlayerAdded:Connect(sweep)
	for _, player in Players:GetPlayers() do
		sweep(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		pendingIntents[player] = nil
	end)
end

return ShopProductsService
