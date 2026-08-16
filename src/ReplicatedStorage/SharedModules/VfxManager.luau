--!strict

-- Central library of cosmetic visual effects. Lives in ReplicatedStorage so any
-- context can require it, BUT its effects are CLIENT-EXECUTED only: they spawn
-- instances into Workspace, and a client-created instance is visible only to the
-- local player (never replicated). If the SERVER ran one, the instance would
-- replicate to everyone -- so each effect guards against running on the server.
--
-- For the server to trigger an effect, fire a RemoteEvent to the target client and
-- have a client-side listener call the matching function here. The server must not
-- call these directly.
--
-- Effects are fire-and-forget: each fully owns and cleans up whatever it spawns
-- (tweens + temporary instances), so callers just call and forget.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local SoundManager = require(script.Parent.SoundManager)

local VfxManager = {}

-- "Clean pop": a neon-yellow duplicate of a just-cleaned part that briefly swells
-- past the original then settles back, reading as a bright outline flash.
local POP_COLOR = Color3.fromRGB(223, 223, 16)
local POP_PEAK_SCALE = 1.06 -- size at the peak of the swell, relative to real size
local POP_SETTLE_SCALE = 1.01 -- size it settles to after the swell
local POP_GROW_TIME = 0.28 -- seconds: normal -> peak
local POP_PEAK_HOLD = 0.045 -- seconds held at the peak before shrinking
local POP_SHRINK_TIME = 0.13 -- seconds: peak -> settle
local POP_SETTLE_HOLD = 0.05 -- seconds held at the settle size before removal

-- Plays the clean-pop flash on `part`. The part itself is untouched; we animate a
-- throwaway neon clone so nothing about the real wall changes.
function VfxManager.cleanPop(part: BasePart)
	-- Client-only: a server-spawned clone would replicate to every player.
	if not RunService:IsClient() then
		warn("VfxManager.cleanPop called on the server; VFX must run on the client")
		return
	end

	local clone = part:Clone() :: BasePart
	-- Strip decals/attachments/etc. so it's a bare neon shell. (A MeshPart keeps its
	-- mesh -- that's intrinsic, not a child -- so the shape is preserved.)
	clone:ClearAllChildren()
	clone.Name = "CleanPopVfx"
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.CastShadow = false
	clone.Material = Enum.Material.Neon
	clone.Color = POP_COLOR
	clone.Transparency = 0.63
	if clone:IsA("MeshPart") then
		clone.TextureID = "" -- a mesh texture would tint the neon glow
	end

	local baseSize = part.Size
	clone.Size = baseSize
	clone.CFrame = part.CFrame -- grows symmetrically about the part's center
	clone.Parent = Workspace -- client-only instance => only this player sees it

	local grow = TweenService:Create(
		clone,
		TweenInfo.new(POP_GROW_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = baseSize * POP_PEAK_SCALE }
	)
	local shrink = TweenService:Create(
		clone,
		TweenInfo.new(POP_SHRINK_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Size = baseSize * POP_SETTLE_SCALE }
	)

	-- grow -> hold at peak -> shrink -> hold at settle -> remove.
	grow.Completed:Connect(function()
		task.delay(POP_PEAK_HOLD, function()
			shrink:Play()
		end)
	end)
	shrink.Completed:Connect(function()
		task.delay(POP_SETTLE_HOLD, function()
			clone:Destroy()
		end)
	end)
	grow:Play()
end

