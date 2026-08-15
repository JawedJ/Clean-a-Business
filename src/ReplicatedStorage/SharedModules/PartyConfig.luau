--!strict

-- Shared constants for the party system (playing a job together with friends). Required by both
-- the server (PartyService, the authority) and the client (PartyController + the party UI), so the
-- action names and attribute keys never drift apart.
--
-- A party is a group of 1..MaxSize players with one LEADER, formed around ONE business: the leader
-- picks the job first (on the normal job board) and the party is created for it, so a party always
-- knows what it's going to play. There are no invites: parties are OPEN and players join them
-- themselves -- the server publishes the list of joinable parties, the UI shows it, and a player
-- picks one.
--
-- The job starts when EVERY member has readied up (see the Ready action), which starts ONE shared
-- job for all of them at once (see JobService / JobServer): shared cleanables, one shared completion
-- bar, and wall strokes relayed between members so everyone's dirt overlays match. Members finish
-- together, unless one finishes early -- which ends the job for them alone, paying out at the
-- group's completion percentage. Once the job COMPLETES the party is disbanded, so everyone is free
-- to play again or go home on their own.

local PartyConfig = {
	-- A party may hold this many players at most, leader included. One player is a valid party
	-- (a "solo party" behaves exactly like playing without one).
	MaxSize = 6,

	-- Published on every Player in a party, server-side, so it replicates to ALL clients (not just
	-- party members). Two players share a party iff they carry the same non-nil value here. Cheap
	-- enough to read per-frame, which is why the visuals use it rather than a replicated snapshot:
	-- JobGhostController hides same-job players EXCEPT the ones sharing your PartyId.
	PartyIdAttribute = "PartyId",
	-- True on the party's leader only (absent on everyone else). Convenience for UI.
	PartyLeaderAttribute = "PartyLeader",

	-- Actions the client may send over the PartyAction remote, as `PartyAction:FireServer(action, target?)`.
	-- Everything is re-validated server-side; these names are just the vocabulary.
	Actions = {
		-- Create a new party with the sender as leader, for the business `target` names (refused if
		-- they're already in one, or if they don't qualify for that business). A party is always
		-- created around a job -- that's what the members are readying up for.
		Create = "create",
		-- Join an existing party. `target` is either a Player already in it or the party's id
		-- string -- the browser UI has the id, a "join my friend" button has the player.
		Join = "join",
		-- Sender leaves their party. On a shared job this finishes their run early (prorated payout).
		Leave = "leave",
		-- Leader removes `target` (a Player) from the party (same job treatment as Leave).
		Kick = "kick",
		-- Leader dissolves the party; every member is removed.
		Disband = "disband",
		-- Sender flips their own ready flag. The party's job starts the moment EVERY member is
		-- ready, so this is how the run is launched -- there's no separate "start" button.
		Ready = "ready",
	},
}

return PartyConfig
