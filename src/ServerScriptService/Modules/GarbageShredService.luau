--!strict

-- Server side of CLEANING cleanable garbage, and the authority over it. Carrying a piece is only
-- half the mechanic (see GarbageCarryService); this is the other half -- getting rid of it.
--
-- Every business with cleanable garbage authors a SHREDDER (see ShredderResolver). Walking a carried
-- piece into its hitbox feeds it in: the piece leaves the carrier's hands, gets dragged down through
-- the machine, and is gone.
--
-- WHO NOTICES THE TOUCH. Garbage is the one cleanable that isn't a shared instance -- each client
-- works with its own local clone (GarbageVisibility), so the collision can only be seen client-side,
-- by whoever is simulating the piece. Their client reports it (ShredGarbage) and this service
-- decides whether it counts: the piece has to be real garbage of the business they're on the job
-- for, not already cleaned, and not already going through the machine. That last one matters because
-- a piece is reported by every client that sees its own copy hit the hitbox, and a party shares one
-- JobServer -- so a session's in-flight pieces are tracked here and a second report is ignored.
--
-- WHAT EVERYONE SEES. Nobody's clone can be moved from here, so the confirmation (GarbageCleaned)
-- goes to every member of the session and each client runs the disposal animation on its OWN clone.
-- That's what makes a party watch the same piece get shredded.
--
-- WHEN IT COUNTS. The reward and the mark against the job land only once the animation has finished
-- (the three beats in CleaningConfig), so the completion bar ticks as the piece disappears rather
-- than as it starts moving -- and a piece that completes the job doesn't end the job out from under
-- its own animation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local ShredderResolver = require(ReplicatedStorage.SharedModules.ShredderResolver)
local GarbageCarryService = require(script.Parent.GarbageCarryService)
local JobService = require(script.Parent.JobService)
local ProgressionService = require(script.Parent.ProgressionService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
-- Client -> server: "my copy of this piece went into the shredder".
local ShredGarbage = Remotes:WaitForChild("ShredGarbage") :: RemoteEvent
-- Server -> every client on the session: (surfaceId) -- run the disposal animation on your clone.
local GarbageCleaned = Remotes:WaitForChild("GarbageCleaned") :: RemoteEvent

-- Reward paid once per piece shredded (matches a web's / stain's per-clean reward).
local GARBAGE_XP = 4
local GARBAGE_CASH = 4

-- How long the client's disposal animation takes, start to finish. Kept in sync with it by both
-- reading the same config.
local SHRED_SECONDS = Config.GarbageShredEntrySeconds + Config.GarbageShredHoldSeconds + Config.GarbageShredDropSeconds

local GarbageShredService = {}

-- Pieces currently going through a session's shredder: JobServer -> { [surfaceId]: true }. Keyed
-- WEAKLY, exactly like GarbageCarryService's sessions -- when a session ends its JobServer becomes
-- garbage and this goes with it. Its whole job is to swallow the duplicate reports a party produces
-- (one per member's clone) and any repeat from a single client during the animation.
local shredding: { [any]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

local function onShred(player: Player, surfaceId: string)
	local businessId = JobService.getActiveJob(player)
	local job = JobService.getJob(player)
	if not businessId or not job then
		return
	end
	-- A real piece of THIS building's garbage, not one already dealt with on this job.
	if not GarbageCarryService.isPiece(businessId, surfaceId) or job:isGarbageCleaned(surfaceId) then
		return
	end
	-- The building has to actually have a shredder to have fed it into.
	if not ShredderResolver.find(businessId) then
		return
	end

	local inFlight = shredding[job]
	if not inFlight then
		inFlight = {}
		shredding[job] = inFlight
	end
	if inFlight[surfaceId] then
		return
	end
	inFlight[surfaceId] = true

	-- It belongs to the machine now, not to whoever was holding it.
	GarbageCarryService.dropPiece(player, surfaceId)

	-- Every member animates their own clone; the piece is only ever gone locally.
	for _, member in JobService.getSessionMembers(player) do
		GarbageCleaned:FireClient(member, surfaceId)
	end

	-- Count it once the piece has actually vanished (see the header).
	task.delay(SHRED_SECONDS, function()
		inFlight[surfaceId] = nil
		if not job.alive then
			return
		end
		ProgressionService.reward(player, GARBAGE_XP, GARBAGE_CASH)
		job:markGarbageCleaned(surfaceId)
	end)
end

function GarbageShredService.init()
	ShredGarbage.OnServerEvent:Connect(function(player, surfaceId)
		if type(surfaceId) ~= "string" then
			return
		end
		onShred(player, surfaceId)
	end)
end

return GarbageShredService
