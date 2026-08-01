--!strict

-- Shared upgrade math for inventory items, used by BOTH the client (to show the upgrade cost
-- and drive the button state) and the server (to charge and apply the upgrade), so the two can
-- never disagree. Each item declares its own BASE numbers -- BaseUpgradeCost plus the per-level
-- Range/Radius steps -- but the cost CURVE is identical for every item.
--
-- THE PRICE LADDER
--
-- Every item's upgrade prices are one geometric curve, described by its two ENDPOINTS rather
-- than by a per-level multiplier:
--
--     cost(level) = basePrice * FINAL_MULTIPLE ^ (((level + 1) / MAX_LEVEL) ^ RAMP)
--
--   * basePrice -- what the ladder is measured against. A tool the player BUYS uses its purchase
--     Cost, so its upgrades are always priced relative to what it cost to own, and the first one
--     is never the same price as the purchase. A free starter tool (Cost 0) was never bought, so
--     it falls back to its own BaseUpgradeCost as a stand-in price.
--   * FINAL_MULTIPLE -- how many times the base price the LAST upgrade costs. It states the thing
--     you actually care about ("maxing the final level costs 1024x the item's price") instead of
--     a per-level rate whose end result you have to work out.
--   * RAMP -- which end of the ladder the cost is concentrated in (see below).
--
-- There is deliberately no fixed per-level multiplier: the step from one level to the next is
-- front-loaded, so the first upgrade is a real jump off the base price and later ones tighten up,
-- rather than every level costing a flat 2x. Pinning the curve to its endpoints also keeps it
-- stable -- raising MAX_LEVEL restretches the same ladder over more levels instead of multiplying
-- what maxing an item costs, which a fixed-rate curve can't do (there, 10 -> 12 levels silently
-- makes the top level 4x pricier).
--
-- Prices are then rounded to PRICE_SIGNIFICANT_DIGITS significant figures so they read like
-- prices (12,000 rather than 12,379), whatever FINAL_MULTIPLE is tuned to.
--
-- BaseUpgradeCost is also what marks an item upgradeable at all. Applying an upgrade bumps Level
-- by one and adds the item's per-level Range/Radius steps to its current Range/Radius.

local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)

type Item = DataTemplate.Item

local ItemUpgrades = {}

-- Highest level an item can reach (the "Level x/MAX" cap). Single source for client + server.
ItemUpgrades.MAX_LEVEL = 10

-- How many times an item's base price the LAST upgrade (level MAX_LEVEL - 1 -> MAX_LEVEL) costs.
-- The ladder is stretched between the base price and this, so it's the knob for how expensive
-- maxing an item is overall. 20000 puts the pressure washer's final level at ~2M (base 100), and
-- every other tool at 20000x whatever it cost to own.
local FINAL_MULTIPLE = 20000

-- Which END of the ladder the cost is concentrated in. 1 spreads FINAL_MULTIPLE evenly, i.e. a
-- CONSTANT per-level multiplier. The exponent bends either way from there:
--
--   * BELOW 1 -- front-loaded. The first upgrades are a big jump off the base price and each step
--     after that costs proportionally LESS than the one before, so the ladder eases off as it
--     climbs. At 0.5 the pressure washer goes 100 -> 2,290 (23x) -> 8,380 (3.7x), then settles
--     toward ~1.7x a level.
--   * ABOVE 1 -- back-loaded. Early upgrades are cheap and the steps get harsher toward the cap.
--
-- 0.5 is exactly a square-root curve, which is why the first step is so much steeper than the
-- rest: it's what makes an upgrade feel like a real commitment rather than pocket change.
local RAMP = 0.5

-- Prices are rounded to this many significant figures, so the ladder reads as prices a player can
-- hold in their head (1,150 / 12,400 / 124,000) instead of raw curve output (1,149 / 12,379).
-- Three rather than two: at a round FINAL_MULTIPLE the exact prices are already clean, and two
-- would coarsen them back out (512,000 -> 510,000) for no gain.
local PRICE_SIGNIFICANT_DIGITS = 3

-- Round `value` to PRICE_SIGNIFICANT_DIGITS significant figures (1,149 -> 1,100; 12,379 -> 12,000).
-- Values below the rounding scale are left alone, so a small price never rounds to 0.
local function roundToPrice(value: number): number
	if value < 10 ^ PRICE_SIGNIFICANT_DIGITS then
		return math.floor(value)
	end
	local scale = 10 ^ (math.floor(math.log(value, 10)) - (PRICE_SIGNIFICANT_DIGITS - 1))
	return math.floor(value / scale + 0.5) * scale
end

-- Floor for UseTime after upgrades, so shortening it per level can never reach zero/negative.
local MIN_USE_TIME = 0.1

-- The price an item's ladder is measured against: what the player paid for it, or its
-- BaseUpgradeCost stand-in for a free starter tool they never bought. nil when the item declares
-- no BaseUpgradeCost, which is what marks it not upgradeable.
local function basePrice(item: Item): number?
	if not item.BaseUpgradeCost then
		return nil
	end
	local purchaseCost = item.Cost
	if purchaseCost and purchaseCost > 0 then
		return purchaseCost
	end
	return item.BaseUpgradeCost
end

-- How many times its base price an item's LAST upgrade costs. An item can pin its own top price
-- with MaxUpgradeCost (the natural way to tune it -- "the vacuum should cap out around 20M"),
-- which we turn back into the multiple the curve wants; otherwise it rides the global
-- FINAL_MULTIPLE. A cap at or below the base price would inverse the ladder, so it's ignored.
local function finalMultiple(item: Item, base: number): number
	local cap = item.MaxUpgradeCost
	if cap and cap > base then
		return cap / base
	end
	return FINAL_MULTIPLE
end

-- Cost to buy the NEXT upgrade for `item`, from its current Level. 0 if the item declares no
-- BaseUpgradeCost (not upgradeable). Not gated on the level cap -- use canUpgrade for that.
function ItemUpgrades.getUpgradeCost(item: Item): number
	local base = basePrice(item)
	if not base then
		return 0
	end
	local level = item.Level or 0
	-- Position along the ladder (0..1 at the last level), bent by RAMP so the early steps are the
	-- big ones and later steps tighten up.
	local progress = ((level + 1) / ItemUpgrades.MAX_LEVEL) ^ RAMP
	return roundToPrice(base * finalMultiple(item, base) ^ progress)
end

-- Whether `item` can still be upgraded: it declares a BaseUpgradeCost and is below the cap.
function ItemUpgrades.canUpgrade(item: Item): boolean
	return item.BaseUpgradeCost ~= nil and (item.Level or 0) < ItemUpgrades.MAX_LEVEL
end

-- Return a NEW item one level higher, with its per-level Range/Radius steps applied. Pure: does
-- not mutate the input. Only steps a stat the item actually has (a broom has no Radius).
function ItemUpgrades.applyUpgrade(item: Item): Item
	local upgraded = table.clone(item)
	upgraded.Level = (item.Level or 0) + 1
	if item.UpgradeRange and item.Range then
		upgraded.Range = item.Range + item.UpgradeRange
	end
	if item.UpgradeRadius and item.Radius then
		upgraded.Radius = item.Radius + item.UpgradeRadius
	end
	if item.UpgradeUseTime and item.UseTime then
		upgraded.UseTime = math.max(MIN_USE_TIME, item.UseTime - item.UpgradeUseTime)
	end
	if item.UpgradePower and item.Power then
		upgraded.Power = item.Power + item.UpgradePower
	end
	return upgraded
end

return ItemUpgrades
