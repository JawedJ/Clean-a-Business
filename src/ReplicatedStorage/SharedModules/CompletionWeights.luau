--!strict

-- Shared job-completion weighting, used by BOTH the client bar (JobClient.getCompletion) and
-- the server payout (JobServer.getCompletion) so the two can never disagree on how much of a
-- job a given mix of cleanables represents.
--
-- A job can have up to three kinds of cleanable: walls, stains (decals) and spills. Each kind
-- present contributes its own 0..1 "how done is this kind" share, weighted by how much of the
-- bar that kind owns:
--   * spills own the business's SpillWeight (default DefaultSpillWeight) when present,
--   * decals own its DecalWeight (default DefaultDecalWeight) when present,
--   * walls own whatever is left.
-- Weights for ABSENT kinds are zeroed and the remaining weights are renormalised to sum to 1,
-- so the bar always reaches 1 when everything is cleaned no matter which kinds a business has.
--
-- Backward compatible: with no spills this reduces EXACTLY to the previous walls/decals split
-- (spillWeight = 0 -> walls get 1 - decalWeight, decals get decalWeight), so existing businesses
-- are unaffected.

local CompletionWeights = {}

export type Shares = {
	hasWalls: boolean,
	hasDecals: boolean,
	hasSpills: boolean,
	-- 0..1 fraction of each kind cleaned (ignored when that kind is absent).
	wallShare: number,
	decalShare: number,
	spillShare: number,
	-- Per-business tuning; the caller resolves the defaults before calling.
	decalWeight: number,
	spillWeight: number,
}

-- Combine per-kind shares into a single 0..1 completion fraction.
function CompletionWeights.combine(s: Shares): number
	-- Only levy a kind's weight when that kind is actually present, so a business without
	-- decals/spills doesn't reserve bar space that can never fill.
	local decalW = if s.hasDecals then s.decalWeight else 0
	local spillW = if s.hasSpills then s.spillWeight else 0
	local wallW = if s.hasWalls then math.max(1 - decalW - spillW, 0) else 0

	local total = wallW + decalW + spillW
	if total <= 0 then
		return 0
	end

	local sum = s.wallShare * wallW + s.decalShare * decalW + s.spillShare * spillW
	return sum / total
end

return CompletionWeights
