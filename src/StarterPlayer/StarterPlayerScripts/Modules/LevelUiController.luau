--!strict

-- Drives the XP bar HUD (PlayerGui.ScreenGui.XpBar): fills "Fillable" to the
-- player's progress toward the next level, and writes the LevelText / XpText labels
-- (plus the "3DEffect" label, a shadow duplicate of the level text). Reads the Level
-- domain from DataService and re-renders whenever it changes -- the server replaces
-- the whole Level table on every XP award, so a single changed signal covers both
-- XP gains and level-ups.
--
-- The ScreenGui resets on spawn (a fresh copy is cloned into PlayerGui whenever the
-- character respawns), so we re-bind to the new instances each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local DataService = require(ReplicatedStorage.Packages.DataService).client
local Leveling = require(ReplicatedStorage.SharedModules.Leveling)
local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local DataTemplate = require(ReplicatedStorage.SharedModules.DataTemplate)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

type Level = DataTemplate.Level

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"

-- One-shot played when CurrentLevel rises (not on plain XP gains).
local LEVEL_UP_SOUND = "LvlUp"

-- Quick, simple slide of the fill bar toward its new position on each XP update.
local FILL_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local LevelUiController = {}

-- Current HUD elements, refreshed each time the ScreenGui is (re)bound.
local fill: Frame? = nil
local levelLabel: TextLabel? = nil
local levelShadow: TextLabel? = nil
local xpLabel: TextLabel? = nil

-- The fill tween currently in flight, so a newer update can supersede it.
local fillTween: Tween? = nil

-- Last CurrentLevel we've seen, so a Level change that raised it plays the level-up
-- sound. Seeded on first render so the initial bind never counts as a level-up.
local lastLevel: number? = nil

-- Move the fill bar to `target`. When animating, the newest call always wins: we
-- cancel any in-flight tween (leaving the bar at its current position) and tween
-- from there, so overlapping XP gains -- e.g. a decal completing mid pressure-wash
-- -- never fight over the bar; it just heads to the most recent value.
local function setFill(target: UDim2, animate: boolean)
	local frame = fill
	if not frame then
		return
	end
	if fillTween then
		fillTween:Cancel()
		fillTween = nil
	end
	if animate then
		local tween = TweenService:Create(frame, FILL_TWEEN, { Size = target })
		fillTween = tween
		tween:Play()
	else
		frame.Size = target
	end
end

-- Paint the current Level onto whatever elements are bound. `animate` tweens the
-- bar (XP updates) vs. snapping it (initial bind). Guards the brief post-respawn
-- window where the old elements are gone but the new ones aren't bound yet.
local function render(animate: boolean)
	if not fill or not fill.Parent then
		return
	end

	local level: Level = DataService:get({ "Level" })
	local needed = Leveling.xpForLevel(level.CurrentLevel)
	local progress = if needed > 0 then math.clamp(level.XP / needed, 0, 1) else 0

	-- Play the level-up sound only when CurrentLevel actually rose. lastLevel starts
	-- nil, so the initial bind seeds it silently rather than sounding on join.
	if lastLevel ~= nil and level.CurrentLevel > lastLevel then
		SoundManager.playOneShot(LEVEL_UP_SOUND)
	end
	lastLevel = level.CurrentLevel

	setFill(UDim2.new(progress, 0, 1, 0), animate)

	local levelText = string.format("Level %d", level.CurrentLevel)
	if levelLabel then
		levelLabel.Text = levelText
	end
	if levelShadow then
		levelShadow.Text = levelText
	end
	if xpLabel then
		xpLabel.Text = string.format("EXP: %s / %s", NumberFormat.abbreviate(level.XP), NumberFormat.abbreviate(needed))
	end
end

-- Resolve and store the elements of one XpBar, then paint it (snapped, no tween).
local function bind(screenGui: Instance)
	local xpBar = screenGui:WaitForChild("XpBar")
	fill = xpBar:WaitForChild("Fillable") :: Frame
	levelLabel = xpBar:WaitForChild("LevelText") :: TextLabel
	levelShadow = xpBar:FindFirstChild("3DEffect") :: TextLabel?
	xpLabel = xpBar:WaitForChild("XpText") :: TextLabel
	render(false)
end

function LevelUiController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- One persistent subscription; render() reads whichever elements are bound.
	DataService:getChangedSignal({ "Level" }):Connect(function()
		render(true)
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

return LevelUiController
