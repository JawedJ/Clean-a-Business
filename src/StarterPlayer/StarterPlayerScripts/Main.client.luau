--!strict

-- Client entry point. Requires each system and runs its init.

local Modules = script.Parent:WaitForChild("Modules")

local DataService = require(game.ReplicatedStorage.Packages.DataService).client
local SurfaceManager = require(Modules:WaitForChild("SurfaceManager"))
local PressureWasherController = require(Modules:WaitForChild("PressureWasherController"))
local BroomController = require(Modules:WaitForChild("BroomController"))
local Crosshair = require(Modules:WaitForChild("Crosshair"))
local RewardPopupController = require(Modules:WaitForChild("RewardPopupController"))
local LevelUiController = require(Modules:WaitForChild("LevelUiController"))


DataService:init()
SurfaceManager.init()
PressureWasherController.init(SurfaceManager.getSurface)
BroomController.init()
Crosshair.init()
RewardPopupController.init()
LevelUiController.init()

