--!strict

-- The party AUTHORITY: who is grouped with whom, and who leads. A party is 1..PartyConfig.MaxSize
-- players; the leader is whoever created it (and, if they leave, the next member in join order).
-- Everything here is server state -- the client only ever asks, through the PartyAction remote, and
-- is told the result through PartyUpdate.
--
-- There are NO INVITES. Parties are open: the server publishes the list of joinable ones to every
-- client, and a player joins the one they want. A party stops being joinable once it's full or
-- once its members are on a job -- you can't drop into a run that's already going, since the shared
-- progress and the teleport both happen at accept time.
--
-- Membership is published two ways, for two different consumers:
--   * PartyId / PartyLeader ATTRIBUTES on each Player. Attributes set server-side replicate to
--     every client, so any client can ask "are these two in the same party?" without holding a
--     snapshot. That's what the in-job visuals use (JobGhostController shows your party members and
--     hides everyone else on the business).
--   * The PartyUpdate REMOTE, carrying { party, available } -- the party you're in (nil if none)
--     and every party you could join. Both fields are always present, so a nil means "none" rather
--     than "unchanged". Pushed to everyone whenever any party changes, so the browser UI is live
--     without polling.
--
-- This module deliberately does NOT require JobService: JobService requires US (it resolves the
-- party at accept time), so the reverse would be a require cycle. Membership-vs-job questions are
-- answered off the replicated ActiveJob attribute instead, and JobService registers a hook through
-- onMemberRemoved -- that's how leaving/being kicked mid-job finishes that player's run early.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CleaningConfig = require(ReplicatedStorage.SharedModules.CleaningConfig)
local PartyConfig = require(ReplicatedStorage.SharedModules.PartyConfig)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PartyAction = Remotes:WaitForChild("PartyAction") :: RemoteEvent
local PartyUpdate = Remotes:WaitForChild("PartyUpdate") :: RemoteEvent

local PartyService = {}

export type Party = {
	id: string,
	leader: Player,
	-- Join order, leader first. Order matters: it decides who inherits the party if the leader
	-- leaves, and it's the order the UI lists members in.
	members: { Player },
}

-- Every live party by id, and the reverse lookup each caller actually uses.
local parties: { [string]: Party } = {}
local partyOf: { [Player]: Party } = {}

-- Monotonic id source. Ids are strings so they can sit on the PartyId attribute as-is.
local nextPartyId = 0

-- Registered by JobService (see the header): called with a player who has just stopped being in a
-- party, for any reason except disconnecting. Lets the job layer end a shared run for them without
-- this module having to know jobs exist.
local memberRemovedHooks: { (Player) -> () } = {}

-- Subscribe to "this player is no longer in a party". Called after the party state is already
-- updated, so a hook that asks about membership sees the post-removal truth.
function PartyService.onMemberRemoved(callback: (Player) -> ())
	table.insert(memberRemovedHooks, callback)
end

local function fireMemberRemoved(player: Player)
	for _, hook in memberRemovedHooks do
		local ok, err = pcall(hook, player)
		if not ok then
			warn(string.format("[PartyService] onMemberRemoved hook failed: %s", tostring(err)))
		end
	end
end

-- The party a player belongs to, or nil.
function PartyService.getParty(player: Player): Party?
	return partyOf[player]
end

-- Every member of the player's party, leader first -- or just the player themselves when they
-- aren't in one. Callers that only need "who does this job cover" can use this without branching.
function PartyService.getMembers(player: Player): { Player }
	local party = partyOf[player]
	if not party then
		return { player }
	end
	return table.clone(party.members)
end

function PartyService.isLeader(player: Player): boolean
	local party = partyOf[player]
	return party ~= nil and party.leader == player
end

-- True while these two share a party. Used by the job layer to decide whether a job is shared.
function PartyService.inSameParty(a: Player, b: Player): boolean
	local party = partyOf[a]
	return party ~= nil and party == partyOf[b]
end

