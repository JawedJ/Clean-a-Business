local DataService = require(game.ReplicatedStorage.Packages.DataService).server
local DataTemplate = require(game.ReplicatedStorage.SharedModules.DataTemplate)
local PlotService = require(game.ServerScriptService.Modules.PlotService)
local PlotButtonService = require(game.ServerScriptService.Modules.PlotButtonService)
local PlotSignService = require(game.ServerScriptService.Modules.PlotSignService)
local BusinessService = require(game.ServerScriptService.Modules.BusinessService)
local JobService = require(game.ServerScriptService.Modules.JobService)
local PlayerCollisionService = require(game.ServerScriptService.Modules.PlayerCollisionService)
local CleaningService = require(game.ServerScriptService.Modules.CleaningService)
local DecalCleaningService = require(game.ServerScriptService.Modules.DecalCleaningService)
local SpillCleaningService = require(game.ServerScriptService.Modules.SpillCleaningService)
local WebCleaningService = require(game.ServerScriptService.Modules.WebCleaningService)
local ToolService = require(game.ServerScriptService.Modules.ToolService)
local ShopService = require(game.ServerScriptService.Modules.ShopService)
local SkillsService = require(game.ServerScriptService.Modules.SkillsService)
local SettingsService = require(game.ServerScriptService.Modules.SettingsService)
local AdminCommands = require(game.ServerScriptService.Modules.AdminCommands)

DataService:init({
	template = DataTemplate,
	useMock = true
})


-- Registers plot assign/release hooks BEFORE PlotService.init() so the join sweep builds each
-- plot's buttons/spawnables from the owner's save data.
PlotButtonService.init()
-- Also registers an assign/release hook before PlotService.init(), so the join sweep names each
-- plot's warehouse sign after its owner.
PlotSignService.init()
PlotService.init()
-- Seeds every catalog business into each player's profile and grants unlocks as requirements
-- are met (level now, permanent once earned). Runs before JobService so accepts see the list.
BusinessService.init()
JobService.init()
-- Players never collide with each other (visual ghosting is client JobGhostController, job-only).
PlayerCollisionService.init()
CleaningService.init()
DecalCleaningService.init()
SpillCleaningService.init()
WebCleaningService.init()
ToolService.init()
ShopService.init()
-- Gem-purchased passive skills (SkillsDisplay UI): purchase authority + gain/walk-speed
-- multipliers other systems read. Init before SettingsService; order among these is not critical.
SkillsService.init()
SettingsService.init()
-- Owner-only dev chat commands (e.g. /completejob <id> <amount>).
AdminCommands.init()

