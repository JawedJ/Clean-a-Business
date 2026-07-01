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
local JobCameraController = require(Modules:WaitForChild("JobCameraController"))
local UiSoundController = require(Modules:WaitForChild("UiSoundController"))


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
JobCameraController.init()
UiSoundController.init()

