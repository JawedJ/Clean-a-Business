--!strict

-- Keeps ScrollingFrame scrollbars looking consistent across devices.
--
-- ScrollingFrame.ScrollBarThickness is measured in absolute pixels only -- unlike UDim2
-- sizing it has no Scale term, so a bar designed at one resolution looks chunky on small
-- viewports and hairline-thin on large ones while the rest of the (Scale-based) UI stays
-- proportional. This controller drives every frame's ScrollBarThickness itself: it remembers
-- the designed value and rewrites it to base * (viewportHeight / REFERENCE), re-running on
-- viewport resize and for any ScrollingFrame added at runtime.
--
-- Height is used (not width) because it is the stabler dimension across the wildly varying
-- aspect ratios of phones/tablets/desktop. Design your bars in Studio at REFERENCE_HEIGHT and
-- this leaves them untouched there; everything else scales from it. Mirrors UiStrokeScaler.

local Players = game:GetService("Players")

-- The viewport height (px) you author your UI at. A scrollbar keeps its designed thickness
-- when the client's viewport matches this, and scales linearly otherwise. Kept in sync with
-- UiStrokeScaler.REFERENCE_HEIGHT (1440p monitor) so both scale off the same baseline.
local REFERENCE_HEIGHT = 1080

-- Floor so a bar can't scale to a literal zero on tiny viewports. A 1px minimum keeps the bar
-- grabbable; frames authored with ScrollBarThickness 0 (bar hidden on purpose) stay at 0 because
-- their base is 0 and we only apply the floor when the base is non-zero.
local MIN_THICKNESS = 1

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

local ScrollBarScaler = {}

-- The frame's authored thickness, stashed on first sight so repeated re-scales always work off
-- the original value instead of compounding. Persisted as an attribute so it survives even if
-- this runs against the same instance twice.
local function baseThickness(frame: ScrollingFrame): number
	local stored = frame:GetAttribute("BaseScrollBarThickness")
	if typeof(stored) ~= "number" then
		stored = frame.ScrollBarThickness
		frame:SetAttribute("BaseScrollBarThickness", stored)
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

local function updateFrame(frame: ScrollingFrame, factor: number)
	local base = baseThickness(frame)
	-- A bar authored at 0 is intentionally hidden; leave it hidden rather than floor it up to 1.
	if base <= 0 then
		frame.ScrollBarThickness = 0
		return
	end
	frame.ScrollBarThickness = math.max(base * factor, MIN_THICKNESS)
end

-- Trees we scan for scrollbars: the player's screen UI, plus the workspace so SurfaceGui
-- ScrollingFrames on in-world panels scale too (their thickness is absolute pixels just like
-- screen UI, so it needs the same treatment).
local function roots(): { Instance }
	return { localPlayer.PlayerGui, workspace }
end

local function updateAll()
	local factor = scaleFactor()
	for _, root in roots() do
		for _, inst in root:GetDescendants() do
			if inst:IsA("ScrollingFrame") then
				updateFrame(inst, factor)
			end
		end
	end
end

function ScrollBarScaler.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Rescale the whole tree whenever the viewport changes (resize, rotate, window move between
	-- monitors). CurrentCamera can be swapped, so track it too.
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateAll)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = workspace.CurrentCamera
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateAll)
		updateAll()
	end)

	-- Catch frames that appear after startup: HUD cloned on respawn, job frames, popups, etc.
	-- DescendantAdded on PlayerGui covers every ScreenGui at once; on workspace it covers every
	-- in-world SurfaceGui.
	local function watch(root: Instance)
		root.DescendantAdded:Connect(function(inst)
			if inst:IsA("ScrollingFrame") then
				updateFrame(inst, scaleFactor())
			end
		end)
	end
	watch(playerGui)
	watch(workspace)

	updateAll()
end

return ScrollBarScaler
