--!strict

-- While the LOCAL player is on a job, every OTHER player working the same business is made
-- invisible for us -- body, floating name and tool VFX all -- so nobody's model or spray gets in
-- the way of the surface you're cleaning. Their collision is dropped separately, on the server
-- (PlayerCollisionService); this module owns only the visuals.
--
-- OUR PARTY IS THE EXCEPTION. Party members share the job on purpose (see PartyService), so they
-- stay fully visible -- the whole point is cleaning it together. Only same-business players from
-- OUTSIDE our party are hidden. Membership is read off the replicated PartyId attribute via
-- PartyController, so it's answerable for any player at any time.
--
-- The hiding itself is done by HidePlayersController, which is the single owner of the
-- transparency / name / emitter values (the Settings.HidePlayers preference hides players too, and
-- one owner keeps the two from clobbering each other's restore values). All this module does is
-- decide WHO is on our job and call setJobHidden. Nothing replicates, so the other player looks
-- normal to themselves and to anyone not on their job.
--
-- The set is recomputed whenever anything that could change it happens: the local player's job
-- changes, another player's job changes, someone respawns, or a player joins or leaves. Matching is
-- by businessId (same job as me), which also means: no job = hide no one.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local PartyConfig = require(ReplicatedStorage.SharedModules.PartyConfig)
local HidePlayersController = require(script.Parent.HidePlayersController)
local PartyController = require(script.Parent.PartyController)

local localPlayer = Players.LocalPlayer

local JobGhostController = {}

-- Per player: the connections (attribute + respawn) that ask us to re-evaluate them. Kept so
-- we can drop them when the player leaves.
local tracking: { [Player]: { RBXScriptConnection } } = {}

local function localBusinessId(): string?
	local id = localPlayer:GetAttribute(Config.ActiveJobAttribute)
	return if type(id) == "string" then id else nil
end

-- A player is hidden by us iff we're on a job, they're on the same business, and they aren't in
-- our party.
local function shouldHide(player: Player): boolean
	if player == localPlayer then
		return false
	end
	local mine = localBusinessId()
	if mine == nil or player:GetAttribute(Config.ActiveJobAttribute) ~= mine then
		return false
	end
	return not PartyController.sharesParty(player)
end

local function refreshPlayer(player: Player)
	HidePlayersController.setJobHidden(player, shouldHide(player))
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
		-- Their job changed: they may now match ours (hide) or no longer (reveal).
		player:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(function()
			refreshPlayer(player)
		end),
		-- Their party changed: joining ours reveals them mid-job, leaving it hides them again.
		player:GetAttributeChangedSignal(PartyConfig.PartyIdAttribute):Connect(function()
			refreshPlayer(player)
		end),
		-- Respawn: re-apply to the fresh character if they should still be hidden.
		player.CharacterAdded:Connect(function()
			refreshPlayer(player)
			HidePlayersController.refresh(player)
		end),
	}
	refreshPlayer(player)
end

local function untrackPlayer(player: Player)
	HidePlayersController.setJobHidden(player, false)
	local conns = tracking[player]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		tracking[player] = nil
	end
end

function JobGhostController.init()
	-- Our own job changing flips whether -- and against which business -- we hide anyone, and our
	-- own party changing flips which of them are exempt.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(refreshAll)
	localPlayer:GetAttributeChangedSignal(PartyConfig.PartyIdAttribute):Connect(refreshAll)

	for _, player in Players:GetPlayers() do
		trackPlayer(player)
	end
	Players.PlayerAdded:Connect(trackPlayer)
	Players.PlayerRemoving:Connect(untrackPlayer)
end

return JobGhostController
