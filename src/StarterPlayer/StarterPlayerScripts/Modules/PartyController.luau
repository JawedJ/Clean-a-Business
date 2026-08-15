--!strict

-- The client's view of the party system (see PartyService, which is the authority). Two jobs:
--
--   * ANSWER "are we in the same party?" for any player, from the PartyId attribute the server
--     publishes on every Player. Attributes replicate to all clients, so this works for players
--     we've never been told about -- which is what the in-job visuals need (JobGhostController
--     hides same-business players EXCEPT our party members).
--   * HOLD the roster the server pushes over PartyUpdate: the party we're in, and every party we
--     could join (there are no invites -- players join open parties themselves). That's the state
--     the party UI renders; PartyController.send is how it asks for changes.
--
-- The two are deliberately separate: the attribute answer is available instantly for everyone, the
-- snapshot only for our own party and the joinable list.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PartyConfig = require(ReplicatedStorage.SharedModules.PartyConfig)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PartyAction = Remotes:WaitForChild("PartyAction") :: RemoteEvent
local PartyUpdate = Remotes:WaitForChild("PartyUpdate") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local PartyController = {}

-- One party's roster, as the server sees it.
export type PartyState = {
	id: string,
	leader: Player,
	-- Join order, leader first.
	members: { Player },
	-- The business the party formed around, fixed when the leader created it.
	businessId: string,
	-- PARALLEL TO `members`: members[i] has readied up iff ready[i] is true. An array rather than a
	-- player-keyed map because remotes only serialize string/number keys -- see PartyService.snapshot.
	ready: { boolean },
}

-- What the server pushes on every change: BOTH the party we're in and the parties we could join,
-- always both fields, so a nil/empty means "none" rather than "unchanged". `available` is empty
-- while we're in a party (we'd have to leave one before joining another).
export type PartyView = {
	party: PartyState?,
	available: { PartyState },
}

local view: PartyView = { party = nil, available = {} }

-- Called with the new view whenever it changes -- for the party UI.
local changedListeners: { (PartyView) -> () } = {}

local function partyIdOf(player: Player): string?
	local id = player:GetAttribute(PartyConfig.PartyIdAttribute)
	return if type(id) == "string" then id else nil
end

-- Whether `player` is in the LOCAL player's party. False when either of them isn't in one, and
-- false for the local player themselves -- callers ask this about OTHER players, and answering
-- "yes, you're in your own party" would have them treat themselves as a party member.
function PartyController.sharesParty(player: Player): boolean
	if player == localPlayer then
		return false
	end
	local mine = partyIdOf(localPlayer)
	return mine ~= nil and partyIdOf(player) == mine
end

-- Whether the local player is in a party at all. Read straight off the attribute, so it's correct
-- from the moment the server publishes it -- before any snapshot arrives.
function PartyController.inParty(): boolean
	return partyIdOf(localPlayer) ~= nil
end

-- Whether the local player is in a party with anyone ELSE -- i.e. whether anything they do needs
-- relaying. A party of one is a party, but nobody is listening, so the washer skips sending its
-- strokes. Falls back to the attribute if the roster snapshot hasn't landed yet, which errs toward
-- sending (the server drops a relay with no recipients anyway).
function PartyController.hasCompany(): boolean
	local party = view.party
	if party then
		return #party.members > 1
	end
	return PartyController.inParty()
end

function PartyController.isLeader(): boolean
	return localPlayer:GetAttribute(PartyConfig.PartyLeaderAttribute) == true
end

-- The party we're in, or nil.
function PartyController.getParty(): PartyState?
	return view.party
end

-- Whether a member of `party` has readied up. Takes the party rather than reading our own so the
-- roster UI can ask it of every member, and keeps the parallel-array indexing (see PartyState.ready)
-- in one place instead of spread through the screens.
function PartyController.isReady(party: PartyState, member: Player): boolean
	local index = table.find(party.members, member)
	return index ~= nil and party.ready[index] == true
end

-- Every party we could join right now (empty while we're in one). Live: the server re-pushes it
-- whenever any party is created, filled, emptied, or starts a job.
function PartyController.getAvailable(): { PartyState }
	return view.available
end

-- Subscribe to changes. Returns a disconnect function; fires immediately with the current view so a
-- listener wired up late doesn't sit blank until the next change.
function PartyController.onChanged(callback: (PartyView) -> ()): () -> ()
	table.insert(changedListeners, callback)
	callback(view)
	return function()
		local index = table.find(changedListeners, callback)
		if index then
			table.remove(changedListeners, index)
		end
	end
end

-- Ask the server to do something (PartyConfig.Actions). `target` is the party to join (a Player in
-- it, or its id) or the Player to kick. Everything is re-validated server-side; a refused action
-- simply produces no change.
function PartyController.send(action: string, target: (Player | string)?)
	PartyAction:FireServer(action, target)
end

function PartyController.init()
	PartyUpdate.OnClientEvent:Connect(function(newView)
		if type(newView) ~= "table" then
			return
		end
		view = {
			party = (newView :: any).party,
			available = (newView :: any).available or {},
		}
		for _, listener in changedListeners do
			listener(view)
		end
	end)
end

return PartyController
