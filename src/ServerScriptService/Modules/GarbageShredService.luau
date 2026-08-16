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
-- for, not already cleaned, and not already taken by the machine. That last one matters because a
-- piece is reported by every client that sees its own copy hit the hitbox, and a party shares one
-- JobServer -- so a session's accepted pieces are tracked here and a second report is ignored.
--
-- WHAT EVERYONE SEES. Nobody's clone can be moved from here, so the confirmation (GarbageCleaned)
-- goes to every member of the session and each client runs the disposal animation on its OWN clone.
-- That's what makes a party watch the same piece get shredded.
--
-- ONE AT A TIME. The machine chews a single piece from start to finish, so a session's shredder is a
-- QUEUE: anything reported while it's busy waits its turn rather than going down alongside. This
-- matters most for a PARTY, where several members can walk pieces into the same machine at once --
-- without it their animations overlap inside the one shredder and the sound stacks on itself.
--
-- A queued piece is NOT taken from its carrier when it's reported -- only when the machine actually
-- accepts it. Until then it stays in their hands, where it already is, rather than being dropped by
-- the machine's mouth to wait on the floor (where it could be walked off with, or shoved around by
-- the next player feeding theirs in).
--
-- WHEN IT COUNTS. The reward and the mark against the job land only once the animation has finished
-- (the three beats in CleaningConfig), so the completion bar ticks as the piece disappears rather
-- than as it starts moving -- and a piece that completes the job doesn't end the job out from under
-- its own animation. That same beat is when the machine takes whatever is next in the queue.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local ShredderResolver = require(ReplicatedStorage.SharedModules.ShredderResolver)
local GarbageCarryService = require(script.Parent.GarbageCarryService)
local JobServer = require(script.Parent.JobServer)
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

-- A piece waiting its turn: what it is, and who fed it in -- they're the one paid for it, whenever it
-- eventually goes through.
type Pending = {
	surfaceId: string,
	player: Player,
}

-- A session's shredder: what's in it, what's lined up behind it, and every piece it has accepted.
-- Keyed by JobServer, WEAKLY, exactly like GarbageCarryService's sessions -- when a session ends its
-- JobServer becomes garbage and its machine goes with it, so nothing has to be swept up by hand.
--
-- `accepted` is what swallows repeat reports: a party produces one per member's clone, and a single
-- client keeps producing them for as long as its piece sits in the queue touching the hitbox.
type Machine = {
	active: string?,
	queue: { Pending },
	accepted: { [string]: boolean },
}
local machines: { [any]: Machine } = setmetatable({}, { __mode = "k" }) :: any

local function machineFor(job: JobServer.JobServer): Machine
	local machine = machines[job]
	if not machine then
		machine = { active = nil, queue = {}, accepted = {} }
		machines[job] = machine
	end
	return machine
end

-- Take the next piece in, if the machine is free and anything is waiting. This is the moment a piece
-- stops being its carrier's -- until now it has been waiting in their hands.
local function feedNext(job: JobServer.JobServer, machine: Machine)
	if machine.active then
		return
	end
	local nextUp = table.remove(machine.queue, 1)
	if not nextUp then
		return
	end
	if not job.alive then
		-- The session ended under the queue; there's nobody left to animate anything for.
		table.clear(machine.queue)
		return
	end
	machine.active = nextUp.surfaceId

	-- It belongs to the machine now, not to whoever was holding it.
	GarbageCarryService.dropPiece(nextUp.player, nextUp.surfaceId)

	-- Every member animates their own clone; the piece is only ever gone locally. Taken off the JOB
	-- rather than off the feeder, who may have left the session while their piece waited.
	for _, member in job:getMembers() do
		GarbageCleaned:FireClient(member, nextUp.surfaceId)
	end

	-- Count it once the piece has actually vanished (see the header) -- which is also the moment the
	-- machine is free for whatever is next.
	task.delay(SHRED_SECONDS, function()
		machine.active = nil
		if job.alive then
			ProgressionService.reward(nextUp.player, GARBAGE_XP, GARBAGE_CASH)
			job:markGarbageCleaned(nextUp.surfaceId)
		end
		feedNext(job, machine)
	end)
end

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

	local machine = machineFor(job)
	if machine.accepted[surfaceId] then
		return
	end
	machine.accepted[surfaceId] = true
	table.insert(machine.queue, { surfaceId = surfaceId, player = player })

	-- Straight in if the machine is idle; otherwise it waits its turn in the carrier's hands.
	feedNext(job, machine)
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
