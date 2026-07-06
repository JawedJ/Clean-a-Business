--!strict

-- While the LOCAL player is on a job, every OTHER player working the same business is masked by
-- a solid blue highlight and their tool VFX is silenced -- so you're aware someone's cleaning
-- next to you without their model, or their spray, getting in your way. Their collision is
-- dropped separately, on the server (JobCollisionService); this module owns only the visuals.
--
-- How the blue figure is made (all client-side; nothing replicates, so the other player looks
-- normal to themselves and to anyone not on their job):
--   * a Highlight with DepthMode = Occluded and FillTransparency = 0 paints every visible
--     surface of their character solid blue -- you can't make out their real model through an
--     opaque fill, and Occluded means walls hide the blue just like they'd hide a real body.
--   * their particle emitters / beams / trails are Enabled = false (kills the washer spray),
--     with the prior value remembered so it's restored on reveal.
-- We deliberately do NOT hide the parts (e.g. via LocalTransparencyModifier): an Occluded
-- highlight reads the parts' depth to know what a wall is covering, and invisible parts write
-- no depth -- so hiding them would make the highlight vanish entirely. The opaque fill is what
-- conceals the model instead.
--
-- The ghost set is recomputed whenever anything that could change it happens: the local
-- player's job changes, another player's job changes, someone respawns, or a player joins or
-- leaves. Matching is by businessId (same job as me), which also means: no job = ghost no one.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

local localPlayer = Players.LocalPlayer

-- Blue ghost look. Fully opaque fill so the real model can't be read through it; Occluded
-- depth so walls hide it (see the header for why the parts stay rendered).
local GHOST_FILL_COLOR = Color3.fromRGB(33, 122, 255)
local GHOST_OUTLINE_COLOR = Color3.fromRGB(140, 195, 255)
local GHOST_FILL_TRANSPARENCY = 0
local GHOST_OUTLINE_TRANSPARENCY = 0

local JobGhostController = {}

-- Per currently-ghosted player: the character we applied to, its highlight, the watcher
-- silencing emitters that stream in after (the tool loads a frame late on equip), and the
-- emitters we disabled mapped to the Enabled value they had -- so reveal restores them exactly.
type Ghost = {
	character: Model,
	highlight: Highlight,
	descConn: RBXScriptConnection,
	emitters: { [Instance]: boolean },
}
local ghosts: { [Player]: Ghost } = {}

-- Per player: the connections (attribute + respawn) that ask us to re-evaluate them. Kept so
-- we can drop them when the player leaves.
local tracking: { [Player]: { RBXScriptConnection } } = {}

-- The emission effects we switch off (spray particles, beams, trails). They all carry Enabled.
local function isEmitter(inst: Instance): boolean
	return inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Trail")
end

-- Silence one emitter for this ghost, remembering its prior Enabled so reveal can put it back.
-- Non-emitters are left alone -- the opaque highlight, not hiding, conceals the model.
local function hideInstance(inst: Instance, ghost: Ghost)
	if isEmitter(inst) then
		local emitter = inst :: any
		if ghost.emitters[inst] == nil then
			ghost.emitters[inst] = emitter.Enabled
		end
		emitter.Enabled = false
	end
end

local function hideCharacter(character: Model, ghost: Ghost)
	for _, d in character:GetDescendants() do
		hideInstance(d, ghost)
	end
end

-- Restore each emitter we silenced to the Enabled value it had before.
local function revealCharacter(ghost: Ghost)
	for emitter, wasEnabled in ghost.emitters do
		if (emitter :: any).Parent then
			(emitter :: any).Enabled = wasEnabled
		end
	end
end

local function localBusinessId(): string?
	local id = localPlayer:GetAttribute(Config.ActiveJobAttribute)
	return if type(id) == "string" then id else nil
end

-- A player is ghosted for us iff we're on a job and they're on the same business.
local function shouldGhost(player: Player): boolean
	if player == localPlayer then
		return false
	end
	local mine = localBusinessId()
	return mine ~= nil and player:GetAttribute(Config.ActiveJobAttribute) == mine
end

-- Reveal a ghosted player again and drop our highlight/watcher. Safe if not ghosted.
local function removeGhost(player: Player)
	local ghost = ghosts[player]
	if not ghost then
		return
	end
	ghost.descConn:Disconnect()
	ghost.highlight:Destroy()
	revealCharacter(ghost)
	ghosts[player] = nil
end

-- Paint the player's current character solid blue and silence its VFX emitters. Rebuilds if we
-- were ghosting an older (pre-respawn) character.
local function applyGhost(player: Player)
	local character = player.Character
	if not character then
		return -- no body yet; CharacterAdded will bring us back
	end
	local existing = ghosts[player]
	if existing then
		if existing.character == character then
			return -- already ghosting this exact character
		end
		removeGhost(player)
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "JobGhostHighlight"
	highlight.Adornee = character
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = GHOST_FILL_COLOR
	highlight.OutlineColor = GHOST_OUTLINE_COLOR
	highlight.FillTransparency = GHOST_FILL_TRANSPARENCY
	highlight.OutlineTransparency = GHOST_OUTLINE_TRANSPARENCY
	highlight.Parent = character

	local ghost: Ghost = {
		character = character,
		highlight = highlight,
		descConn = nil :: any,
		emitters = {},
	}
	-- Silence emitters that stream in later (the tool on equip).
	ghost.descConn = character.DescendantAdded:Connect(function(d)
		hideInstance(d, ghost)
	end)
	ghosts[player] = ghost

	hideCharacter(character, ghost)
end

local function refreshPlayer(player: Player)
	if shouldGhost(player) then
		applyGhost(player)
	else
		removeGhost(player)
	end
end

local function refreshAll()
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer then
			refreshPlayer(player)
		end
	end
end

local function trackPlayer(player: Player)
	if player == localPlayer or tracking[player] then
		return
	end
	tracking[player] = {
		-- Their job changed: they may now match ours (ghost) or no longer (reveal).
		player:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(function()
			refreshPlayer(player)
		end),
		-- Respawn: re-apply to the fresh character if they should still be ghosted.
		player.CharacterAdded:Connect(function()
			refreshPlayer(player)
		end),
	}
	refreshPlayer(player)
end

local function untrackPlayer(player: Player)
	removeGhost(player)
	local conns = tracking[player]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		tracking[player] = nil
	end
end

function JobGhostController.init()
	-- Our own job changing flips whether -- and against which business -- we ghost anyone.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(refreshAll)

	for _, player in Players:GetPlayers() do
		trackPlayer(player)
	end
	Players.PlayerAdded:Connect(trackPlayer)
	Players.PlayerRemoving:Connect(untrackPlayer)
end

return JobGhostController
