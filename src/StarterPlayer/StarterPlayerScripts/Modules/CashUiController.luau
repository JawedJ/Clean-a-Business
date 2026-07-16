--!strict

-- Drives the cash HUD (PlayerGui.ScreenGui.HUD.AllDisplays.CashDisplay.MoneyAmt): writes the
-- player's Cash balance into the MoneyAmt label as an abbreviated, "$"-prefixed
-- string (e.g. 1100 -> "$1.1k"). Reads the Cash domain from DataService and
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

local CashUiController = {}

-- Current HUD element, refreshed each time the ScreenGui is (re)bound.
local moneyLabel: TextLabel? = nil

-- Paint the current Cash balance onto whatever label is bound. Guards the brief
-- post-respawn window where the old label is gone but the new one isn't bound yet.
local function render()
	local label = moneyLabel
	if not label or not label.Parent then
		return
	end

	local cash: number = DataService:get({ "Cash" })
	label.Text = "$" .. NumberFormat.abbreviate(cash)
end

-- Resolve and store the MoneyAmt label of one CashDisplay, then paint it.
local function bind(screenGui: Instance)
	local cashDisplay = screenGui:WaitForChild("HUD"):WaitForChild("AllDisplays"):WaitForChild("CashDisplay")
	moneyLabel = cashDisplay:WaitForChild("MoneyAmt") :: TextLabel
	render()
end

function CashUiController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- One persistent subscription; render() reads whichever label is bound.
	DataService:getChangedSignal({ "Cash" }):Connect(render)

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

return CashUiController
