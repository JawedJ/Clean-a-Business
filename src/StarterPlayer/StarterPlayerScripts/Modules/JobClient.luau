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
local SurfaceManager = require(script.Parent.SurfaceManager)
local DecalVisibility = require(script.Parent.DecalVisibility)

local WallCleaned = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("WallCleaned") :: RemoteEvent

local JobClient = {}
JobClient.__index = JobClient

export type JobClient = typeof(setmetatable(
	{} :: {
		businessId: string,
		alive: boolean,
		totalWalls: number,
		totalDecals: number,
		cleanedWalls: number,
		cleanedDecals: number,
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

function JobClient.new(businessId: string): JobClient
	local self = setmetatable({}, JobClient) :: JobClient
	self.businessId = businessId
	self.alive = true
	self.totalWalls = 0
	self.totalDecals = 0
	self.cleanedWalls = 0
	self.cleanedDecals = 0

	task.spawn(function()
		self:_load()
	end)

	return self
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

	if walls then
		self.totalWalls = countChildren(walls, "BasePart")
		SurfaceManager.buildWalls(walls, function(part)
			self:_onWallCleaned(part)
		end)
	end
end

function JobClient._onWallCleaned(self: JobClient, part: BasePart)
	if not self.alive then
		return
	end
	self.cleanedWalls += 1
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
end

-- 0..1 fraction of this job cleaned locally (for UI).
function JobClient.getCompletion(self: JobClient): number
	local total = self.totalWalls + self.totalDecals
	if total == 0 then
		return 0
	end
	return (self.cleanedWalls + self.cleanedDecals) / total
end

function JobClient.destroy(self: JobClient)
	self.alive = false
	SurfaceManager.clear()
end

return JobClient
