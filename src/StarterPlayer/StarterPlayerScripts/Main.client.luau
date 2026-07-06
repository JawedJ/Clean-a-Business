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
local JobUiController = require(Modules:WaitForChild("JobUiController"))
local JobCompletionController = require(Modules:WaitForChild("JobCompletionController"))
local JobSummaryController = require(Modules:WaitForChild("JobSummaryController"))
local JobCameraController = require(Modules:WaitForChild("JobCameraController"))
local UiSoundController = require(Modules:WaitForChild("UiSoundController"))
local UiStrokeScaler = require(Modules:WaitForChild("UiStrokeScaler"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local ToolFloatController = require(Modules:WaitForChild("ToolFloatController"))
local MissingHighlightController = require(Modules:WaitForChild("MissingHighlightController"))
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
JobUiController.init()
JobCompletionController.init()
JobSummaryController.init()
JobCameraController.init()
UiSoundController.init()
UiStrokeScaler.init()
InventoryController.init()
ToolFloatController.init()
-- Press R on a job to flash a yellow, through-walls highlight over what's left to clean.
MissingHighlightController.init()
-- Warm the HUD's image assets in the background so they don't first render blurry.
UiPreloader.init()

