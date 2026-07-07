--!strict

-- Client coordinator for mutually-exclusive full-screen panels (the job board, the upgrades
-- shop, ...). At most one is open at a time: asking to open one while another is open closes
-- that other panel first -- playing its normal close animation -- and opens the requested one
-- only once that close settles, so the two never overlap and neither animation is interrupted.
--
-- Each panel registers under a stable name on every bind (HUD ScreenGuis are re-cloned each
-- respawn, so the UiAnimations.Panel is rebuilt and must be re-registered). All open/close goes
-- through here rather than calling Panel:open()/:close() directly, so this stays the single
-- place that knows which panel is up.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local ExclusivePanels = {}

type Entry = {
	panel: UiAnimations.Panel,
	-- Run just before the panel opens (e.g. refresh its contents). Optional.
	beforeOpen: (() -> ())?,
}

-- name -> its current Entry, replaced on each respawn's bind.
local entries: { [string]: Entry } = {}
-- The name of the panel currently open (or mid-open, while another is animating out), or nil.
local openName: string? = nil

-- (Re)register a panel under a stable name; call on every bind. A freshly cloned panel starts
-- hidden, so if this name was the open one that state no longer holds -- clear it.
function ExclusivePanels.register(name: string, panel: UiAnimations.Panel, beforeOpen: (() -> ())?)
	entries[name] = { panel = panel, beforeOpen = beforeOpen }
	if openName == name then
		openName = nil
	end
end

-- Open `name`, first closing any other open panel with its animation and opening this one once
-- that close settles. Returns false (no-op) if another panel is still animating -- matching how
-- each panel ignores its own toggle mid-animation; a settled click will work.
local function openExclusive(name: string): boolean
	local entry = entries[name]
	if not entry then
		return false
	end

	local other = openName
	if other and other ~= name then
		local closing = entries[other]
		if closing then
			-- The panel we'd have to close is mid-animation: ignore this request for now.
			if closing.panel:isAnimating() then
				return false
			end
			openName = name -- claim now so a re-entrant request sees the new target
			closing.panel:close()
			task.spawn(function()
				-- Wait out the close animation, then open -- unless a later request superseded us.
				while closing.panel:isAnimating() do
					task.wait()
				end
				if openName == name then
					if entry.beforeOpen then
						entry.beforeOpen()
					end
					entry.panel:open()
				end
			end)
			return true
		end
	end

	openName = name
	if entry.beforeOpen then
		entry.beforeOpen()
	end
	entry.panel:open()
	return true
end

-- Toggle `name`: close it if it's the open one, otherwise open it (closing any other first).
-- Returns true if it acted, false if the click was ignored (mid-animation / pending open), so
-- callers can gate side effects (e.g. a click sound) on the result.
function ExclusivePanels.toggle(name: string): boolean
	local entry = entries[name]
	if not entry then
		return false
	end
	-- Don't act while this panel is mid-animation (matches the per-panel toggle gating).
	if entry.panel:isAnimating() then
		return false
	end

	if openName == name then
		-- Claimed as current but not shown yet (waiting on another panel's close): ignore.
		if not entry.panel.frame.Visible then
			return false
		end
		entry.panel:close()
		openName = nil
		return true
	end

	return openExclusive(name)
end

-- Close `name` if it's registered (e.g. its own exit button). Clears it as the open panel.
function ExclusivePanels.close(name: string)
	local entry = entries[name]
	if entry then
		entry.panel:close()
	end
	if openName == name then
		openName = nil
	end
end

-- `name` was hidden without animation (e.g. a job started, snapping it away): drop it as the
-- open panel so the coordinator's state stays in sync.
function ExclusivePanels.markHidden(name: string)
	if openName == name then
		openName = nil
	end
end

return ExclusivePanels
