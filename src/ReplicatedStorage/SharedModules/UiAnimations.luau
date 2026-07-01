--!strict

-- Shared UI animation helpers, one home for the game's reusable GUI motion. It handles the
-- fiddly bits so callers don't repeat them per element. Two things live here today:
--
--   * UiAnimations.Panel -- open/close animation for full-panel frames (job board, shop,
--     settings...). Springs the frame up from below while expanding on open, swoops it back
--     down while shrinking on close. Build one per frame (re-build on each respawn, since
--     HUD ScreenGuis are re-cloned):
--         local panel = UiAnimations.Panel.new(someFrame)
--         panel:open()        -- slide up + expand into view
--         panel:close()       -- slide down + shrink out, then Visible = false
--         panel:hideInstant() -- snap hidden with no tween (forced state changes)
--
--   * UiAnimations.hoverGrow(button) -- grows a button a touch while hovered, settling back
--     on leave. Attach once per button (re-attach on each respawn):
--         UiAnimations.hoverGrow(someButton)
--
-- Purely tween helpers -- they never touch game state, and only the hover events for input.

local TweenService = game:GetService("TweenService")

local UiAnimations = {}

-- Re-anchor an element to its own center while keeping it visually in place, so anything
-- that scales it (a Size tween, a child UIScale) grows about the middle -- all sides evenly
-- -- instead of toward whichever corner the original anchor sat at. The new center position
-- is the old position shifted by how far the anchor moved. No-op if already centered.
local function recenterAnchor(element: GuiObject)
	if element.AnchorPoint == Vector2.new(0.5, 0.5) then
		return
	end
	local pos = element.Position
	local size = element.Size
	element.Position = UDim2.new(
		pos.X.Scale + (0.5 - element.AnchorPoint.X) * size.X.Scale,
		pos.X.Offset + (0.5 - element.AnchorPoint.X) * size.X.Offset,
		pos.Y.Scale + (0.5 - element.AnchorPoint.Y) * size.Y.Scale,
		pos.Y.Offset + (0.5 - element.AnchorPoint.Y) * size.Y.Offset
	)
	element.AnchorPoint = Vector2.new(0.5, 0.5)
end

--============================================================================--
-- Panel: open/close for full-panel frames
--============================================================================--

