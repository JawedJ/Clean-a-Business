local DataService = require(game.ReplicatedStorage.Packages.DataService).server
local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)


DataService:init({
	template = DataTemplate,
	useMock = true
})

