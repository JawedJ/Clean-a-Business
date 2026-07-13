--!strict

-- Plays the purchase SFX whenever the local player completes ANY Robux purchase -- developer
-- products (e.g. the SkillsDisplay's Unlock All), game passes, or catalog assets. Wiring it here,
-- off MarketplaceService's prompt-finished signals, means every current and future purchase prompt
-- gets the same confirmation sound for free, without each caller remembering to play it. These
-- signals fire client-side only for prompts THIS player completed, and we play only on success.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

-- Same one-shot the shop/skills UIs play on a gem purchase, reused so all buying feels consistent.
local PURCHASE_SOUND = "Purchase"

local PurchaseSoundController = {}

local function onPurchased(purchased: boolean)
	if purchased then
		SoundManager.playOneShot(PURCHASE_SOUND)
	end
end

function PurchaseSoundController.init()
	-- Developer products (consumables). Fires (userId, productId, isPurchased).
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(_userId, _productId, isPurchased)
		onPurchased(isPurchased)
	end)
	-- Game passes. Fires (player, gamePassId, wasPurchased).
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_player, _gamePassId, wasPurchased)
		onPurchased(wasPurchased)
	end)
	-- Catalog assets. Fires (player, assetId, isPurchased).
	MarketplaceService.PromptPurchaseFinished:Connect(function(_player, _assetId, isPurchased)
		onPurchased(isPurchased)
	end)
end

return PurchaseSoundController
