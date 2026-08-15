--!strict

-- Watches the local player's ActiveJob attribute and owns the one JobClient that
-- represents the job they're currently on. When the attribute is set it spins up a
-- JobClient (which loads overlays + restores stains); when it changes it tears the old
-- one down and builds the new; when it clears (job finished or left) it tears down.
--
-- It also routes the server's DecalCleaned confirmations to hiding the stain locally,
-- independent of the JobClient's lifetime -- so the final stain that *completes* a job
-- (which clears ActiveJob and tears the JobClient down) still vanishes on this client.
--
-- SHARED (PARTY) JOBS. The same routing is what makes a party's job shared on screen: the server
-- sends DecalCleaned / WebCleaned to every member of the session rather than only the cleaner, and
-- adds SpillCleaned (spills are client-driven, so the mopper hides their own and the server relays
-- to the rest) and WallStroke (a member's erase strokes, replayed onto our own wall overlays). Every
-- one of these paths also feeds the JobClient, so the completion bar counts the group's work, not
-- just ours.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local JobClient = require(script.Parent.JobClient)
local DecalVisibility = require(script.Parent.DecalVisibility)
local SpillVisibility = require(script.Parent.SpillVisibility)
local WebVisibility = require(script.Parent.WebVisibility)
local GarbageVisibility = require(script.Parent.GarbageVisibility)
local SurfaceManager = require(script.Parent.SurfaceManager)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DecalCleaned = Remotes:WaitForChild("DecalCleaned") :: RemoteEvent
local WebCleaned = Remotes:WaitForChild("WebCleaned") :: RemoteEvent
local SpillCleaned = Remotes:WaitForChild("SpillCleaned") :: RemoteEvent
local WallStroke = Remotes:WaitForChild("WallStroke") :: RemoteEvent

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
	-- Webs (vacuum targets) are shown/hidden/restored the same way, owned by WebVisibility.
	WebVisibility.setActiveBusiness(businessId)
	-- Garbage is owned by GarbageVisibility too, but it doesn't merely show and hide: it rebuilds
	-- this job's own local clones of the business's pieces at their authored positions. That IS the
	-- garbage reset, and being local is what keeps two players working the same building from
	-- dragging each other's garbage around.
	GarbageVisibility.setActiveBusiness(businessId)
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

-- Called by GarbageShredController when the server confirms a piece of garbage shredded on this job
-- -- by us or by a party member. Disposing of the piece is GarbageShredController's own job (it owns
-- the animation and the clone); this only counts it toward the completion bar. Identified by
-- surfaceId, not by instance: every client's garbage is its own local clone.
function JobController.onGarbageCleaned(surfaceId: string)
	if current then
		current:onGarbageCleaned(surfaceId)
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

	-- Webs mirror stains exactly: the server confirms a vacuumed web, we hide it locally (regardless
	-- of JobClient state, so the last web of a job still vanishes) and count it toward the bar.
	WebCleaned.OnClientEvent:Connect(function(web)
		-- A web may be a BasePart or a Model (WebResolver accepts either), so don't gate on Model.
		if typeof(web) ~= "Instance" or not (web:IsA("BasePart") or web:IsA("Model")) then
			return
		end
		WebVisibility.hideOne(web)
		if current then
			current:onWebCleaned(web)
		end
	end)

	-- A party member fully mopped a spill: hide it here and count it, exactly as if we had. The
	-- server sends this to the OTHER members only (the mopper's own client already did both when its
	-- fade finished), so it can't double-count anyone.
	SpillCleaned.OnClientEvent:Connect(function(model)
		if typeof(model) ~= "Instance" or not model:IsA("Model") then
			return
		end
		SpillVisibility.hideOne(model)
		if current then
			current:onSpillCleaned(model)
		end
	end)

	-- A batch of erase strokes from a party member's washer. Replaying them on our own overlays is
	-- what keeps every member's EditableImages -- and therefore the shared completion bar -- showing
	-- the same wall. A wall finished by the replay reports itself to the server through the normal
	-- path (SurfaceManager -> JobClient -> WallCleaned), which the session dedupes.
	WallStroke.OnClientEvent:Connect(function(strokes)
		if type(strokes) ~= "table" then
			return
		end
		for _, stroke in strokes :: { any } do
			if
				type(stroke) == "table"
				and typeof(stroke.part) == "Instance"
				and stroke.part:IsA("BasePart")
				and typeof(stroke.to) == "Vector3"
			then
				SurfaceManager.applyRemoteStroke(stroke.part, stroke.to, stroke.from, stroke.radius)
			end
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