-- Is this player on a job right now? Read off the replicated ActiveJob attribute rather than
-- through JobService, which would be a require cycle (see the header).
--
-- Being on a job locks a player out of the party system entirely -- they can neither create one nor
-- join one. That matches the UI (the party screens aren't reachable during a job) and it closes the
-- one hole that ordering left open: a player who joined mid-job would have their own solo run ended
-- without payout the moment the leader accepted for the party.
local function playerIsOnJob(player: Player): boolean
	return player:GetAttribute(CleaningConfig.ActiveJobAttribute) ~= nil
end

-- Is anyone in this party currently on a job? A party mid-run is closed to newcomers: the shared
-- session, its progress and its teleport all happened at accept time, so there's nothing coherent
-- to drop a late joiner into.
local function partyIsOnJob(party: Party): boolean
	for _, member in party.members do
		if playerIsOnJob(member) then
			return true
		end
	end
	return false
end

-- Can `player` join this party right now? They must be partyless and off the clock, and the party
-- must have room and not already be running a job.
local function isJoinable(party: Party, player: Player): boolean
	return partyOf[player] == nil
		and not playerIsOnJob(player)
		and #party.members < PartyConfig.MaxSize
		and not partyIsOnJob(party)
end

-- The roster snapshot the party UI reads. Players are sent as Player instances (they replicate fine
-- over a remote) so the UI can pull DisplayName/UserId off them directly.
local function snapshot(party: Party): { id: string, leader: Player, members: { Player } }
	return {
		id = party.id,
		leader = party.leader,
		members = table.clone(party.members),
	}
end

-- Push one player their complete picture: the party they're IN (nil if none) and every party they
-- could JOIN. A player already in a party gets an empty `available` list -- they'd have to leave
-- first, and showing joinable parties there would just invite a refused action.
local function sendState(player: Player)
	local party = partyOf[player]
	local available: { { id: string, leader: Player, members: { Player } } } = {}
	if not party then
		for _, candidate in parties do
			if isJoinable(candidate, player) then
				table.insert(available, snapshot(candidate))
			end
		end
	end
	PartyUpdate:FireClient(player, {
		party = if party then snapshot(party) else nil,
		available = available,
	})
end

-- Any party change moves the joinable list for EVERYONE (a party filling up, starting a job, or
-- disbanding all remove it from the browser), so the whole server is refreshed. Parties change
-- rarely -- on a click, not on a frame -- so this stays cheap.
local function broadcast()
	for _, player in Players:GetPlayers() do
		sendState(player)
	end
end

-- Publish (or clear) a player's party attributes. These replicate to every client, which is what
-- makes "is that player in my party?" answerable anywhere without a snapshot.
local function applyAttributes(player: Player, party: Party?)
	if party then
		player:SetAttribute(PartyConfig.PartyIdAttribute, party.id)
		player:SetAttribute(PartyConfig.PartyLeaderAttribute, if party.leader == player then true else nil)
	else
		player:SetAttribute(PartyConfig.PartyIdAttribute, nil)
		player:SetAttribute(PartyConfig.PartyLeaderAttribute, nil)
	end
end

-- Remove one player from their party. `notifyRemoved` is false only when the player is
-- disconnecting (their job is being torn down by the disconnect path anyway).
--
-- The leader leaving hands the party to the next member in join order rather than dissolving it --
-- the rest of the group is mid-session and shouldn't lose it because one person stepped out. A
-- party that empties is dissolved.
local function removeMember(player: Player, notifyRemoved: boolean)
	local party = partyOf[player]
	if not party then
		return
	end

	local index = table.find(party.members, player)
	if index then
		table.remove(party.members, index)
	end
	partyOf[player] = nil
	applyAttributes(player, nil)

	if #party.members == 0 then
		parties[party.id] = nil
	elseif party.leader == player then
		party.leader = party.members[1]
		applyAttributes(party.leader, party)
	end

	broadcast()
	if notifyRemoved then
		fireMemberRemoved(player)
	end
end

local function create(player: Player)
	if partyOf[player] then
		return -- already in one; leave first
	end
	if playerIsOnJob(player) then
		return -- on the clock: the party screens aren't reachable during a job
	end
	nextPartyId += 1
	local party: Party = {
		id = tostring(nextPartyId),
		leader = player,
		members = { player },
	}
	parties[party.id] = party
	partyOf[player] = party
	applyAttributes(player, party)
	broadcast()
end

-- Join an open party. `target` is either a Player already in it (a "join my friend" button) or the
-- party's id string (the browser). Refused if the sender is already in a party, the party is full,
-- or it's already on a job -- see isJoinable.
local function join(player: Player, target: any)
	local party: Party? = nil
	if type(target) == "string" then
		party = parties[target]
	elseif typeof(target) == "Instance" and target:IsA("Player") then
		party = partyOf[target]
	end
	if not party or not isJoinable(party, player) then
		-- Refused: refresh their view so a UI acting on a stale list corrects itself.
		sendState(player)
		return
	end
	table.insert(party.members, player)
	partyOf[player] = party
	applyAttributes(player, party)
	broadcast()
end

-- Leader removes another member. Refused for anyone but the leader, for a target who isn't in this
-- party, and for the LEADER THEMSELVES: kicking is strictly "remove someone else", and a leader who
-- wants out uses Leave (which hands the party to the next member rather than dissolving it). Without
-- that guard a self-kick would be a second, subtly different exit path for the same button.
--
-- A kicked member mid-job is finished early by the onMemberRemoved hook (see removeMember), so they
-- keep the payout for the group's progress instead of losing the run outright.
local function kick(leader: Player, target: any)
	if typeof(target) ~= "Instance" or not target:IsA("Player") then
		return
	end
	if target == leader then
		return
	end
	local party = partyOf[leader]
	if not party or party.leader ~= leader or partyOf[target] ~= party then
		return
	end
	removeMember(target, true)
end

-- Tear a party down completely: every member is detached and told.
local function disband(leader: Player)
	local party = partyOf[leader]
	if not party or party.leader ~= leader then
		return
	end
	local members = table.clone(party.members)
	table.clear(party.members)
	parties[party.id] = nil
	for _, member in members do
		if partyOf[member] == party then
			partyOf[member] = nil
			applyAttributes(member, nil)
		end
	end
	-- Told only once the party is fully unpicked, so each player's payload reflects the end state.
	broadcast()
	for _, member in members do
		fireMemberRemoved(member)
	end
end

local function onAction(player: Player, action: any, target: any)
	if type(action) ~= "string" then
		return
	end
	local A = PartyConfig.Actions
	if action == A.Create then
		create(player)
	elseif action == A.Join then
		join(player, target)
	elseif action == A.Leave then
		removeMember(player, true)
	elseif action == A.Kick then
		kick(player, target)
	elseif action == A.Disband then
		disband(player)
	end
end

function PartyService.init()
	PartyAction.OnServerEvent:Connect(onAction)

	-- Going on or off the clock changes what's joinable, and that has to reach the browser. ActiveJob
	-- is set per player by JobService, so watching each player's attribute covers every party without
	-- this module knowing anything about jobs. A player in a party moves the list for EVERYONE (their
	-- party opens/closes to newcomers); a partyless player only moves their own (a player on a job
	-- can't join anything, so their list empties and refills).
	local function watchJobState(player: Player)
		player:GetAttributeChangedSignal(CleaningConfig.ActiveJobAttribute):Connect(function()
			if partyOf[player] then
				broadcast()
			else
				sendState(player)
			end
		end)
	end
	for _, player in Players:GetPlayers() do
		watchJobState(player)
		sendState(player)
	end
	Players.PlayerAdded:Connect(function(player)
		watchJobState(player)
		-- Send the joinable list as soon as they arrive, so the UI has something before anything
		-- changes on its own.
		sendState(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Their job is torn down by JobService's own PlayerRemoving handler, so the removal hook
		-- would have nothing left to do -- skip it.
		removeMember(player, false)
	end)
end

return PartyService
