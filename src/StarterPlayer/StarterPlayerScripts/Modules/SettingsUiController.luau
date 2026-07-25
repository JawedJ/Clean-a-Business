--!strict

-- Drives the settings UI (PlayerGui.ScreenGui: HUD.AllButtons.Buttons3.SettingsButton +
-- SettingsTab). The
-- SettingsButton toggles the SettingsTab open/closed with the SAME slide + expand animation as
-- the job board and upgrades shop (via the shared ExclusivePanels coordinator, so opening it
-- closes whichever of those was open, and vice versa); the tab's ExitButton closes it.
--
-- The tab's ScrollingFrame holds two identically-shaped controls -- MusicVolumeControl and
-- SFXVolumeControl -- each a horizontal bar with a draggable Slider handle. Dragging a slider
-- from full-left (off) to full-right (max) sets that channel's 0..1 master volume, applied LIVE
-- through SoundGroups so the change is heard instantly while dragging. On release the final value
-- is sent to the server (UpdateSetting) to persist; the server clamps + saves it via DataService
-- and replicates the confirmed value back, which we re-apply and re-sync the handle to.
--
-- Alongside the sliders sits the HidePlayersCB checkbox (a TextButton): clicking it toggles the
-- Settings.HidePlayers preference, showing/hiding its Design.X check mark and applying it live via
-- HidePlayersController (every other player's character hides for this client). It persists through
-- the same UpdateSetting round-trip as the sliders.
--
-- Initial values come from the player's saved Settings (a first-join profile defaults both volumes
-- to 0.5, so each handle starts centered, and HidePlayers to off). Volumes are applied on init --
-- before the music starts -- so a returning player never hears a blip at the wrong level.
--
-- Like the other HUD controllers, the ScreenGui is re-cloned into PlayerGui on every respawn, so
-- we re-bind to the fresh instances each time one appears. The SettingsButton lives in the Buttons3
-- cluster, which hides during a job, so the tab also snaps hidden (and refuses to open) mid-job.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local SoundGroups = require(ReplicatedStorage.SharedModules.SoundGroups)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local ExclusivePanels = require(script.Parent.ExclusivePanels)
local HidePlayersController = require(script.Parent.HidePlayersController)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateSetting = Remotes:WaitForChild("UpdateSetting") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Stable name this panel registers under with ExclusivePanels (only one exclusive panel is open
-- at a time; opening this closes the job board / upgrades shop first, and vice versa).
local PANEL_NAME = "Settings"
-- Value a slider falls back to if its saved setting is missing/invalid -- the centered default.
local DEFAULT_VALUE = 0.5
-- The setting key + control name for the "hide other players" checkbox (a TextButton whose Design.X
-- label is shown when the toggle is on). Persisted like the volume rows via UpdateSetting.
local HIDE_PLAYERS_KEY = "HidePlayers"
local HIDE_PLAYERS_CONTROL = "HidePlayersCB"

-- One row of settings: the DataService path key it persists under, the control frame (the bar),
-- and the SoundGroups setter that applies its live value.
local ROWS = {
	{ key = "MusicVolume", control = "MusicVolumeControl", apply = SoundGroups.setMusicVolume },
	{ key = "SFXVolume", control = "SFXVolumeControl", apply = SoundGroups.setSfxVolume },
}

local SettingsUiController = {}

-- A bound, draggable slider row: setValue re-syncs the handle to a value (0..1) from outside a
-- drag (init / server confirmation / reopen). One per row, rebuilt each bind.
type Slider = {
	setValue: (value: number) -> (),
}

-- Drives the tab's open/close (slide + expand) animation; rebuilt per bind alongside the frame.
local settingsPanel: UiAnimations.Panel? = nil
local settingsTab: Frame? = nil
-- The currently-bound sliders, keyed by their setting key, refreshed each bind.
local sliders: { [string]: Slider } = {}

-- A bound checkbox: setValue re-syncs its checked state (X visibility) from outside a click
-- (init / server confirmation / reopen). Rebuilt each bind; nil before the first bind.
type Checkbox = {
	setValue: (value: boolean) -> (),
}
local hidePlayersCheckbox: Checkbox? = nil

-- Read a saved setting as a 0..1 value, falling back to the centered default if it's missing or
-- not a number (e.g. before the profile reconciles the new Settings table in).
local function getSaved(key: string): number
	local value = DataService:get({ "Settings", key })
	return if type(value) == "number" then math.clamp(value, 0, 1) else DEFAULT_VALUE
end

-- Read a saved boolean setting, defaulting to false if it's missing or not a boolean (e.g. before
-- the profile reconciles the new key in).
local function getSavedBool(key: string): boolean
	return DataService:get({ "Settings", key }) == true
end

