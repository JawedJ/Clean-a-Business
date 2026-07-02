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

local JobServer = {}
JobServer.__index = JobServer

export type JobServer = typeof(setmetatable(
	{} :: {
		player: Player,
		businessId: string,
		onComplete: (JobServer) -> (),
		totalWalls: number,
		totalDecals: number,
		cleanedWalls: { [string]: boolean },
		cleanedDecals: { [string]: boolean },
		cleanedWallCount: number,
		cleanedDecalCount: number,
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
	onComplete: (JobServer) -> ()
): JobServer
	local self = setmetatable({}, JobServer) :: JobServer
	self.player = player
	self.businessId = businessId
	self.onComplete = onComplete
	self.totalWalls = countChildren(building, Config.WallsFolderName, "BasePart")
	self.totalDecals = countChildren(building, Config.DecalsFolderName, "Model")
	self.cleanedWalls = {}
	self.cleanedDecals = {}
	self.cleanedWallCount = 0
	self.cleanedDecalCount = 0
	self.completed = false
	return self
end

function JobServer.isWallCleaned(self: JobServer, surfaceId: string): boolean
	return self.cleanedWalls[surfaceId] == true
end

function JobServer.isDecalCleaned(self: JobServer, surfaceId: string): boolean
	return self.cleanedDecals[surfaceId] == true
end

-- Total cleanables, and how many are done (for completion % / UI).
function JobServer.getTotal(self: JobServer): number
	return self.totalWalls + self.totalDecals
end

function JobServer.getCleaned(self: JobServer): number
	return self.cleanedWallCount + self.cleanedDecalCount
end

-- 0..1 fraction of the job cleaned (0 if the business has no cleanables).
function JobServer.getCompletion(self: JobServer): number
	local total = self:getTotal()
	if total == 0 then
		return 0
	end
	return self:getCleaned() / total
end

function JobServer.isComplete(self: JobServer): boolean
	return self.completed
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
	-- top of the per-clean rewards. Paid silently via awardCash/awardXp (not reward), so no
	-- floating popup is fired to the client -- the balances/XP bar just tick up.
	local def = BusinessConfig[self.businessId]
	if def then
		ProgressionService.awardCash(self.player, def.BaseReward)
		ProgressionService.awardXp(self.player, def.XpReward)
	end

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

	local def = BusinessConfig[self.businessId]
	if def then
		local fraction = self:getCompletion()
		ProgressionService.awardCash(self.player, math.floor(def.BaseReward * fraction))
		ProgressionService.awardXp(self.player, math.floor(def.XpReward * fraction))
	end

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
