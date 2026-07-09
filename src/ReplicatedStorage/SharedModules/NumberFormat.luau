--!strict

-- Shared number -> display string helpers. abbreviate() compacts large numbers
-- with lowercase suffixes: k (thousand), m (million), b (billion), t (trillion).
-- Anything below 1,000 is shown as a plain integer. One decimal place is kept, with
-- a trailing ".0" trimmed, so 1500 -> "1.5k" and 2000 -> "2k".

local NumberFormat = {}

-- Largest first; the first tier the value reaches wins. Values at or above one
-- trillion keep using "t" (e.g. 1e15 -> "1000t").
local TIERS = {
	{ value = 1e12, suffix = "t" },
	{ value = 1e9, suffix = "b" },
	{ value = 1e6, suffix = "m" },
	{ value = 1e3, suffix = "k" },
}

-- "2.0" -> "2", "1.20" -> "1.2", "1.5" -> "1.5".
local function trimZeros(s: string): string
	if string.find(s, "%.") then
		s = (string.gsub(s, "0+$", ""))
		s = (string.gsub(s, "%.$", ""))
	end
	return s
end

function NumberFormat.abbreviate(n: number): string
	local sign = if n < 0 then "-" else ""
	local abs = math.abs(n)

	for i, tier in TIERS do
		if abs >= tier.value then
			local scaled = abs / tier.value
			-- Rounding to one decimal can push a value up into the next tier (e.g.
			-- 999,999 -> "1000.0k"); when it does, carry it to the larger tier so it
			-- reads "1m" instead. The top tier has nowhere to carry, so it keeps "t".
			if math.floor(scaled * 10 + 0.5) >= 10000 and i > 1 then
				tier = TIERS[i - 1]
				scaled = abs / tier.value
			end
			return sign .. trimZeros(string.format("%.1f", scaled)) .. tier.suffix
		end
	end

	return sign .. string.format("%d", abs)
end

-- Full number with thousands separators, no abbreviation: 2500 -> "2,500", 250 -> "250".
-- Used where a label wants the exact figure (e.g. the job board's Rewards line) rather than
-- the compact "2.5k" form. Fractions are floored first.
function NumberFormat.commas(n: number): string
	local sign = if n < 0 then "-" else ""
	local out = string.format("%d", math.abs(math.floor(n)))
	-- Walk in 3-digit groups from the right, inserting a comma before each group that still has
	-- digits ahead of it, until no more can be inserted.
	while true do
		local next, count = string.gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
		out = next
		if count == 0 then
			break
		end
	end
	return sign .. out
end

return NumberFormat