-- Feel of the two directions. Back gives the springy overshoot the design calls for.
-- Durations double as the input cooldown (see open/close): a call is ignored until the
-- tween it would start has had time to finish.
local OPEN_DURATION = 0.45
local CLOSE_DURATION = 0.35
local OPEN_TWEEN = TweenInfo.new(OPEN_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(CLOSE_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In)
-- Off-screen resting spot: center dropped fully below the bottom edge (Y > 1), scaled down
-- so the open tween reads as an expand and the close tween as a shrink.
local CLOSED_Y_SCALE = 1.4
local CLOSED_SIZE_SCALE = 0.6

local Panel = {}
Panel.__index = Panel
UiAnimations.Panel = Panel

export type Panel = typeof(setmetatable(
	{} :: {
		frame: GuiObject,
		openPosition: UDim2,
		openSize: UDim2,
		closedPosition: UDim2,
		closedSize: UDim2,
		activeTween: Tween?,
		-- os.clock() timestamp until which open()/close() are locked out: set to now + the
		-- upcoming tween's duration each time one starts, so a spammed toggle can't re-enter
		-- mid-tween (Back/In in particular anticipates past the live size, which would
		-- otherwise snowball on each restart). A plain timestamp -- not a Completed-driven
		-- flag, which a cancelled tween's late Completed can clobber a frame after the fact.
		busyUntil: number,
	},
	Panel
))

-- Scale a UDim2 about the origin (both scale and offset), for shrinking the closed size.
local function scaleUDim2(value: UDim2, factor: number): UDim2
	return UDim2.new(
		value.X.Scale * factor,
		value.X.Offset * factor,
		value.Y.Scale * factor,
		value.Y.Offset * factor
	)
end

function Panel.new(frame: GuiObject): Panel
	-- Center-anchor so the frame scales & slides about its own middle (a corner-anchored
	-- frame would otherwise grow toward that corner), keeping it visually in place.
	recenterAnchor(frame)
	local center = frame.Position
	local restSize = frame.Size

	return setmetatable({
		frame = frame,
		openPosition = center,
		openSize = restSize,
		closedPosition = UDim2.new(center.X.Scale, center.X.Offset, CLOSED_Y_SCALE, 0),
		closedSize = scaleUDim2(restSize, CLOSED_SIZE_SCALE),
		activeTween = nil,
		busyUntil = 0,
	}, Panel)
end

-- Whether a tween is still within its cooldown window (i.e. presumed to be playing).
local function isBusy(self: Panel): boolean
	return os.clock() < self.busyUntil
end

-- Slide up + expand into view. Ignored while the previous tween is still within its
-- cooldown, so a spammed toggle can't re-enter mid-animation.
function Panel.open(self: Panel)
	if isBusy(self) then
		return
	end
	self.busyUntil = os.clock() + OPEN_DURATION
	local frame = self.frame
	frame.Position = self.closedPosition
	frame.Size = self.closedSize
	frame.Visible = true
	local tween = TweenService:Create(frame, OPEN_TWEEN, {
		Position = self.openPosition,
		Size = self.openSize,
	})
	self.activeTween = tween
	tween:Play()
end

-- Slide down + shrink out, then hide and restore the resting geometry. Ignored while the
-- previous tween is still within its cooldown (see open()).
function Panel.close(self: Panel)
	if isBusy(self) then
		return
	end
	self.busyUntil = os.clock() + CLOSE_DURATION
	local frame = self.frame
	local tween = TweenService:Create(frame, CLOSE_TWEEN, {
		Position = self.closedPosition,
		Size = self.closedSize,
	})
	self.activeTween = tween
	tween.Completed:Connect(function(state)
		-- Cancel() also fires Completed (with a Cancelled state); only a natural finish
		-- should hide, so a close interrupted by hideInstant doesn't fight it.
		if state == Enum.PlaybackState.Completed then
			frame.Visible = false
			frame.Position = self.openPosition
			frame.Size = self.openSize
		end
	end)
	tween:Play()
end

-- Whether an open/close tween is currently playing (within its cooldown). Callers gate
-- their toggle on this so input is only accepted once the animation settles.
function Panel.isAnimating(self: Panel): boolean
	return isBusy(self)
end

-- Snap fully hidden with no animation, restoring the resting geometry, for forced state
-- changes (e.g. a job starting) where a tween would be wrong. Clears the cooldown so a
-- later open()/close() isn't blocked by a tween that no longer matters.
function Panel.hideInstant(self: Panel)
	if self.activeTween then
		self.activeTween:Cancel()
		self.activeTween = nil
	end
	self.busyUntil = 0
	local frame = self.frame
	frame.Visible = false
	frame.Position = self.openPosition
	frame.Size = self.openSize
end

--============================================================================--
-- hoverGrow: grow a button while hovered
--============================================================================--

-- Feel of the grow: a small pop out on enter, the same settle back on leave.
local HOVER_SCALE = 1.08
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Grow a button a touch while the cursor is over it, settling back on leave. Scales via a
-- child UIScale rather than the button's Size, so the grow doesn't disturb layout
-- (UIListLayout, constraints...); center-anchoring the button first makes it grow about its
-- middle -- all sides evenly -- rather than toward its original anchor corner. Idempotent
-- per button: reuses an existing UIScale so a re-attach after a respawn doesn't stack it.
function UiAnimations.hoverGrow(button: GuiButton)
	recenterAnchor(button)
	local scale = button:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = button
	end

	button.MouseEnter:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = HOVER_SCALE }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
	end)
end

return UiAnimations
