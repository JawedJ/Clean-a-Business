--!strict

-- One active job SESSION on the server, created per business when a job is accepted and dropped
-- when its last member leaves it. It is the AUTHORITY on job progress: it knows how many cleanables
-- the business has (counted from the shared building), records which have been cleaned (deduped,
-- fed in by the cleaning services after they validate each clean), and once every wall, stain,
-- spill, web and piece of garbage is done it pays the completion reward to every member and hands
-- back to JobService to end the job for them.
--
-- A session covers ONE OR MORE players: a solo player is a session of one, and a party (see
-- PartyService) is a session of up to PartyConfig.MaxSize. Everything about the WORK is shared --
-- one set of cleaned cleanables, one completion percentage, one bar -- so a stain cleaned by any
-- member is cleaned for all of them and counts once. Everything about the PAYOUT is per member:
-- each has their own replay multiplier, their own mastery/skill boosts, their own Completions
-- tally and their own JobSummary.
--
-- Two ways a member's run ends:
--   * FULL COMPLETION -- every cleanable is done. Every member still in the session is paid the
--     completion reward and finishes together.
--   * FINISH EARLY -- one member bails. They alone are paid, prorated by the SESSION's completion
--     percentage (so it reflects what the group had cleaned), and they alone leave; everyone else
--     keeps cleaning the same job with the same progress.
--
-- One class, data-driven by the building + BusinessConfig -- adding a business needs no new code here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local BusinessConfig = require(ReplicatedStorage.SharedModules.BusinessConfig)
local CompletionWeights = require(ReplicatedStorage.SharedModules.CompletionWeights)
local Mastery = require(ReplicatedStorage.SharedModules.Mastery)
local JobRating = require(ReplicatedStorage.SharedModules.JobRating)
local DataService = require(ReplicatedStorage.Packages.DataService).server
local ProgressionService = require(script.Parent.ProgressionService)
local ShopPerks = require(script.Parent.ShopPerks)
local SkillsService = require(script.Parent.SkillsService)

-- Fired to a member when their run ends (full completion OR finish-early) so their client can show
-- the JobSummary screen. See JobSummaryController.
local JobSummary = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("JobSummary") :: RemoteEvent

local JobServer = {}
JobServer.__index = JobServer

-- Everything that is per-MEMBER rather than per-session.
export type Member = {
	player: Player,
	-- Multiplier on this member's completion payout (1 normally, 1.5 on a PlayAgain replay -- see
	-- JobService's replay-bonus tracking). Applied to full completion and finish-early alike.
	rewardMultiplier: number,
	-- This member's latest client-reported wall completion, in whole-wall units. Walls are erased
	-- client-side, so their PARTIAL progress can't be server-verified. Members of a shared job all
	-- see the same overlays (strokes are relayed), so the reports converge; the session takes the
	-- highest as the group's figure. Only affects the prorated finish-early payout.
	reportedWallAmount: number,
	-- The walk-speed pin's connections for this member, dropped when they leave the session.
	connections: { RBXScriptConnection },
}

export type JobServer = typeof(setmetatable(
	{} :: {
		businessId: string,
		-- Called with a member whose run has just ended (paid, summary fired). JobService uses it to
		-- clear their ActiveJob attribute and drop them from the session.
		onMemberFinished: (Player) -> (),
		-- os.clock() when the job was accepted, for the summary's "finished in mm:ss". One value for
		-- the session: every member starts together.
		startedAt: number,
		members: { [Player]: Member },
		memberCount: number,
		totalWalls: number,
		totalDecals: number,
		totalSpills: number,
		totalWebs: number,
		totalGarbage: number,
		-- SHARED across the session: cleaned by anyone means cleaned for everyone, counted once.
		cleanedWalls: { [string]: boolean },
		cleanedDecals: { [string]: boolean },
		cleanedSpills: { [string]: boolean },
		cleanedWebs: { [string]: boolean },
		cleanedGarbage: { [string]: boolean },
		cleanedWallCount: number,
		cleanedDecalCount: number,
		cleanedSpillCount: number,
		cleanedWebCount: number,
		cleanedGarbageCount: number,
		-- True once the session has fully completed (every cleanable done). Not the same as a member
		-- being finished -- see finishEarly.
		completed: boolean,
		-- False once destroy() has run: guards the async walk-speed binding from wiring up a
		-- humanoid after the session has already ended.
		alive: boolean,
	},
	JobServer
))

