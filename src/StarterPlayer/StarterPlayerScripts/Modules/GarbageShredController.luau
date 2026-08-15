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
--   * THE SOUND -- ShredderSFX starts the moment the piece reaches the mouth and is cut off the
--     instant the piece is gone: the machine is only ever heard chewing something. It's played out
--     of the hitbox (positional), so it belongs to the machine rather than to the player.
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

-- Pieces currently mid-animation. They're no longer GarbageVisibility's, so if the job ends under
-- them (the last piece of a job completes it) nothing else would ever clean them up.
local inFlight: { [PVInstance]: boolean } = {}

local function destroyInFlight(piece: PVInstance)
	inFlight[piece] = nil
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
-- Yields until done (or until the piece is gone). Runs off Heartbeat rather than a Tween because a
-- Model has no tweenable CFrame property, and the shake has to be re-randomised every frame.
local function glide(piece: PVInstance, from: CFrame, to: CFrame, seconds: number, shake: boolean)
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
	end
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
	-- Ours from here: nothing else may carry, hover or reset it.
	local piece = GarbageVisibility.takePiece(surfaceId)
	if not piece then
		return
	end
	inFlight[piece] = true
	freeze(piece)

	task.spawn(function()
		local entry = shredder.entry.CFrame
		local exit = shredder.exit.CFrame

		glide(piece, piece:GetPivot(), entry, Config.GarbageShredEntrySeconds, false)
		if not piece.Parent then
			return
		end

		-- At the mouth: the machine starts chewing. Out of the hitbox rather than 2D, so it's the
		-- MACHINE that's audible -- it fades with distance, and a party member across the building
		-- hears it from where it actually is.
		local sound = SoundManager.playAt(Config.ShredderSoundName, shredder.hitbox)
		task.wait(Config.GarbageShredHoldSeconds)

		if piece.Parent then
			glide(piece, entry, exit, Config.GarbageShredDropSeconds, true)
		end

		-- Gone, and the sound with it: the machine only makes noise while there's something in it.
		if sound then
			sound:Stop()
			sound:Destroy()
		end
		if not piece.Parent then
			-- Torn down under us (the job ended mid-animation); it's already been forgotten.
			return
		end
		destroyInFlight(piece)
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
	GarbageCleaned.OnClientEvent:Connect(function(surfaceId)
		if type(surfaceId) ~= "string" then
			return
		end
		shred(surfaceId)
	end)

	local function sync()
		local id = localPlayer:GetAttribute(Config.ActiveJobAttribute)
		setActiveBusiness(if type(id) == "string" then id else nil)
	end
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(sync)
	sync()
end

return GarbageShredController
