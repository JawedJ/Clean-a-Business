--!strict

-- Server authority for the gem-purchased SKILLS (PlayerGui.ScreenGui.SkillsDisplay, driven by
-- the client's SkillsUiController). Owns the one skill action, re-validated here so a client can
-- never grant itself a level it didn't pay for:
--
--   * PurchaseSkill(skillName) -- buy the NEXT level of a skill: if it's below the cap and the
--     player can afford SkillsConfig.getCost(currentLevel) in Gems, deduct that cost and bump the
--     level by one. The client repaints off the resulting Skills/Gems data change.
--
-- Skills are priced in GEMS. All the price/cap/effect math lives in the shared SkillsConfig so
-- the client's display and this authority can't disagree. This module is also the single place
-- other server systems read a player's skill MULTIPLIER from (getMultiplier), used by
-- ProgressionService (Cash/XP/Gem gain) and JobServer (walk speed). The Speedy skill's walk-speed
-- boost is applied here directly on each character.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local StarterPlayer = game:GetService("StarterPlayer")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local SkillsConfig = require(ReplicatedStorage.SharedModules.SkillsConfig)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PurchaseSkill = Remotes:WaitForChild("PurchaseSkill") :: RemoteEvent

-- Base free-roam walk speed the Speedy multiplier scales: StarterPlayer.CharacterWalkSpeed, the
-- same value Roblox spawns characters at, so with no Speedy levels a player moves at exactly the
-- authored default. Read live rather than cached so tuning the property (in Studio, or at runtime)
-- takes effect on the next apply. Deliberately NOT Config.JobWalkSpeed -- that is the separate,
-- pinned ON-THE-JOB speed (see JobServer._pinWalkSpeed).
local function baseWalkSpeed(): number
	return StarterPlayer.CharacterWalkSpeed
end

-- Robux developer product that maxes every skill at once (the SkillsDisplay's "UNLOCK ALL SKILLS"
-- button prompts it). Granting is idempotent (just sets each skill to the cap), so re-processing a
-- receipt after a restart can never over-grant.
local UNLOCK_ALL_PRODUCT_ID = 3609731896

local SkillsService = {}

-- A player's current level in `skillName` (0 if unset / not yet reconciled).
local function getLevel(player: Player, skillName: string): number
	local level = DataService:get(player, { "Skills", skillName })
	return if type(level) == "number" then level else 0
end

-- The passive multiplier a player's `skillName` currently grants (1.0 with none bought). The
-- single read-point other server systems use to apply a skill's effect.
function SkillsService.getMultiplier(player: Player, skillName: string): number
	return SkillsConfig.multiplier(skillName, getLevel(player, skillName))
end

-- Set a character's Humanoid walk speed to the player's Speedy-boosted free-roam speed. No-op
-- until the Humanoid exists. Kept idempotent so it's safe to reassert (respawn, purchase).
local function applyWalkSpeed(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	humanoid.WalkSpeed = baseWalkSpeed() * SkillsService.getMultiplier(player, "Speedy")
end

-- Re-apply the player's Speedy-boosted walk speed to their current character, if any. Called
-- after a successful Speedy purchase so the boost takes effect immediately (JobServer independently
-- pins the boosted speed during a job).
function SkillsService.refreshWalkSpeed(player: Player)
	local character = player.Character
	if character then
		applyWalkSpeed(player, character)
	end
end

-- Set every skill to the level cap (the UNLOCK_ALL_PRODUCT_ID grant). Idempotent -- writing the
-- cap over an already-maxed skill is a no-op in effect -- so it's safe to run on a re-processed
-- receipt. Refreshes walk speed in case Speedy jumped.
local function grantAllSkills(player: Player)
	for skillName in SkillsConfig.Skills do
		DataService:set(player, { "Skills", skillName }, SkillsConfig.MAX_LEVEL)
	end
	SkillsService.refreshWalkSpeed(player)
end

-- MarketplaceService receipt handler for the skill dev products. Returns PurchaseGranted only
-- after the grant is safely written, NotProcessedYet otherwise so Roblox retries later (the grant
-- is idempotent, so a retry can't double-apply). Unknown products are left unprocessed.
local function processReceipt(receiptInfo: { PlayerId: number, ProductId: number }): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Buyer left before we could grant; Roblox will re-deliver when they're next in-game.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if receiptInfo.ProductId == UNLOCK_ALL_PRODUCT_ID then
		local ok = pcall(function()
			DataService:waitForData(player)
			grantAllSkills(player)
		end)
		return if ok then Enum.ProductPurchaseDecision.PurchaseGranted else Enum.ProductPurchaseDecision.NotProcessedYet
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

-- Buy the next level of a skill, charging its Gems cost. Ignores bad names, maxed skills, and
-- players who can't afford the next level.
local function onPurchase(player: Player, skillName: unknown)
	if type(skillName) ~= "string" or not SkillsConfig.isSkill(skillName) then
		return
	end

	local level = getLevel(player, skillName)
	if not SkillsConfig.canUpgrade(level) then
		return -- maxed
	end

	local cost = SkillsConfig.getCost(level)
	local gems = DataService:get(player, { "Gems" })
	if type(gems) ~= "number" or gems < cost then
		return -- can't afford it
	end

	-- Deduct the cost, then bump the level. The server handles one remote event at a time and
	-- neither call yields, so there's no partial-purchase race between the two.
	DataService:update(player, { "Gems" }, function(current: number?)
		return (current or 0) - cost
	end)
	DataService:update(player, { "Skills", skillName }, function(current: number?)
		return (current or 0) + 1
	end)

	-- Speedy changes movement immediately, not just on the next respawn.
	if skillName == "Speedy" then
		SkillsService.refreshWalkSpeed(player)
	end
end

function SkillsService.init()
	PurchaseSkill.OnServerEvent:Connect(onPurchase)

	-- Deliver the skill dev products. Only one ProcessReceipt callback exists per game; this is
	-- currently the only one. If other products are added later, route them through a shared
	-- receipt dispatcher instead of overwriting this.
	MarketplaceService.ProcessReceipt = processReceipt

	-- Apply each player's Speedy-boosted walk speed to every character they spawn into. Reading
	-- their skill level needs the profile loaded, and a character can spawn before it is, so gate
	-- each apply on waitForData (spawned so the yield never blocks the CharacterAdded signal).
	local function applyWhenReady(player: Player, character: Model)
		task.spawn(function()
			DataService:waitForData(player)
			-- The character may have been replaced (respawn) while we waited.
			if character.Parent then
				applyWalkSpeed(player, character)
			end
		end)
	end

	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			applyWhenReady(player, character)
		end)
		if player.Character then
			applyWhenReady(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
end

return SkillsService
