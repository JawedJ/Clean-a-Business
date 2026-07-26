--!strict

-- The per-job star rating (1..5), shared by the client (which draws it on the JobSummary screen)
-- and the server (which records it into the player's running Ratings tally when a job ends), so
-- the shown rating and the persisted one can never drift apart -- the same rule the Mastery module
-- follows for its stars.
--
-- A job's rating is one star per 20% of the job cleaned, clamped to 1..5: a full completion
-- (fraction = 1) is always 5 stars, a bail at 0% is still 1 (there's always a rating to show).

local JobRating = {}

-- Stars for a 0..1 completion fraction. The tiny epsilon keeps an exact 1.0 from floating just
-- under 5 (floor(0.9999995 * 5) would give 4).
function JobRating.starsFor(fraction: number): number
	return math.clamp(math.floor(fraction * 5 + 1e-6), 1, 5)
end

return JobRating
