--!strict

-- Client side of CLEANING cleanable garbage: feeding a piece into the business's shredder. This is
-- the other half of GarbageCarryController (which only picks pieces up and carries them around).
--
--   * THE TOUCH -- while on a job we watch that building's shredder hitbox (see ShredderResolver).
--     Garbage is the one cleanable that is a LOCAL clone rather than a shared instance, so the
--     collision only exists on the machine simulating the piece: we notice our own clone go in and
--     tell the server (ShredGarbage), which is the authority on whether it counts.
--   * THE ANIMATION -- the server answers on GarbageCleaned, to every member of the session. Each
--     client then runs the disposal on its OWN clone, which is what lets a party watch the same
--     piece get shredded. The piece is taken out of GarbageVisibility first (so nothing can carry,
--     hover or idle-reset something that's already in the machine) and this module owns the instance
--     from there: it snaps to the mouth (p1), holds for a beat, then gets dragged down to p2 shaking
--     violently, and is destroyed.
--   * THE QUEUE -- the machine only chews one piece at a time, so a piece accepted while it's busy
--     arrives with its place in the line instead (GarbageCleaned's second argument). Those pieces
--     hover in a vertical column above the mouth, lowest first, and step down a slot each time the
--     machine takes one. The column is laid out from the pieces' BOUNDING BOXES rather than their
--     pivots, so every neighbour is left GarbageQueueGapStuds of clear air whatever shape it is --
--     nothing in the line ever touches its neighbour or the piece being chewed below it. Waiting
--     pieces are frozen exactly like an animating one, so they can't be carried, hovered, bumped,
--     or re-fed into the hitbox they're floating over.
--   * THE FEED SOUND -- a 2D whoosh (GarbageFeedSoundName) the moment the machine ACCEPTS a piece,
--     queued or not. It's feedback for the player's own action, so unlike the machine's sound it's
--     played only for whoever walked that piece in -- never for the rest of the party, who are told
--     about the acceptance all the same.
--   * THE SOUND + DEBRIS -- both cover the DESCENT only (p1 -> p2), the beat where the piece is
--     actually being chewed. ShredderSFX plays out of the hitbox (positional), so it belongs to the
--     machine rather than to the player, and is cut off the instant the piece is gone; a shower of
--     yellow flecks (VfxManager.shredDebris) rides the piece down and falls away from it.
--
-- Nothing here decides that a piece is clean. The server counts it (GarbageShredService), on its own
-- timer of the same length, so the completion bar ticks as the piece disappears.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local GarbageResolver = require(ReplicatedStorage.SharedModules.GarbageResolver)
local ShredderResolver = require(ReplicatedStorage.SharedModules.ShredderResolver)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local VfxManager = require(ReplicatedStorage.SharedModules.VfxManager)
local GarbageVisibility = require(script.Parent.GarbageVisibility)
local JobController = require(script.Parent.JobController)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShredGarbage = Remotes:WaitForChild("ShredGarbage") :: RemoteEvent
local GarbageCleaned = Remotes:WaitForChild("GarbageCleaned") :: RemoteEvent

local localPlayer = Players.LocalPlayer

-- The shake as the piece is dragged through the blades: a fresh random offset every frame. It is
-- deliberately SIDE TO SIDE -- along the piece's own X axis, with only a hint of vertical and
-- nothing in/out -- so the piece reads as being fought over by the blades while its descent stays
-- steady. (Much vertical jitter fights the p1 -> p2 travel and just looks like the piece is
-- glitching, hence the far smaller figure.) The rotation is a token wobble on top, small enough
-- never to read as tumbling.
local SHAKE_STUDS = 0.22
local SHAKE_VERTICAL_STUDS = 0.11
local SHAKE_RADIANS = math.rad(1.2)

-- How long a business's shredder is waited for when a job starts. The building is already
-- replicated by the time a job can be accepted; this only covers a cold join racing the stream-in.
local SHREDDER_WAIT_SECONDS = 10
local SHREDDER_RETRY_INTERVAL = 0.5

-- The names GarbageCarryController parents its drag onto a piece under. A piece can be fed in at the
-- exact moment we're still dragging it, so the animation tears these off itself rather than trusting
-- the server's drop to have reached us first. Only these names: the piece's own authored attachments
-- (welds, particles) have to survive.
local CARRY_INSTANCE_NAMES = { "GarbageCarryPosition", "GarbageCarryOrientation", "GarbageCarryAttachment" }

local GarbageShredController = {}

-- The active job's business, and the connection watching its shredder hitbox. Both are torn down
-- and rebuilt whenever the job changes.
local activeBusinessId: string? = nil
local hitboxConnection: RBXScriptConnection? = nil

-- surfaceIds we've already reported this job, so the several Touched events one piece produces as it
-- settles into the hitbox don't turn into several requests. Cleared with the job.
local reported: { [string]: boolean } = {}

-- Pieces currently mid-animation OR waiting in the queue above the mouth. They're no longer
-- GarbageVisibility's, so if the job ends under them (the last piece of a job completes it) nothing
-- else would ever clean them up.
local inFlight: { [PVInstance]: boolean } = {}

-- The waiting line above the mouth: the surfaceIds in it, bottom (next to go in) first, and each
-- one's clone. Kept in step with the server's queue -- it appends, and the machine takes from the
-- front -- so our order is its order.
local queueOrder: { string } = {}
local queuedPieces: { [string]: PVInstance } = {}
-- The rotation each waiting piece hovers at: the one it was AUTHORED with, not the one it happened
-- to be carried in. Every client computes the column's spacing from these, so taking the authored
-- rotation is what makes a party's lines identical rather than each member's slightly different.
local queuedRotation: { [string]: CFrame } = {}
-- Bumped per piece whenever it's given a new slot, so a shuffle that starts while the last one is
-- still playing cancels it instead of two moves fighting over the same piece.
local slotToken: { [PVInstance]: number } = {}

-- What the machine is chewing right now, and how tall it stands: the bottom of the column is held
-- clear of it, so the piece waiting its turn never hangs inside the one going down.
local activeId: string? = nil
local activeHeight = 0

local function destroyInFlight(piece: PVInstance)
	inFlight[piece] = nil
	slotToken[piece] = nil
	piece:Destroy()
end

-- Take the piece out of the physics simulation entirely: the animation drives its pivot directly, so
-- anything that could move it or be moved by it has to go first. That includes the carry constraints
-- (ours if we were the one holding it -- the server's drop reaches us first, but a piece is fed in at
-- exactly the moment we're still dragging it, so don't rely on the ordering).
local function freeze(piece: PVInstance)
	for _, part in GarbageResolver.getParts(piece) do
		-- Only OUR constraints, by the names GarbageCarryController builds them under -- a piece may
		-- have authored attachments (welds, particles) that have to survive.
		for _, name in CARRY_INSTANCE_NAMES do
			local child = part:FindFirstChild(name)
			if child then
				child:Destroy()
			end
		end
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end
end

-- Drive `piece`'s pivot from `from` to `to` over `seconds`, optionally jittering it about the path.
-- `follow` (if given) is called with each pivot, so an effect can ride along. Yields until done (or
-- until the piece is gone). Runs off Heartbeat rather than a Tween because a Model has no tweenable
-- CFrame property, and the shake has to be re-randomised every frame.
local function glide(
	piece: PVInstance,
	from: CFrame,
	to: CFrame,
	seconds: number,
	shake: boolean,
	follow: ((CFrame) -> ())?
)
	local elapsed = 0
	while elapsed < seconds do
		elapsed += RunService.Heartbeat:Wait()
		if not piece.Parent then
			return
		end
		local alpha = math.min(elapsed / seconds, 1)
		local pivot = from:Lerp(to, alpha)
		if shake then
			-- Side to side (local X), a hint of vertical, nothing in/out -- see SHAKE_STUDS.
			pivot = pivot
				* CFrame.new(
					(math.random() * 2 - 1) * SHAKE_STUDS,
					(math.random() * 2 - 1) * SHAKE_VERTICAL_STUDS,
					0
				)
				* CFrame.Angles(
					(math.random() * 2 - 1) * SHAKE_RADIANS,
					(math.random() * 2 - 1) * SHAKE_RADIANS,
					(math.random() * 2 - 1) * SHAKE_RADIANS
				)
		end
		piece:PivotTo(pivot)
		if follow then
			follow(pivot)
		end
	end
end

-- How tall a piece stands in WORLD terms while hovering at `rotation` -- the vertical extent of its
-- bounding box, which is what the gaps in the column are measured between.
--
-- Not simply the box's own Y: a piece authored on its side or at a tilt stands taller (or shorter)
-- than its box says, and using the wrong figure is exactly how two pieces end up overlapping. This
-- is the standard "how tall is a rotated box" sum -- each of its three axes contributes as much
-- height as that axis is turned toward vertical.
local function worldHeight(piece: PVInstance, rotation: CFrame): number
	local size: Vector3
	if piece:IsA("Model") then
		local _, extents = piece:GetBoundingBox()
		size = extents
	else
		size = (piece :: BasePart).Size
	end
	return math.abs(rotation.RightVector.Y) * size.X
		+ math.abs(rotation.UpVector.Y) * size.Y
		+ math.abs(rotation.LookVector.Y) * size.Z
end

-- Float a waiting piece to `target` over GarbageQueueTravelSeconds, cancelling any move it was
-- already making. Doesn't yield: several pieces shuffle down at once.
local function slideToSlot(piece: PVInstance, target: CFrame)
	local token = (slotToken[piece] or 0) + 1
	slotToken[piece] = token

	task.spawn(function()
		local from = piece:GetPivot()
		local seconds = Config.GarbageQueueTravelSeconds
		local elapsed = 0
		while elapsed < seconds do
			elapsed += RunService.Heartbeat:Wait()
			-- Gone, or given a newer slot (or fed into the machine) while we were moving it.
			if not piece.Parent or slotToken[piece] ~= token then
				return
			end
			piece:PivotTo(from:Lerp(target, math.min(elapsed / seconds, 1)))
		end
	end)
end

-- Stack the waiting pieces up the column above the mouth and send each to its slot. Called whenever
-- the line changes: a piece joins the back, or the machine takes the one at the front and everything
-- behind it steps down.
--
-- Heights are accumulated as we climb, so the gap between any two neighbours is exactly
-- GarbageQueueGapStuds of clear air regardless of their sizes. The bottom of the column clears
-- whatever the machine is holding -- or the mouth itself, whichever is taller, which is also what
-- covers a piece we have no clone of (a member who joined mid-job).
local function layoutQueue(shredder: ShredderResolver.Shredder)
	local entry = shredder.entry
	local top = entry.Position.Y + math.max(activeHeight / 2, entry.Size.Y / 2)

	for _, surfaceId in queueOrder do
		local piece = queuedPieces[surfaceId]
		local rotation = queuedRotation[surfaceId]
		if not piece or not piece.Parent or not rotation then
			continue
		end
		local height = worldHeight(piece, rotation)
		top += Config.GarbageQueueGapStuds + height / 2
		slideToSlot(piece, CFrame.new(entry.Position.X, top, entry.Position.Z) * rotation)
		top += height / 2
	end
end

-- Take a piece out of the line (it's about to go down the machine). No-op for one that was never in
-- it -- a piece fed into an idle machine goes straight from the player's hands to the mouth.
local function leaveQueue(surfaceId: string)
	local index = table.find(queueOrder, surfaceId)
	if index then
		table.remove(queueOrder, index)
	end
	queuedPieces[surfaceId] = nil
	queuedRotation[surfaceId] = nil
end

-- The "that went in" whoosh, for the player who actually fed the piece in. Played 2D, because it's
-- feedback for THEIR action rather than a noise the machine makes -- the machine's own sound is the
-- positional one that runs during the descent.
--
-- `reported` holds exactly the surfaceIds THIS client pushed into the hitbox, and every member of a
-- party gets told about every acceptance on the session, so this gate is what keeps a member's feed
-- from whooshing in everyone else's ears.
local function feedSound(surfaceId: string)
	if reported[surfaceId] then
		SoundManager.playOneShot(Config.GarbageFeedSoundName)
	end
end

-- The machine accepted this piece but is still busy: park our clone in the line above the mouth, at
-- the place in it the server gave us. Like a shred, this takes the piece out of GarbageVisibility --
-- it's waiting to be destroyed, not lying around to be picked back up.
local function park(surfaceId: string, index: number)
	local businessId = activeBusinessId
	if not businessId or queuedPieces[surfaceId] then
		return
	end
	local shredder = ShredderResolver.find(businessId)
	if not shredder then
		return
	end
	-- Read the authored rotation BEFORE taking the piece, which forgets it.
	local home = GarbageVisibility.getHome(surfaceId)
	local piece = GarbageVisibility.takePiece(surfaceId)
	if not piece then
		return
	end
	inFlight[piece] = true
	freeze(piece)
	feedSound(surfaceId)

	queuedPieces[surfaceId] = piece
	queuedRotation[surfaceId] = if home then home.Rotation else piece:GetPivot().Rotation
	table.insert(queueOrder, math.clamp(index, 1, #queueOrder + 1), surfaceId)
	layoutQueue(shredder)
end

-- The server says this piece went into the shredder: run the disposal on our clone of it. Safe to
-- call for a piece we don't have (a member who joined the session mid-job) -- it just does nothing.
local function shred(surfaceId: string)
	local businessId = activeBusinessId
	if not businessId then
		return
	end
	local shredder = ShredderResolver.find(businessId)
	if not shredder then
		return
	end
	-- Already hovering in the line (the common case once a second piece has been fed in), or coming
	-- straight from a player's hands into an idle machine -- in which case it becomes ours here, and
	-- nothing else may carry, hover or reset it from now on.
	local waiting = queuedPieces[surfaceId]
	local rotation = queuedRotation[surfaceId]
	local piece: PVInstance
	if waiting then
		leaveQueue(surfaceId)
		-- Cancel the slot move it may still have been making, so nothing tugs at it once the
		-- disposal has it.
		slotToken[waiting] = (slotToken[waiting] or 0) + 1
		piece = waiting
	else
		local taken = GarbageVisibility.takePiece(surfaceId)
		if not taken then
			return
		end
		inFlight[taken] = true
		freeze(taken)
		-- Straight from the player's hands into an idle machine: this is the piece being accepted,
		-- so it's the beat the feed sound belongs to. (A piece that WAITED already played it when it
		-- joined the queue -- going in isn't a second acceptance.)
		feedSound(surfaceId)
		piece = taken
	end

	-- Hold the rest of the line clear of this piece for as long as it's in the machine; it steps down
	-- once the piece is gone.
	activeId = surfaceId
	activeHeight = worldHeight(piece, rotation or piece:GetPivot().Rotation)
	layoutQueue(shredder)

	task.spawn(function()
		local entry = shredder.entry.CFrame
		local exit = shredder.exit.CFrame

		glide(piece, piece:GetPivot(), entry, Config.GarbageShredEntrySeconds, false)
		if not piece.Parent then
			return
		end

		-- Sat at the mouth for a beat before the machine takes it, but with the SFX starting a little
		-- BEFORE the drop (GarbageShredSoundLeadSeconds): the file opens on the machine spinning up,
		-- so this lands its bite on the moment the piece actually moves. Positional, out of the
		-- hitbox rather than 2D, so it's the MACHINE that's audible -- it fades with distance, and a
		-- party member across the building hears it from where it actually is.
		local lead = math.min(Config.GarbageShredSoundLeadSeconds, Config.GarbageShredHoldSeconds)
		task.wait(Config.GarbageShredHoldSeconds - lead)
		local sound: Sound? = if piece.Parent
			then SoundManager.playAt(Config.ShredderSoundName, shredder.hitbox)
			else nil
		task.wait(lead)

		-- The descent is the beat where it's actually being chewed, so it's the only one with debris:
		-- a shower of yellow flecks riding the piece down and falling away from it, which outlives
		-- the piece by a fleck's lifetime so the last of it is still in the air as the piece vanishes
		-- (see VfxManager.shredDebris).
		if piece.Parent then
			local debris = VfxManager.shredDebris(entry)
			glide(piece, entry, exit, Config.GarbageShredDropSeconds, true, debris.move)
			debris.stop()
		end

		-- Gone, and the sound with it: the machine only makes noise while there's something in it.
		if sound then
			sound:Stop()
			sound:Destroy()
		end

		-- The mouth is clear, so the line can drop a slot. Guarded on still being the piece in the
		-- machine: the server feeds the next one the instant this one is counted, so its message can
		-- land before we get here -- and that piece's clearance is the one that should stand.
		if activeId == surfaceId then
			activeId = nil
			activeHeight = 0
			layoutQueue(shredder)
		end

		if not piece.Parent then
			-- Torn down under us (the job ended mid-animation); it's already been forgotten.
			return
		end
		destroyInFlight(piece)

		-- Payout beat: coins burst out of the machine's mouth and fly into the player, as the piece
		-- disappears. Only for a piece WE fed in -- `reported` holds exactly the surfaceIds this
		-- client pushed into the hitbox, and every member animates this same disposal on their own
		-- clone, so without the gate a party member's shred would pay us coins too.
		if reported[surfaceId] then
			VfxManager.rewardBurst(entry.Position)
		end

		-- Count it toward the completion bar as it vanishes, which is the moment the server counts it
		-- too (GarbageShredService waits out the same three beats before marking it).
		JobController.onGarbageCleaned(surfaceId)
	end)
end

-- One of our clones hit the hitbox. Report it and let the server decide; it answers on
-- GarbageCleaned (to us and the rest of the party) if it counts.
local function onHitboxTouched(hit: BasePart)
	local businessId = activeBusinessId
	if not businessId then
		return
	end
	local identity = GarbageResolver.resolve(hit)
	if not identity or identity.businessId ~= businessId or reported[identity.surfaceId] then
		return
	end
	-- Only our own clone of a piece on this job counts -- never the off-world authored template, and
	-- never a piece belonging to some other business.
	if GarbageVisibility.getPiece(identity.surfaceId) ~= identity.garbage then
		return
	end
	reported[identity.surfaceId] = true
	ShredGarbage:FireServer(identity.surfaceId)
end

-- Point the watcher at a job's shredder, or nowhere (nil). Also throws away anything still animating
-- from the previous job: those pieces are ours alone, so nothing else would clean them up.
local function setActiveBusiness(businessId: string?)
	if hitboxConnection then
		hitboxConnection:Disconnect()
		hitboxConnection = nil
	end
	activeBusinessId = businessId
	table.clear(reported)
	-- The line goes with the job: its pieces are in inFlight, so the sweep below is what actually
	-- destroys them.
	table.clear(queueOrder)
	table.clear(queuedPieces)
	table.clear(queuedRotation)
	table.clear(slotToken)
	activeId = nil
	activeHeight = 0
	for piece in inFlight do
		if piece.Parent then
			piece:Destroy()
		end
	end
	table.clear(inFlight)

	if not businessId then
		return
	end

	-- The building may still be streaming in on a cold join; keep looking for a little while. A
	-- business with no cleanable garbage authors no shredder, so giving up is a normal outcome.
	task.spawn(function()
		local deadline = os.clock() + SHREDDER_WAIT_SECONDS
		while activeBusinessId == businessId do
			local shredder = ShredderResolver.find(businessId)
			if shredder then
				-- Guard the re-entry: the job may have changed while we yielded.
				if activeBusinessId ~= businessId or hitboxConnection then
					return
				end
				hitboxConnection = shredder.hitbox.Touched:Connect(onHitboxTouched)
				return
			end
			if os.clock() > deadline then
				return
			end
			task.wait(SHREDDER_RETRY_INTERVAL)
		end
	end)
end

function GarbageShredController.init()
	-- A queueIndex means the machine took the piece but is still busy: it waits in the line above the
	-- mouth. No index means it's going down now.
	GarbageCleaned.OnClientEvent:Connect(function(surfaceId, queueIndex)
		if type(surfaceId) ~= "string" then
			return
		end
		if type(queueIndex) == "number" then
			park(surfaceId, queueIndex)
		else
			shred(surfaceId)
		end
	end)

	local function sync()
		local id = localPlayer:GetAttribute(Config.ActiveJobAttribute)
		setActiveBusiness(if type(id) == "string" then id else nil)
	end
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(sync)
	sync()
end

return GarbageShredController
