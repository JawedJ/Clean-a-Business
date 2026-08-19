--!strict

-- Client entry point. Requires each system and runs its init.

local Modules = script.Parent:WaitForChild("Modules")

local DataService = require(game.ReplicatedStorage.Packages.DataService).client
local SurfaceManager = require(Modules:WaitForChild("SurfaceManager"))
local DecalVisibility = require(Modules:WaitForChild("DecalVisibility"))
local SpillVisibility = require(Modules:WaitForChild("SpillVisibility"))
local WebVisibility = require(Modules:WaitForChild("WebVisibility"))
local GarbageVisibility = require(Modules:WaitForChild("GarbageVisibility"))
local JobController = require(Modules:WaitForChild("JobController"))
local PressureWasherController = require(Modules:WaitForChild("PressureWasherController"))
local WashJoystickController = require(Modules:WaitForChild("WashJoystickController"))
local BroomController = require(Modules:WaitForChild("BroomController"))
local MopController = require(Modules:WaitForChild("MopController"))
local VacuumController = require(Modules:WaitForChild("VacuumController"))
local GarbageCarryController = require(Modules:WaitForChild("GarbageCarryController"))
local GarbageShredController = require(Modules:WaitForChild("GarbageShredController"))
local InteractButtonController = require(Modules:WaitForChild("InteractButtonController"))
local Crosshair = require(Modules:WaitForChild("Crosshair"))
local RewardPopupController = require(Modules:WaitForChild("RewardPopupController"))
local LevelUiController = require(Modules:WaitForChild("LevelUiController"))
local CashUiController = require(Modules:WaitForChild("CashUiController"))
local GemUiController = require(Modules:WaitForChild("GemUiController"))
local JobUiController = require(Modules:WaitForChild("JobUiController"))
local WarehouseBoardProximity = require(Modules:WaitForChild("WarehouseBoardProximity"))
local BoardTextVisibility = require(Modules:WaitForChild("BoardTextVisibility"))
local UpgradesUiController = require(Modules:WaitForChild("UpgradesUiController"))
local SkillsUiController = require(Modules:WaitForChild("SkillsUiController"))
local ShopUiController = require(Modules:WaitForChild("ShopUiController"))
local PurchaseSoundController = require(Modules:WaitForChild("PurchaseSoundController"))
local PlotButtonSoundController = require(Modules:WaitForChild("PlotButtonSoundController"))
local WorkerGemPopupController = require(Modules:WaitForChild("WorkerGemPopupController"))
local JobCompletionController = require(Modules:WaitForChild("JobCompletionController"))
local UncleanedInfoController = require(Modules:WaitForChild("UncleanedInfoController"))
local JobSummaryController = require(Modules:WaitForChild("JobSummaryController"))
local JobCameraController = require(Modules:WaitForChild("JobCameraController"))
local ViewmodelController = require(Modules:WaitForChild("ViewmodelController"))
local JobRigController = require(Modules:WaitForChild("JobRigController"))
local UiButtonController = require(Modules:WaitForChild("UiButtonController"))
local SettingsUiController = require(Modules:WaitForChild("SettingsUiController"))
local CompanyUiController = require(Modules:WaitForChild("CompanyUiController"))
local BackgroundMusicController = require(Modules:WaitForChild("BackgroundMusicController"))
local UiStrokeScaler = require(Modules:WaitForChild("UiStrokeScaler"))
local ScrollBarScaler = require(Modules:WaitForChild("ScrollBarScaler"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local ToolFloatController = require(Modules:WaitForChild("ToolFloatController"))
local MissingHighlightController = require(Modules:WaitForChild("MissingHighlightController"))
local JobGhostController = require(Modules:WaitForChild("JobGhostController"))
local HidePlayersController = require(Modules:WaitForChild("HidePlayersController"))
local PartyController = require(Modules:WaitForChild("PartyController"))
local PartyUiController = require(Modules:WaitForChild("PartyUiController"))
local PlayTogetherController = require(Modules:WaitForChild("PlayTogetherController"))
local AfkEarningsController = require(Modules:WaitForChild("AfkEarningsController"))
local GemBuffController = require(Modules:WaitForChild("GemBuffController"))
local GemBurst = require(Modules:WaitForChild("GemBurst"))
local FirstSpawnCameraController = require(Modules:WaitForChild("FirstSpawnCameraController"))
local LeaderboardController = require(Modules:WaitForChild("LeaderboardController"))
local UiPreloader = require(Modules:WaitForChild("UiPreloader"))
local TutorialController = require(Modules:WaitForChild("TutorialController"))


-- The PlayerGui and replicated folders can lag the first frames this script runs; wait for the game
-- to finish loading so init logic doesn't race partially-replicated instances.
if not game:IsLoaded() then
	game.Loaded:Wait()
end

-- Run each system's init in isolation. Without this, a single init erroring (e.g. racing a not-yet-
-- replicated instance on a slow load) aborts the whole sequence, leaving every later system -- the
-- HUD, purchase SFX, worker popups -- silently dead, which reads as a random "sometimes the UI/sounds
-- don't work" on load. pcall preserves the order but turns any one failure into a warning, not a
-- cascade. Order still matters where noted (e.g. settings before music).
local function safeInit(label: string, init: () -> ())
	xpcall(init, function(err)
		warn(string.format("[Main.client] %s.init() failed: %s", label, tostring(err)))
	end)
end

-- Connect the server-driven remote listeners FIRST, before any init that can yield on replication.
-- These just :Connect (no yielding), and doing them up front means the server's per-second worker
-- popups and on-touch purchase SFX aren't dropped ("remote queue exhausted") during startup or lost
-- entirely if a later init stalls.
safeInit("PlotButtonSoundController", PlotButtonSoundController.init)
safeInit("WorkerGemPopupController", WorkerGemPopupController.init)
-- Belongs in this early block for the same reason: the server aims the camera the instant it
-- places a first-ever character, which is right at join -- a listener connected any later misses it.
safeInit("FirstSpawnCameraController", FirstSpawnCameraController.init)
-- Party roster mirror. Also belongs up here: the server pushes the roster the moment anything
-- changes, and a snapshot sent before we connect would be lost -- leaving the UI (and the washer's
-- stroke relay) thinking we're alone.
safeInit("PartyController", PartyController.init)

safeInit("DataService", function()
	DataService:init()
end)
-- SurfaceManager is the overlay engine; JobController drives it per accepted job.
safeInit("SurfaceManager", SurfaceManager.init)
-- Hide all cleanable stains by default; JobController shows the active job's via this.
safeInit("DecalVisibility", DecalVisibility.init)
-- Same for spills (mop targets): hidden until their business is the active job.
safeInit("SpillVisibility", SpillVisibility.init)
-- Same for webs (vacuum targets): hidden until their business is the active job.
safeInit("WebVisibility", WebVisibility.init)
-- Cleanable garbage (carry targets) goes further than hiding: the authored pieces are taken
-- off-world and each job gets LOCAL CLONES of them, so garbage one player carries around can't
-- disturb anyone else's run of the same building.
safeInit("GarbageVisibility", GarbageVisibility.init)
safeInit("JobController", JobController.init)
safeInit("PressureWasherController", function()
	PressureWasherController.init(SurfaceManager.getSurface)
end)
-- The touch washer trigger + look joystick. After PressureWasherController, whose equip state it
-- subscribes to and whose firing it drives.
safeInit("WashJoystickController", WashJoystickController.init)
safeInit("BroomController", BroomController.init)
safeInit("MopController", MopController.init)
safeInit("VacuumController", VacuumController.init)
-- Hover-highlight, pick up and carry cleanable garbage (the server owns who holds what).
safeInit("GarbageCarryController", GarbageCarryController.init)
-- Feeding a carried piece into the business's shredder: the touch report, and the disposal animation
-- every member of the session runs on their own clone. Init after GarbageCarryController so the
-- carry is already listening by the time a piece can be fed in.
safeInit("GarbageShredController", GarbageShredController.init)
-- The HUD's touch interact button: picks up the outlined piece, or drops the carried one (the only
-- way to let go on touch). After GarbageCarryController, whose carry + hover state it subscribes to.
safeInit("InteractButtonController", InteractButtonController.init)
safeInit("Crosshair", Crosshair.init)
safeInit("RewardPopupController", RewardPopupController.init)
safeInit("LevelUiController", LevelUiController.init)
safeInit("CashUiController", CashUiController.init)
safeInit("GemUiController", GemUiController.init)
-- The shared gem-shower effect. Init before its callers (AfkEarnings / Company UI claims) so a
-- payout that lands early still has something bound to play.
safeInit("GemBurst", GemBurst.init)
safeInit("JobUiController", JobUiController.init)
-- Open/close the job board and upgrades shop as the player walks in/out of their warehouse
-- board hitboxes.
safeInit("WarehouseBoardProximity", WarehouseBoardProximity.init)
-- Show each plot's board text (Job/Upgrades billboards) only on its owner's client.
safeInit("BoardTextVisibility", BoardTextVisibility.init)
safeInit("UpgradesUiController", UpgradesUiController.init)
safeInit("SkillsUiController", SkillsUiController.init)
-- Robux store panel (StoreButton + ShopUI): currency packs and the permanent perks.
safeInit("ShopUiController", ShopUiController.init)
safeInit("PurchaseSoundController", PurchaseSoundController.init)
-- PlotButtonSoundController (purchase SFX) and WorkerGemPopupController (worker popups) are
-- connected first, up top, so their remote events aren't dropped during startup.
safeInit("JobCompletionController", JobCompletionController.init)
-- One-line "what's left" readout beside the completion bar, shown only while on a job.
safeInit("UncleanedInfoController", UncleanedInfoController.init)
safeInit("JobSummaryController", JobSummaryController.init)
safeInit("JobCameraController", JobCameraController.init)
-- The first-person arms rig, shown in front of the camera for the duration of a job. After
-- JobCameraController, which locks the camera to first person off the same ActiveJob attribute.
safeInit("ViewmodelController", ViewmodelController.init)
-- The full-body job rig (the cat the server swaps them into): plays its animations -- which
-- replicate, so everyone sees them -- and keeps it invisible to its own owner, who sees the
-- first-person arms instead.
safeInit("JobRigController", JobRigController.init)
safeInit("UiButtonController", UiButtonController.init)
-- Settings tab (volume sliders). Init BEFORE the music starts so saved volumes apply first.
safeInit("SettingsUiController", SettingsUiController.init)
-- Company panel (avatar, "<name>'s Business", average rating, editable saved description).
safeInit("CompanyUiController", CompanyUiController.init)
-- Loop the BackgroundMusic playlist for the local player, with fade transitions.
safeInit("BackgroundMusicController", BackgroundMusicController.init)
safeInit("UiStrokeScaler", UiStrokeScaler.init)
safeInit("ScrollBarScaler", ScrollBarScaler.init)
safeInit("InventoryController", InventoryController.init)
safeInit("ToolFloatController", ToolFloatController.init)
-- Press R on a job to flash a yellow, through-walls highlight over what's left to clean.
safeInit("MissingHighlightController", MissingHighlightController.init)
-- On a job, other players working the same business are hidden entirely (model, name and VFX).
safeInit("JobGhostController", JobGhostController.init)
-- Optional (Settings.HidePlayers) hiding of every other player's character, toggled from the tab.
safeInit("HidePlayersController", HidePlayersController.init)
-- The party screens (create / browse / party room). Init BEFORE the button that opens them, so the
-- first press always lands on bound panels.
safeInit("PartyUiController", PartyUiController.init)
-- Standalone "play together" button: hidden during a job, and inert for the tutorial's duration.
safeInit("PlayTogetherController", PlayTogetherController.init)
-- Offline-earnings claim screen: shown on join when the server reports AFK gems to collect.
safeInit("AfkEarningsController", AfkEarningsController.init)
-- HUD countdown for the purchased 10x gem boost, shown only while one is running.
safeInit("GemBuffController", GemBuffController.init)
-- Builds the three in-world top-100 boards (workspace.Leaderboard) from the server's broadcast.
safeInit("LeaderboardController", LeaderboardController.init)
-- Warm the HUD's image assets in the background so they don't first render blurry.
safeInit("UiPreloader", UiPreloader.init)
-- First-join onboarding: renders the server's current tutorial step and applies its UI locks. Init
-- LAST -- it reads the job board / upgrades shop through their controllers, and its first act is to
-- pick up a step the server may already have set, which should land on a fully built HUD.
safeInit("TutorialController", TutorialController.init)

