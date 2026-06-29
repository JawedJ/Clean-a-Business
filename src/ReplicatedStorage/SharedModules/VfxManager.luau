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

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local VfxManager = {}

-- "Clean pop": a neon-yellow duplicate of a just-cleaned part that briefly swells
-- past the original then settles back, reading as a bright outline flash.
local POP_COLOR = Color3.fromRGB(255, 255, 0)
local POP_PEAK_SCALE = 1.05 -- size at the peak of the swell, relative to real size
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
	clone.Transparency = 0.6
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

return VfxManager
