--!strict

-- The job board MANAGER. Owns the active JobServer sessions and the AcceptJob flow: validate that
-- everyone who will be on the job has Unlocked the business and still meets its requirements
-- (BusinessService.meetsRequirements -- level + owned tools), end any job they're already on, spin
-- up a fresh JobServer, publish the businessId on each player's ActiveJob attribute (so their
-- client loads the wall overlays + restores the stains), and teleport them onto the building's
-- TeleportPart. One job at a time, per player.
--
-- PARTIES (see PartyService): a party's job starts ONE shared session for every member -- they are
-- all teleported in, all put on the clock, and all cleaning the same cleanables with the same
-- completion bar. Two things start it, both covering the whole party: EVERY member readying up
-- (PartyService.onAllReady), and the LEADER alone firing AcceptJob -- the board's Wash or the
-- summary's PlayAgain, which replays the run the party already agreed to. A non-leader's AcceptJob
-- is ignored. Either way the job is refused unless every member qualifies for the business (the
-- party UI keeps unqualified players out in the first place; this is the server-side backstop). A
-- player with no party gets a session of one, which behaves exactly as a solo job always did. A
-- party that COMPLETES its job is disbanded.
--
-- The shared buildings -- including their Cleanables -- are authored in the Workspace, so nothing is
-- spawned here; accepting a job is a fresh, per-session clean. When a session finishes, JobServer
-- pays the completion reward to every member and calls back here to end it for each of them, which
-- clears their ActiveJob attribute (ending the state on their client). Pressing the button again
-- starts a brand-new job and reloads everything -- that's the redo.
--
-- The cleaning services authorize cleans through getActiveJob (a player may only clean the business
-- they currently hold) and report cleans through getJob. Because a party's members share ONE
-- JobServer, a clean by any of them is recorded once and counts for all -- and the services use
-- getSessionMembers to mirror the visual result (stain/web/spill hidden, wall strokes applied) onto
-- everyone else on the session.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local BusinessService = require(script.Parent.BusinessService)
local JobServer = require(script.Parent.JobServer)
local PartyService = require(script.Parent.PartyService)
local PlotService = require(script.Parent.PlotService)
local SkillsService = require(script.Parent.SkillsService)
local TutorialService = require(script.Parent.TutorialService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local AcceptJob = Remotes:WaitForChild("AcceptJob") :: RemoteEvent
local FinishEarly = Remotes:WaitForChild("FinishEarly") :: RemoteEvent
local WallCompletion = Remotes:WaitForChild("WallCompletion") :: RemoteEvent
local GoHome = Remotes:WaitForChild("GoHome") :: RemoteEvent

-- Multiplier applied to the completion reward of a "play again" replay: finishing a job
-- makes the SAME business eligible for one bonus run, claimed by re-accepting it (the
-- JobSummary's PlayAgain button, which just fires AcceptJob again).
local REPLAY_BONUS = 1.5

local JobService = {}

-- The JobServer session each player is currently on the clock for, or nil. Every member of a shared
-- session maps to the SAME JobServer instance.
local jobs: { [Player]: JobServer.JobServer } = {}

-- The businessId a player just finished (full completion or finish-early) that is eligible
-- for one REPLAY_BONUS run. Set when a job ends, consumed (and cleared) by the next accept:
-- accepting that same business pays the bonus, accepting anything else clears it. This keeps
-- the bonus server-authoritative -- the client never asks for it, it just re-accepts.
local replayBonusBusiness: { [Player]: string } = {}

local function businessesFolder(): Instance?
	return Workspace:FindFirstChild(Config.BusinessesFolderName)
end

local function buildingFor(businessId: string): Instance?
	local folder = businessesFolder()
	return folder and folder:FindFirstChild(businessId)
end

-- Keep every shared business building fully loaded on every client, no matter how far away
-- they roam. The buildings are cleaned via per-client EditableImage overlays parented to the
-- wall parts (see SurfaceManager); with StreamingEnabled a Default-streaming building can cull
-- a wall part mid-job, taking its client-side overlay decal with it -- the wall visually goes
-- blank even though the server's completion tracking (JobServer) is untouched, so the player
-- keeps getting paid for cleaning a wall they can no longer see. Marking the buildings
-- Persistent removes that whole class of streaming despawn. Applied to any Model added to the
-- Businesses folder later too, so a newly authored business needs no extra wiring.
local function pinBusinessesPersistent()
	local folder = businessesFolder()
	if not folder then
		return
	end
	local function pin(inst: Instance)
		if inst:IsA("Model") then
			inst.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		end
	end
	for _, child in folder:GetChildren() do
		pin(child)
	end
	folder.ChildAdded:Connect(pin)
end

-- A building's TeleportPart, or nil if it's missing/isn't a BasePart. Resolved BEFORE a job is
-- started (see accept): a job the players can't be dropped into is refused outright rather than
-- accepted and left with them standing wherever they were, on the clock for a building they never
-- entered. Non-recursive by design -- the part is authored as a direct child of the building.
local function teleportPartFor(building: Instance): BasePart?
	local teleportPart = building:FindFirstChild(Config.TeleportPartName)
	return if teleportPart and teleportPart:IsA("BasePart") then teleportPart else nil
end

-- Drop the character onto a building's TeleportPart (upright, slightly above it),
-- facing the same direction as the part's Front face (flattened so we never pitch/roll).
local function teleportToJob(character: Model, teleportPart: BasePart)
	character:WaitForChild("HumanoidRootPart")
	local pos = teleportPart.Position + Config.TeleportOffset
	local front = teleportPart.CFrame.LookVector
	local flat = Vector3.new(front.X, 0, front.Z)
	flat = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.new(0, 0, -1)
	character:PivotTo(CFrame.lookAt(pos, pos + flat))
end

-- End a player's run: drop them from their session (destroying it once its last member is gone)
-- and clear the ActiveJob attribute, which tears the job state down on their client. Everyone else
-- on a shared session is untouched -- their job, and its progress, continues. Safe to call with no
-- active job.
function JobService.endJob(player: Player)
	local job = jobs[player]
	if not job then
		return
	end
	jobs[player] = nil
	player:SetAttribute(Config.ActiveJobAttribute, nil)
	job:removeMember(player)
	if job:getMemberCount() == 0 then
		job:destroy()
	end
	-- Going off the clock can reopen their party to newcomers -- a party is unjoinable while ANY
	-- member is working, so the last one to finish makes it joinable again. Said outright rather than
	-- left to PartyService's ActiveJob watcher to notice, so a party's return to the browser doesn't
	-- depend on that side channel. No-op for a player with no party.
	PartyService.refreshJoinable()
end

-- The businessId the player is currently on the clock for, or nil. Used by the cleaning
-- services to authorize a clean against the job the player actually holds.
function JobService.getActiveJob(player: Player): string?
	local job = jobs[player]
	if job then
		return job.businessId
	end
	return nil
end

-- The player's active JobServer session, or nil. The cleaning services report cleans into it.
function JobService.getJob(player: Player): JobServer.JobServer?
	return jobs[player]
end

-- Everyone else sharing this player's session (empty when they're solo or have no job). The
-- cleaning services fire their "this is cleaned now" confirmations at these players too, so a
-- cleanable removed by one member disappears for the whole party.
function JobService.getOtherMembers(player: Player): { Player }
	local job = jobs[player]
	if not job then
		return {}
	end
	local others: { Player } = {}
	for _, member in job:getMembers() do
		if member ~= player then
			table.insert(others, member)
		end
	end
	return others
end

-- Everyone on this player's session, themselves included (empty when they have no job).
function JobService.getSessionMembers(player: Player): { Player }
	local job = jobs[player]
	return if job then job:getMembers() else {}
end

-- Put `members` on `businessId`'s job as ONE session. The single path onto a job: a solo player is
-- a session of one (from the AcceptJob remote), a party is a session of all its members (from the
-- all-ready hook). All-or-nothing -- if anything here refuses, nobody starts.
local function startJob(businessId: any, members: { Player })
	if type(businessId) ~= "string" or #members == 0 then
		return
	end

	-- All-or-nothing on entitlement: a party job needs EVERY member to qualify. Unlocking is one-way,
	-- so canPlay re-checks the live requirements rather than trusting the Unlocked flag alone -- the
	-- client board hides the Wash button on the same gates, and PartyService refuses a join on them,
	-- so this only fires on a stale party or a forged accept.
	for _, member in members do
		if not BusinessService.canPlay(member, businessId) then
			return
		end
	end

	local building = buildingFor(businessId)
	if not building then
		warn(string.format("[JobService] No building %q under Workspace.%s.", businessId, Config.BusinessesFolderName))
		return
	end

	-- Everything the teleport needs is resolved up front, because accepting is all-or-nothing: a
	-- job that can't put the players inside the building must not start at all. Without this they
	-- would be on the clock, HUD and all, standing outside a building they can't clean.
	local teleportPart = teleportPartFor(building)
	if not teleportPart then
		warn(string.format("[JobService] Building %s has no %q part; refusing the job.", building.Name, Config.TeleportPartName))
		return
	end
	-- Same reasoning for characters: a member mid-respawn has nothing to teleport, so the job waits
	-- rather than starting without them.
	local characters: { [Player]: Model } = {}
	for _, member in members do
		local character = member.Character
		if not character then
			return
		end
		characters[member] = character
	end

	-- One at a time: drop whatever each member was on first. Re-accepting the same business is
	-- exactly the "redo" path -- a fresh session with progress reset to zero.
	for _, member in members do
		JobService.endJob(member)
	end

	-- Claim each member's replay bonus if this accept is the business THEY are eligible on
	-- (PlayAgain on the job they just finished); otherwise they pay normal rate. Either way the
	-- pending eligibility is spent -- accepting anything clears it, so the bonus only ever applies
	-- to the very next run after a finish.
	local multipliers: { [Player]: number } = {}
	for _, member in members do
		multipliers[member] = if replayBonusBusiness[member] == businessId then REPLAY_BONUS else 1
		replayBonusBusiness[member] = nil
	end

	-- This callback runs when a member's run ends -- genuine completion OR finish-early (both go
	-- through JobServer), never a job switch or leave. End their job right away (clearing ActiveJob
	-- hides the HUD, stops cleaning, and cues the client's 1s camera pull-back + JobSummary reveal)
	-- and mark this business eligible for one replay bonus for them. We no longer teleport home
	-- here -- the JobSummary's GoHome button does that on demand.
	--
	-- A party that FINISHES its job is also disbanded here: the group formed around this one
	-- business, they played it, and each of them is now on their own summary free to play again or
	-- go home -- none of which should silently keep them queued up together for another run. Only on
	-- full completion; a single member bailing early leaves the party (and the job) intact for the
	-- rest. The first member's disband takes the whole party down, so the later calls no-op.
	local session: JobServer.JobServer
	session = JobServer.new(businessId, building, members, multipliers, function(member: Player)
		JobService.endJob(member)
		replayBonusBusiness[member] = businessId
		if session:isComplete() then
			PartyService.disbandFor(member)
		end
	end)

	for _, member in members do
		jobs[member] = session
		member:SetAttribute(Config.ActiveJobAttribute, businessId)
		teleportToJob(characters[member], teleportPart)
		-- Starting a job is what ends the tutorial's "pick a job" step. A no-op otherwise --
		-- including for the PlayAgain re-accept, which lands on a later step than the one this
		-- advances, and for anyone not in the tutorial.
		TutorialService.notifyJobAccepted(member)
	end

	-- And the mirror of endJob's: a party that has just started working closes to newcomers.
	PartyService.refreshJoinable()
end

-- The AcceptJob remote: one player pressing Wash on the board, or PlayAgain on their summary.
--
-- In a party this covers the WHOLE party -- everyone is put back on the clock and teleported in
-- together -- and only the LEADER may fire it. A member pressing it is ignored rather than starting
-- a second, competing job, or dragging the group somewhere the leader didn't choose. This is the one
-- way a party's job starts other than everybody readying up: it's the leader replaying the run the
-- party already agreed to.
local function onAcceptJob(player: Player, businessId: any)
	local party = PartyService.getParty(player)
	if party then
		if party.leader ~= player then
			return
		end
		-- Cloned: the roster keeps changing under the session this builds.
		startJob(businessId, table.clone(party.members))
		return
	end
	startJob(businessId, { player })
end

-- Client's periodic wall-completion report (whole-wall units): trusted for the prorated
-- finish-early reward only (walls are erased client-side, so partial progress can't be
-- server-verified). Ignored if they aren't on a job or the value isn't a number.
local function reportWallCompletion(player: Player, amount: any)
	local job = jobs[player]
	if job and type(amount) == "number" then
		job:reportWallProgress(player, amount)
	end
end

-- Player asked to stop their job early: fold in the wall completion they report at press time (so
-- the payout matches the % they were shown), pay the prorated reward, and end the job FOR THEM.
-- On a shared job everyone else keeps cleaning, with the session's progress untouched. Ignored if
-- they aren't on a job (nothing to finish).
--
-- Bailing also takes them OUT OF THE PARTY. A party exists to play one job together, so a member who
-- has walked off that job has left the group in every sense that matters: keeping them in would hold
-- the party closed to newcomers until they happened to press something, and would sweep them back
-- into the run if the leader hit PlayAgain. Done AFTER the payout, so they're paid for their share
-- of the group's progress first -- and by then their job is already ended, so the leave can't
-- double-finish it.
local function finishEarly(player: Player, wallAmount: any)
	local job = jobs[player]
	if not job then
		return
	end
	if type(wallAmount) == "number" then
		job:reportWallProgress(player, wallAmount)
	end
	job:finishEarly(player)
	PartyService.leaveFor(player)
end

-- Player pressed GoHome on the JobSummary: send them back to their plot spawn. This is the
-- teleport that used to fire automatically a second after finishing; now it's on demand so
-- the player can sit on the summary (and PlayAgain) as long as they like. No-op if they're
-- somehow back on a job.
local function goHome(player: Player)
	if JobService.getActiveJob(player) == nil then
		PlotService.sendToPlotSpawn(player)

		-- Give them their free-roam walk speed back. A job pins them to the slower on-the-clock
		-- speed (JobServer._pinWalkSpeed), and this is the moment they stop being on the clock in
		-- any sense that matters: the job merely ENDING leaves them stood in the business with the
		-- summary up, one PlayAgain away from another run, so the restore belongs here on the
		-- actual trip home rather than back there.
		--
		-- Routed through SkillsService rather than a value captured at job start, so there's one
		-- definition of free-roam speed (StarterPlayer.CharacterWalkSpeed x Speedy, plus the
		-- store's flat speed perk) shared with
		-- respawn and skill purchases -- and buying Speedy mid-job restores the new speed instead
		-- of a stale pre-purchase one. Safe to run when the pin is already gone: the job's
		-- connections were dropped in destroy, so nothing reasserts over this.
		SkillsService.refreshWalkSpeed(player)

		-- Finishing the job and CHOOSING to leave the summary is what ends the tutorial's job step
		-- -- PlayAgain keeps them on it. A no-op outside the tutorial.
		TutorialService.notifyGoHome(player)

		-- Going home also takes them out of any party -- the BACKSTOP for the same rule finishEarly
		-- applies. Whichever way their run ended (bailing early, or finishing it in a party that
		-- somehow wasn't disbanded), choosing to leave the summary is them done with the group's job,
		-- so no party should still be holding them. Leaving is what everyone else's browser needs to
		-- see the party open up again, and it's what stops the leader's PlayAgain from pulling back
		-- someone who has already walked home.
		PartyService.leaveFor(player)
	end
end

function JobService.init()
	-- Buildings never stream out, so their cleanable geometry (and the client overlays on it)
	-- can't despawn mid-job. See pinBusinessesPersistent.
	pinBusinessesPersistent()

	AcceptJob.OnServerEvent:Connect(onAcceptJob)
	FinishEarly.OnServerEvent:Connect(finishEarly)
	WallCompletion.OnServerEvent:Connect(reportWallCompletion)
	GoHome.OnServerEvent:Connect(goHome)

	-- A party whose members have ALL readied up is asking to start the job it formed around. This is
	-- the ONLY way a party's job begins (see onAcceptJob), and it runs through the same startJob a
	-- solo player's Wash does, so the entitlement, building and teleport checks all still apply.
	-- Refused starts (a member mid-respawn) simply leave the party un-readied, to try again.
	PartyService.onAllReady(function(party)
		-- Cloned: startJob outlives this call through the session it builds, and the party's own
		-- roster keeps changing under it as members come and go.
		startJob(party.businessId, table.clone(party.members))
	end)

	-- Leaving a party (by choice, kick or disband) while on a SHARED job ends that player's run the
	-- same way pressing FinishEarly would: they're paid for the group's progress and get their
	-- summary, and the members left behind keep the job. A solo session isn't a party job at all,
	-- so it just carries on.
	PartyService.onMemberRemoved(function(player: Player)
		local job = jobs[player]
		if job and job:getMemberCount() > 1 then
			job:finishEarly(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		JobService.endJob(player)
		replayBonusBusiness[player] = nil
	end)
end

return JobService
