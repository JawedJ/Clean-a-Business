--!strict

-- Server side of web (vacuum) cleaning, and the AUTHORITY over it. Cleanable webs live in the
-- shared business buildings:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableWebs.<model>
-- The Vacuum Tool lives in ReplicatedStorage.Items; ToolService grants it.
--
-- This is a direct mirror of DecalCleaningService (stains/broom): the client sends a single
-- "I vacuumed this web" request; it does NOT decide when the web is cleaned. The server validates
-- (the player holds this business's job, has the vacuum equipped, and hasn't already cleaned this
-- web on this job), then runs the UseTime timer itself. When its own timer elapses it re-validates,
-- pays the per-web reward, records the web in the player's JobServer (which may complete the job),
-- and -- because webs are SHARED across every player in the game -- it does NOT destroy the model.
-- Instead it tells the cleaning player's client (WebCleaned remote) to hide that model locally, so
-- the web vanishes for them while players on other jobs still see it.
--
-- On a PARTY job that confirmation goes to every member of the session (they share one JobServer,
-- so the web is cleaned once for the group and has to vanish on every member's screen); the
-- per-clean reward stays with whoever vacuumed it.
--
-- Which webs a session has cleaned lives in its JobServer, so it resets every time the job is
-- (re)accepted -- letting them redo the job for the reward again.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local WebResolver = require(ReplicatedStorage.SharedModules.WebResolver)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local JobService = require(script.Parent.JobService)
local ProgressionService = require(script.Parent.ProgressionService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CleanWeb = Remotes:WaitForChild("CleanWeb") :: RemoteEvent
local WebCleaned = Remotes:WaitForChild("WebCleaned") :: RemoteEvent

local TOOL_ID = ToolConfig.vacuum.UniqueID

-- Reward paid once per web fully cleaned (matches a stain's per-clean reward).
local WEB_XP = 4
local WEB_CASH = 4

-- This player's current vacuum UseTime (seconds), read fresh so tool upgrades take effect
-- immediately, falling back to the static ToolConfig default.
local function getUseTime(player: Player): number
	return DataService:get(player, { "Inventory", TOOL_ID, "UseTime" }) or ToolConfig[TOOL_ID].UseTime
end

local WebCleaningService = {}

-- A player may only clean one web at a time; they must wait the full UseTime before the vacuum
-- is usable again. Tracked server-side, never trusted from the client.
local activeClean: { [Player]: boolean } = {}

-- Latest click that arrived while a clean was still active. Because the server's timer starts
-- (and therefore ends) about half a ping AFTER the client's cosmetic bar, an honest click on the
-- NEXT web -- sent the instant the client's bar finished -- can reach us just before the previous
-- timer's completion callback clears activeClean. Dropping that click silently strands the client:
-- it already showed a bar and marked the web started, but no clean ever runs and no WebCleaned ever
-- comes. So instead of dropping, remember the click and process it as soon as the current clean
-- resolves. Only one is kept (newest wins); cleans stay strictly one-at-a-time. Mirrors the broom.
local pendingClick: { [Player]: Instance } = {}

-- True if the player currently has the vacuum equipped (its Tool is parented under their
-- character while equipped).
local function hasVacuumEquipped(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute("ToolId") == TOOL_ID then
			return true
		end
	end
	return false
end

-- Validate that this player may clean this web right now: it's a real web, it belongs to the
-- business whose job they currently hold, and they haven't already cleaned it on this job.
-- Returns the identity.
local function validate(player: Player, target: Instance): WebResolver.WebIdentity?
	local identity = WebResolver.resolve(target)
	if not identity then
		return nil
	end
	if JobService.getActiveJob(player) ~= identity.businessId then
		return nil
	end
	local job = JobService.getJob(player)
	if not job or job:isWebCleaned(identity.surfaceId) then
		return nil
	end
	return identity
end

-- Handle one click on a web: validate, run the authoritative UseTime timer, and on completion
-- reward + confirm. Recurses into the pending click (if one queued up) once the timer resolves,
-- so a boundary click is processed instead of lost.
local function tryStartClean(player: Player, target: Instance)
	-- One clean at a time: hold the click until the current timer finishes.
	if activeClean[player] then
		pendingClick[player] = target
		return
	end

	if not hasVacuumEquipped(player) then
		return
	end

	local identity = validate(player, target)
	if not identity then
		return
	end

	activeClean[player] = true

	-- The SERVER waits out the UseTime; the client cannot shortcut it.
	task.delay(getUseTime(player), function()
		activeClean[player] = nil

		-- Re-validate at completion: the player's job (or their claim to this web) may have
		-- changed during the wait.
		local job = JobService.getJob(player)
		if identity.web.Parent ~= nil and job and validate(player, identity.web) then
			-- Reward the cleaner, tell every client ON THIS SESSION to hide its copy of the shared
			-- model (just the cleaner when they're solo; the whole party otherwise), and record the
			-- web in the job (which may complete it). The server model is left intact so players on
			-- other jobs still see -- and can clean -- their own.
			ProgressionService.reward(player, WEB_XP, WEB_CASH)
			for _, member in JobService.getSessionMembers(player) do
				WebCleaned:FireClient(member, identity.web)
			end
			job:markWebCleaned(identity.surfaceId)
		end

		-- A click that raced this clean's completion was parked in pendingClick; now that the
		-- vacuum is free, treat it as if it just arrived. (Runs after markWebCleaned so a duplicate
		-- click on THIS web fails validation.)
		local queued = pendingClick[player]
		pendingClick[player] = nil
		if queued then
			tryStartClean(player, queued)
		end
	end)
end

function WebCleaningService.init()
	CleanWeb.OnServerEvent:Connect(function(player, target)
		if typeof(target) ~= "Instance" then
			return
		end
		tryStartClean(player, target)
	end)

	Players.PlayerRemoving:Connect(function(player)
		activeClean[player] = nil
		pendingClick[player] = nil
	end)
end

return WebCleaningService
