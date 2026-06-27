--!strict

-- Single client entry point. Requires and inits all client controllers in order.
-- No other client script should run logic on its own (see CleanABusiness.md).

local Modules = script.Parent:WaitForChild("Modules")

local PressureWasherController = require(Modules:WaitForChild("PressureWasherController"))

PressureWasherController.init()
