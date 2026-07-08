--!strict

-- Client-side toggle that hides every OTHER player's character for the local player only. Driven
-- by the persisted Settings.HidePlayers preference (wired in SettingsUiController): when on, other
-- players vanish for you; when off, they render normally. Nothing here replicates, so everyone
-- still looks normal to themselves and to players who leave the toggle off.
--
-- How a character is hidden: every BasePart gets LocalTransparencyModifier = 1 (the same
-- client-only, non-replicated knob the engine uses to hide your own body in first person -- it
-- also hides the part's decals/textures), its particle emitters / beams / trails are disabled so
-- no stray spray hangs in the air, and its Humanoid's NameDisplayDistance is zeroed so the floating
-- name (which transparency doesn't touch) disappears too. Parts / emitters / the Humanoid that
-- stream in later (accessories, a tool on equip) are caught via DescendantAdded. Revealing restores
-- every value we touched.
--
-- The hidden set is re-evaluated on respawn (CharacterAdded) and as players join / leave. This is
-- independent of JobGhostController's in-job blue highlight; if both would apply, fully hidden wins
-- (an invisible part writes no depth, so the Occluded ghost highlight simply doesn't show -- which
-- is the intended result while HidePlayers is on).

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer

local HidePlayersController = {}

-- Whether the preference is currently on. Applied lazily: turning it on hides everyone tracked,
-- turning it off reveals them.
local enabled = false

-- Per hidden player: the character we applied to, the watcher catching late descendants, the parts
-- we dimmed mapped to their prior LocalTransparencyModifier, the emitters we disabled mapped to
-- their prior Enabled, and the Humanoids we hid the name on mapped to their prior
-- NameDisplayDistance -- so reveal restores every value exactly.
type Hidden = {
	character: Model,
	descConn: RBXScriptConnection,
	parts: { [BasePart]: number },
	emitters: { [Instance]: boolean },
	humanoids: { [Humanoid]: number },
}
local hidden: { [Player]: Hidden } = {}

-- Per player: the respawn connection that re-hides their fresh character. Kept so we can drop it
-- when the player leaves.
local tracking: { [Player]: RBXScriptConnection } = {}

-- The emission effects we switch off (spray particles, beams, trails). They all carry Enabled.
local function isEmitter(inst: Instance): boolean
	return inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Trail")
end

-- Hide one instance for this character, remembering its prior value so reveal can put it back.
local function hideInstance(inst: Instance, entry: Hidden)
	if inst:IsA("BasePart") then
		if entry.parts[inst] == nil then
			entry.parts[inst] = inst.LocalTransparencyModifier
		end
		inst.LocalTransparencyModifier = 1
	elseif isEmitter(inst) then
		local emitter = inst :: any
		if entry.emitters[inst] == nil then
			entry.emitters[inst] = emitter.Enabled
		end
		emitter.Enabled = false
	elseif inst:IsA("Humanoid") then
		-- Zero the name-display distance to hide the floating character name (transparency
		-- doesn't cover it). Client-side only; the server never rewrites it, so it sticks.
		if entry.humanoids[inst] == nil then
			entry.humanoids[inst] = inst.NameDisplayDistance
		end
		inst.NameDisplayDistance = 0
	end
end

-- Hide the player's current character. No-op if we're already hiding this exact character;
-- rebuilds if we were hiding an older (pre-respawn) one.
local function hidePlayer(player: Player)
	local character = player.Character
	if not character then
		return -- no body yet; CharacterAdded will bring us back
	end
	local existing = hidden[player]
	if existing then
		if existing.character == character then
			return
		end
		HidePlayersController._reveal(player)
	end

	local entry: Hidden = {
		character = character,
		descConn = nil :: any,
		parts = {},
		emitters = {},
		humanoids = {},
	}
	-- Catch parts/emitters that stream in later (accessories, the tool on equip).
	entry.descConn = character.DescendantAdded:Connect(function(d)
		hideInstance(d, entry)
	end)
	hidden[player] = entry

	for _, d in character:GetDescendants() do
		hideInstance(d, entry)
	end
end

-- Reveal a hidden player: restore every part / emitter we touched and drop the watcher. Safe if
-- the player isn't currently hidden. Underscore-prefixed only because hidePlayer references it.
function HidePlayersController._reveal(player: Player)
	local entry = hidden[player]
	if not entry then
		return
	end
	entry.descConn:Disconnect()
	for part, prior in entry.parts do
		if part.Parent then
			part.LocalTransparencyModifier = prior
		end
	end
	for emitter, wasEnabled in entry.emitters do
		if (emitter :: any).Parent then
			(emitter :: any).Enabled = wasEnabled
		end
	end
	for humanoid, priorDistance in entry.humanoids do
		if humanoid.Parent then
			humanoid.NameDisplayDistance = priorDistance
		end
	end
	hidden[player] = nil
end

-- Apply the current `enabled` state to one player (hide if on, reveal if off).
local function refreshPlayer(player: Player)
	if enabled then
		hidePlayer(player)
	else
		HidePlayersController._reveal(player)
	end
end

local function trackPlayer(player: Player)
	if player == localPlayer or tracking[player] then
		return
	end
	-- Respawn: re-apply (or not) to the fresh character.
	tracking[player] = player.CharacterAdded:Connect(function()
		refreshPlayer(player)
	end)
	refreshPlayer(player)
end

local function untrackPlayer(player: Player)
	HidePlayersController._reveal(player)
	local conn = tracking[player]
	if conn then
		conn:Disconnect()
		tracking[player] = nil
	end
end

-- Turn the hide-other-players preference on or off, applying it to everyone currently tracked.
function HidePlayersController.setEnabled(value: boolean)
	if value == enabled then
		return
	end
	enabled = value
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer then
			refreshPlayer(player)
		end
	end
end

function HidePlayersController.init()
	for _, player in Players:GetPlayers() do
		trackPlayer(player)
	end
	Players.PlayerAdded:Connect(trackPlayer)
	Players.PlayerRemoving:Connect(untrackPlayer)
end

return HidePlayersController
