--!strict

-- Client entry point. Requires each system and runs its init.

local Modules = script.Parent:WaitForChild("Modules")

local DataService = require(game.ReplicatedStorage.Packages.DataService).client
local SurfaceManager = require(Modules:WaitForChild("SurfaceManager"))
local DecalVisibility = require(Modules:WaitForChild("DecalVisibility"))
local JobController = require(Modules:WaitForChild("JobController"))
local PressureWasherController = require(Modules:WaitForChild("PressureWasherController"))
local BroomController = require(Modules:WaitForChild("BroomController"))
local Crosshair = require(Modules:WaitForChild("Crosshair"))
local RewardPopupController = require(Modules:WaitForChild("RewardPopupController"))
local LevelUiController = require(Modules:WaitForChild("LevelUiController"))
local CashUiController = require(Modules:WaitForChild("CashUiController"))
local GemUiController = require(Modules:WaitForChild("GemUiController"))
local JobUiController = require(Modules:WaitForChild("JobUiController"))
local WarehouseBoardProximity = require(Modules:WaitForChild("WarehouseBoardProximity"))
local UpgradesUiController = require(Modules:WaitForChild("UpgradesUiController"))
local PlotButtonSoundController = require(Modules:WaitForChild("PlotButtonSoundController"))
local JobCompletionController = require(Modules:WaitForChild("JobCompletionController"))
local JobSummaryController = require(Modules:WaitForChild("JobSummaryController"))
local JobCameraController = require(Modules:WaitForChild("JobCameraController"))
local UiSoundController = require(Modules:WaitForChild("UiSoundController"))
local SettingsUiController = require(Modules:WaitForChild("SettingsUiController"))
local BackgroundMusicController = require(Modules:WaitForChild("BackgroundMusicController"))
local UiStrokeScaler = require(Modules:WaitForChild("UiStrokeScaler"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local ToolFloatController = require(Modules:WaitForChild("ToolFloatController"))
local MissingHighlightController = require(Modules:WaitForChild("MissingHighlightController"))
local JobGhostController = require(Modules:WaitForChild("JobGhostController"))
local HidePlayersController = require(Modules:WaitForChild("HidePlayersController"))
local UiPreloader = require(Modules:WaitForChild("UiPreloader"))


DataService:init()
-- SurfaceManager is the overlay engine; JobController drives it per accepted job.
SurfaceManager.init()
-- Hide all cleanable stains by default; JobController shows the active job's via this.
DecalVisibility.init()
JobController.init()
PressureWasherController.init(SurfaceManager.getSurface)
BroomController.init()
Crosshair.init()
RewardPopupController.init()
LevelUiController.init()
CashUiController.init()
GemUiController.init()
JobUiController.init()
-- Open/close the job board and upgrades shop as the player walks in/out of their warehouse
-- board hitboxes.
WarehouseBoardProximity.init()
UpgradesUiController.init()
-- Plays the buy / fail SFX when the player steps on a plot purchase button (server-driven).
PlotButtonSoundController.init()
JobCompletionController.init()
JobSummaryController.init()
JobCameraController.init()
UiSoundController.init()
-- Settings tab (volume sliders). Init BEFORE the music starts so saved volumes apply first.
SettingsUiController.init()
-- Loop the BackgroundMusic playlist for the local player, with fade transitions.
BackgroundMusicController.init()
UiStrokeScaler.init()
InventoryController.init()
ToolFloatController.init()
-- Press R on a job to flash a yellow, through-walls highlight over what's left to clean.
MissingHighlightController.init()
-- On a job, other players working the same business show as a blue highlight, not their model.
JobGhostController.init()
-- Optional (Settings.HidePlayers) hiding of every other player's character, toggled from the tab.
HidePlayersController.init()
-- Warm the HUD's image assets in the background so they don't first render blurry.
UiPreloader.init()

