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
local GoHome = Remotes:WaitForChild("GoHome") :: RemoteEvent

-- Multiplier applied to the completion reward of a "play again" replay: finishing a job
-- makes the SAME business eligible for one bonus run, claimed by re-accepting it (the
-- JobSummary's PlayAgain button, which just fires AcceptJob again).
local REPLAY_BONUS = 1.5

local JobService = {}

-- The JobServer each player is currently on the clock for, or nil.
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

-- Drop the character onto a building's TeleportPart (upright, slightly above it),
-- facing the same direction as the part's Front face (flattened so we never pitch/roll).
local function teleportToJob(character: Model, building: Instance)
	local teleportPart = building:FindFirstChild(Config.TeleportPartName)
	if not teleportPart or not teleportPart:IsA("BasePart") then
		warn(string.format("[JobService] Building %s has no %q part.", building.Name, Config.TeleportPartName))
		return
	end
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

	-- Claim the replay bonus if this accept is the eligible business (PlayAgain on the same
	-- job you just finished); otherwise pay normal rate. Either way the pending eligibility
	-- is spent -- accepting anything clears it, so the bonus only ever applies to the very
	-- next run after a finish.
	local multiplier = if replayBonusBusiness[player] == businessId then REPLAY_BONUS else 1
	replayBonusBusiness[player] = nil

	-- This callback runs when the job ends -- genuine completion OR finish-early (both go
	-- through JobServer -> onComplete), never a job switch or leave. End the job right away
	-- (clearing ActiveJob hides the HUD, stops cleaning, and cues the client's 1s camera
	-- pull-back + JobSummary reveal) and mark this business eligible for one replay bonus.
	-- We no longer teleport home here -- the JobSummary's GoHome button does that on demand.
	jobs[player] = JobServer.new(player, businessId, building, multiplier, function(_job)
		JobService.endJob(player)
		replayBonusBusiness[player] = businessId
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

-- Player pressed GoHome on the JobSummary: send them back to their plot spawn. This is the
-- teleport that used to fire automatically a second after finishing; now it's on demand so
-- the player can sit on the summary (and PlayAgain) as long as they like. No-op if they're
-- somehow back on a job.
local function goHome(player: Player)
	if JobService.getActiveJob(player) == nil then
		PlotService.sendToPlotSpawn(player)
	end
end

function JobService.init()
	AcceptJob.OnServerEvent:Connect(accept)
	FinishEarly.OnServerEvent:Connect(finishEarly)
	WallCompletion.OnServerEvent:Connect(reportWallCompletion)
	GoHome.OnServerEvent:Connect(goHome)

	Players.PlayerRemoving:Connect(function(player)
		JobService.endJob(player)
		replayBonusBusiness[player] = nil
	end)
end

return JobService