-- "Shred debris": a shower of small yellow flecks thrown outward and dragged straight back down, as
-- if something were being chewed up at the emitter's position. Unlike cleanPop this one is NOT
-- fire-and-forget -- it runs for as long as the thing making it is running -- so it returns a handle
-- the caller drives (see DebrisEffect below).
--
-- The flecks are emitted from a throwaway invisible part of our own rather than from the object
-- being destroyed, for two reasons: the object may be a Model (with no obvious part to attach to),
-- and destroying it would take every particle still in the air with it -- the shower has to outlive
-- the thing that made it by the length of a fleck's life.
--
-- A MIX of yellows is done with one emitter per colour: a ParticleEmitter's ColorSequence varies a
-- particle over its own lifetime, not from particle to particle, so a single emitter can only ever
-- produce one colour of fleck at a time. The range runs from almost-white down to a dark bronze --
-- the darker end is what stops the shower reading as a single flat yellow blob and gives it depth.
--
-- NOTE: DEBRIS_RATE is PER COLOUR, so adding an entry here adds that many more particles per second
-- to the shower. Divide the rate when you lengthen this list, or the density jumps with it.
local DEBRIS_COLORS = {
	Color3.fromRGB(255, 241, 148), -- pale, almost white-hot
	Color3.fromRGB(255, 214, 51), -- golden yellow
	Color3.fromRGB(240, 186, 40), -- deeper gold
	Color3.fromRGB(226, 158, 33), -- amber
	Color3.fromRGB(184, 121, 26), -- bronze
	Color3.fromRGB(138, 88, 20), -- dark bronze, nearly brown
}
-- Solid SQUARE flecks, not the fuzzy star a ParticleEmitter defaults to (sparkles_main) -- chips off
-- something being chewed up, not sparkles. A 32x32 image of pure opaque white, which is what lets
-- DEBRIS_COLORS tint it: a particle's Color MULTIPLIES the texture, so pure white reproduces each
-- colour below exactly, while a dark or semi-transparent source couldn't be tinted bright at all.
-- Any replacement has to keep those two properties (opaque, white).
local DEBRIS_TEXTURE = "rbxassetid://108698270607975"
-- Particles/sec PER COLOUR -- six colours, so ~150/sec in total. Halved from what three colours used
-- so that widening the palette varies the shower rather than thickening it.
local DEBRIS_RATE = 20
local DEBRIS_LIFETIME = NumberRange.new(0.45, 1.0)
-- How WIDE the shower is comes from these two, not from SpreadAngle -- that's already at its maximum
-- (180/180, a full sphere), so the flecks always leave in every direction; speed and drag decide how
-- far out they get before the fall takes over.
local DEBRIS_SPEED = NumberRange.new(9, 17)
local DEBRIS_DRAG = 1.4 -- lower = the outward throw survives longer, so the shower reaches further
-- Still above real gravity: the flecks should be pulled down promptly, reading as little chips
-- rather than as a floaty spray -- just not so hard that they drop before they've spread.
local DEBRIS_GRAVITY = Vector3.new(0, -52, 0)
-- Flecks shrink as they fall, so they read as chips being flung off rather than as a puff.
local DEBRIS_SIZE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.38),
	NumberSequenceKeypoint.new(1, 0.09),
})
local DEBRIS_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.1),
	NumberSequenceKeypoint.new(0.65, 0.25),
	NumberSequenceKeypoint.new(1, 1),
})

-- A running debris shower. `move` repositions it (follow whatever is being shredded); `stop` ends
-- emission and cleans up once the flecks already in the air have lived out.
export type DebrisEffect = {
	move: (CFrame) -> (),
	stop: () -> (),
}

local NOOP_DEBRIS: DebrisEffect = {
	move = function() end,
	stop = function() end,
}

