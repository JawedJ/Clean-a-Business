local DataService = require(game.ReplicatedStorage.Packages.DataService).server
local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)
local CleaningService = require(game.ServerScriptService.Modules.CleaningService)

DataService:init({
	template = DataTemplate,
	useMock = true
})


CleaningService.init()

