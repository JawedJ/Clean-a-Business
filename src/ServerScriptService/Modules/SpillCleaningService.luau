--!strict

-- Server side of spill (mop) cleaning. Cleanable spills live in the shared business buildings:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableSpills.<model>
-- The Mop Tool lives in ReplicatedStorage.Items; ToolService grants it.
--
-- The mop fade is CLIENT-driven (like a wall wash, not the broom's server timer): the client
-- fades a spill to invisible at its own pace, then reports "this spill is fully mopped" through
-- CleanSpill. We can't witness the client's fade, but the report is harmless beyond progress --
-- we re-validate it against the job the player currently holds (so it can't clean a spill on a
-- business they haven't accepted), pay the per-spill reward, and record it in the player's
-- JobServer (which dedupes, so a replayed/forged report can't over-count or double-pay, and may
-- complete the job once every wall + stain + spill is done).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpillResolver = require(ReplicatedStorage.SharedModules.SpillResolver)
local JobService = require(script.Parent.JobService)
local ProgressionService = require(script.Parent.ProgressionService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CleanSpill = Remotes:WaitForChild("CleanSpill") :: RemoteEvent

-- Reward paid once per spill fully mopped (matches a stain's per-clean reward).
local SPILL_XP = 4
local SPILL_CASH = 4

local SpillCleaningService = {}

-- Resolve a reported spill to its identity, but only if it's a real cleanable spill AND belongs
-- to the business this player is currently on the clock for. Returns nil otherwise.
local function resolveForJob(player: Player, target: any): SpillResolver.SpillIdentity?
	if typeof(target) ~= "Instance" then
		return nil
	end
	local identity = SpillResolver.resolve(target)
	if not identity then
		return nil
	end
	if JobService.getActiveJob(player) ~= identity.businessId then
		return nil
	end
	return identity
end

function SpillCleaningService.init()
	CleanSpill.OnServerEvent:Connect(function(player, target)
		local identity = resolveForJob(player, target)
		if not identity then
			return
		end
		local job = JobService.getJob(player)
		if not job then
			return
		end
		-- Dedupe on the JobServer: only the FIRST report of a given spill this job pays out and
		-- counts toward completion, so a replayed report earns nothing.
		if job:markSpillCleaned(identity.surfaceId) then
			ProgressionService.reward(player, SPILL_XP, SPILL_CASH)
		end
	end)
end

return SpillCleaningService
