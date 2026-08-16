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
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

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

return VfxManager