-- Count the cleanables of one kind authored in a building's Cleanables folder.
local function countChildren(building: Instance, folderName: string, className: string): number
	local cleanables = building:FindFirstChild(Config.CleanablesFolderName)
	local folder = cleanables and cleanables:FindFirstChild(folderName)
	if not folder then
		return 0
	end
	local n = 0
	for _, child in folder:GetChildren() do
		if child:IsA(className) then
			n += 1
		end
	end
	return n
end

-- Count the cleanables of one kind that may be authored as EITHER a bare BasePart or a Model (webs
-- and garbage -- see WebResolver / GarbageResolver): every direct child of the folder carrying the
-- given id attribute. Exactly what the client counts (WebVisibility / GarbageVisibility) so the two
-- agree.
local function countIdentified(building: Instance, folderName: string, idAttribute: string): number
	local cleanables = building:FindFirstChild(Config.CleanablesFolderName)
	local folder = cleanables and cleanables:FindFirstChild(folderName)
	if not folder then
		return 0
	end
	local n = 0
	for _, child in folder:GetChildren() do
		if (child:IsA("BasePart") or child:IsA("Model")) and child:GetAttribute(idAttribute) ~= nil then
			n += 1
		end
	end
	return n
end

-- Start a session on `building` for `members`, each with their own completion multiplier (keyed by
-- player; missing entries default to 1).
function JobServer.new(
	businessId: string,
	building: Instance,
	members: { Player },
	multipliers: { [Player]: number },
	onMemberFinished: (Player) -> ()
): JobServer
	local self = setmetatable({}, JobServer) :: JobServer
	self.businessId = businessId
	self.onMemberFinished = onMemberFinished
	self.startedAt = os.clock()
	self.members = {}
	self.memberCount = 0
	self.totalWalls = countChildren(building, Config.WallsFolderName, "BasePart")
	self.totalDecals = countChildren(building, Config.DecalsFolderName, "Model")
	self.totalSpills = countChildren(building, Config.SpillsFolderName, "Model")
	self.totalWebs = countIdentified(building, Config.WebsFolderName, Config.SurfaceIdAttribute)
	self.totalGarbage = countIdentified(building, Config.GarbageFolderName, Config.GarbageSurfaceIdAttribute)
	self.cleanedWalls = {}
	self.cleanedDecals = {}
	self.cleanedSpills = {}
	self.cleanedWebs = {}
	self.cleanedGarbage = {}
	self.cleanedWallCount = 0
	self.cleanedDecalCount = 0
	self.cleanedSpillCount = 0
	self.cleanedWebCount = 0
	self.cleanedGarbageCount = 0
	self.completed = false
	self.alive = true

	for _, player in members do
		self:addMember(player, multipliers[player] or 1)
	end

	return self
end

function JobServer.addMember(self: JobServer, player: Player, rewardMultiplier: number)
	if self.members[player] then
		return
	end
	local member: Member = {
		player = player,
		rewardMultiplier = rewardMultiplier,
		reportedWallAmount = 0,
		connections = {},
	}
	self.members[player] = member
	self.memberCount += 1
	self:_pinWalkSpeed(member)
end

-- Drop a member from the session (they finished, bailed, or disconnected). Does NOT pay anything --
-- paying is complete()/finishEarly()'s job. The session's shared progress is untouched, so the
-- members still on it keep cleaning exactly where the group left off.
function JobServer.removeMember(self: JobServer, player: Player)
	local member = self.members[player]
	if not member then
		return
	end
	for _, conn in member.connections do
		conn:Disconnect()
	end
	table.clear(member.connections)
	self.members[player] = nil
	self.memberCount -= 1
