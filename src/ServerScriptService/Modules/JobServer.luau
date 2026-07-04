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
local DataService = require(ReplicatedStorage.Packages.DataService).server
local ProgressionService = require(script.Parent.ProgressionService)

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
		cleanedWalls: { [string]: boolean },
		cleanedDecals: { [string]: boolean },
		cleanedWallCount: number,
		cleanedDecalCount: number,
		-- Client-reported wall completion in whole-wall units (e.g. 2.5 of 5 walls). Walls
		-- are erased entirely client-side, so their PARTIAL progress can't be server-verified
		-- -- we trust the client's report (throttled ~1/s, and refreshed when they finish
		-- early) purely for the prorated finish-early reward. The authoritative FULL
		-- completion still comes from cleanedWallCount (deduped WallCleaned events).
		reportedWallAmount: number,
		completed: boolean,
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
	self.cleanedWalls = {}
	self.cleanedDecals = {}
	self.cleanedWallCount = 0
	self.cleanedDecalCount = 0
	self.reportedWallAmount = 0
	self.completed = false
	return self
end

function JobServer.isWallCleaned(self: JobServer, surfaceId: string): boolean
	return self.cleanedWalls[surfaceId] == true
end

function JobServer.isDecalCleaned(self: JobServer, surfaceId: string): boolean
	return self.cleanedDecals[surfaceId] == true
end

-- Total cleanables, and how many are fully done server-side (deduped WallCleaned +
-- validated stains) -- the authoritative count the full-completion trigger uses.
function JobServer.getTotal(self: JobServer): number
	return self.totalWalls + self.totalDecals
end

function JobServer.getCleaned(self: JobServer): number
	return self.cleanedWallCount + self.cleanedDecalCount
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
function JobServer.getCompletion(self: JobServer): number
	local total = self:getTotal()
	if total == 0 then
		return 0
	end
	local walls = math.clamp(self.reportedWallAmount, self.cleanedWallCount, self.totalWalls)
	return (walls + self.cleanedDecalCount) / total
end

function JobServer.isComplete(self: JobServer): boolean
	return self.completed
end

-- Tell the owning player's client to show the JobSummary screen. `fraction` is how much of
-- the job was cleaned (1 for a full completion, the prorated share for a finish-early), which
-- drives the star rating; `cash`/`xp` are the amounts actually awarded (already multiplied).
function JobServer._fireSummary(self: JobServer, cash: number, xp: number, fraction: number)
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

	-- Tally this completion in the player's business record. The record is guaranteed to
	-- exist -- a job can't start (let alone complete) unless the business was Unlocked --
	-- but default the count anyway so a missing field can't error the write.
	DataService:update(self.player, { "BusinessList", self.businessId, "Completions" }, function(current: number?)
		return (current or 0) + 1
	end)

	-- Completion pays the business's BaseReward (Cash) and XpReward (XP) as a lump bonus on
	-- top of the per-clean rewards, scaled by the replay multiplier. Paid silently via
	-- awardCash/awardXp (not reward), so no floating popup is fired to the client -- the
	-- balances/XP bar just tick up, and the JobSummary reports the totals instead.
	local def = BusinessConfig[self.businessId]
	local cash, xp = 0, 0
	if def then
		cash = math.floor(def.BaseReward * self.rewardMultiplier)
		xp = math.floor(def.XpReward * self.rewardMultiplier)
		ProgressionService.awardCash(self.player, cash)
		ProgressionService.awardXp(self.player, xp)
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

	local fraction = self:getCompletion()
	local def = BusinessConfig[self.businessId]
	local cash, xp = 0, 0
	if def then
		cash = math.floor(def.BaseReward * fraction * self.rewardMultiplier)
		xp = math.floor(def.XpReward * fraction * self.rewardMultiplier)
		ProgressionService.awardCash(self.player, cash)
		ProgressionService.awardXp(self.player, xp)
	end

	self:_fireSummary(cash, xp, fraction)
	self.onComplete(self)
end

-- Finish the job once every wall and stain is done (and there's at least one cleanable).
function JobServer._checkComplete(self: JobServer)
	if self.completed or self:getTotal() == 0 then
		return
	end
	if self.cleanedWallCount >= self.totalWalls and self.cleanedDecalCount >= self.totalDecals then
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

function JobServer.destroy(self: JobServer)
	-- Nothing to disconnect yet; here for symmetry + future cleanup.
end

return JobServer