-- Whether the local player currently holds a job (the Buttons3 cluster -- including the
-- SettingsButton -- hides while on one, so the tab must hide/refuse to open then too).
local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Make `control` (a horizontal bar) a slider whose child Slider handle tracks the pointer along
-- the X axis. `onChange` is called continuously with the live 0..1 value while dragging (apply
-- volume); `onCommit` is called once with the final value on release (persist). The handle is
-- positioned in scale off AbsoluteSize so it works whether the handle was authored in offset or
-- scale, and stays inside the bar at both ends.
--
-- `scroll` is the enclosing ScrollingFrame: on touch devices a drag that starts on the bar would
-- otherwise ALSO pan the list up/down, so we freeze its scrolling for the duration of the drag and
-- restore it on release.
local function bindSlider(control: Frame, scroll: ScrollingFrame, onChange: (value: number) -> (), onCommit: (value: number) -> ()): Slider
	local handle = control:WaitForChild("Slider") :: Frame
	-- The bar receives the input (clicking/dragging anywhere on it moves the handle), so it must
	-- be Active; the handle stays inactive so the pointer over it still reaches the bar.
	control.Active = true

	-- Preserve the handle's authored Y (it's vertically offset to straddle the thin bar); we only
	-- ever drive its X.
	local baseY = handle.Position.Y
	local currentValue = DEFAULT_VALUE

	-- Place the handle for `currentValue`: scale 0 pins its left edge to the bar's left, scale
	-- (1 - handleWidth/barWidth) pins its right edge to the bar's right, so full-left..full-right
	-- maps cleanly to 0..1 with the handle always fully inside. No-op until the bar has rendered
	-- (AbsoluteSize 0 while the tab is hidden) -- the AbsoluteSize signal below re-places it then.
	local function place()
		local barWidth = control.AbsoluteSize.X
		if barWidth <= 0 then
			return
		end
		local handleFraction = handle.AbsoluteSize.X / barWidth
		handle.Position = UDim2.new(currentValue * (1 - handleFraction), 0, baseY.Scale, baseY.Offset)
	end

	-- Value (0..1) for a pointer X (pixels): the handle's CENTRE follows the pointer, clamped so
	-- the handle can't leave the bar, then normalized over the travel its centre can cover.
	local function valueFromX(pointerX: number): number
		local barWidth = control.AbsoluteSize.X
		local handleWidth = handle.AbsoluteSize.X
		local travel = barWidth - handleWidth
		if travel <= 0 then
			return 0
		end
		local left = (pointerX - control.AbsolutePosition.X) - handleWidth / 2
		return math.clamp(left / travel, 0, 1)
	end

	local function drag(pointerX: number)
		currentValue = valueFromX(pointerX)
		place()
		onChange(currentValue)
	end

	-- Movement + release are tracked globally (so the drag follows the pointer even past the bar's
	-- edges) but only WHILE dragging: the two connections are made on press and torn down on
	-- release, so nothing global lingers between drags or leaks across respawns.
	control.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		drag(input.Position.X)
		-- Stop the drag from doubling as a scroll pan on touch; restored on release below.
		scroll.ScrollingEnabled = false

		local moveConn: RBXScriptConnection
		local endConn: RBXScriptConnection
		moveConn = UserInputService.InputChanged:Connect(function(moveInput)
			if moveInput.UserInputType == Enum.UserInputType.MouseMovement or moveInput.UserInputType == Enum.UserInputType.Touch then
				drag(moveInput.Position.X)
			end
		end)
		endConn = UserInputService.InputEnded:Connect(function(endInput)
			if endInput.UserInputType == Enum.UserInputType.MouseButton1 or endInput.UserInputType == Enum.UserInputType.Touch then
				moveConn:Disconnect()
				endConn:Disconnect()
				scroll.ScrollingEnabled = true
				onCommit(currentValue)
			end
		end)
	end)

	-- Re-place on (re)render / resolution change so a value set while the tab was hidden lands
	-- correctly once the bar has a real size.
	control:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	handle:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)

	return {
		setValue = function(value: number)
			currentValue = math.clamp(value, 0, 1)
			place()
		end,
	}
end

