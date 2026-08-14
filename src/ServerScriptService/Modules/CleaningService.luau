--!strict

-- Server side of pressure-washer (wall) cleaning. Cleanable walls live in the
-- shared business buildings:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableWalls.<part>
-- The Pressure Washer Tool lives in ReplicatedStorage.Items; ToolService grants it.
--
-- The dirt overlay is an EditableImage built entirely on the client, so the server
-- never sees pixel data and there's nothing to save (jobs are per-session). Three things
-- flow through here, all re-validated every time against the job the player currently
-- holds (so none works on a wall they aren't on the clock for):
--   * CleanProgress -- "I'm actively erasing dirt": pays the per-second wash reward,
--     throttled by a cooldown so it can't be farmed by spamming the remote.
--   * WallCleaned   -- "this wall is fully erased": reported into the player's JobServer
--     so it can tell when every wall + stain is done and complete the job.
--   * WallStroke    -- "here's where I just erased": relayed to the other members of a
--     PARTY job so their overlays erase in the same places (below).
--
-- SHARING THE OVERLAYS. Each client builds its own EditableImage per wall, and the pixels
-- never leave that client -- there's no way to hand a party member the image itself. What we
-- relay instead are the STROKES: batched (position, previous position, brush radius) triples,
-- which the receiving client replays onto its own overlay for that wall (see JobController ->
-- SurfaceManager.applyRemoteStroke). Every member erases the same brush path over the same
-- starting dirt, so their images stay in step -- and because each client's own wall completion
-- moves with it, so does the shared completion bar. The server stays out of the pixels: it only
-- checks the wall belongs to the sender's job and passes the strokes on.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local SurfaceResolver = require(ReplicatedStorage.SharedModules.SurfaceResolver)
local JobService = require(script.Parent.JobService)
local ProgressionService = require(script.Parent.ProgressionService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CleanProgress = Remotes:WaitForChild("CleanProgress") :: RemoteEvent
local WallCleaned = Remotes:WaitForChild("WallCleaned") :: RemoteEvent
local WallStroke = Remotes:WaitForChild("WallStroke") :: RemoteEvent

-- Most strokes we relay from a single WallStroke message. The client batches ~10 messages a
-- second and only sends while the trigger is actually erasing, so an honest batch is a handful
-- of entries; this just bounds what a forged one can cost the other members' clients.
local MAX_STROKES_PER_MESSAGE = 60
-- Ceiling (studs) on a relayed brush radius. Comfortably above any upgraded washer, and far below
-- "erase the whole wall in one stamp" -- see the relay handler.
local MAX_STROKE_RADIUS = 16

-- Reward paid for each second of actively erasing dirt from a wall (the EditableImage overlays).
-- WASH_COOLDOWN is the server-enforced minimum gap between payouts, so a client can't earn faster
-- by sending CleanProgress more often.
local WASH_XP = 1
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

	-- A batch of erase strokes from one member of a party job, to be replayed on the other
	-- members' overlays. Each entry is { part, to, from?, radius }. We validate the shape and the
	-- wall (it must belong to the job the sender holds -- resolveForJob, exactly as above), then
	-- pass the surviving entries to everyone else on the session. Nothing is relayed for a solo
	-- job, so a lone player's strokes never leave their own client.
	--
	-- The brush radius is taken from the sender because it's THEIR tool's reach (upgrades + the
	-- RadiusMaster skill) that decided how wide the stroke was. It's clamped so a forged radius
	-- can't have every other client erase a whole wall in one stamp -- the real cost of a bad
	-- value lands on the receivers, not the sender.
	WallStroke.OnServerEvent:Connect(function(player, strokes)
		if type(strokes) ~= "table" then
			return
		end
		local others = JobService.getOtherMembers(player)
		if #others == 0 then
			return
		end

		local relay = {}
		for _, stroke in strokes :: { any } do
			if #relay >= MAX_STROKES_PER_MESSAGE then
				break
			end
			if
				type(stroke) == "table"
				and typeof(stroke.to) == "Vector3"
				and (stroke.from == nil or typeof(stroke.from) == "Vector3")
				and type(stroke.radius) == "number"
				and resolveForJob(player, stroke.part)
			then
				table.insert(relay, {
					part = stroke.part,
					to = stroke.to,
					from = stroke.from,
					radius = math.clamp(stroke.radius, 0, MAX_STROKE_RADIUS),
				})
			end
		end
		if #relay == 0 then
			return
		end
		for _, member in others do
			WallStroke:FireClient(member, relay)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastWashReward[player] = nil
	end)
end

return CleaningService