end

function JobServer.hasMember(self: JobServer, player: Player): boolean
	return self.members[player] ~= nil
end

function JobServer.getMemberCount(self: JobServer): number
	return self.memberCount
end

-- Every player currently on this session, as a fresh array (safe to iterate while members leave).
function JobServer.getMembers(self: JobServer): { Player }
	local result: { Player } = {}
	for player in self.members do
		table.insert(result, player)
	end
	return result
end

-- Pin a member's walk speed for the life of their run: apply it to the current character, reassert
-- it whenever anything changes it, and reapply to any character they respawn into while still on
-- the job. The pinned speed is Config.JobWalkSpeed scaled by their Speedy skill, recomputed on each
-- apply so buying Speedy mid-job takes effect at once.
--
-- This is a DIFFERENT speed from free-roam, which is StarterPlayer.CharacterWalkSpeed scaled by the
-- same skill (see SkillsService) -- so something has to hand the player back their free-roam speed
-- once they're done. It doesn't happen by itself: the two are only equal while nobody has retuned
-- CharacterWalkSpeed away from Config.JobWalkSpeed, and relying on that left players walking at the
-- job speed after every job until their next respawn. That restore lives in JobService.goHome (the
-- trip back to the plot), not in removeMember -- see the note there. The member's connections are
-- dropped when they leave the session, so nothing re-pins the speed once their run is over.
function JobServer._pinWalkSpeed(self: JobServer, member: Member)
	local player = member.player
	local function bind(character: Model)
		task.spawn(function()
			local humanoid = character:WaitForChild("Humanoid", 10)
			-- The session may have ended (or the member left, or the character been replaced) while
			-- we waited.
			if not self.alive or self.members[player] ~= member or not humanoid or not humanoid:IsA("Humanoid") then
				return
			end
			local function apply()
				-- Same shape as the free-roam speed (SkillsService.applyWalkSpeed), off the job's
				-- own base: the Speedy multiplier scales it, then the store's permanent speed perk
				-- is added flat -- the perk is explicitly meant to apply on the clock too.
				local target = Config.JobWalkSpeed * SkillsService.getMultiplier(player, "Speedy")
					+ ShopPerks.getSpeedBonus(player)
				-- Guard the reassign so setting it back to target doesn't re-fire us in a loop
				-- (a same-value write wouldn't fire Changed anyway, but this is explicit).
				if humanoid.WalkSpeed ~= target then
					humanoid.WalkSpeed = target
				end
			end
			apply()
			table.insert(member.connections, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(apply))
		end)
	end

	table.insert(member.connections, player.CharacterAdded:Connect(bind))
	if player.Character then
		bind(player.Character)
	end
end

function JobServer.isWallCleaned(self: JobServer, surfaceId: string): boolean
	return self.cleanedWalls[surfaceId] == true
end

function JobServer.isDecalCleaned(self: JobServer, surfaceId: string): boolean
	return self.cleanedDecals[surfaceId] == true
end

function JobServer.isSpillCleaned(self: JobServer, surfaceId: string): boolean
	return self.cleanedSpills[surfaceId] == true
end

function JobServer.isWebCleaned(self: JobServer, surfaceId: string): boolean
	return self.cleanedWebs[surfaceId] == true
end

function JobServer.isGarbageCleaned(self: JobServer, surfaceId: string): boolean
	return self.cleanedGarbage[surfaceId] == true
end

-- Total cleanables, and how many are fully done server-side (deduped WallCleaned + validated
-- stains) -- the authoritative count the full-completion trigger uses.
function JobServer.getTotal(self: JobServer): number
	return self.totalWalls + self.totalDecals + self.totalSpills + self.totalWebs + self.totalGarbage
end

function JobServer.getCleaned(self: JobServer): number
	return self.cleanedWallCount
		+ self.cleanedDecalCount
		+ self.cleanedSpillCount
		+ self.cleanedWebCount
		+ self.cleanedGarbageCount
end

-- Record a member's latest wall completion (whole-wall units). Client-trusted -- clamped to
-- [0, totalWalls] so a garbage value can't blow the reward past 100% of the walls. Only affects the
-- prorated finish-early reward, never full completion.
function JobServer.reportWallProgress(self: JobServer, player: Player, amount: number)
	local member = self.members[player]
	if member then
		member.reportedWallAmount = math.clamp(amount, 0, self.totalWalls)
	end
end

-- The group's wall progress: the highest figure any member currently reports. Members of a shared
-- job see the same overlays (wall strokes are relayed between them), so their reports agree to
-- within a report interval; taking the max means a member who just joined the tick late, or whose
-- report is momentarily behind, can't drag the group's payout down.
function JobServer._groupWallAmount(self: JobServer): number
	local best = 0
	for _, member in self.members do
		if member.reportedWallAmount > best then
			best = member.reportedWallAmount
		end
	end
	return best
end

-- 0..1 fraction of the job cleaned by the SESSION, used for the prorated finish-early reward (0 if
-- the business has no cleanables). Stains, spills and webs are server-authoritative; walls use the
-- group's live report, floored at the server-verified full-wall count so it can never pay LESS than
-- what we've confirmed. Full completion does NOT use this -- see _checkComplete, which gates on the
-- authoritative counts only.
--
-- Stains are weighted at the business's DecalWeight of the job, walls at the rest -- kept in sync
-- with the client bar (JobClient.getCompletion) so the finish-early payout matches the % the player
-- saw. If the business has only one kind of cleanable, that kind is the whole job.
function JobServer.getCompletion(self: JobServer): number
	local hasWalls = self.totalWalls > 0
	local hasDecals = self.totalDecals > 0
	local hasSpills = self.totalSpills > 0
	local hasWebs = self.totalWebs > 0
	local hasGarbage = self.totalGarbage > 0
	local walls = math.clamp(self:_groupWallAmount(), self.cleanedWallCount, self.totalWalls)
	local def = BusinessConfig[self.businessId]
	return CompletionWeights.combine({
		hasWalls = hasWalls,
		hasDecals = hasDecals,
		hasSpills = hasSpills,
		hasWebs = hasWebs,
		hasGarbage = hasGarbage,
		wallShare = if hasWalls then walls / self.totalWalls else 0,
		decalShare = if hasDecals then self.cleanedDecalCount / self.totalDecals else 0,
		spillShare = if hasSpills then self.cleanedSpillCount / self.totalSpills else 0,
		webShare = if hasWebs then self.cleanedWebCount / self.totalWebs else 0,
		garbageShare = if hasGarbage then self.cleanedGarbageCount / self.totalGarbage else 0,
		decalWeight = (def and def.DecalWeight) or Config.DefaultDecalWeight,
		spillWeight = (def and def.SpillWeight) or Config.DefaultSpillWeight,
		webWeight = (def and def.WebWeight) or Config.DefaultWebWeight,
		garbageWeight = (def and def.GarbageWeight) or Config.DefaultGarbageWeight,
	})
end

function JobServer.isComplete(self: JobServer): boolean
	return self.completed
end

-- Tell one member's client to show the JobSummary screen. `fraction` is how much of the job the
-- SESSION had cleaned (1 for a full completion, the group's share for a finish-early), which drives
-- the star rating; `cash`/`xp` are the amounts actually awarded to them (already multiplied).
function JobServer._fireSummary(self: JobServer, player: Player, cash: number, xp: number, fraction: number)
	-- Fold this job's star rating into the player's running Ratings tally so the Company UI can
	-- show their business's AVERAGE rating (Sum / Count). Every job end is rated -- a full
	-- completion (fraction 1 -> 5 stars) and a finish-early (prorated) alike -- since both funnel
	-- through here. The client's JobSummary uses the same JobRating.starsFor, so the star it shows
	-- for this job is exactly the one we bank.
	local stars = JobRating.starsFor(fraction)
	DataService:update(player, { "Ratings", "Sum" }, function(current: number?)
		return (current or 0) + stars
	end)
	DataService:update(player, { "Ratings", "Count" }, function(current: number?)
		return (current or 0) + 1
	end)

	JobSummary:FireClient(player, {
		businessId = self.businessId,
		cash = cash,
		xp = xp,
		fraction = fraction,
		duration = os.clock() - self.startedAt,
	})
end

-- Pay one member their full completion reward and end their run. Shared by complete() across every
-- member still on the session.
function JobServer._payCompletion(self: JobServer, member: Member)
	local player = member.player

	-- Mastery stars are earned off the LIFETIME Completions count, so read it BEFORE we tally this
	-- run. The XP boost applied here therefore matches the star level the player already had (and
	-- the board's Rewards line already showed) when they started the job -- crossing a milestone
	-- rewards the NEXT job, not the one that crossed it.
	local completions = DataService:get(player, { "BusinessList", self.businessId, "Completions" }) or 0
	local masteryMultiplier = Mastery.xpMultiplier(Mastery.starsForCompletions(completions))

	-- Tally this completion in the player's business record. The record is guaranteed to exist -- a
	-- job can't start (let alone complete) unless the business was Unlocked -- but default the count
	-- anyway so a missing field can't error the write.
	DataService:update(player, { "BusinessList", self.businessId, "Completions" }, function(current: number?)
		return (current or 0) + 1
	end)

	-- Completion pays the business's BaseReward (Cash) and XpReward (XP) as a lump bonus on top of
	-- the per-clean rewards, scaled by this member's replay multiplier. XP is additionally scaled by
	-- the mastery multiplier (+5% of base per star -- see Mastery). Every member of a shared job is
	-- paid this in full: the group's work finished the job, so the job's reward is each member's.
	-- Paid silently via awardCash/awardXp (not reward), so no floating popup is fired -- the
	-- balances/XP bar just tick up, and the JobSummary reports the totals instead.
	local def = BusinessConfig[self.businessId]
	local cash, xp = 0, 0
	if def then
		-- The awards apply the player's Greed/Inteligence skill boosts and return what they actually
		-- credited, so the summary reports the boosted totals.
		cash = ProgressionService.awardCash(player, math.floor(def.BaseReward * member.rewardMultiplier))
		xp = ProgressionService.awardXp(player, math.floor(def.XpReward * member.rewardMultiplier * masteryMultiplier))
	end

	self:_fireSummary(player, cash, xp, 1)
end

-- The whole job is done: pay every member still on the session and finish them all together. Runs
-- once.
function JobServer.complete(self: JobServer)
	if self.completed then
		return
	end
	self.completed = true

	-- Snapshot the roster first: onMemberFinished ends each member's job, which removes them from
	-- self.members mid-loop.
	local finishing: { Member } = {}
	for _, member in self.members do
		table.insert(finishing, member)
	end
	for _, member in finishing do
		self:_payCompletion(member)
	end
	for _, member in finishing do
		self.onMemberFinished(member.player)
	end
end

-- End ONE member's run early at their request, paying them a prorated share of the completion
-- reward for the fraction the GROUP has cleaned so far (10% cleaned -> a tenth of BaseReward +
-- XpReward), then handing back to JobService to end it for them. Everyone else keeps cleaning: the
-- session, its progress and its cleanables are untouched.
--
-- Unlike complete() this does NOT tally a Completions -- the player bailed, so it doesn't count as
-- a finished job. Uses the server's own getCompletion (the authority) so the payout can't be
-- inflated by the client. A no-op if the session already completed or they aren't a member.
function JobServer.finishEarly(self: JobServer, player: Player)
	if self.completed then
		return
	end
	local member = self.members[player]
	if not member then
		return
	end

	-- XP carries the same mastery boost as a full completion (see _payCompletion). A finish-early
	-- never tallies a Completions, so the star level is simply whatever the player currently holds
	-- on this business.
	local completions = DataService:get(player, { "BusinessList", self.businessId, "Completions" }) or 0
	local masteryMultiplier = Mastery.xpMultiplier(Mastery.starsForCompletions(completions))

	local fraction = self:getCompletion()
	local def = BusinessConfig[self.businessId]
	local cash, xp = 0, 0
	if def then
		-- As in _payCompletion: award the prorated base reward and report the boosted amounts the
		-- awards actually credited (Greed/Inteligence applied) on the summary.
		cash = ProgressionService.awardCash(player, math.floor(def.BaseReward * fraction * member.rewardMultiplier))
		xp = ProgressionService.awardXp(
			player,
			math.floor(def.XpReward * fraction * member.rewardMultiplier * masteryMultiplier)
		)
	end

	self:_fireSummary(player, cash, xp, fraction)
	self.onMemberFinished(player)
end

-- Finish the job once every cleanable is done (and there's at least one).
function JobServer._checkComplete(self: JobServer)
	if self.completed or self:getTotal() == 0 then
		return
	end
	if
		self.cleanedWallCount >= self.totalWalls
		and self.cleanedDecalCount >= self.totalDecals
		and self.cleanedSpillCount >= self.totalSpills
		and self.cleanedWebCount >= self.totalWebs
		and self.cleanedGarbageCount >= self.totalGarbage
	then
		self:complete()
	end
end

-- Record a wall as cleaned for the whole session (idempotent). Returns true if this was a new clean.
function JobServer.markWallCleaned(self: JobServer, surfaceId: string): boolean
	if self.cleanedWalls[surfaceId] then
		return false
	end
	self.cleanedWalls[surfaceId] = true
	self.cleanedWallCount += 1
	self:_checkComplete()
	return true
end

function JobServer.markDecalCleaned(self: JobServer, surfaceId: string): boolean
	if self.cleanedDecals[surfaceId] then
		return false
	end
	self.cleanedDecals[surfaceId] = true
	self.cleanedDecalCount += 1
	self:_checkComplete()
	return true
end

function JobServer.markSpillCleaned(self: JobServer, surfaceId: string): boolean
	if self.cleanedSpills[surfaceId] then
		return false
	end
	self.cleanedSpills[surfaceId] = true
	self.cleanedSpillCount += 1
	self:_checkComplete()
	return true
end

function JobServer.markWebCleaned(self: JobServer, surfaceId: string): boolean
	if self.cleanedWebs[surfaceId] then
		return false
	end
	self.cleanedWebs[surfaceId] = true
	self.cleanedWebCount += 1
	self:_checkComplete()
	return true
end

-- Record a piece of garbage as cleaned for the whole session (idempotent). NOTE: nothing calls this
-- yet -- carrying garbage is only the first half of the mechanic (see GarbageCarryService); the
-- clean itself (binning it) is still to come. Until then a business with garbage authored can't
-- reach full completion, and its garbage slice of the bar stays empty.
function JobServer.markGarbageCleaned(self: JobServer, surfaceId: string): boolean
	if self.cleanedGarbage[surfaceId] then
		return false
	end
	self.cleanedGarbage[surfaceId] = true
	self.cleanedGarbageCount += 1
	self:_checkComplete()
	return true
end

function JobServer.destroy(self: JobServer)
	self.alive = false
	for player in self.members do
		self:removeMember(player)
	end
	-- Deliberately does NOT restore free-roam walk speed. A job ENDING isn't the player going
	-- anywhere -- they're still standing in the business with the summary up, and may well press
	-- PlayAgain straight back into another run. Handing their speed back there would have them
	-- sprinting around the job site between runs. It's restored when they actually travel home
	-- instead; see JobService.goHome.
end

return JobServer
