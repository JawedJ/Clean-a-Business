--!strict

-- The white hover outline shared by every cleanable the player aims at (garbage, stains, spills,
-- webs). Walls are deliberately excluded -- they're EditableImage overlays painted onto the
-- building's own geometry, so an outline would trace the whole wall rather than the dirt.
--
-- The look is the garbage carry outline, kept here so all four cleanables read identically. It is
-- OCCLUDED: geometry in front of the target hides the outline, exactly as it hides the target. The
-- alternative (AlwaysOnTop) draws it over everything, which is stronger on pale or busy geometry but
-- means an outline hanging in the air through a wall -- and a highlight that ignores walls reads as
-- a bug, not as emphasis. If it turns out too faint on light-coloured pieces, lower
-- HIGHLIGHT_FILL_TRANSPARENCY or pick a colour with more contrast rather than going back on top.
--
-- Callers still owe a visibility check when they pick a target WITHOUT a ray: the aim hovers get one
-- for free (a raycast can't reach through a wall), and garbage's proximity hover
-- (GarbageCarryController.findNearest) tests it explicitly. Occlusion only hides such an outline --
-- the piece would still be the thing a pickup targets.
--
-- One Highlight per owner, created once and re-adorned: Highlight instances are relatively expensive
-- to build, and only one tool is ever equipped at a time so at most one is enabled.
--
-- THE PLAYERGUI IS WIPED ON EVERY CHARACTER ADD, AND TAKES THE OUTLINE WITH IT. That includes
-- respawns and -- the reason this matters now -- being swapped into the job rig at the start of
-- every job (JobRigService assigns Player.Character, which the engine treats as a spawn). A
-- ScreenGui opts out of the wipe with ResetOnSpawn = false; a Highlight has no such property, so it
-- simply goes. The symptom is silent and total: the owner carries on setting Adornee and Enabled on
-- an instance that is no longer in the DataModel, so every outline stops appearing for the rest of
-- the session with nothing logged. Hence ensure() below -- checked before every set, rebuilt when
-- the outline has lost its parent, and re-adorned to whatever it was showing.

local Players = game:GetService("Players")

local HIGHLIGHT_COLOR = Color3.fromRGB(255, 255, 255)
local HIGHLIGHT_FILL_TRANSPARENCY = 0.2
local HIGHLIGHT_DEPTH_MODE = Enum.HighlightDepthMode.Occluded

local localPlayer = Players.LocalPlayer

local HoverHighlight = {}
HoverHighlight.__index = HoverHighlight

export type HoverHighlight = typeof(setmetatable(
	{} :: {
		name: string,
		highlight: Highlight,
		current: Instance?,
	},
	HoverHighlight
))

-- Build the Highlight instance itself. Separate from new() because a wiped outline is rebuilt
-- through here too -- see ensure().
local function build(name: string): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = name
	highlight.FillColor = HIGHLIGHT_COLOR
	highlight.OutlineColor = HIGHLIGHT_COLOR
	highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY
	highlight.OutlineTransparency = 0
	highlight.DepthMode = HIGHLIGHT_DEPTH_MODE
	highlight.Enabled = false
	highlight.Parent = localPlayer:WaitForChild("PlayerGui")
	return highlight
end

-- Build one reusable outline. `name` only shows up in the explorer, to tell the tools' outlines
-- apart while debugging.
function HoverHighlight.new(name: string): HoverHighlight
	return setmetatable({
		name = name,
		highlight = build(name),
		current = nil,
	}, HoverHighlight)
end

-- Replace the outline if it has been wiped out from under us (see the header). Cheap enough to ask
-- every frame -- it's one property read until the day it isn't. The rebuild re-adorns whatever we
-- were showing, so a wipe mid-hover doesn't need the caller to change its target to recover.
function HoverHighlight.ensure(self: HoverHighlight)
	if self.highlight.Parent then
		return
	end
	self.highlight:Destroy()
	self.highlight = build(self.name)
	if self.current then
		self.highlight.Adornee = self.current
		self.highlight.Enabled = true
	end
end

-- Outline `target`, or clear the outline when nil. Re-setting the same target is a no-op, so this
-- is cheap to call every frame from an aim loop.
function HoverHighlight.set(self: HoverHighlight, target: Instance?)
	-- BEFORE the no-op check, never after: a wipe leaves `current` still pointing at the piece we
	-- were showing, so an owner that keeps asking for the same target would take the early exit
	-- every frame and never recover.
	self:ensure()

	if target == self.current then
		return
	end
	self.current = target

	if target then
		self.highlight.Adornee = target
		self.highlight.Enabled = true
	else
		self.highlight.Adornee = nil
		self.highlight.Enabled = false
	end
end

return HoverHighlight
