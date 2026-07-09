--!strict

-- Job mastery rules, shared by the server (which applies the XP boost when a job is paid out)
-- and the client (which draws the stars / requirement text on each job-board row). Kept here so
-- the payout and the display can never drift apart.
--
-- A business earns one mastery star per milestone, up to MAX_STARS. Each milestone asks for
-- STEP more completions than the last WITHIN ITS OWN TIER: tier 1 wants 5, tier 2 wants 10,
-- tier 3 wants 15, ... So the CUMULATIVE completions to have N stars are 5, 15, 30, 50, 75. The
-- board shows progress relative to the current tier (it "resets" to 0 after each star), but the
-- underlying Completions count is never reset -- we just subtract the previous tiers.
--
-- Every star compounds a BOOST onto the business's XP reward: the multiplier is (1 + BOOST)^stars,
-- so star 2 adds 5% of the already-boosted 105% (an extra 5.25%), not a flat 5% of the base.

local Mastery = {}

-- Most stars a business can reach.
Mastery.MAX_STARS = 5
-- Extra completions each successive tier asks for over the previous one (tier N wants STEP*N).
Mastery.STEP = 5
-- Fractional XP boost each star compounds onto the reward (0.05 = +5% per star).
Mastery.BOOST = 0.05

-- Cumulative completions needed to have reached exactly `stars` stars (0 -> 0, 1 -> 5, 2 -> 15,
-- 3 -> 30, 4 -> 50, 5 -> 75). Sum of STEP*1 + STEP*2 + ... + STEP*stars.
function Mastery.cumulativeFor(stars: number): number
	local total = 0
	for tier = 1, stars do
		total += Mastery.STEP * tier
	end
	return total
end

-- Stars earned for a given lifetime Completions count, clamped to [0, MAX_STARS].
function Mastery.starsForCompletions(completions: number): number
	local stars = 0
	while stars < Mastery.MAX_STARS and completions >= Mastery.cumulativeFor(stars + 1) do
		stars += 1
	end
	return stars
end

-- Compounding XP multiplier applied to the reward at a given star count: (1 + BOOST)^stars.
-- 0 stars -> 1.0 (no change), 1 -> 1.05, 2 -> 1.1025, ...
function Mastery.xpMultiplier(stars: number): number
	return (1 + Mastery.BOOST) ^ stars
end

-- Completions the NEXT tier asks for (STEP*(stars+1)); also the denominator the board shows.
function Mastery.nextTierRequirement(stars: number): number
	return Mastery.STEP * (stars + 1)
end

-- How far into the current tier the player is: completions past the previous star's cumulative
-- total. Always in [0, nextTierRequirement) since reaching the requirement bumps `stars`.
function Mastery.tierProgress(completions: number, stars: number): number
	return completions - Mastery.cumulativeFor(stars)
end

-- The EXTRA XP boost (in whole-percent units) the next star unlocks: the difference between the
-- multiplier at stars+1 and at stars, as a percent of the base reward. 0 stars -> 5, 1 -> 5.25,
-- 2 -> 5.5125, ... (each is 5% of the previous tier's already-boosted total). Returned as a
-- number so callers format it; nil once MAX_STARS is reached (no further star to unlock).
function Mastery.nextBoostPercent(stars: number): number?
	if stars >= Mastery.MAX_STARS then
		return nil
	end
	return (Mastery.xpMultiplier(stars + 1) - Mastery.xpMultiplier(stars)) * 100
end

return Mastery
