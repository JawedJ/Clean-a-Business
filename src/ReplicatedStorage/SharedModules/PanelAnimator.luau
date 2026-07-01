--!strict

-- Reusable open/close animation for full-panel UI frames (job board, shop, settings...).
-- Opening springs the frame up from below the screen while expanding to full size
-- (Back/Out overshoots for a pop); closing anticipates upward then swoops back down while
-- shrinking (Back/In), and hides the frame once it settles off-screen.
--
-- It handles the fiddly bits so callers don't repeat them per panel:
--   * converts the frame to center anchoring so it scales & slides about its own middle
--     (a top-left anchored frame would otherwise grow toward a corner), keeping it
--     visually in place,
--   * caches the on-screen ("open") geometry and derives an off-screen ("closed") one,
--   * locks out open()/close() for the tween's duration so a spammed toggle can't stack
--     tweens, and toggles Visible around the animation.
--
-- Purely a tween helper -- it never touches input or game state. Build one per frame
-- (re-build on each respawn, since HUD ScreenGuis are re-cloned):
--   local panel = PanelAnimator.new(someFrame)
--   panel:open()        -- slide up + expand into view
--   panel:close()       -- slide down + shrink out, then Visible = false
--   panel:hideInstant() -- snap hidden with no tween (forced state changes)

local TweenService = game:GetService("TweenService")

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

local PanelAnimator = {}
PanelAnimator.__index = PanelAnimator

export type PanelAnimator = typeof(setmetatable(
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
	PanelAnimator
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

function PanelAnimator.new(frame: GuiObject): PanelAnimator
	-- Re-anchor to the frame's center while keeping it visually in place: the new center
	-- position is the old edge position shifted by how far the anchor moved.
	local restPos = frame.Position
	local restSize = frame.Size
	local center = UDim2.new(
		restPos.X.Scale + (0.5 - frame.AnchorPoint.X) * restSize.X.Scale,
		restPos.X.Offset + (0.5 - frame.AnchorPoint.X) * restSize.X.Offset,
		restPos.Y.Scale + (0.5 - frame.AnchorPoint.Y) * restSize.Y.Scale,
		restPos.Y.Offset + (0.5 - frame.AnchorPoint.Y) * restSize.Y.Offset
	)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = center

	return setmetatable({
		frame = frame,
		openPosition = center,
		openSize = restSize,
		closedPosition = UDim2.new(center.X.Scale, center.X.Offset, CLOSED_Y_SCALE, 0),
		closedSize = scaleUDim2(restSize, CLOSED_SIZE_SCALE),
		activeTween = nil,
		busyUntil = 0,
	}, PanelAnimator)
end

-- Whether a tween is still within its cooldown window (i.e. presumed to be playing).
local function isBusy(self: PanelAnimator): boolean
	return os.clock() < self.busyUntil
end

-- Slide up + expand into view. Ignored while the previous tween is still within its
-- cooldown, so a spammed toggle can't re-enter mid-animation.
function PanelAnimator.open(self: PanelAnimator)
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
function PanelAnimator.close(self: PanelAnimator)
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
function PanelAnimator.isAnimating(self: PanelAnimator): boolean
	return isBusy(self)
end

-- Snap fully hidden with no animation, restoring the resting geometry, for forced state
-- changes (e.g. a job starting) where a tween would be wrong. Clears the cooldown so a
-- later open()/close() isn't blocked by a tween that no longer matters.
function PanelAnimator.hideInstant(self: PanelAnimator)
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

return PanelAnimator
