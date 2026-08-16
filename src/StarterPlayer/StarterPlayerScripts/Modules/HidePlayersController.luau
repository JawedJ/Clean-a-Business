--!strict

-- Client-side hiding of every OTHER player's character for the local player only. Two independent
-- reasons ask for a player to be hidden, and this module is the single owner of the actual hiding
-- so they can't fight over the restore values:
--   * the persisted Settings.HidePlayers preference (wired in SettingsUiController) -- hides
--     everyone, all the time, while it's on.
--   * being on the same job as us (JobGhostController) -- hides just the players working the
--     business we're currently cleaning, for as long as that job lasts.
-- A player is hidden while EITHER reason holds, and revealed only once both drop. Nothing here
-- replicates, so everyone still looks normal to themselves and to other clients.
--
-- How a character is hidden: every BasePart gets LocalTransparencyModifier = 1 (the same
-- client-only, non-replicated knob the engine uses to hide your own body in first person -- it
-- also hides the part's decals/textures), its particle emitters / beams / trails are disabled so
-- no stray spray hangs in the air, and its Humanoid's name display is switched off so the floating
-- name (which transparency doesn't touch) disappears too. Parts / emitters / the Humanoid that
-- stream in later (accessories, a tool on equip) are caught via DescendantAdded. Revealing restores
-- every value we touched.
--
-- THE NAME NEEDS DisplayDistanceType, not just NameDisplayDistance. A humanoid's own
-- NameDisplayDistance is only consulted when its DisplayDistanceType is Subject; the default is
-- Viewer, under which the LOCAL player's humanoid decides what names they see -- so zeroing the
-- hidden player's distance alone left their name floating over an invisible body. Setting their
-- DisplayDistanceType to None turns the name (and health bar) off outright, whatever the viewer's
-- settings say. We set both, so the hiding holds even if these characters are later authored as
-- Subject.
--
-- The hidden set is re-evaluated on respawn (CharacterAdded) and as players join / leave.
--
-- Separately, and regardless of either reason: every other player's TOOL effects (the pressure
-- washer's spray, and anything authored like it) are muted for us permanently. See muteToolEffect --
-- the short version is that emission is driven on the tool owner's own client and never replicates,
-- so what we'd otherwise see is a teammate's washer spraying non-stop whether they're firing or not.

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer

local HidePlayersController = {}

-- Whether the preference is currently on. Applied lazily: turning it on hides everyone tracked,
-- turning it off reveals everyone the job reason doesn't still cover.
local enabled = false

-- Players the job reason currently wants hidden (same business as us), kept as a set.
local jobHidden: { [Player]: true } = {}

-- Per hidden player: the character we applied to, the watcher catching late descendants, the parts
-- we dimmed mapped to their prior LocalTransparencyModifier, the emitters we disabled mapped to
-- their prior Enabled, and the Humanoids we hid the name on mapped to the two name-display values we
-- overwrote -- so reveal restores every value exactly.
type NameDisplay = { distance: number, displayType: Enum.HumanoidDisplayDistanceType }
type Hidden = {
	character: Model,
	descConn: RBXScriptConnection,
	parts: { [BasePart]: number },
	emitters: { [Instance]: boolean },
	humanoids: { [Humanoid]: NameDisplay },
}
local hidden: { [Player]: Hidden } = {}

-- Per player: the respawn connection that re-hides their fresh character. Kept so we can drop it
-- when the player leaves.
local tracking: { [Player]: RBXScriptConnection } = {}

-- Per player: the watcher muting tool effects on their current character. Separate from the hiding
-- watcher because it runs whether or not the player is hidden, and is replaced on respawn.
local muting: { [Player]: RBXScriptConnection } = {}

-- The emission effects we switch off (spray particles, beams, trails). They all carry Enabled.
local function isEmitter(inst: Instance): boolean
	return inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Trail")
end

-- An emitter that belongs to an equipped TOOL rather than to the body itself.
local function isToolEffect(inst: Instance): boolean
	return isEmitter(inst) and inst:FindFirstAncestorWhichIsA("Tool") ~= nil
end

-- Other players' tool effects are muted for us ALWAYS -- hidden, revealed, job or no job.
--
-- Emission is driven locally on the tool owner's OWN client (PressureWasherController enables the
-- spray only while they hold the trigger), and a client-side Enabled never replicates. So the copy
-- we see is stuck at whatever the tool was authored with: a party member's washer sprays at us
-- constantly, whether or not they're firing, and no amount of hiding their body covers a tool they
-- equip afterwards. Nobody needs to see anyone else's spray, so it just stays off. Our own tool is
-- untouched -- the local player is never tracked here.
local function muteToolEffect(inst: Instance)
	if isToolEffect(inst) then
		(inst :: any).Enabled = false
	end
end

local function muteToolEffects(character: Model)
	for _, d in character:GetDescendants() do
		muteToolEffect(d)
	end
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
		-- Switch the floating character name off (transparency doesn't cover it). DisplayDistanceType
		-- None is what actually does it -- see the header on why the distance alone isn't enough.
		-- Client-side only; the server never rewrites either value, so they stick.
		if entry.humanoids[inst] == nil then
			entry.humanoids[inst] = { distance = inst.NameDisplayDistance, displayType = inst.DisplayDistanceType }
		end
		inst.NameDisplayDistance = 0
		inst.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
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
		-- A tool's effects are never revealed -- see muteToolEffect. Restoring the authored `true`
		-- here is exactly how a revealed teammate's washer would start spraying at us again.
		if (emitter :: any).Parent and not isToolEffect(emitter) then
			(emitter :: any).Enabled = wasEnabled
		end
	end
	for humanoid, prior in entry.humanoids do
		if humanoid.Parent then
			humanoid.NameDisplayDistance = prior.distance
			humanoid.DisplayDistanceType = prior.displayType
		end
	end
	hidden[player] = nil
end

-- Apply the current state to one player: hidden while either reason holds, revealed once neither does.
local function refreshPlayer(player: Player)
	if enabled or jobHidden[player] then
		hidePlayer(player)
	else
		HidePlayersController._reveal(player)
	end
end

-- Point the tool-effect mute at a player's current character, dropping the watcher on the old one.
local function muteCharacter(player: Player, character: Model)
	local existing = muting[player]
	if existing then
		existing:Disconnect()
	end
	-- Tools stream in on equip, long after the character does, so the watcher matters more than the
	-- initial sweep here.
	muting[player] = character.DescendantAdded:Connect(muteToolEffect)
	muteToolEffects(character)
end

local function trackPlayer(player: Player)
	if player == localPlayer or tracking[player] then
		return
	end
	-- Respawn: re-apply (or not) to the fresh character, and re-mute the new body's tools.
	tracking[player] = player.CharacterAdded:Connect(function(character)
		muteCharacter(player, character)
		refreshPlayer(player)
	end)
	if player.Character then
		muteCharacter(player, player.Character)
	end
	refreshPlayer(player)
end

local function untrackPlayer(player: Player)
	jobHidden[player] = nil
	HidePlayersController._reveal(player)
	local conn = tracking[player]
	if conn then
		conn:Disconnect()
		tracking[player] = nil
	end
	local muteConn = muting[player]
	if muteConn then
		muteConn:Disconnect()
		muting[player] = nil
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

-- Called by JobGhostController as players join / leave our job. Independent of the preference:
-- clearing it only reveals the player if the preference isn't hiding them too.
function HidePlayersController.setJobHidden(player: Player, value: boolean)
	if player == localPlayer then
		return
	end
	local current = jobHidden[player] ~= nil
	if current == value then
		return
	end
	jobHidden[player] = if value then true else nil
	refreshPlayer(player)
end

-- Re-apply the current state to a player (used when their character is replaced or their job
-- membership is re-evaluated against an already-hidden character).
function HidePlayersController.refresh(player: Player)
	if player ~= localPlayer then
		refreshPlayer(player)
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
