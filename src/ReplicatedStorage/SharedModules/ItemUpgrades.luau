--!strict

-- Shared upgrade math for inventory items, used by BOTH the client (to show the upgrade cost
-- and drive the button state) and the server (to charge and apply the upgrade), so the two can
-- never disagree. Each item declares its own BASE numbers -- BaseUpgradeCost plus the per-level
-- Range/Radius steps -- but the cost CURVE is identical for every item.
--
-- Cost of the next upgrade grows geometrically from the item's BaseUpgradeCost:
--     cost(level) = floor(BaseUpgradeCost * GROWTH ^ level)
-- so the first upgrade (from level 0) costs exactly BaseUpgradeCost, and each further level
-- costs GROWTH x more. Applying an upgrade bumps Level by one and adds the item's per-level
-- Range/Radius steps to its current Range/Radius.

local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)

type Item = DataTemplate.Item

local ItemUpgrades = {}

-- Highest level an item can reach (the "Level x/MAX" cap). Single source for client + server.
ItemUpgrades.MAX_LEVEL = 10

-- How much each successive upgrade costs relative to the previous one.
local GROWTH = 2.3

-- Floor for UseTime after upgrades, so shortening it per level can never reach zero/negative.
local MIN_USE_TIME = 0.1

-- Cost to buy the NEXT upgrade for `item`, from its current Level. 0 if the item declares no
-- BaseUpgradeCost (not upgradeable). Not gated on the level cap -- use canUpgrade for that.
function ItemUpgrades.getUpgradeCost(item: Item): number
	local base = item.BaseUpgradeCost
	if not base then
		return 0
	end
	local level = item.Level or 0
	return math.floor(base * GROWTH ^ level)
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
