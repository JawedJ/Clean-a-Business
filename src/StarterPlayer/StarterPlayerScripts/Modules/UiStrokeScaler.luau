--!strict

-- Keeps UIStroke thickness looking consistent across devices.
--
-- UIStroke.Thickness is measured in absolute pixels only -- unlike UDim2 sizing it
-- has no Scale term, so a stroke designed at one resolution looks chunky on small
-- viewports and hairline-thin on large ones while the rest of the (Scale-based) UI
-- stays proportional. This controller drives every stroke's Thickness itself: it
-- remembers the designed value and rewrites it to base * (viewportHeight / REFERENCE),
-- re-running on viewport resize and for any stroke added at runtime.
--
-- Height is used (not width) because it is the stabler dimension across the wildly
-- varying aspect ratios of phones/tablets/desktop. Design your strokes in Studio at
-- REFERENCE_HEIGHT and this leaves them untouched there; everything else scales from it.

local Players = game:GetService("Players")

-- The viewport height (px) you author your UI at. A stroke keeps its designed
-- thickness when the client's viewport matches this, and scales linearly otherwise.
-- Set to match the monitor you eyeball strokes on in Studio (1440p here) so they
-- render as authored on your screen and scale down on smaller devices.
local REFERENCE_HEIGHT = 1080

-- Floor so a stroke can't scale to a literal zero, but kept tiny on purpose: some UI is authored
-- with near-invisible strokes (~0.05-0.07px, e.g. SkillsDisplay), and a larger floor would inflate
-- those up to itself -- rendering a thick outline in-game that isn't there in the authored design.
-- Genuine strokes (2px+) never approach this even on the smallest phones, so it only ever guards
-- against a base of zero.
local MIN_THICKNESS = 0.03

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

local UiStrokeScaler = {}

-- The stroke's authored thickness, stashed on first sight so repeated re-scales
-- always work off the original value instead of compounding. Persisted as an
-- attribute so it survives even if this runs against the same instance twice.
local function baseThickness(stroke: UIStroke): number
	local stored = stroke:GetAttribute("BaseThickness")
	if typeof(stored) ~= "number" then
		stored = stroke.Thickness
		stroke:SetAttribute("BaseThickness", stored)
	end
	return stored :: number
end

local function scaleFactor(): number
	local viewportY = camera.ViewportSize.Y
	-- ViewportSize can be 0 for a frame before the camera is ready; skip scaling then.
	if viewportY <= 0 then
		return 1
	end
	return viewportY / REFERENCE_HEIGHT
end

local function updateStroke(stroke: UIStroke, factor: number)
	stroke.Thickness = math.max(baseThickness(stroke) * factor, MIN_THICKNESS)
end

-- Trees we scan for strokes: the player's screen UI, plus the workspace so
-- BillboardGui/SurfaceGui strokes on in-world signs and labels scale too (their
-- Thickness is absolute pixels just like screen UI, so it needs the same treatment).
local function roots(): { Instance }
	return { localPlayer.PlayerGui, workspace }
end

local function updateAll()
	local factor = scaleFactor()
	for _, root in roots() do
		for _, inst in root:GetDescendants() do
			if inst:IsA("UIStroke") then
				updateStroke(inst, factor)
			end
		end
	end
end

function UiStrokeScaler.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Rescale the whole tree whenever the viewport changes (resize, rotate, window
	-- move between monitors). CurrentCamera can be swapped, so track it too.
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateAll)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = workspace.CurrentCamera
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateAll)
		updateAll()
	end)

	-- Catch strokes that appear after startup: HUD cloned on respawn, job frames,
	-- popups, in-world billboards, etc. DescendantAdded on PlayerGui covers every
	-- ScreenGui at once; on workspace it covers every in-world Billboard/SurfaceGui.
	local function watch(root: Instance)
		root.DescendantAdded:Connect(function(inst)
			if inst:IsA("UIStroke") then
				updateStroke(inst, scaleFactor())
			end
		end)
	end
	watch(playerGui)
	watch(workspace)

	updateAll()
end

return UiStrokeScaler
