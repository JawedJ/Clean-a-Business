--!strict

-- The tutorial's client-side lock state, as plain flags with no behaviour and no dependencies.
--
-- It exists to break a require cycle. The restrictions are DECIDED by TutorialController (which
-- requires the UI controllers to read their state) but must be ENFORCED inside those same
-- controllers and the panel coordinator -- so they can't require the controller back. Instead the
-- controller writes here and the enforcers read here, and nothing has to know about anything else.
--
-- Everything defaults to unrestricted, and clear() puts it back that way, so a player who was never
-- in the tutorial (or has just finished it) is never touched by any of this.
--
-- The SERVER is the authority on all of these -- it refuses the same purchases independently (see
-- TutorialService). These flags are the client half: they stop the UI from offering an action it
-- knows the server will reject, so a locked control simply does nothing instead of firing a remote
-- and playing a success sound for a purchase that never happens.

local TutorialState = {}

-- ExclusivePanels names the tutorial currently allows to be OPENED, or nil for "no restriction".
-- An empty table is meaningful and different from nil: it locks every panel.
local openAllowed: { [string]: boolean }? = nil

-- ExclusivePanels names that currently refuse to CLOSE -- the tutorial pins a board open while the
-- step that needs it runs. Note this only covers the coordinator's close paths (exit button, the
-- toggle, walking out of a proximity hitbox); a job starting hides its panel through hideInstant,
-- which deliberately bypasses the coordinator and so still works.
local closeLocked: { [string]: boolean } = {}

-- Tool purchases: `toolRestricted` is whether the tutorial is narrowing them at all, and
-- `toolAllowed` is the single id permitted while it is. The two are separate because "only the
-- broom" and "no tool at all" are both restricted states -- a lone nullable id couldn't tell the
-- latter apart from "unrestricted", which is exactly the case that must not be confused.
local toolRestricted = false
local toolAllowed: string? = nil
-- Whether tool UPGRADES are permitted. Off for the whole tutorial -- no step asks for one.
local upgradesAllowed = true

-- Set which panels may be opened; nil removes the restriction entirely.
function TutorialState.setOpenAllowed(names: { [string]: boolean }?)
	openAllowed = names
end

function TutorialState.isOpenAllowed(name: string): boolean
	local allowed = openAllowed
	return allowed == nil or allowed[name] == true
end

-- Set which panels refuse to close. Pass nil/{} to unpin everything.
function TutorialState.setCloseLocked(names: { [string]: boolean }?)
	closeLocked = names or {}
end

function TutorialState.isCloseLocked(name: string): boolean
	return closeLocked[name] == true
end

-- Restrict tool purchases to `uniqueId` alone, or to nothing at all when it's nil. Use clear() to
-- lift the restriction entirely -- passing nil here does NOT mean "unrestricted".
function TutorialState.setToolAllowed(uniqueId: string?)
	toolRestricted = true
	toolAllowed = uniqueId
end

function TutorialState.isToolAllowed(uniqueId: string): boolean
	return not toolRestricted or toolAllowed == uniqueId
end

function TutorialState.setUpgradesAllowed(value: boolean)
	upgradesAllowed = value
end

function TutorialState.areUpgradesAllowed(): boolean
	return upgradesAllowed
end

-- Drop every restriction. Called when the tutorial ends (and on the step that lifts them early),
-- so nothing here can outlive the tutorial state.
function TutorialState.clear()
	openAllowed = nil
	closeLocked = {}
	toolRestricted = false
	toolAllowed = nil
	upgradesAllowed = true
end

return TutorialState
