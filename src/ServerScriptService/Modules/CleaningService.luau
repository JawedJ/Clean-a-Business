--!strict

-- Server side of pressure-washer (wall) cleaning. Cleanable walls live in the
-- Studio place under each plot: Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableWalls.
-- The Pressure Washer tool (StarterPack) likewise lives in the place, not in code.
--
-- Two things flow through here, both validated against the player's plot + owned
-- businesses:
--   * CleanSurface  -- "this wall is fully clean", saved under
--     BusinessList[businessId].CleanedParts[surfaceId].
--   * CleanProgress -- "I'm actively erasing dirt on this unfinished wall right
--     now"; pays the per-second wash reward, throttled server-side.
--
-- The dirt overlay is an EditableImage built entirely on the client, so the server
-- never touches pixel data.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local SurfaceResolver = require(ReplicatedStorage.SharedModules.SurfaceResolver)
local PlotService = require(script.Parent.PlotService)
local ProgressionService = require(script.Parent.ProgressionService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CleanSurface = Remotes:WaitForChild("CleanSurface") :: RemoteEvent
local CleanProgress = Remotes:WaitForChild("CleanProgress") :: RemoteEvent

-- Reward paid for each second of actively erasing dirt from an unfinished wall.
-- WASH_COOLDOWN is the server-enforced minimum gap between payouts, so a client
-- can't earn faster by sending CleanProgress more often.
local WASH_XP = 4
local WASH_CASH = 4
local WASH_COOLDOWN = 1 -- seconds

local CleaningService = {}

-- os.clock() of the last wash reward paid to each player. Server-owned: the client
-- never sees or sets it.
local lastWashReward: { [Player]: number } = {}

-- Resolve a reported wall to its identity, but only if it's a real BasePart on the
-- player's assigned plot AND part of a business they actually own. Returns nil
-- otherwise. Shared by both handlers so they validate identically.
local function resolveOwned(player: Player, surface: any): SurfaceResolver.SurfaceIdentity?
	if typeof(surface) ~= "Instance" or not surface:IsA("BasePart") then
		return nil
	end
	local identity = SurfaceResolver.resolve(surface)
	if not identity then
		return nil
	end
	if identity.plot ~= PlotService.getPlot(player) then
		return nil
	end
	if not DataService:get(player, { "BusinessList", identity.businessId }) then
		return nil
	end
	return identity
end

-- True once the server has recorded this wall as fully cleaned.
local function isCleaned(player: Player, identity: SurfaceResolver.SurfaceIdentity): boolean
	return DataService:get(player, { "BusinessList", identity.businessId, "CleanedParts", identity.surfaceId })
		== true
end

function CleaningService.init()
	CleanSurface.OnServerEvent:Connect(function(player, surface)
		local identity = resolveOwned(player, surface)
		if not identity then
			return
		end

		-- Server intervention: cleaned state is MONOTONIC. The wall pixel-erasing is
		-- client-driven (the one thing we can't verify server-side), but the saved
		-- boolean is the server's. This remote can only ever set it to `true`, and once
		-- a surface is cleaned we ignore further reports for it -- so a client can never
		-- drive a surface back to `false` (un-clean) by replaying or forging this event.
		if isCleaned(player, identity) then
			return
		end

		DataService:set(player, { "BusinessList", identity.businessId, "CleanedParts", identity.surfaceId }, true)
	end)

	-- The client reports it is actively erasing dirt on a not-yet-finished wall. We
	-- pay the wash reward at most once per WASH_COOLDOWN, after re-validating that the
	-- wall is owned and not already done -- so the reward can't be farmed on a clean
	-- wall, on someone else's wall, or by spamming the remote faster than the cooldown.
	CleanProgress.OnServerEvent:Connect(function(player, surface)
		local identity = resolveOwned(player, surface)
		if not identity then
			return
		end
		if isCleaned(player, identity) then
			return
		end

		local now = os.clock()
		local last = lastWashReward[player]
		if last and now - last < WASH_COOLDOWN then
			return
		end
		lastWashReward[player] = now

		ProgressionService.reward(player, WASH_XP, WASH_CASH)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastWashReward[player] = nil
	end)
end

return CleaningService
