--!strict

-- Drives the gem HUD (PlayerGui.ScreenGui.GemDisplay.GemAmt): writes the
-- player's Gems balance into the GemAmt label as an abbreviated string
-- (e.g. 1100 -> "1.1k"). Reads the Gems domain from DataService and
-- re-renders whenever it changes.
--
-- The ScreenGui resets on spawn (a fresh copy is cloned into PlayerGui whenever the
-- character respawns), so we re-bind to the new instances each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).client
local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"

local GemUiController = {}

-- Current HUD element, refreshed each time the ScreenGui is (re)bound.
local gemLabel: TextLabel? = nil

-- Paint the current Gems balance onto whatever label is bound. Guards the brief
-- post-respawn window where the old label is gone but the new one isn't bound yet.
local function render()
	local label = gemLabel
	if not label or not label.Parent then
		return
	end

	local gems: number = DataService:get({ "Gems" })
	label.Text = NumberFormat.abbreviate(gems)
end

-- Resolve and store the GemAmt label of one GemDisplay, then paint it.
local function bind(screenGui: Instance)
	local gemDisplay = screenGui:WaitForChild("GemDisplay")
	gemLabel = gemDisplay:WaitForChild("GemAmt") :: TextLabel
	render()
end

function GemUiController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- One persistent subscription; render() reads whichever label is bound.
	DataService:getChangedSignal({ "Gems" }):Connect(render)

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

return GemUiController
