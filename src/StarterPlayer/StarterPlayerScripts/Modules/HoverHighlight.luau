--!strict

-- The white hover outline shared by every cleanable the player aims at (garbage, stains, spills,
-- webs). Walls are deliberately excluded -- they're EditableImage overlays painted onto the
-- building's own geometry, so an outline would trace the whole wall rather than the dirt.
--
-- The look is the garbage carry outline, kept here so all four cleanables read identically: drawn
-- OVER the target (AlwaysOnTop) rather than shaded onto it, so it stays visible on pale or busy
-- geometry -- an occluded outline on a light-coloured piece is almost invisible. Every hover that
-- uses this comes from a raycast (so it already requires a clear line of sight), which is why
-- drawing on top can't reveal anything through a wall.
--
-- One Highlight per owner, created once and re-adorned: Highlight instances are relatively
-- expensive to build, and only one tool is ever equipped at a time so at most one is enabled.
-- They live under the PlayerGui so they survive respawns.

local Players = game:GetService("Players")

local HIGHLIGHT_COLOR = Color3.fromRGB(255, 255, 255)
local HIGHLIGHT_FILL_TRANSPARENCY = 0.2
local HIGHLIGHT_DEPTH_MODE = Enum.HighlightDepthMode.AlwaysOnTop

local localPlayer = Players.LocalPlayer

local HoverHighlight = {}
HoverHighlight.__index = HoverHighlight

export type HoverHighlight = typeof(setmetatable(
	{} :: {
		highlight: Highlight,
		current: Instance?,
	},
	HoverHighlight
))

-- Build one reusable outline. `name` only shows up in the explorer, to tell the tools' outlines
-- apart while debugging.
function HoverHighlight.new(name: string): HoverHighlight
	local highlight = Instance.new("Highlight")
	highlight.Name = name
	highlight.FillColor = HIGHLIGHT_COLOR
	highlight.OutlineColor = HIGHLIGHT_COLOR
	highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY
	highlight.OutlineTransparency = 0
	highlight.DepthMode = HIGHLIGHT_DEPTH_MODE
	highlight.Enabled = false
	highlight.Parent = localPlayer:WaitForChild("PlayerGui")

	return setmetatable({
		highlight = highlight,
		current = nil,
	}, HoverHighlight)
end

-- Outline `target`, or clear the outline when nil. Re-setting the same target is a no-op, so this
-- is cheap to call every frame from an aim loop.
function HoverHighlight.set(self: HoverHighlight, target: Instance?)
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
