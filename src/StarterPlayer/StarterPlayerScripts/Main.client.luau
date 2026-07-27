--!strict

-- Client entry point. Requires each system and runs its init.

local Modules = script.Parent:WaitForChild("Modules")

local DataService = require(game.ReplicatedStorage.Packages.DataService).client
local SurfaceManager = require(Modules:WaitForChild("SurfaceManager"))
local DecalVisibility = require(Modules:WaitForChild("DecalVisibility"))
local SpillVisibility = require(Modules:WaitForChild("SpillVisibility"))
local WebVisibility = require(Modules:WaitForChild("WebVisibility"))
local JobController = require(Modules:WaitForChild("JobController"))
local PressureWasherController = require(Modules:WaitForChild("PressureWasherController"))
local BroomController = require(Modules:WaitForChild("BroomController"))
local MopController = require(Modules:WaitForChild("MopController"))
local VacuumController = require(Modules:WaitForChild("VacuumController"))
local Crosshair = require(Modules:WaitForChild("Crosshair"))
local RewardPopupController = require(Modules:WaitForChild("RewardPopupController"))
local LevelUiController = require(Modules:WaitForChild("LevelUiController"))
local CashUiController = require(Modules:WaitForChild("CashUiController"))
local GemUiController = require(Modules:WaitForChild("GemUiController"))
local JobUiController = require(Modules:WaitForChild("JobUiController"))
local WarehouseBoardProximity = require(Modules:WaitForChild("WarehouseBoardProximity"))
local BoardTextVisibility = require(Modules:WaitForChild("BoardTextVisibility"))
local UpgradesUiController = require(Modules:WaitForChild("UpgradesUiController"))
local SkillsUiController = require(Modules:WaitForChild("SkillsUiController"))
local PurchaseSoundController = require(Modules:WaitForChild("PurchaseSoundController"))
local PlotButtonSoundController = require(Modules:WaitForChild("PlotButtonSoundController"))
local WorkerGemPopupController = require(Modules:WaitForChild("WorkerGemPopupController"))
local JobCompletionController = require(Modules:WaitForChild("JobCompletionController"))
local JobSummaryController = require(Modules:WaitForChild("JobSummaryController"))
local JobCameraController = require(Modules:WaitForChild("JobCameraController"))
local UiButtonController = require(Modules:WaitForChild("UiButtonController"))
local SettingsUiController = require(Modules:WaitForChild("SettingsUiController"))
local CompanyUiController = require(Modules:WaitForChild("CompanyUiController"))
local BackgroundMusicController = require(Modules:WaitForChild("BackgroundMusicController"))
local UiStrokeScaler = require(Modules:WaitForChild("UiStrokeScaler"))
local ScrollBarScaler = require(Modules:WaitForChild("ScrollBarScaler"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local ToolFloatController = require(Modules:WaitForChild("ToolFloatController"))
local MissingHighlightController = require(Modules:WaitForChild("MissingHighlightController"))
local JobGhostController = require(Modules:WaitForChild("JobGhostController"))
local HidePlayersController = require(Modules:WaitForChild("HidePlayersController"))
local AfkEarningsController = require(Modules:WaitForChild("AfkEarningsController"))
local UiPreloader = require(Modules:WaitForChild("UiPreloader"))


-- The PlayerGui and replicated folders can lag the first frames this script runs; wait for the game
-- to finish loading so init logic doesn't race partially-replicated instances.
if not game:IsLoaded() then
	game.Loaded:Wait()
end

-- Run each system's init in isolation. Without this, a single init erroring (e.g. racing a not-yet-
-- replicated instance on a slow load) aborts the whole sequence, leaving every later system -- the
-- HUD, purchase SFX, worker popups -- silently dead, which reads as a random "sometimes the UI/sounds
-- don't work" on load. pcall preserves the order but turns any one failure into a warning, not a
-- cascade. Order still matters where noted (e.g. settings before music).
local function safeInit(label: string, init: () -> ())
	xpcall(init, function(err)
		warn(string.format("[Main.client] %s.init() failed: %s", label, tostring(err)))
	end)
end

-- Connect the server-driven remote listeners FIRST, before any init that can yield on replication.
-- These just :Connect (no yielding), and doing them up front means the server's per-second worker
-- popups and on-touch purchase SFX aren't dropped ("remote queue exhausted") during startup or lost
-- entirely if a later init stalls.
safeInit("PlotButtonSoundController", PlotButtonSoundController.init)
safeInit("WorkerGemPopupController", WorkerGemPopupController.init)

safeInit("DataService", function()
	DataService:init()
end)
-- SurfaceManager is the overlay engine; JobController drives it per accepted job.
safeInit("SurfaceManager", SurfaceManager.init)
-- Hide all cleanable stains by default; JobController shows the active job's via this.
safeInit("DecalVisibility", DecalVisibility.init)
-- Same for spills (mop targets): hidden until their business is the active job.
safeInit("SpillVisibility", SpillVisibility.init)
-- Same for webs (vacuum targets): hidden until their business is the active job.
safeInit("WebVisibility", WebVisibility.init)
safeInit("JobController", JobController.init)
safeInit("PressureWasherController", function()
	PressureWasherController.init(SurfaceManager.getSurface)
end)
safeInit("BroomController", BroomController.init)
safeInit("MopController", MopController.init)
safeInit("VacuumController", VacuumController.init)
safeInit("Crosshair", Crosshair.init)
safeInit("RewardPopupController", RewardPopupController.init)
safeInit("LevelUiController", LevelUiController.init)
safeInit("CashUiController", CashUiController.init)
safeInit("GemUiController", GemUiController.init)
safeInit("JobUiController", JobUiController.init)
-- Open/close the job board and upgrades shop as the player walks in/out of their warehouse
-- board hitboxes.
safeInit("WarehouseBoardProximity", WarehouseBoardProximity.init)
-- Show each plot's board text (Job/Upgrades billboards) only on its owner's client.
safeInit("BoardTextVisibility", BoardTextVisibility.init)
safeInit("UpgradesUiController", UpgradesUiController.init)
safeInit("SkillsUiController", SkillsUiController.init)
safeInit("PurchaseSoundController", PurchaseSoundController.init)
-- PlotButtonSoundController (purchase SFX) and WorkerGemPopupController (worker popups) are
-- connected first, up top, so their remote events aren't dropped during startup.
safeInit("JobCompletionController", JobCompletionController.init)
safeInit("JobSummaryController", JobSummaryController.init)
safeInit("JobCameraController", JobCameraController.init)
safeInit("UiButtonController", UiButtonController.init)
-- Settings tab (volume sliders). Init BEFORE the music starts so saved volumes apply first.
safeInit("SettingsUiController", SettingsUiController.init)
-- Company panel (avatar, "<name>'s Business", average rating, editable saved description).
safeInit("CompanyUiController", CompanyUiController.init)
-- Loop the BackgroundMusic playlist for the local player, with fade transitions.
safeInit("BackgroundMusicController", BackgroundMusicController.init)
safeInit("UiStrokeScaler", UiStrokeScaler.init)
safeInit("ScrollBarScaler", ScrollBarScaler.init)
safeInit("InventoryController", InventoryController.init)
safeInit("ToolFloatController", ToolFloatController.init)
-- Press R on a job to flash a yellow, through-walls highlight over what's left to clean.
safeInit("MissingHighlightController", MissingHighlightController.init)
-- On a job, other players working the same business show as a blue highlight, not their model.
safeInit("JobGhostController", JobGhostController.init)
-- Optional (Settings.HidePlayers) hiding of every other player's character, toggled from the tab.
safeInit("HidePlayersController", HidePlayersController.init)
-- Offline-earnings claim screen: shown on join when the server reports AFK gems to collect.
safeInit("AfkEarningsController", AfkEarningsController.init)
-- Warm the HUD's image assets in the background so they don't first render blurry.
safeInit("UiPreloader", UiPreloader.init)

