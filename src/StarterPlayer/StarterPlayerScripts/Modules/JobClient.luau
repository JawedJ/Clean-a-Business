--!strict

-- One active job on the CLIENT, created when the local player's ActiveJob attribute is
-- set (by accepting a job) and destroyed when it changes or clears. It builds the wall
-- EditableImage overlays for the job (via the SurfaceManager engine), tracks local
-- completion for UI, reports each finished wall to the server (WallCleaned), and is told
-- about finished stains by JobController (from DecalCleaned).
--
-- Stain VISIBILITY (hidden unless on the job, restored on redo) is owned separately by
-- DecalVisibility, driven by JobController off the same ActiveJob attribute.
--
-- One class, data-driven by the building -- adding a business needs no new code here.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local BusinessConfig = require(ReplicatedStorage.SharedModules.BusinessConfig)
local CompletionWeights = require(ReplicatedStorage.SharedModules.CompletionWeights)
local SurfaceManager = require(script.Parent.SurfaceManager)
local DecalVisibility = require(script.Parent.DecalVisibility)
local SpillVisibility = require(script.Parent.SpillVisibility)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local WallCleaned = Remotes:WaitForChild("WallCleaned") :: RemoteEvent
-- Reports our live wall completion (whole-wall units) to the server, which trusts it for
-- the prorated finish-early reward (walls are erased client-side, so their partial progress
-- isn't server-verifiable). Sent on a timer -- see the reporter loop in new().
local WallCompletion = Remotes:WaitForChild("WallCompletion") :: RemoteEvent

-- How often (seconds) we push wall completion to the server while it's changing.
local WALL_REPORT_INTERVAL = 1

local JobClient = {}
JobClient.__index = JobClient

export type JobClient = typeof(setmetatable(
	{} :: {
		businessId: string,
		alive: boolean,
		totalWalls: number,
		totalDecals: number,
		totalSpills: number,
		cleanedDecals: number,
		cleanedSpills: number,
		-- Called with the new 0..1 completion after every clean (and once totals load), so
		-- the completion UI can track progress. nil if no one is listening.
		onProgress: ((number) -> ())?,
	},
	JobClient
))

local function countChildren(folder: Instance, className: string): number
	local n = 0
	for _, child in folder:GetChildren() do
		if child:IsA(className) then
			n += 1
		end
	end
	return n
end

function JobClient.new(businessId: string, onProgress: ((number) -> ())?): JobClient
	local self = setmetatable({}, JobClient) :: JobClient
	self.businessId = businessId
	self.alive = true
	self.totalWalls = 0
	self.totalDecals = 0
	self.totalSpills = 0
	self.cleanedDecals = 0
	self.cleanedSpills = 0
	self.onProgress = onProgress

	task.spawn(function()
		self:_load()
	end)
	task.spawn(function()
		self:_reportWallProgress()
	end)

	return self
end

-- Push our wall completion to the server about once a second while alive, but only when it
-- changed since the last send, so a job sitting idle costs no traffic. The server trusts
-- this figure for the prorated finish-early reward (see WallCompletion). Finishing early
-- also sends a fresh value with the FinishEarly event, so the payout matches the % shown
-- even if the last timer tick was up to a second ago.
function JobClient._reportWallProgress(self: JobClient)
	local lastSent = -1
	while self.alive do
		task.wait(WALL_REPORT_INTERVAL)
		if not self.alive then
			break
		end
		local amount = self:getWallAmount()
		if amount ~= lastSent then
			lastSent = amount
			WallCompletion:FireServer(amount)
		end
	end
end

-- Resolve the building's cleanables (they may stream/replicate in) and start the job.
-- `alive` is re-checked after every yield so a job switched away mid-load wires up nothing.
function JobClient._load(self: JobClient)
	local businesses = Workspace:WaitForChild(Config.BusinessesFolderName)
	if not self.alive then
		return
	end
	local building = businesses:WaitForChild(self.businessId, 10)
	if not building or not self.alive then
		return
	end
	local cleanables = building:WaitForChild(Config.CleanablesFolderName, 10)
	if not cleanables or not self.alive then
		return
	end

	local walls = cleanables:WaitForChild(Config.WallsFolderName, 10)
	if not self.alive then
		return
	end

	-- Stain visibility (show/hide/restore) is owned by DecalVisibility, driven by
	-- JobController; here we just read the total for the local completion %.
	self.totalDecals = DecalVisibility.getStainCount(self.businessId)
	-- Spill visibility works the same way (owned by SpillVisibility); read the total here.
	self.totalSpills = SpillVisibility.getSpillCount(self.businessId)

	if walls then
		self.totalWalls = countChildren(walls, "BasePart")
		SurfaceManager.buildWalls(walls, function(part)
			self:_onWallCleaned(part)
		end, function()
			-- Any wall's clean amount changed (mid-wash) -- re-push completion so the bar
			-- moves smoothly, not just when a whole wall finishes.
			self:_notifyProgress()
		end)
	end

	-- Totals are known now (0 before this); push the starting completion so the UI can
	-- paint an accurate empty bar rather than waiting for the first clean.
	self:_notifyProgress()
end

-- Fire the progress callback with the current completion, if anyone is listening.
function JobClient._notifyProgress(self: JobClient)
	if self.onProgress then
		self.onProgress(self:getCompletion())
	end
end

-- A wall finished: report it to the server. Progress is pushed by the per-stroke callback
-- from SurfaceManager (which fires on the finishing stroke too), so we don't re-notify here.
function JobClient._onWallCleaned(self: JobClient, part: BasePart)
	if not self.alive then
		return
	end
	WallCleaned:FireServer(part)
end

-- Called by JobController when the server confirms a stain this client cleaned. The
-- actual hiding is done by JobController (so the last stain of a job still hides even if
-- this JobClient is torn down by completion); here we just track progress.
function JobClient.onDecalCleaned(self: JobClient, _model: Model)
	if not self.alive then
		return
	end
	self.cleanedDecals += 1
	self:_notifyProgress()
end

-- Called by JobController when this client finishes mopping a spill (client-driven, like a
-- wall). The hiding is done by JobController/SpillVisibility; here we just track progress for
-- the completion bar. The server is told separately (MopController -> CleanSpill) for the
-- reward + authoritative completion.
function JobClient.onSpillCleaned(self: JobClient, _model: Model)
	if not self.alive then
		return
	end
	self.cleanedSpills += 1
	self:_notifyProgress()
end

-- Live wall completion in whole-wall units (a half-washed wall counts as 0.5). This is what
-- we report to the server for the finish-early reward, kept in the same units the server
-- combines with its stain count.
function JobClient.getWallAmount(self: JobClient): number
	return SurfaceManager.getCleanedWallAmount()
end

-- 0..1 fraction of this job cleaned locally (for UI). Walls contribute their live clean
-- amount (a half-washed wall counts as half), so this moves smoothly mid-wall rather than
-- stepping only when a whole wall finishes. The three cleanable kinds (walls, stains, spills)
-- are weighted by CompletionWeights so a business with only some kinds still fills the whole
-- bar. Mirrored server-side in JobServer.getCompletion (same shared weighting).
function JobClient.getCompletion(self: JobClient): number
	local hasWalls = self.totalWalls > 0
	local hasDecals = self.totalDecals > 0
	local hasSpills = self.totalSpills > 0
	local def = BusinessConfig[self.businessId]
	return CompletionWeights.combine({
		hasWalls = hasWalls,
		hasDecals = hasDecals,
		hasSpills = hasSpills,
		wallShare = if hasWalls then self:getWallAmount() / self.totalWalls else 0,
		decalShare = if hasDecals then self.cleanedDecals / self.totalDecals else 0,
		spillShare = if hasSpills then self.cleanedSpills / self.totalSpills else 0,
		decalWeight = (def and def.DecalWeight) or Config.DefaultDecalWeight,
		spillWeight = (def and def.SpillWeight) or Config.DefaultSpillWeight,
	})
end

function JobClient.destroy(self: JobClient)
	self.alive = false
	SurfaceManager.clear()
end

return JobClient
