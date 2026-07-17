--!strict

-- Server side of stain (broom) cleaning, and the AUTHORITY over it. Cleanable stains live
-- in the shared business buildings:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableDecals.<model>
-- The Broom Tool lives in ReplicatedStorage.Items; ToolService grants it.
--
-- The client sends a single "I clicked this stain" request; it does NOT decide when the
-- stain is cleaned. The server validates the request (the player holds this business's
-- job, has the broom equipped, and hasn't already cleaned this stain on this job), then
-- runs the UseTime timer itself. When its own timer elapses it re-validates, pays the
-- per-stain reward, records the stain in the player's JobServer (which may complete the
-- job), and -- because the stains are SHARED across every player -- it does NOT destroy
-- the model. Instead it tells the cleaning player's client (DecalCleaned remote) to hide
-- that model locally, so the stain vanishes for them while everyone else still sees it.
--
-- Which stains a player has cleaned lives in their JobServer, so it resets every time the
-- job is (re)accepted -- letting them redo the job for the reward again.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local DecalResolver = require(ReplicatedStorage.SharedModules.DecalResolver)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local JobService = require(script.Parent.JobService)
local ProgressionService = require(script.Parent.ProgressionService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CleanDecal = Remotes:WaitForChild("CleanDecal") :: RemoteEvent
local DecalCleaned = Remotes:WaitForChild("DecalCleaned") :: RemoteEvent

local TOOL_ID = ToolConfig.startingBroom.UniqueID

-- Reward paid once per stain fully cleaned.
local DECAL_XP = 4
local DECAL_CASH = 4

-- This player's current broom UseTime (seconds), read fresh so tool upgrades take effect
-- immediately, falling back to the static ToolConfig default.
local function getUseTime(player: Player): number
	return DataService:get(player, { "Inventory", TOOL_ID, "UseTime" }) or ToolConfig[TOOL_ID].UseTime
end

local DecalCleaningService = {}

-- A player may only clean one stain at a time; they must wait the full UseTime before the
-- broom is usable again. Tracked server-side, never trusted from the client.
local activeClean: { [Player]: boolean } = {}

-- Latest click that arrived while a clean was still active. Because the server's timer
-- starts (and therefore ends) about half a ping AFTER the client's cosmetic bar, an honest
-- click on the NEXT stain -- sent the instant the client's bar finished -- can reach us just
-- before the previous timer's completion callback clears activeClean. Dropping that click
-- silently strands the client: it already showed a bar and marked the stain started, but no
-- clean ever runs and no DecalCleaned ever comes. So instead of dropping, remember the click
-- and process it as soon as the current clean resolves. Only one is kept (newest wins);
-- cleans stay strictly one-at-a-time, so this gives exploiters nothing.
local pendingClick: { [Player]: Instance } = {}

-- True if the player currently has the broom equipped (its Tool is parented under their
-- character while equipped).
local function hasBroomEquipped(player: Player): boolean
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

-- Validate that this player may clean this stain right now: it's a real stain, it belongs
-- to the business whose job they currently hold, and they haven't already cleaned it on
-- this job. Returns the identity.
local function validate(player: Player, target: Instance): DecalResolver.DecalIdentity?
	local identity = DecalResolver.resolve(target)
	if not identity then
		return nil
	end
	if JobService.getActiveJob(player) ~= identity.businessId then
		return nil
	end
	local job = JobService.getJob(player)
	if not job or job:isDecalCleaned(identity.surfaceId) then
		return nil
	end
	return identity
end

-- Handle one click on a stain: validate, run the authoritative UseTime timer, and on
-- completion reward + confirm. Recurses into the pending click (if one queued up) once
-- the timer resolves, so a boundary click is processed instead of lost.
local function tryStartClean(player: Player, target: Instance)
	-- One clean at a time: hold the click until the current timer finishes.
	if activeClean[player] then
		pendingClick[player] = target
		return
	end

	if not hasBroomEquipped(player) then
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

		-- Re-validate at completion: the player's job (or their claim to this stain)
		-- may have changed during the wait.
		local job = JobService.getJob(player)
		if identity.model.Parent ~= nil and job and validate(player, identity.model) then
			-- Reward them, tell THEIR client to hide its copy of the shared model, and
			-- record the stain in the job (which may complete it). The server model is
			-- left intact so other players can still clean it independently.
			ProgressionService.reward(player, DECAL_XP, DECAL_CASH)
			DecalCleaned:FireClient(player, identity.model)
			job:markDecalCleaned(identity.surfaceId)
		end

		-- A click that raced this clean's completion was parked in pendingClick; now
		-- that the broom is free, treat it as if it just arrived. (Runs after
		-- markDecalCleaned so a duplicate click on THIS stain fails validation.)
		local queued = pendingClick[player]
		pendingClick[player] = nil
		if queued then
			tryStartClean(player, queued)
		end
	end)
end

function DecalCleaningService.init()
	CleanDecal.OnServerEvent:Connect(function(player, target)
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

return DecalCleaningService
