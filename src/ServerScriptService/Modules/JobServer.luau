--!strict

-- One active job on the SERVER, created per (player, business) when a job is accepted
-- and dropped when it completes or is replaced. It is the AUTHORITY on job progress: it
-- knows how many cleanables the business has (counted from the shared building), records
-- which the player has cleaned (deduped, fed in by the cleaning services after they
-- validate each clean), and once every wall and stain is done it pays the completion
-- reward and hands back to JobService to end the job.
--
-- One class, data-driven by the building + BusinessConfig -- adding a business needs no
-- new code here. Cleans come in through markWallCleaned / markDecalCleaned; UI and other
-- systems read getCompletion / isComplete.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local BusinessConfig = require(ReplicatedStorage.SharedModules.BusinessConfig)
local CompletionWeights = require(ReplicatedStorage.SharedModules.CompletionWeights)
local Mastery = require(ReplicatedStorage.SharedModules.Mastery)
local JobRating = require(ReplicatedStorage.SharedModules.JobRating)
local DataService = require(ReplicatedStorage.Packages.DataService).server
local ProgressionService = require(script.Parent.ProgressionService)
local SkillsService = require(script.Parent.SkillsService)

-- Fired to the owning player when the job ends (full completion OR finish-early) so their
-- client can show the JobSummary screen. See JobSummaryController.
local JobSummary = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("JobSummary") :: RemoteEvent

local JobServer = {}
JobServer.__index = JobServer

