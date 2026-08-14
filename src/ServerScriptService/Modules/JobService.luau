--!strict

-- The job board MANAGER. Owns the active JobServer sessions and the AcceptJob flow: validate that
-- everyone who will be on the job has Unlocked the business and still meets its requirements
-- (BusinessService.meetsRequirements -- level + owned tools), end any job they're already on, spin
-- up a fresh JobServer, publish the businessId on each player's ActiveJob attribute (so their
-- client loads the wall overlays + restores the stains), and teleport them onto the building's
-- TeleportPart. One job at a time, per player.
--
-- PARTIES (see PartyService): accepting a job while in a party starts ONE shared session for every
-- member -- they are all teleported in, all put on the clock, and all cleaning the same cleanables
-- with the same completion bar. Only the LEADER may accept, and the job is refused unless EVERY
-- member qualifies for the business (the party UI is expected to keep unqualified players out in
-- the first place; this is the server-side backstop). A player with no party gets a session of one,
-- which behaves exactly as a solo job always did.
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
local DataService = require(ReplicatedStorage.Packages.DataService).server
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

local function isUnlocked(player: Player, businessId: string): boolean
	return DataService:get(player, { "BusinessList", businessId, "Unlocked" }) == true
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

-- Can this player be put on this business's job right now? Checked for EVERY member of a party
-- before the job starts, so a shared job never begins with someone who isn't entitled to it.
local function qualifies(player: Player, businessId: string): boolean
	if not isUnlocked(player, businessId) then
		return false
	end
	-- Unlocking is one-way, so the Unlocked flag alone can outlive the requirements that earned it
	-- (a config change adding a gate to a business someone already owns). Re-check them here so the
	-- live requirements always win. The client board hides the Wash button on the same gates.
	return BusinessService.meetsRequirements(player, businessId)
end

local function accept(player: Player, businessId: any)
	if type(businessId) ~= "string" then
		return
	end

	-- Resolve who this accept covers. In a party that's every member, and only the leader may press
	-- the button -- a member accepting is ignored rather than starting a second, competing job.
	local party = PartyService.getParty(player)
	if party and party.leader ~= player then
		return
	end
	local members = PartyService.getMembers(player)

	-- All-or-nothing on entitlement: a party job needs EVERY member to qualify. (The party UI is
	-- expected to keep unqualified players from joining in the first place, so this only fires on a
	-- stale party -- someone who lost the requirement, or a forged accept.)
	for _, member in members do
		if not qualifies(member, businessId) then
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
	local session = JobServer.new(businessId, building, members, multipliers, function(member: Player)
		JobService.endJob(member)
		replayBonusBusiness[member] = businessId
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
local function finishEarly(player: Player, wallAmount: any)
	local job = jobs[player]
	if not job then
		return
	end
	if type(wallAmount) == "number" then
		job:reportWallProgress(player, wallAmount)
	end
	job:finishEarly(player)
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
	end
end

function JobService.init()
	-- Buildings never stream out, so their cleanable geometry (and the client overlays on it)
	-- can't despawn mid-job. See pinBusinessesPersistent.
	pinBusinessesPersistent()

	AcceptJob.OnServerEvent:Connect(accept)
	FinishEarly.OnServerEvent:Connect(finishEarly)
	WallCompletion.OnServerEvent:Connect(reportWallCompletion)
	GoHome.OnServerEvent:Connect(goHome)

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
