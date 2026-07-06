--!strict

-- Warms the HUD's image assets during the load window so nothing appears blurry the first
-- time it's shown. Roblox only downloads/decodes an ImageLabel or ImageButton's texture when
-- the GUI first renders, so any frame that starts hidden -- JobCompletion, the inventory, the
-- highlight button, the job summary, ... -- pops in low-res and then sharpens a moment later.
-- Forcing the decode ahead of time removes that first-show blur.
--
-- Cost is kept off the player's back two ways:
--   * It runs in a background task, so it never blocks client startup or gameplay -- the work
--     overlaps the join/load screen when the player isn't doing anything yet.
--   * It preloads the StarterGui TEMPLATES (what gets cloned into every PlayerGui, and
--     re-cloned on each respawn), and ContentProvider caches by asset. So each texture is
--     decoded exactly once for the whole session; the per-spawn HUD clones reuse the cache and
--     there is no repeated work.

local StarterGui = game:GetService("StarterGui")
local ContentProvider = game:GetService("ContentProvider")

local UiPreloader = {}

function UiPreloader.init()
	-- Off the main path: PreloadAsync yields while it downloads + decodes, and it already
	-- spaces the per-asset decode out on its own, so a slow or missing asset can't stall
	-- startup. pcall so one bad asset id doesn't abort the rest.
	task.spawn(function()
		pcall(function()
			-- GetDescendants covers every frame/button under StarterGui; PreloadAsync just
			-- skips the non-asset instances (layouts, corners, scripts).
			ContentProvider:PreloadAsync(StarterGui:GetDescendants())
		end)
	end)
end

return UiPreloader