export type JobServer = typeof(setmetatable(
	{} :: {
		player: Player,
		businessId: string,
		onComplete: (JobServer) -> (),
		-- Multiplier on the completion payout (1 normally, 1.5 on a PlayAgain replay -- see
		-- JobService's replay-bonus tracking). Applied to full completion and the prorated
		-- finish-early reward alike.
		rewardMultiplier: number,
		-- os.clock() when the job was accepted, for the summary's "finished in mm:ss".
		startedAt: number,
		totalWalls: number,
		totalDecals: number,
		totalSpills: number,
		totalWebs: number,
		cleanedWalls: { [string]: boolean },
		cleanedDecals: { [string]: boolean },
		cleanedSpills: { [string]: boolean },
		cleanedWebs: { [string]: boolean },
		cleanedWallCount: number,
		cleanedDecalCount: number,
		cleanedSpillCount: number,
		cleanedWebCount: number,
		-- Client-reported wall completion in whole-wall units (e.g. 2.5 of 5 walls). Walls
		-- are erased entirely client-side, so their PARTIAL progress can't be server-verified
		-- -- we trust the client's report (throttled ~1/s, and refreshed when they finish
		-- early) purely for the prorated finish-early reward. The authoritative FULL
		-- completion still comes from cleanedWallCount (deduped WallCleaned events).
		reportedWallAmount: number,
		completed: boolean,
		-- False once destroy() has run: guards the async walk-speed binding from wiring up a
		-- humanoid after the job has already ended.
		alive: boolean,
		-- Every connection this job holds (walk-speed pinning), all dropped in destroy.
		connections: { RBXScriptConnection },
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

-- Count the cleanable webs authored in a building. Unlike walls/stains/spills a web may be a bare
-- BasePart OR a Model (see WebResolver), so count every direct child of the CleanableWebs folder
-- carrying a SurfaceIdAttribute -- exactly what the client counts (WebVisibility) so the two agree.
local function countWebs(building: Instance): number
	local cleanables = building:FindFirstChild(Config.CleanablesFolderName)
	local folder = cleanables and cleanables:FindFirstChild(Config.WebsFolderName)
	if not folder then
		return 0
	end
	local n = 0
	for _, child in folder:GetChildren() do
		if (child:IsA("BasePart") or child:IsA("Model")) and child:GetAttribute(Config.SurfaceIdAttribute) ~= nil then
			n += 1
		end
	end
	return n
end

function JobServer.new(
	player: Player,
	businessId: string,
	building: Instance,
	rewardMultiplier: number,
	onComplete: (JobServer) -> ()
): JobServer
	local self = setmetatable({}, JobServer) :: JobServer
	self.player = player
	self.businessId = businessId
	self.onComplete = onComplete
	self.rewardMultiplier = rewardMultiplier
	self.startedAt = os.clock()
	self.totalWalls = countChildren(building, Config.WallsFolderName, "BasePart")
	self.totalDecals = countChildren(building, Config.DecalsFolderName, "Model")
	self.totalSpills = countChildren(building, Config.SpillsFolderName, "Model")
	self.totalWebs = countWebs(building)
	self.cleanedWalls = {}
	self.cleanedDecals = {}
	self.cleanedSpills = {}
	self.cleanedWebs = {}
	self.cleanedWallCount = 0
	self.cleanedDecalCount = 0
	self.cleanedSpillCount = 0
	self.cleanedWebCount = 0
	self.reportedWallAmount = 0
	self.completed = false
	self.alive = true
	self.connections = {}
	self:_pinWalkSpeed()
	return self
end

-- Pin the owner's walk speed for the life of the job: apply it to the current character, reassert
-- it whenever anything changes it, and reapply to any character the player respawns into while
-- still on the job. The pinned speed is Config.JobWalkSpeed scaled by the player's Speedy skill --
-- recomputed on each apply so buying Speedy mid-job takes effect at once -- matching their free-roam
-- speed, so ending the job leaves them at the right speed with nothing to restore. All connections
-- are torn down in destroy.
function JobServer._pinWalkSpeed(self: JobServer)
	local function bind(character: Model)
		task.spawn(function()
			local humanoid = character:WaitForChild("Humanoid", 10)
			-- The job may have ended (or the character been replaced) while we waited.
			if not self.alive or not humanoid or not humanoid:IsA("Humanoid") then
				return
			end
			local function apply()
				local target = Config.JobWalkSpeed * SkillsService.getMultiplier(self.player, "Speedy")
				-- Guard the reassign so setting it back to target doesn't re-fire us in a loop
				-- (a same-value write wouldn't fire Changed anyway, but this is explicit).
				if humanoid.WalkSpeed ~= target then
					humanoid.WalkSpeed = target
				end
			end
			apply()
			table.insert(self.connections, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(apply))
		end)
	end

	table.insert(self.connections, self.player.CharacterAdded:Connect(bind))
	if self.player.Character then
		bind(self.player.Character)
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

-- Total cleanables, and how many are fully done server-side (deduped WallCleaned +
-- validated stains) -- the authoritative count the full-completion trigger uses.
function JobServer.getTotal(self: JobServer): number
	return self.totalWalls + self.totalDecals + self.totalSpills + self.totalWebs
end

function JobServer.getCleaned(self: JobServer): number
	return self.cleanedWallCount + self.cleanedDecalCount + self.cleanedSpillCount + self.cleanedWebCount
end

-- Record the client's latest wall completion (whole-wall units). Client-trusted -- clamp
-- to [0, totalWalls] so a garbage value can't blow the reward past 100% of the walls; the
-- lower bound against server-verified walls is applied in getCompletion (cleanedWallCount
-- moves independently). Only affects the prorated finish-early reward, never full completion.
function JobServer.reportWallProgress(self: JobServer, amount: number)
	self.reportedWallAmount = math.clamp(amount, 0, self.totalWalls)
end

-- 0..1 fraction of the job cleaned, used for the prorated finish-early reward (0 if the
-- business has no cleanables). Stains are server-authoritative (cleanedDecalCount); walls
-- use the client's live report, floored at the server-verified full-wall count so it can
-- never pay LESS than what we've confirmed. Full completion does NOT use this -- see
-- _checkComplete, which gates on the authoritative counts only.
--
-- Stains are weighted at the business's DecalWeight of the job, walls at the rest -- kept in
-- sync with the client bar (JobClient.getCompletion) so the finish-early payout matches the %
-- the player saw. If the business has only one kind of cleanable, that kind is the whole job.
function JobServer.getCompletion(self: JobServer): number
	local hasWalls = self.totalWalls > 0
	local hasDecals = self.totalDecals > 0
	local hasSpills = self.totalSpills > 0
	local hasWebs = self.totalWebs > 0
	-- Walls use the client's live report, floored at the server-verified full-wall count so it
	-- can never pay LESS than what we've confirmed. Stains + spills + webs are server-authoritative.
	local walls = math.clamp(self.reportedWallAmount, self.cleanedWallCount, self.totalWalls)
	local def = BusinessConfig[self.businessId]
	return CompletionWeights.combine({
		hasWalls = hasWalls,
		hasDecals = hasDecals,
		hasSpills = hasSpills,
		hasWebs = hasWebs,
		wallShare = if hasWalls then walls / self.totalWalls else 0,
		decalShare = if hasDecals then self.cleanedDecalCount / self.totalDecals else 0,
		spillShare = if hasSpills then self.cleanedSpillCount / self.totalSpills else 0,
		webShare = if hasWebs then self.cleanedWebCount / self.totalWebs else 0,
		decalWeight = (def and def.DecalWeight) or Config.DefaultDecalWeight,
		spillWeight = (def and def.SpillWeight) or Config.DefaultSpillWeight,
		webWeight = (def and def.WebWeight) or Config.DefaultWebWeight,
	})
end

function JobServer.isComplete(self: JobServer): boolean
	return self.completed
end

-- Tell the owning player's client to show the JobSummary screen. `fraction` is how much of
-- the job was cleaned (1 for a full completion, the prorated share for a finish-early), which
-- drives the star rating; `cash`/`xp` are the amounts actually awarded (already multiplied).
function JobServer._fireSummary(self: JobServer, cash: number, xp: number, fraction: number)
	-- Fold this job's star rating into the player's running Ratings tally so the Company UI can
	-- show their business's AVERAGE rating (Sum / Count). Every job end is rated -- a full
	-- completion (fraction 1 -> 5 stars) and a finish-early (prorated) alike -- since both funnel
	-- through here. The client's JobSummary uses the same JobRating.starsFor, so the star it shows
	-- for this job is exactly the one we bank.
	local stars = JobRating.starsFor(fraction)
	DataService:update(self.player, { "Ratings", "Sum" }, function(current: number?)
		return (current or 0) + stars
	end)
	DataService:update(self.player, { "Ratings", "Count" }, function(current: number?)
		return (current or 0) + 1
	end)

	JobSummary:FireClient(self.player, {
		businessId = self.businessId,
		cash = cash,
		xp = xp,
		fraction = fraction,
		duration = os.clock() - self.startedAt,
	})
end

-- Pay the completion reward and hand back to JobService to end the job. Runs once.
function JobServer.complete(self: JobServer)
	if self.completed then
		return
	end
	self.completed = true

	-- Mastery stars are earned off the LIFETIME Completions count, so read it BEFORE we tally
	-- this run. The XP boost applied here therefore matches the star level the player already
	-- had (and the board's Rewards line already showed) when they started the job -- crossing a
	-- milestone rewards the NEXT job, not the one that crossed it.
	local completions = DataService:get(self.player, { "BusinessList", self.businessId, "Completions" }) or 0
	local masteryMultiplier = Mastery.xpMultiplier(Mastery.starsForCompletions(completions))

	-- Tally this completion in the player's business record. The record is guaranteed to
	-- exist -- a job can't start (let alone complete) unless the business was Unlocked --
	-- but default the count anyway so a missing field can't error the write.
	DataService:update(self.player, { "BusinessList", self.businessId, "Completions" }, function(current: number?)
		return (current or 0) + 1
	end)

	-- Completion pays the business's BaseReward (Cash) and XpReward (XP) as a lump bonus on
	-- top of the per-clean rewards, scaled by the replay multiplier. XP is additionally scaled
	-- by the mastery multiplier (+5% of base per star -- see Mastery). Paid silently via awardCash/awardXp
	-- (not reward), so no floating popup is fired to the client -- the balances/XP bar just
	-- tick up, and the JobSummary reports the totals instead.
	local def = BusinessConfig[self.businessId]
	local cash, xp = 0, 0
	if def then
		-- Award the base completion reward; the awards apply the player's Greed/Inteligence skill
		-- boosts and return what they actually credited, so the summary reports the boosted totals.
		cash = ProgressionService.awardCash(self.player, math.floor(def.BaseReward * self.rewardMultiplier))
		xp = ProgressionService.awardXp(self.player, math.floor(def.XpReward * self.rewardMultiplier * masteryMultiplier))
	end

	self:_fireSummary(cash, xp, 1)
	self.onComplete(self)
end

-- End the job early at the player's request, paying a prorated share of the completion
-- reward for the fraction cleaned so far (10% cleaned -> a tenth of BaseReward + XpReward),
-- then handing back to JobService to end it. Unlike complete() this does NOT tally a
-- Completions -- the player bailed, so it doesn't count as a finished job. Uses the
-- server's own getCompletion (the authority) so the payout can't be inflated by the client.
-- Runs once; a no-op if the job already completed or was already finished early.
function JobServer.finishEarly(self: JobServer)
	if self.completed then
		return
	end
	self.completed = true

	-- XP carries the same mastery boost as a full completion (see complete). A finish-early never
	-- tallies a Completions, so the star level is simply whatever the player currently holds on
	-- this business.
	local completions = DataService:get(self.player, { "BusinessList", self.businessId, "Completions" }) or 0
	local masteryMultiplier = Mastery.xpMultiplier(Mastery.starsForCompletions(completions))

	local fraction = self:getCompletion()
	local def = BusinessConfig[self.businessId]
	local cash, xp = 0, 0
	if def then
		-- As in complete(): award the prorated base reward and report the boosted amounts the
		-- awards actually credited (Greed/Inteligence applied) on the summary.
		cash = ProgressionService.awardCash(self.player, math.floor(def.BaseReward * fraction * self.rewardMultiplier))
		xp = ProgressionService.awardXp(self.player, math.floor(def.XpReward * fraction * self.rewardMultiplier * masteryMultiplier))
	end

	self:_fireSummary(cash, xp, fraction)
	self.onComplete(self)
end

-- Finish the job once every wall and stain is done (and there's at least one cleanable).
function JobServer._checkComplete(self: JobServer)
	if self.completed or self:getTotal() == 0 then
		return
	end
	if
		self.cleanedWallCount >= self.totalWalls
		and self.cleanedDecalCount >= self.totalDecals
		and self.cleanedSpillCount >= self.totalSpills
		and self.cleanedWebCount >= self.totalWebs
	then
		self:complete()
	end
end

-- Record a wall as cleaned (idempotent). Returns true if this was a new clean.
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

function JobServer.destroy(self: JobServer)
	self.alive = false
	for _, conn in self.connections do
		conn:Disconnect()
	end
	table.clear(self.connections)
end

return JobServer
