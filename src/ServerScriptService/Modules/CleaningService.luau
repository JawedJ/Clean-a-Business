--!strict

-- Server side of pressure-washer (wall) cleaning. Cleanable walls live in the
-- shared business buildings:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableWalls.<part>
-- The Pressure Washer Tool lives in ReplicatedStorage.Items; ToolService grants it.
--
-- The dirt overlay is an EditableImage built entirely on the client, so the server
-- never sees pixel data and there's nothing to save (jobs are per-session). Two things
-- flow through here, both re-validated every time against the job the player currently
-- holds (so neither works on a wall they aren't on the clock for):
--   * CleanProgress -- "I'm actively erasing dirt": pays the per-second wash reward,
--     throttled by a cooldown so it can't be farmed by spamming the remote.
--   * WallCleaned   -- "this wall is fully erased": reported into the player's JobServer
--     so it can tell when every wall + stain is done and complete the job.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local SurfaceResolver = require(ReplicatedStorage.SharedModules.SurfaceResolver)
local JobService = require(script.Parent.JobService)
local ProgressionService = require(script.Parent.ProgressionService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CleanProgress = Remotes:WaitForChild("CleanProgress") :: RemoteEvent
local WallCleaned = Remotes:WaitForChild("WallCleaned") :: RemoteEvent

-- Reward paid for each second of actively erasing dirt from a wall. WASH_COOLDOWN is
-- the server-enforced minimum gap between payouts, so a client can't earn faster by
-- sending CleanProgress more often.
local WASH_XP = 2
local WASH_CASH = 2
local WASH_COOLDOWN = 1 -- seconds

local CleaningService = {}

-- os.clock() of the last wash reward paid to each player. Server-owned.
local lastWashReward: { [Player]: number } = {}

-- Resolve a reported wall to its identity, but only if it's a real cleanable wall
-- BasePart AND it belongs to the business this player is currently on the clock for.
-- Returns nil otherwise.
local function resolveForJob(player: Player, surface: any): SurfaceResolver.SurfaceIdentity?
	if typeof(surface) ~= "Instance" or not surface:IsA("BasePart") then
		return nil
	end
	local identity = SurfaceResolver.resolve(surface)
	if not identity then
		return nil
	end
	if JobService.getActiveJob(player) ~= identity.businessId then
		return nil
	end
	return identity
end

function CleaningService.init()
	-- The client reports it is actively erasing dirt on a wall. We pay the wash reward
	-- at most once per WASH_COOLDOWN, after re-validating that the wall is part of the
	-- player's current job -- so the reward can't be farmed on someone else's job, on a
	-- business they haven't accepted, or by spamming the remote faster than the cooldown.
	CleanProgress.OnServerEvent:Connect(function(player, surface)
		if not resolveForJob(player, surface) then
			return
		end

		local now = os.clock()
		local last = lastWashReward[player]
		if last and now - last < WASH_COOLDOWN then
			return
		end
		lastWashReward[player] = now

		ProgressionService.reward(player, WASH_XP, WASH_CASH)
	end)

	-- The client reports a wall fully erased. We can't witness the pixels (they're
	-- client-only), but the report is harmless beyond progress: record it in the player's
	-- job so completion can be detected. Re-validated against the active job, and the
	-- JobServer dedupes, so a replayed/forged report can't over-count.
	WallCleaned.OnServerEvent:Connect(function(player, surface)
		local identity = resolveForJob(player, surface)
		if not identity then
			return
		end
		local job = JobService.getJob(player)
		if job then
			job:markWallCleaned(identity.surfaceId)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastWashReward[player] = nil
	end)
end

return CleaningService
