--!strict

-- Client entry point. Requires each system and runs its init.

local Modules = script.Parent:WaitForChild("Modules")

local DataService = require(game.ReplicatedStorage.Packages.DataService).client
local SurfaceManager = require(Modules:WaitForChild("SurfaceManager"))
local PressureWasherController = require(Modules:WaitForChild("PressureWasherController"))
local Crosshair = require(Modules:WaitForChild("Crosshair"))


DataService:init()
SurfaceManager.init()
PressureWasherController.init(SurfaceManager.getSurface)
Crosshair.init()


print(DataService:get())