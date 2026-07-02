--!strict

-- The job board MANAGER. Owns the per-player active JobServer instances and the AcceptJob
-- flow: validate the player has Unlocked the business, end any job they're already on,
-- spin up a fresh JobServer, publish the businessId on the ActiveJob player attribute (so
-- their client loads the wall overlays + restores the stains), and teleport them onto the
-- building's TeleportPart. One job at a time.
--
-- The shared buildings -- including their Cleanables -- are authored in the Workspace, so
-- nothing is spawned here; accepting a job is a fresh, per-session clean. When a job
-- finishes, its JobServer pays the completion reward and calls back here to end it, which
-- clears the ActiveJob attribute (ending the state on the client). Pressing the button
-- again starts a brand-new job and reloads everything -- that's the redo.
--
-- The cleaning services authorize cleans through getActiveJob (a player may only clean
-- the business they currently hold) and report cleans through getJob.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).server
local JobServer = require(script.Parent.JobServer)
local PlotService = require(script.Parent.PlotService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local AcceptJob = Remotes:WaitForChild("AcceptJob") :: RemoteEvent
local FinishEarly = Remotes:WaitForChild("FinishEarly") :: RemoteEvent
local WallCompletion = Remotes:WaitForChild("WallCompletion") :: RemoteEvent

local JobService = {}

-- The JobServer each player is currently on the clock for, or nil.
local jobs: { [Player]: JobServer.JobServer } = {}

local function businessesFolder(): Instance?
	return Workspace:FindFirstChild(Config.BusinessesFolderName)
end

local function buildingFor(businessId: string): Instance?
	local folder = businessesFolder()
	return folder and folder:FindFirstChild(businessId)
end

-- Drop the character onto a building's TeleportPart (upright, slightly above it).
local function teleportToJob(character: Model, building: Instance)
	local teleportPart = building:FindFirstChild(Config.TeleportPartName)
	if not teleportPart or not teleportPart:IsA("BasePart") then
		warn(string.format("[JobService] Building %s has no %q part.", building.Name, Config.TeleportPartName))
		return
	end
	character:WaitForChild("HumanoidRootPart")
	character:PivotTo(CFrame.new(teleportPart.Position + Config.TeleportOffset))
end

local function isUnlocked(player: Player, businessId: string): boolean
	return DataService:get(player, { "BusinessList", businessId, "Unlocked" }) == true
end

-- End a player's current job: drop the JobServer and clear the ActiveJob attribute (which
-- tears the job state down on their client). Safe to call with no active job.
function JobService.endJob(player: Player)
	local job = jobs[player]
	if not job then
		return
	end
	job:destroy()
	jobs[player] = nil
	player:SetAttribute(Config.ActiveJobAttribute, nil)
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

-- The player's active JobServer, or nil. The cleaning services report cleans into it.
function JobService.getJob(player: Player): JobServer.JobServer?
	return jobs[player]
end

local function accept(player: Player, businessId: any)
	if type(businessId) ~= "string" then
		return
	end
	if not isUnlocked(player, businessId) then
		return -- not unlocked: ignore (button shouldn't have been offered)
	end
	local building = buildingFor(businessId)
	if not building then
		warn(string.format("[JobService] No building %q under Workspace.%s.", businessId, Config.BusinessesFolderName))
		return
	end

	-- One at a time: drop whatever they were on first. Re-accepting the same business is
	-- exactly the "redo" path -- a fresh JobServer with progress reset to zero.
	JobService.endJob(player)

	-- This callback runs only on genuine completion (JobServer.complete), not on a
	-- job switch or leave. Hold the completed state a beat -- the job stays active for
	-- that second, so the client keeps showing the finished 100% frame and first-person
	-- camera -- then END the job (which clears ActiveJob, restoring the camera/zoom) and
	-- send them home. Bail if they've since started another job (this one's no longer the
	-- active one), so we don't end/teleport out of a fresh job.
	jobs[player] = JobServer.new(player, businessId, building, function(job)
		task.delay(1, function()
			if jobs[player] ~= job then
				return
			end
			JobService.endJob(player)
			PlotService.sendToPlotSpawn(player)
		end)
	end)
	player:SetAttribute(Config.ActiveJobAttribute, businessId)

	local character = player.Character
	if character then
		teleportToJob(character, building)
	end
end

-- Client's periodic wall-completion report (whole-wall units): trusted for the prorated
-- finish-early reward only (walls are erased client-side, so partial progress can't be
-- server-verified). Ignored if they aren't on a job or the value isn't a number.
local function reportWallCompletion(player: Player, amount: any)
	local job = jobs[player]
	if job and type(amount) == "number" then
		job:reportWallProgress(amount)
	end
end

-- Player asked to stop their job early: fold in the wall completion they report at press
-- time (so the payout matches the % they were shown), pay the prorated reward, and end the
-- job. Ignored if they aren't on a job (nothing to finish).
local function finishEarly(player: Player, wallAmount: any)
	local job = jobs[player]
	if not job then
		return
	end
	if type(wallAmount) == "number" then
		job:reportWallProgress(wallAmount)
	end
	job:finishEarly()
end

function JobService.init()
	AcceptJob.OnServerEvent:Connect(accept)
	FinishEarly.OnServerEvent:Connect(finishEarly)
	WallCompletion.OnServerEvent:Connect(reportWallCompletion)

	Players.PlayerRemoving:Connect(function(player)
		JobService.endJob(player)
	end)
end

return JobService
