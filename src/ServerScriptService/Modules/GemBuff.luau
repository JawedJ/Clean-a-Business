--!strict

-- The purchased 10x gem boost: its tuning, and the one place anything asks "is it running, and by
-- how much does it scale gems right now?".
--
-- State is a single absolute expiry stamp in the profile (DataTemplate.GemBuffExpiresAt, os.time()
-- seconds). Absolute means it keeps counting down while the player is offline, which is what lets
-- AfkEarningsService pay the boosted rate for whatever slice of an absence the boost still covered.
--
-- This module deliberately has no dependencies beyond DataService: PlotButtonService (which scales
-- live payouts) and AfkEarningsService (which scales offline ones) both read it, and the product
-- that sells it lives in GemProductsService -- so keeping the state + constants here is what stops
-- those from having to require each other.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local GemBuff = {}

-- What the boost multiplies gem income by while it's running.
GemBuff.MULTIPLIER = 10

-- How long a single purchase adds. Purchases stack (see activate), so the total remaining can be any
-- multiple of this -- the HUD countdown grows an hours field past 59:59 rather than being capped.
GemBuff.DURATION = 3600

-- The player's boost expiry as an os.time() stamp (0 = never bought / long expired). Reads default
-- to 0 while a profile is still loading.
function GemBuff.expiresAt(player: Player): number
	local value = DataService:get(player, { "GemBuffExpiresAt" })
	return if type(value) == "number" then value else 0
end

-- Seconds of boost left, 0 once it's done.
function GemBuff.secondsRemaining(player: Player): number
	return math.max(0, GemBuff.expiresAt(player) - os.time())
end

function GemBuff.isActive(player: Player): boolean
	return GemBuff.secondsRemaining(player) > 0
end

-- What to multiply gem income by for this player right now: MULTIPLIER while boosted, else 1.
function GemBuff.getMultiplier(player: Player): number
	return if GemBuff.isActive(player) then GemBuff.MULTIPLIER else 1
end

-- Add a full DURATION of boost. Purchases STACK: buying while one is already running extends the
-- existing expiry instead of restarting it, so two buys really are two hours. We extend from the
-- later of now and the stored stamp, so an old expired stamp can't eat into the new time.
function GemBuff.activate(player: Player)
	local from = math.max(os.time(), GemBuff.expiresAt(player))
	DataService:set(player, { "GemBuffExpiresAt" }, from + GemBuff.DURATION)
end

return GemBuff