-- Starts a debris shower at `cframe`. Returns a handle; the caller MUST call stop() or the emitter
-- runs forever.
function VfxManager.shredDebris(cframe: CFrame): DebrisEffect
	-- Client-only: a server-spawned emitter would replicate to every player.
	if not RunService:IsClient() then
		warn("VfxManager.shredDebris called on the server; VFX must run on the client")
		return NOOP_DEBRIS
	end

	local emitterPart = Instance.new("Part")
	emitterPart.Name = "ShredDebrisVfx"
	emitterPart.Size = Vector3.one * 0.2
	emitterPart.Transparency = 1
	emitterPart.Anchored = true
	emitterPart.CanCollide = false
	emitterPart.CanQuery = false
	emitterPart.CanTouch = false
	emitterPart.CastShadow = false
	emitterPart.CFrame = cframe

	for _, color in DEBRIS_COLORS do
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = DEBRIS_TEXTURE
		emitter.Color = ColorSequence.new(color)
		emitter.Rate = DEBRIS_RATE
		emitter.Lifetime = DEBRIS_LIFETIME
		emitter.Speed = DEBRIS_SPEED
		emitter.SpreadAngle = Vector2.new(180, 180) -- the maximum: thrown out in every direction
		emitter.Acceleration = DEBRIS_GRAVITY
		emitter.Drag = DEBRIS_DRAG
		emitter.Size = DEBRIS_SIZE
		emitter.Transparency = DEBRIS_TRANSPARENCY
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-320, 320)
		-- Kept low: LightEmission brightens a particle toward white, which flattens exactly the dark
		-- end of DEBRIS_COLORS that the palette exists to provide. Raise it for more glow, at the
		-- cost of the bronzes reading as just more yellow.
		emitter.LightEmission = 0.15
		emitter.LockedToPart = false -- flecks fall away in world space, they don't ride the emitter
		emitter.Parent = emitterPart
	end

	emitterPart.Parent = Workspace -- client-only instance => only this player sees it

	return {
		move = function(to: CFrame)
			if emitterPart.Parent then
				emitterPart.CFrame = to
			end
		end,
		stop = function()
			if not emitterPart.Parent then
				return
			end
			for _, emitter in emitterPart:GetChildren() do
				if emitter:IsA("ParticleEmitter") then
					emitter.Enabled = false
				end
			end
			-- Outlive the flecks already in the air, then take the emitter with them.
			Debris:AddItem(emitterPart, DEBRIS_LIFETIME.Max)
		end,
	}
end

-- "Clean burst": a single image sprite that pops off the spot being cleaned, arcs OUT TOWARD the
-- player, then snaps into them with a ping -- the reward feedback for washing a wall (it replaces
-- the floating text that used to sit on cleanable walls).
--
-- It's a billboard, not a particle: the sprite has to fly to a moving target (the player's root)
-- and play a sound the moment it lands there, which a ParticleEmitter can't do -- its particles are
-- fire-and-forget and can't be steered or reported on.
--
-- One call = ONE sprite. Callers fire it on their own cadence (the washer does so every
-- CLEAN_BURST_INTERVAL while dirt is actually coming off), so density is the caller's choice.
--
-- The sprite parts are POOLED. At a burst every 0.2s with a ~0.5s flight, a handful are alive at
-- once and each one would otherwise mean building a Part + BillboardGui + Trail + 2 Attachments,
-- five instances a fifth of a second, forever -- exactly the churn that makes cleaning hitch.
local BURST_TEXTURE = "rbxassetid://88320390473526"
local BURST_SOUND = "WallBurstSFX" -- arrival ping; template under ReplicatedStorage.Audios.SFX
local BURST_TRAIL_COLOR = Color3.fromRGB(255, 229, 29)
local BURST_SPRITE_SIZE = 0.9 -- studs, billboard width/height

-- LAUNCH. The sprite is thrown along the flat direction from the wall to the player, so it reads as
-- coming off the surface at them rather than flying off sideways. Gravity is far heavier than real
-- so the arc is short and punchy instead of floaty.
local BURST_GRAVITY = -150
local BURST_LAUNCH_SPEED = NumberRange.new(6, 10) -- outward, toward the player
local BURST_LAUNCH_HEIGHT = NumberRange.new(14, 20) -- upward kick
local BURST_SIDE_SPREAD = 5 -- studs/sec of sideways jitter, so repeats don't trace one line
-- Studs off the surface the sprite is born at. Kept past half the sprite's width so the whole quad
-- (and the trail it starts recording) clears the wall plane rather than straddling it.
local BURST_SPAWN_OFFSET = 1.2

-- FLIGHT. A short free arc, then a fixed-length flight into the player. Back/In eases *backwards*
-- first, so the sprite winds up before it snaps in -- that wind-up is what sells the pull.
local BURST_ARC_TIME = 0.18
local BURST_ATTRACT_TIME = 0.3
local BURST_ARRIVE_RADIUS = 2 -- studs from the target counted as arrived

local BURST_TRAIL_LIFETIME = 0.1
local BURST_TRAIL_WIDTH = 0.5
-- Newest end of the ribbon (time 0) is full width; the oldest end narrows off.
local BURST_TRAIL_WIDTH_SCALE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.6, 0.9),
	NumberSequenceKeypoint.new(1, 0.4),
})
local BURST_TRAIL_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.2),
	NumberSequenceKeypoint.new(1, 1),
})

