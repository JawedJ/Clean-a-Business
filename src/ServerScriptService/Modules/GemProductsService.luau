--!strict

-- The two Robux products on the Company UI's bottom row, both delivered through PurchaseService's
-- single receipt dispatcher:
--
--   * CLAIM_PRODUCT_ID (ClaimCard) -- instantly pays a full day of OFFLINE-rate earnings: the
--     plot's current gems/sec, divided by CleaningConfig.OfflineRateDivisor, times
--     CleaningConfig.ClaimEarningsSeconds. Exactly the sum the card quotes, computed here from the
--     live plot rather than from anything the client sends.
--
--   * BOOST_PRODUCT_ID (PurchaseCard) -- adds GemBuff.DURATION of the 10x gem boost, stacking onto
--     any time already left. The boost itself lives in GemBuff; this only sells it.
--
-- The claim deliberately quotes the UNBOOSTED rate. GemsPerSecond (what the card reads) is the
-- plot's base output, so a player can't buy the boost and then buy a 10x-inflated day of earnings
-- for the same fixed price.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).server

local GemBuff = require(script.Parent.GemBuff)
local PlotButtonService = require(script.Parent.PlotButtonService)
local PurchaseService = require(script.Parent.PurchaseService)
local SkillsService = require(script.Parent.SkillsService)

-- Dev products: the ClaimCard's "24-Hour Earnings" button and the PurchaseCard's 10x boost button.
local CLAIM_PRODUCT_ID = 3611875543
local BOOST_PRODUCT_ID = 3611875531

local GemProductsService = {}

-- The player's base (unboosted) gems/sec, Hoarding included -- the same figure AfkEarningsService
-- snapshots at leave, and what the Company UI's EarningsCard shows.
local function getBaseRate(player: Player): number
	return PlotButtonService.getGemsPerSecond(player) * SkillsService.getMultiplier(player, "Hoarding")
end

-- What a 24-hour claim is worth right now: a day at the reduced offline rate. Shared with the
-- client only in formula, never in value -- the client renders its own copy of this for the label
-- and the server recomputes it here at purchase time.
function GemProductsService.getClaimAmount(player: Player): number
	return math.floor(getBaseRate(player) / Config.OfflineRateDivisor * Config.ClaimEarningsSeconds)
end

-- Credit gems directly. Hoarding is already folded into the rate (see getBaseRate), so this doesn't
-- route through ProgressionService.awardGems, which would apply it a second time -- the same reason
-- AfkEarningsService grants its offline payout directly.
local function grantGems(player: Player, gems: number)
	if gems <= 0 then
		return
	end
	DataService:update(player, { "Gems" }, function(current: number?)
		return (current or 0) + gems
	end)
end

function GemProductsService.init()
	PurchaseService.register(CLAIM_PRODUCT_ID, function(player)
		grantGems(player, GemProductsService.getClaimAmount(player))
		return true
	end)

	PurchaseService.register(BOOST_PRODUCT_ID, function(player)
		GemBuff.activate(player)
		return true
	end)
end

return GemProductsService
