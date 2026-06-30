--!strict

-- Server authority for player progression: awarding Cash and XP, and resolving
-- level-ups. Every reward in the game funnels through here so the leveling rules
-- live in exactly one place. All writes go through DataService so they replicate
-- to the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local Leveling = require(ReplicatedStorage.SharedModules.Leveling)

local RewardPopup = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RewardPopup") :: RemoteEvent

local ProgressionService = {}

-- Adds `cash` to the player's balance. No-op for non-positive amounts.
function ProgressionService.awardCash(player: Player, cash: number)
	if cash <= 0 then
		return
	end
	DataService:update(player, { "Cash" }, function(current: number?)
		return (current or 0) + cash
	end)
end

-- Adds `xp` to the player's level, applying any level-ups via Leveling. No-op for
-- non-positive amounts.
function ProgressionService.awardXp(player: Player, xp: number)
	if xp <= 0 then
		return
	end
	DataService:update(player, { "Level" }, function(level)
		return Leveling.addXp(level, xp)
	end)
end

-- Convenience: award XP and Cash together, and tell the client to show its
-- floating "+N XP! / +N Cash!" popups for whatever was actually granted.
function ProgressionService.reward(player: Player, xp: number, cash: number)
	ProgressionService.awardXp(player, xp)
	ProgressionService.awardCash(player, cash)
	RewardPopup:FireClient(player, xp, cash)
end

return ProgressionService
