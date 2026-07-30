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
local CompanyService = require(game.ServerScriptService.Modules.CompanyService)
local PurchaseService = require(game.ServerScriptService.Modules.PurchaseService)
local AfkEarningsService = require(game.ServerScriptService.Modules.AfkEarningsService)
local GemProductsService = require(game.ServerScriptService.Modules.GemProductsService)
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
-- Owns the single MarketplaceService.ProcessReceipt; every dev-product grant registers a handler
-- with it. Init before any service that registers a product (SkillsService, AfkEarningsService)
-- so the callback is live before receipts can arrive.
PurchaseService.init()
-- Gem-purchased passive skills (SkillsDisplay UI): purchase authority + gain/walk-speed
-- multipliers other systems read. Init before SettingsService; order among these is not critical.
SkillsService.init()
SettingsService.init()
-- Persists the player's business description (Company UI) and feeds its stat cards: accrues
-- lifetime playtime and mirrors the plot's gem rate into the profile.
CompanyService.init()
-- Offline gem earnings: snapshots gems/sec + leave time on exit, grants a fraction on rejoin via
-- the AfkEarnings UI. Init after SkillsService (reads its Hoarding multiplier) and PurchaseService
-- (registers the Double dev product).
AfkEarningsService.init()
-- The Company UI's two Robux products: the 24-hour earnings claim and the 10x gem boost. Init after
-- PurchaseService (it registers both with the receipt dispatcher).
GemProductsService.init()
-- Owner-only dev chat commands (e.g. /completejob <id> <amount>).
AdminCommands.init()

