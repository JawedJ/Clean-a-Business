local DataService = require(game.ReplicatedStorage.Packages.DataService).server
local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)
local PlotService = require(game.ServerScriptService.Modules.PlotService)
local JobService = require(game.ServerScriptService.Modules.JobService)
local CleaningService = require(game.ServerScriptService.Modules.CleaningService)
local DecalCleaningService = require(game.ServerScriptService.Modules.DecalCleaningService)
local ToolService = require(game.ServerScriptService.Modules.ToolService)

DataService:init({
	template = DataTemplate,
})


PlotService.init()
JobService.init()
CleaningService.init()
DecalCleaningService.init()
ToolService.init()

