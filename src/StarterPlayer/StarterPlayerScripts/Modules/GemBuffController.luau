--!strict

-- The HUD status line for the purchased 10x gem boost (PlayerGui.ScreenGui.BuffStatusGems).
--
-- The boost is stored as an absolute expiry stamp in the profile (DataTemplate.GemBuffExpiresAt, in
-- os.time() seconds -- see GemBuff), so all this does is subtract the current time from it once a
-- second and render the authored "10x GEMS: MM:SS" shape. The label is hidden whenever nothing is
-- running, which is also its authored state.
--
-- Boost purchases stack (GemBuff.activate extends the expiry rather than restarting it), so the
-- remaining time is NOT bounded by one hour -- past 59:59 the countdown grows an hours field
-- ("10x GEMS: 2:00:00") instead of wrapping.
--
-- The countdown compares the server's os.time() stamp against the CLIENT's clock. Both are UTC
-- seconds, so they agree to within whatever the player's machine clock is off by -- fine for a
-- display, and the boost itself is resolved entirely server-side regardless of what this shows.
--
-- Like the other HUD controllers the ScreenGui is re-cloned into PlayerGui on every respawn, so we
-- re-bind to the fresh instance each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).client

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- The multiplier the boost applies, mirrored from GemBuff for the label's copy.
local MULTIPLIER = 10

local GemBuffController = {}

-- The currently-bound label, refreshed each time the ScreenGui is (re)bound.
local statusLabel: TextLabel? = nil
-- Whole seconds left at the last repaint, so we only touch the label when the countdown ticks over.
local lastShown = -1

-- Seconds of boost left (0 when none), from the absolute expiry the server persisted.
local function secondsRemaining(): number
	local expiresAt = DataService:get({ "GemBuffExpiresAt" })
	if type(expiresAt) ~= "number" then
		return 0
	end
	return math.max(0, expiresAt - os.time())
end

-- Show/hide the label and paint the countdown, but only when the displayed second actually changed.
local function render()
	local label = statusLabel
	if not label or not label.Parent then
		return
	end

	local remaining = math.floor(secondsRemaining())
	if remaining == lastShown then
		return
	end
	lastShown = remaining

	if remaining <= 0 then
		label.Visible = false
		return
	end
	-- Under an hour keeps the authored "MM:SS"; stacked purchases past that get an hours field so
	-- the minutes never have to read "90:00".
	local hours = remaining // 3600
	if hours > 0 then
		label.Text =
			string.format("%dx GEMS: %d:%02d:%02d", MULTIPLIER, hours, remaining % 3600 // 60, remaining % 60)
	else
		label.Text = string.format("%dx GEMS: %02d:%02d", MULTIPLIER, remaining // 60, remaining % 60)
	end
	label.Visible = true
end

local function bind(screenGui: Instance)
	statusLabel = screenGui:WaitForChild("BuffStatusGems") :: TextLabel
	-- Force a repaint on the fresh label rather than trusting the previous clone's state.
	lastShown = -1
	render()
end

function GemBuffController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- A purchase replicates a new expiry; repaint immediately rather than waiting for the next tick.
	DataService:getChangedSignal({ "GemBuffExpiresAt" }):Connect(function()
		lastShown = -1
		render()
	end)

	-- One-second cadence: the label only shows whole seconds, so a Heartbeat loop would be pure
	-- waste. render() no-ops until the count actually moves.
	task.spawn(function()
		while true do
			task.wait(1)
			render()
		end
	end)

	local function onChild(child: Instance)
		if child.Name == SCREEN_GUI_NAME then
			task.spawn(bind, child)
		end
	end
	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
	playerGui.ChildAdded:Connect(onChild)
end

return GemBuffController