-- Wire `control` (a TextButton) as an on/off checkbox: clicking flips its state, shows/hides the
-- Design.X check label to match, calls `onChange` with the new state (apply live), and calls
-- `onCommit` with it (persist). setValue re-syncs the check from outside a click without firing
-- either callback. `checked` seeds the initial state.
local function bindCheckbox(control: TextButton, checked: boolean, onChange: (value: boolean) -> (), onCommit: (value: boolean) -> ()): Checkbox
	local check = control:WaitForChild("Design"):WaitForChild("X") :: TextLabel
	-- The button must be Active for Activated to fire on click (it's authored inactive in Studio).
	control.Active = true
	local currentValue = checked

	local function render()
		check.Visible = currentValue
	end
	render()

	control.Activated:Connect(function()
		currentValue = not currentValue
		render()
		onChange(currentValue)
		onCommit(currentValue)
	end)

	return {
		setValue = function(value: boolean)
			currentValue = value
			render()
		end,
	}
end

-- Re-sync every bound handle to the current saved values -- used as the panel's beforeOpen so the
-- sliders reflect the latest data each time the tab is shown.
local function syncSliders()
	for key, slider in sliders do
		slider.setValue(getSaved(key))
	end
	if hidePlayersCheckbox then
		hidePlayersCheckbox.setValue(getSavedBool(HIDE_PLAYERS_KEY))
	end
end

-- Toggle the tab open/closed via the shared coordinator (closing any other open panel first).
-- No-op while on a job -- the Buttons3 cluster is hidden then.
local function togglePanel()
	if hasActiveJob() then
		return
	end
	ExclusivePanels.toggle(PANEL_NAME)
end

-- Snap the tab hidden if a job starts with it open (the Buttons3 cluster hides mid-job, so the
-- tab must not linger over the job UI). Guards the gap before anything is bound.
local function applyActiveJobState()
	local panel = settingsPanel
	local tab = settingsTab
	if hasActiveJob() and panel and tab and tab.Parent then
		panel:hideInstant()
		ExclusivePanels.markHidden(PANEL_NAME)
	end
end

-- Resolve one ScreenGui's settings elements, wire the button + sliders, then apply current state.
-- Yields on WaitForChild for a fresh clone.
local function bind(screenGui: Instance)
	local buttons3 = screenGui:WaitForChild("HUD"):WaitForChild("AllButtons"):WaitForChild("Buttons3")
	local settingsButton = buttons3:WaitForChild("SettingsButton") :: ImageButton
	local tab = screenGui:WaitForChild("SettingsTab") :: Frame
	-- ExitButton + ScrollingFrame now sit under a Background wrapper (refactor), not on the tab directly.
	local background = tab:WaitForChild("Background")
	local exitButton = background:WaitForChild("ExitButton") :: ImageButton
	local scroll = background:WaitForChild("ScrollingFrame") :: ScrollingFrame

	local panel = UiAnimations.Panel.new(tab)
	settingsTab = tab
	settingsPanel = panel
	tab.Visible = false

	-- Register with the coordinator so open/close is sequenced against the other panels; it
	-- re-syncs the sliders (beforeOpen) right before showing.
	ExclusivePanels.register(PANEL_NAME, panel, syncSliders)

	settingsButton.Activated:Connect(togglePanel)
	exitButton.Activated:Connect(function()
		ExclusivePanels.close(PANEL_NAME)
	end)

	-- Wire each volume slider: apply its channel's volume live while dragging, persist on release.
	sliders = {}
	for _, row in ROWS do
		local control = scroll:WaitForChild(row.control) :: Frame
		local key = row.key
		local apply = row.apply
		local slider = bindSlider(control, scroll, apply, function(value: number)
			UpdateSetting:FireServer(key, value)
		end)
		slider.setValue(getSaved(key))
		sliders[key] = slider
	end

	-- Wire the hide-other-players checkbox: apply the toggle live, then persist it on click.
	local hidePlayersControl = scroll:WaitForChild(HIDE_PLAYERS_CONTROL) :: TextButton
	hidePlayersCheckbox = bindCheckbox(hidePlayersControl, getSavedBool(HIDE_PLAYERS_KEY), HidePlayersController.setEnabled, function(value: boolean)
		UpdateSetting:FireServer(HIDE_PLAYERS_KEY, value)
	end)

	applyActiveJobState()
end

function SettingsUiController.init()
	-- Apply the saved (or default) volumes immediately -- before the music starts in Main -- so a
	-- returning player's mix is right from the first note, even before the tab is ever opened.
	for _, row in ROWS do
		row.apply(getSaved(row.key))
	end
	-- Apply the saved hide-other-players preference immediately, before any characters are handled.
	HidePlayersController.setEnabled(getSavedBool(HIDE_PLAYERS_KEY))

	-- Keep volume in sync with the data: fires on the server's confirmation of a committed change
	-- (and any other write), re-applying it and nudging the handle to the confirmed value.
	for _, row in ROWS do
		local key = row.key
		local apply = row.apply
		DataService:getChangedSignal({ "Settings", key }):Connect(function(value)
			if type(value) ~= "number" then
				return
			end
			apply(value)
			local slider = sliders[key]
			if slider then
				slider.setValue(value)
			end
		end)
	end

	-- Keep the hide-other-players toggle in sync with the data (server confirmation / any write),
	-- re-applying it and nudging the checkbox to the confirmed state.
	DataService:getChangedSignal({ "Settings", HIDE_PLAYERS_KEY }):Connect(function(value)
		if type(value) ~= "boolean" then
			return
		end
		HidePlayersController.setEnabled(value)
		if hidePlayersCheckbox then
			hidePlayersCheckbox.setValue(value)
		end
	end)

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(applyActiveJobState)

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

return SettingsUiController