local BURST_POOL_LIMIT = 8 -- parked sprites kept for reuse; the excess is destroyed
-- Arrivals inside this window share one sound, so sprites landing together can't stack into one
-- loud hit. Pitch is randomised per play so repeats don't sound cloned.
local BURST_SOUND_GAP = 0.07
local BURST_PITCH = NumberRange.new(0.95, 1.08)

-- The recycled instances behind one sprite.
type BurstParts = {
	part: BasePart,
	gui: BillboardGui,
	trail: Trail,
}

type BurstSprite = {
	parts: BurstParts,
	position: Vector3,
	velocity: Vector3,
	elapsed: number,
	attracting: boolean,
	attractElapsed: number,
	attractStart: Vector3,
	warmTrail: boolean,
}

local burstPool: { BurstParts } = {}
local burstSprites: { BurstSprite } = {}
local burstConn: RBXScriptConnection? = nil
local lastBurstSound = 0

local function buildBurstParts(): BurstParts
	local part = Instance.new("Part")
	part.Name = "CleanBurstVfx"
	part.Size = Vector3.one * 0.15
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true

	local gui = Instance.new("BillboardGui")
	gui.LightInfluence = 0
	-- MUST stay true. The sprite is born a fraction of a stud off a wall that carries the dirt
	-- overlay -- itself a SurfaceGui (see CleanableSurface). A depth-tested BillboardGui is a flat
	-- quad CENTRED on its part, so half of it sits behind the wall plane and gets cut off by the
	-- wall, and where the two GUIs overlap the engine sorts them as whole objects rather than
	-- per-pixel, so the overlay wins outright and the sprite disappears. AlwaysOnTop takes it out of
	-- that fight entirely. The cost is that it draws through geometry for its ~0.5s flight, which is
	-- what a reward pickup flying at you should do anyway.
	gui.AlwaysOnTop = false
	gui.Size = UDim2.fromScale(BURST_SPRITE_SIZE, BURST_SPRITE_SIZE)
	gui.Parent = part

	local image = Instance.new("ImageLabel")
	image.BackgroundTransparency = 1
	image.Image = BURST_TEXTURE
	image.Size = UDim2.fromScale(1, 1)
	image.Parent = gui

	-- A Trail needs two attachments; the gap between them is the ribbon width.
	local attachment0 = Instance.new("Attachment")
	attachment0.Position = Vector3.new(0, BURST_TRAIL_WIDTH * 0.5, 0)
	attachment0.Parent = part

	local attachment1 = Instance.new("Attachment")
	attachment1.Position = Vector3.new(0, -BURST_TRAIL_WIDTH * 0.5, 0)
	attachment1.Parent = part

	local trail = Instance.new("Trail")
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	trail.Color = ColorSequence.new(BURST_TRAIL_COLOR)
	trail.Lifetime = BURST_TRAIL_LIFETIME
	trail.WidthScale = BURST_TRAIL_WIDTH_SCALE
	trail.Transparency = BURST_TRAIL_TRANSPARENCY
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.FaceCamera = true -- keeps the ribbon readable from any angle
	trail.MinLength = 0
	trail.Enabled = false -- switched on after the first position update
	trail.Parent = part

	return { part = part, gui = gui, trail = trail }
end

-- What the sprite flies into: the local player's root. Resolved every frame because the flight
-- tracks the player as they move, and because the character can go away mid-flight.
local function burstTarget(): BasePart?
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Parks the sprite for reuse (and plays the arrival ping if it actually made it).
local function releaseBurst(sprite: BurstSprite, arrived: boolean)
	local parts = sprite.parts

	if arrived then
		local now = os.clock()
		if now - lastBurstSound >= BURST_SOUND_GAP then
			lastBurstSound = now
			local sound = SoundManager.playOneShot(BURST_SOUND)
			if sound then
				sound.PlaybackSpeed = BURST_PITCH.Min + math.random() * (BURST_PITCH.Max - BURST_PITCH.Min)
			end
		end
	end

	-- Something may have cleared the part out from under us; touching Parent then throws.
	if not parts.part.Parent then
		return
	end

	parts.trail.Enabled = false -- stop recording before the part is parked
	parts.trail:Clear()
	parts.part.Parent = nil

	if #burstPool < BURST_POOL_LIMIT then
		table.insert(burstPool, parts)
	else
		parts.part:Destroy()
	end
