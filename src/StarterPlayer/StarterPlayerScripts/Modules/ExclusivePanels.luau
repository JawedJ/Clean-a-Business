--!strict

-- Client coordinator for mutually-exclusive full-screen panels (the job board, the upgrades
-- shop, ...). At most one is open at a time: asking to open one while another is open closes
-- that other panel and opens the requested one *at the same time* -- both play their normal
-- animation together, the old one swooping out while the new one springs in. The opening panel
-- is raised above the one sliding out (see bringToFront) so it's never masked mid-animation.
--
-- If the open panel is still mid-animation (e.g. it's only just springing in) when another
-- open or close is requested, we don't interrupt it: the action is queued and runs the moment
-- that animation settles, so the old one plays its close as the new one springs in. This covers
-- closes too -- a panel asked to close before its own open finished (e.g. walking out of a
-- proximity hitbox mid-open) still closes the instant that open settles, rather than the request
-- being dropped. Up to MAX_PENDING actions can be queued, run in request order; the latest
-- request for a given panel supersedes any earlier queued one for it (a walk out then back in
-- collapses to just the final state). See queueAction.
--
-- Two things can override all of this. A modal can lock opening outright (setLocked -- the
-- AfkEarnings claim screen), and the tutorial can narrow opening to a single panel and pin that
-- panel open so it refuses to close; both are read through TutorialState, and both leave the forced
-- hide path (a panel's own hideInstant + markHidden, used when a job starts) working regardless.
--
-- Each panel registers under a stable name on every bind (HUD ScreenGuis are re-cloned each
-- respawn, so the UiAnimations.Panel is rebuilt and must be re-registered). All open/close goes
-- through here rather than calling Panel:open()/:close() directly, so this stays the single
-- place that knows which panel is up.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local TutorialState = require(script.Parent.TutorialState)

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
-- Actions requested while an animation was in flight, run in this (request) order as each
-- in-flight animation settles: each opens or closes a panel. Both opens and closes queue here,
-- so a close asked for mid-open-animation (e.g. walking out of a proximity hitbox before the
-- board finished opening) still fires the instant that open settles, instead of being dropped.
-- Capped at MAX_PENDING so a mash of requests can't stack up an endless run.
type PendingAction = { name: string, close: boolean }
local pendingQueue: { PendingAction } = {}
local MAX_PENDING = 2

-- When true, every request to OPEN a panel is refused (closes still work). Set by a modal that must
-- block all other UI while it's up -- currently the AfkEarnings claim screen, which has no exit
-- button and must be dealt with before anything else can open.
local locked = false

-- Lock or unlock opening. While locked, open/toggle are no-ops so no panel can be brought up; the
-- modal that locked it is responsible for unlocking when it closes.
function ExclusivePanels.setLocked(value: boolean)
	locked = value
end

-- Whether `name` may be opened right now: the AfkEarnings modal blocks everything, and the tutorial
-- narrows opening to the one panel its current step calls for (both default to "no restriction", so
-- outside those two states this is always true). Deliberately kept SEPARATE from `locked` rather
-- than folded into it -- they're owned by different systems and either may be in force alone, so
-- one shared flag would let whichever released first unlock the other's UI.
local function canOpen(name: string): boolean
	return not locked and TutorialState.isOpenAllowed(name)
end

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
-- any panel it has to close has already settled (the queue guarantees this); a no-op if `name`
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

-- Close `name` now: play its close animation and drop it as the open panel. Assumes it has
-- already settled (the queue guarantees this); a no-op if `name` isn't registered.
local function doClose(name: string)
	local entry = entries[name]
	if entry then
		entry.panel:close()
	end
	if openName == name then
		openName = nil
	end
end

-- Is a drain loop already running? Keeps queueAction from spawning more than one at a time.
local swapWatching = false

-- Queue an open (close=false) or close (close=true) of `name` for when the in-flight animation
-- settles, then drain the queue in order (one action per settle). The latest request for a panel
-- supersedes any earlier queued one for it -- so a walk out then back in collapses to just the
-- final open/close rather than replaying both. Returns false -- the request is dropped -- when
-- the queue is already full. A single watcher loop drains the queue, so at most one runs at a time.
local function queueAction(name: string, close: boolean): boolean
	-- Drop any earlier queued action for this same panel; the newest intent wins.
	for i = #pendingQueue, 1, -1 do
		if pendingQueue[i].name == name then
			table.remove(pendingQueue, i)
		end
	end
	if #pendingQueue >= MAX_PENDING then
		return false
	end
	table.insert(pendingQueue, { name = name, close = close })
	if swapWatching then
		return true
	end
	swapWatching = true
	task.spawn(function()
		while #pendingQueue > 0 do
			local current = if openName then entries[openName] else nil
			-- The next action's OWN panel must be settled too: doOpen/doClose call
			-- panel:open()/close(), which silently no-op while that panel is mid-animation. If we
			-- only waited on the currently-open panel, a re-open of a panel still playing its close
			-- (walk out then back in) would fire a no-op open, leaving openName set but the frame
			-- hidden -- a stuck panel that never reopens. So wait on both.
			local nextEntry = entries[pendingQueue[1].name]
			if (current and current.panel:isAnimating()) or (nextEntry and nextEntry.panel:isAnimating()) then
				-- Don't interrupt the in-flight animation; wait it out, then act.
				task.wait()
			else
				local action = table.remove(pendingQueue, 1)
				if action then
					if action.close then
						doClose(action.name)
					else
						doOpen(action.name)
					end
				end
			end
		end
		swapWatching = false
	end)
	return true
end

-- Open `name`, closing any other open panel at the same moment so the two animate together. If
-- that other panel is still mid-animation, the open is queued to run the instant it settles
-- (see queueAction) rather than interrupting it. Returns true when the request was accepted; false
-- if `name` isn't registered or the queue is full.
local function openExclusive(name: string): boolean
	if not canOpen(name) then
		return false
	end
	local entry = entries[name]
	if not entry then
		return false
	end

	local other = openName
	if other and other ~= name then
		local closing = entries[other]
		if closing and closing.panel:isAnimating() then
			return queueAction(name, false)
		end
	end

	doOpen(name)
	return true
end

-- Open `name` (closing any other open panel), without the toggle-closed behaviour: if it's
-- already the settled open one this is a no-op rather than closing it. Used by non-toggle
-- triggers (e.g. walking into a warehouse board's proximity hitbox). If this panel (or the
-- currently-open one) is mid-animation the open is queued to run once things settle, superseding
-- any close queued for this panel -- so walking back into a hitbox before the close fired keeps
-- the panel open. Returns true if the request was accepted; false if `name` isn't registered or
-- the queue is full.
function ExclusivePanels.open(name: string): boolean
	if not canOpen(name) then
		return false
	end
	local entry = entries[name]
	if not entry then
		return false
	end
	-- Already open and settled: nothing to do (don't re-trigger its open animation).
	if openName == name and not entry.panel:isAnimating() then
		return false
	end
	local current = if openName then entries[openName] else nil
	if entry.panel:isAnimating() or (current and current.panel:isAnimating()) then
		return queueAction(name, false)
	end
	return openExclusive(name)
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
		-- Pinned open by the tutorial: the toggle can't close it (nor can its exit button, below).
		if TutorialState.isCloseLocked(name) then
			return false
		end
		entry.panel:close()
		openName = nil
		table.clear(pendingQueue) -- an explicit close cancels any swaps queued behind this panel
		return true
	end

	return openExclusive(name)
end

-- Close `name` if it's registered (e.g. its own exit button, or walking out of a proximity
-- hitbox). If it's mid-animation (typically asked to close before its open finished) the close
-- can't play yet, so it's queued to fire the instant the animation settles -- superseding any
-- open queued for this panel. openName is kept pointing at it meanwhile so the drain loop waits
-- on the right panel. Otherwise it closes now and cancels any actions queued behind it.
function ExclusivePanels.close(name: string)
	local entry = entries[name]
	if not entry then
		return
	end
	-- Pinned open by the tutorial: refuse every coordinator close path -- the panel's exit button,
	-- and walking back out of the board's proximity hitbox. A job starting still clears it, because
	-- that path calls the panel's hideInstant + markHidden directly rather than coming through here.
	if TutorialState.isCloseLocked(name) then
		return
	end
	if entry.panel:isAnimating() then
		queueAction(name, true)
		return
	end
	entry.panel:close()
	if openName == name then
		openName = nil
		table.clear(pendingQueue)
	end
end

-- `name` was hidden without animation (e.g. a job started, snapping it away): drop it as the
-- open panel so the coordinator's state stays in sync, and cancel any queued swaps so a panel
-- doesn't pop up after the forced hide.
function ExclusivePanels.markHidden(name: string)
	if openName == name then
		openName = nil
		table.clear(pendingQueue)
	end
end

return ExclusivePanels
