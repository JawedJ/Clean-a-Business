local DataService = require(game.ReplicatedStorage.Packages.DataService).server
local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)
local PlotService = require(game.ServerScriptService.Modules.PlotService)
local BusinessService = require(game.ServerScriptService.Modules.BusinessService)
local JobService = require(game.ServerScriptService.Modules.JobService)
local PlayerCollisionService = require(game.ServerScriptService.Modules.PlayerCollisionService)
local CleaningService = require(game.ServerScriptService.Modules.CleaningService)
local DecalCleaningService = require(game.ServerScriptService.Modules.DecalCleaningService)
local ToolService = require(game.ServerScriptService.Modules.ToolService)
local ShopService = require(game.ServerScriptService.Modules.ShopService)
local SettingsService = require(game.ServerScriptService.Modules.SettingsService)

DataService:init({
	template = DataTemplate,
})


PlotService.init()
-- Seeds every catalog business into each player's profile and grants unlocks as requirements
-- are met (level now, permanent once earned). Runs before JobService so accepts see the list.
BusinessService.init()
JobService.init()
-- Players never collide with each other (visual ghosting is client JobGhostController, job-only).
PlayerCollisionService.init()
CleaningService.init()
DecalCleaningService.init()
ToolService.init()
ShopService.init()
SettingsService.init()

