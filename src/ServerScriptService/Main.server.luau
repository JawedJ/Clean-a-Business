local DataService = require(game.ReplicatedStorage.Packages.DataService).server
local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)
local PlotService = require(game.ServerScriptService.Modules.PlotService)
local CleaningService = require(game.ServerScriptService.Modules.CleaningService)

DataService:init({
	template = DataTemplate,
	useMock = true,
})


PlotService.init()
CleaningService.init()

