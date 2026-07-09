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
-- Every star adds a flat BOOST of the BASE XP reward: the multiplier is 1 + BOOST*stars, so the
-- boost grows 5% per star (star 1 -> +5%, star 2 -> +10%, ... star 5 -> +25%).

local Mastery = {}

-- Most stars a business can reach.
Mastery.MAX_STARS = 5
-- Extra completions each successive tier asks for over the previous one (tier N wants STEP*N).
Mastery.STEP = 5
-- Fractional XP boost each star adds to the reward, relative to base (0.05 = +5% per star).
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

-- XP multiplier applied to the reward at a given star count: 1 + BOOST*stars (flat 5% of base
-- per star). 0 stars -> 1.0 (no change), 1 -> 1.05, 2 -> 1.10, ... 5 -> 1.25.
function Mastery.xpMultiplier(stars: number): number
	return 1 + Mastery.BOOST * stars
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

-- The TOTAL XP boost (in whole-percent units) the player will have once the NEXT star is earned:
-- BOOST*(stars+1) as a percent of the base reward. 0 stars -> 5, 1 -> 10, 2 -> 15, ... This is
-- the cumulative figure the requirement label shows ("the 2nd star gives +10% EXP"), not the
-- per-star increment. Returned as a number so callers format it; nil once MAX_STARS is reached.
function Mastery.nextTotalBoostPercent(stars: number): number?
	if stars >= Mastery.MAX_STARS then
		return nil
	end
	return Mastery.BOOST * (stars + 1) * 100
end

return Mastery