end

-- Advances one sprite. Returns true once it's finished, and whether it reached the player.
local function stepBurst(sprite: BurstSprite, dt: number): (boolean, boolean)
	sprite.elapsed += dt

	local target = burstTarget()
	if not target then
		return true, false -- character went away mid-flight
	end

	if not sprite.attracting then
		sprite.velocity += Vector3.new(0, BURST_GRAVITY * dt, 0)
		sprite.position += sprite.velocity * dt

		if sprite.elapsed >= BURST_ARC_TIME then
			sprite.attracting = true
			sprite.attractStart = sprite.position
		end
		return false, false
	end

	sprite.attractElapsed += dt
	local alpha = math.min(sprite.attractElapsed / BURST_ATTRACT_TIME, 1)
	local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	sprite.position = sprite.attractStart:Lerp(target.Position, eased)

	local arrived = alpha >= 1 or (sprite.position - target.Position).Magnitude <= BURST_ARRIVE_RADIUS
	return arrived, arrived
end

-- Per-frame stepping for every live sprite. The connection is made on the first burst and dropped
-- as soon as the last sprite lands, so an idle place pays nothing for the effect.
local function stepBursts(dt: number)
	for i = #burstSprites, 1, -1 do
		local sprite = burstSprites[i]
		local finished, arrived = stepBurst(sprite, dt)

		sprite.parts.part.Position = sprite.position

		if sprite.warmTrail then
			-- Position is now current, so there's no stale point to streak from.
			sprite.parts.trail:Clear()
			sprite.parts.trail.Enabled = true
			sprite.warmTrail = false
		end

		if finished then
			table.remove(burstSprites, i)
			releaseBurst(sprite, arrived)
		end
	end

	if #burstSprites == 0 and burstConn then
		burstConn:Disconnect()
		burstConn = nil
	end
end

-- Throws one sprite out of `position` toward the local player, where it lands with a ping.
-- No-ops before the character exists -- there'd be nothing to fly to.
function VfxManager.cleanBurst(position: Vector3)
	-- Client-only: a server-spawned sprite would replicate to every player.
	if not RunService:IsClient() then
		warn("VfxManager.cleanBurst called on the server; VFX must run on the client")
		return
	end

	local target = burstTarget()
	if not target then
		return
	end

	-- Flat direction wall -> player. Directly under/over the player (no flat component) is a
	-- degenerate case; throw it straight up rather than dividing by zero.
	local flat = target.Position - position
	local outward = Vector3.new(flat.X, 0, flat.Z)
	outward = if outward.Magnitude > 0.01 then outward.Unit else Vector3.zero
	local sideways = Vector3.new(-outward.Z, 0, outward.X) -- perpendicular, for the jitter

	local speed = BURST_LAUNCH_SPEED.Min + math.random() * (BURST_LAUNCH_SPEED.Max - BURST_LAUNCH_SPEED.Min)
	local height = BURST_LAUNCH_HEIGHT.Min + math.random() * (BURST_LAUNCH_HEIGHT.Max - BURST_LAUNCH_HEIGHT.Min)
	local spread = (math.random() * 2 - 1) * BURST_SIDE_SPREAD

	local parts = table.remove(burstPool) or buildBurstParts()
	local origin = position + outward * BURST_SPAWN_OFFSET
	parts.part.Position = origin
	parts.part.Parent = Workspace -- client-only instance => only this player sees it

	table.insert(burstSprites, {
		parts = parts,
		position = origin,
		velocity = outward * speed + sideways * spread + Vector3.new(0, height, 0),
		elapsed = 0,
		attracting = false,
		attractElapsed = 0,
		attractStart = origin,
		warmTrail = true, -- enable the trail *after* the first frame
	} :: BurstSprite)

	if not burstConn then
		burstConn = RunService.Heartbeat:Connect(stepBursts)
	end
end

return VfxManager
