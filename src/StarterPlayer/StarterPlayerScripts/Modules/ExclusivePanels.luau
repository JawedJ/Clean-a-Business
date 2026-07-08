--!strict

-- Client coordinator for mutually-exclusive full-screen panels (the job board, the upgrades
-- shop, ...). At most one is open at a time: asking to open one while another is open closes
-- that other panel and opens the requested one *at the same time* -- both play their normal
-- animation together, the old one swooping out while the new one springs in. The opening panel
-- is raised above the one sliding out (see bringToFront) so it's never masked mid-animation.
--
-- If the open panel is still mid-animation (e.g. it's only just springing in) when another is
-- requested, we don't interrupt it: the swap is queued and runs the moment that animation
-- settles, so the old one plays its close as the new one springs in (a later request supersedes
-- an earlier queued one). See queueSwap.
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
	-- The frame's authored ZIndex, captured at register: the resting layer we pin panels back
	-- to so bringToFront's elevation never creeps upward across repeated switches.
	baseZIndex: number,
}

-- name -> its current Entry, replaced on each respawn's bind.
local entries: { [string]: Entry } = {}
-- The name of the panel currently open (or mid-open, while another is animating out), or nil.
local openName: string? = nil
-- A switch requested while the open panel was still mid-animation: performed the moment it
-- settles. Only the latest such request stands (a newer press supersedes it); nil when none.
local pendingName: string? = nil

-- (Re)register a panel under a stable name; call on every bind. A freshly cloned panel starts
-- hidden, so if this name was the open one that state no longer holds -- clear it.
function ExclusivePanels.register(name: string, panel: UiAnimations.Panel, beforeOpen: (() -> ())?)
	entries[name] = { panel = panel, beforeOpen = beforeOpen, baseZIndex = panel.frame.ZIndex }
	if openName == name then
		openName = nil
	end
end

-- Raise `front`'s frame above every other registered panel so, while another panel animates out
-- beneath it, the opening one is never masked. Others are first pinned back to their authored
-- ZIndex (and `front` sits one above the highest), so this never creeps upward across switches.
-- Relies on the ScreenGui's Sibling ZIndexBehavior, under which a frame's ZIndex layers its whole
-- subtree as a unit against its siblings.
local function bringToFront(front: Entry)
	local top = front.baseZIndex
	for _, entry in entries do
		entry.panel.frame.ZIndex = entry.baseZIndex
		if entry.baseZIndex > top then
			top = entry.baseZIndex
		end
	end
	front.panel.frame.ZIndex = top + 1
end

-- Perform the swap to `name`: start the close of any other open panel at the same moment so the
-- two animate together (old out, new in), layering the opener above so it's never masked. Assumes
-- any panel it has to close has already settled (queueSwap guarantees this); a no-op if `name`
-- isn't registered.
local function doOpen(name: string)
	local entry = entries[name]
	if not entry then
		return
	end

	local other = openName
	if other and other ~= name then
		local closing = entries[other]
		if closing then
			closing.panel:close()
		end
	end

	openName = name
	-- Layer above any panel now sliding out beneath us so it never masks the opening one.
	bringToFront(entry)
	if entry.beforeOpen then
		entry.beforeOpen()
	end
	entry.panel:open()
end

-- Is a swap watcher already looping? Keeps queueSwap from spawning more than one at a time.
local swapWatching = false

-- Queue a switch to `name` for when the open panel finishes its in-flight animation, then swap.
-- A single watcher loop drains the latest pendingName, so rapid presses collapse to whichever
-- panel was asked for last.
local function queueSwap(name: string)
	pendingName = name
	if swapWatching then
		return
	end
	swapWatching = true
	task.spawn(function()
		while pendingName do
			local target = pendingName
			local current = if openName then entries[openName] else nil
			if current and current.panel:isAnimating() then
				-- Don't interrupt the open panel's animation; wait it out, then swap.
				task.wait()
			else
				pendingName = nil
				doOpen(target)
			end
		end
		swapWatching = false
	end)
end

-- Open `name`, closing any other open panel at the same moment so the two animate together. If
-- that other panel is still mid-animation, the swap is queued to run the instant it settles
-- (see queueSwap) rather than interrupting it. Returns true (the request was accepted) except
-- when `name` isn't registered.
local function openExclusive(name: string): boolean
	local entry = entries[name]
	if not entry then
		return false
	end

	local other = openName
	if other and other ~= name then
		local closing = entries[other]
		if closing and closing.panel:isAnimating() then
			queueSwap(name)
			return true
		end
	end

	doOpen(name)
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
		pendingName = nil -- an explicit close cancels any swap that was queued behind this panel
		return true
	end

	return openExclusive(name)
end

-- Close `name` if it's registered (e.g. its own exit button). Clears it as the open panel, and
-- cancels any swap queued behind it -- an explicit close means the user is done with the panels.
function ExclusivePanels.close(name: string)
	local entry = entries[name]
	if entry then
		entry.panel:close()
	end
	if openName == name then
		openName = nil
		pendingName = nil
	end
end

-- `name` was hidden without animation (e.g. a job started, snapping it away): drop it as the
-- open panel so the coordinator's state stays in sync, and cancel any queued swap so a panel
-- doesn't pop up after the forced hide.
function ExclusivePanels.markHidden(name: string)
	if openName == name then
		openName = nil
		pendingName = nil
	end
end

return ExclusivePanels
