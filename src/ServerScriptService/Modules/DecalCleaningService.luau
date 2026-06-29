--!strict

-- Server side of stain (broom) cleaning, and the AUTHORITY over it. Cleanable
-- stains live in the Studio place under each plot:
--   Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableDecals.<model>
-- The Broom tool (StarterPack) likewise lives in the place, not in code.
--
-- The client sends a single "I clicked this stain" request; it does NOT decide
-- when the stain is cleaned. The server validates the request, then runs the
-- UseTime timer itself (UseTime read from the player's broom in their DataService
-- Inventory, so upgrades apply; the ToolConfig default is only a fallback). When
-- its own timer elapses it re-validates and deletes the model, saving it under
-- BusinessList[businessId].CleanedStains[surfaceId] via DataService. The client's
-- progress bar is purely cosmetic feedback.
--
-- (Unlike the EditableImage wall cleaning -- which is inherently client-driven
-- pixel work -- there is nothing client-only here, so none of it is trusted.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local DecalResolver = require(ReplicatedStorage.SharedModules.DecalResolver)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local PlotService = require(script.Parent.PlotService)

local CleanDecal = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CleanDecal") :: RemoteEvent

local TOOL_ID = ToolConfig.startingBroom.UniqueID

-- This player's current broom UseTime (seconds), read fresh so tool upgrades take
-- effect immediately, falling back to the static ToolConfig default.
local function getUseTime(player: Player): number
	return DataService:get(player, { "Inventory", TOOL_ID, "UseTime" }) or ToolConfig[TOOL_ID].UseTime
end

local DecalCleaningService = {}

-- A player may only clean one stain at a time; they must wait the full UseTime
-- before the broom is usable again. Tracked server-side, never trusted from the client.
local activeClean: { [Player]: boolean } = {}

-- True if the player currently has the broom equipped (its Tool is parented under
-- their character while equipped).
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

-- Validate that this player may clean this stain right now. Returns the identity.
local function validate(player: Player, target: Instance): DecalResolver.DecalIdentity?
	local identity = DecalResolver.resolve(target)
	if not identity then
		return nil
	end
	-- The stain must be on the plot this player was assigned.
	if identity.plot ~= PlotService.getPlot(player) then
		return nil
	end
	-- ...and belong to a business the player actually has.
	if not DataService:get(player, { "BusinessList", identity.businessId }) then
		return nil
	end
	return identity
end

function DecalCleaningService.init()
	CleanDecal.OnServerEvent:Connect(function(player, target)
		if typeof(target) ~= "Instance" then
			return
		end

		-- One clean at a time: ignore the click until the current timer finishes.
		if activeClean[player] then
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

			-- Re-validate at completion: the stain (or the player's claim to it) may
			-- have changed during the wait.
			if identity.model.Parent == nil then
				return
			end
			if not validate(player, identity.model) then
				return
			end

			DataService:set(
				player,
				{ "BusinessList", identity.businessId, "CleanedStains", identity.surfaceId },
				true
			)
			identity.model:Destroy()
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		activeClean[player] = nil
	end)
end

return DecalCleaningService
