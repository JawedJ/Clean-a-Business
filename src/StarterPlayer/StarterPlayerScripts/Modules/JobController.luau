--!strict

-- Watches the local player's ActiveJob attribute and owns the one JobClient that
-- represents the job they're currently on. When the attribute is set it spins up a
-- JobClient (which loads overlays + restores stains); when it changes it tears the old
-- one down and builds the new; when it clears (job finished or left) it tears down.
--
-- It also routes the server's DecalCleaned confirmations to hiding the stain locally,
-- independent of the JobClient's lifetime -- so the final stain that *completes* a job
-- (which clears ActiveJob and tears the JobClient down) still vanishes on this client.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local JobClient = require(script.Parent.JobClient)
local DecalVisibility = require(script.Parent.DecalVisibility)
local SpillVisibility = require(script.Parent.SpillVisibility)

local DecalCleaned = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DecalCleaned") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local JobController = {}

local current: JobClient.JobClient? = nil

-- Listeners for job progress changes (the completion UI). Each is called with the new
-- 0..1 completion whenever the active JobClient reports a clean.
local progressListeners: { (number) -> () } = {}

local function emitProgress(fraction: number)
	for _, listener in progressListeners do
		listener(fraction)
	end
end

-- Subscribe to the active job's completion (0..1), fired on every clean. Returns a
-- disconnect function. Persistent across jobs -- the callback simply stops receiving
-- updates between jobs.
function JobController.onProgressChanged(callback: (number) -> ()): () -> ()
	table.insert(progressListeners, callback)
	return function()
		local index = table.find(progressListeners, callback)
		if index then
			table.remove(progressListeners, index)
		end
	end
end

local function setJob(businessId: string?)
	if current then
		current:destroy()
		current = nil
	end
	-- Show this business's stains (hide the previous job's). Done here, not in JobClient,
	-- so stains hide the instant the job ends even before the JobClient finishes tearing
	-- down, and so it's the single owner of stain visibility.
	DecalVisibility.setActiveBusiness(businessId)
	-- Spills are shown/hidden/reset (redo) the same way, owned by SpillVisibility.
	SpillVisibility.setActiveBusiness(businessId)
	if businessId then
		current = JobClient.new(businessId, emitProgress)
	end
end

-- Called by MopController when this client fully mops a spill. Hide it locally (independent of
-- the JobClient's lifetime, so the spill that COMPLETES a job -- which tears the JobClient down --
-- still vanishes) and, if a job is live, count it toward the completion bar. The server is told
-- separately by MopController (CleanSpill) for the reward + authoritative completion.
function JobController.onSpillCleaned(model: Model)
	SpillVisibility.hideOne(model)
	if current then
		current:onSpillCleaned(model)
	end
end

-- The local player's active JobClient, or nil. (For UI / other systems.)
function JobController.getJob(): JobClient.JobClient?
	return current
end

function JobController.init()
	DecalCleaned.OnClientEvent:Connect(function(model)
		if typeof(model) ~= "Instance" or not model:IsA("Model") then
			return
		end
		-- Hide regardless of JobClient state so the last stain of a job still vanishes.
		DecalVisibility.hideOne(model)
		if current then
			current:onDecalCleaned(model)
		end
	end)

	local function sync()
		local id = localPlayer:GetAttribute(Config.ActiveJobAttribute)
		setJob(if type(id) == "string" then id else nil)
	end
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(sync)
	sync()
end

return JobController
