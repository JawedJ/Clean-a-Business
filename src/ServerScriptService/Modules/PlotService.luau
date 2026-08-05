--!strict

-- Assigns each player one of the workspace plots (Workspace.<PlotsFolderName>.Plot1..N) on join
-- as their personal home/spawn base, and frees it on leave. The owner is told which
-- plot is theirs through a player attribute, and their character spawns there on
-- join and respawn. Plots no longer hold businesses -- cleaning happens at the
-- shared business buildings, gated by the player's accepted job (see JobService).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).server

-- Fired to a player on their first-ever spawn with the horizontal direction their character was
-- pointed in, so the client can swing the camera round to match (see FirstSpawnCameraController).
-- The camera is client-owned, so turning the character alone would leave them facing the
-- warehouse while still LOOKING wherever the default camera happened to sit.
local AimSpawnCamera = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AimSpawnCamera") :: RemoteEvent

local PlotService = {}

-- Stud offset above the spawn part so the character drops in instead of clipping.
local SPAWN_OFFSET = Vector3.new(0, 5, 0)

local ownerByPlot: { [Instance]: Player } = {}
local plotByPlayer: { [Player]: Instance } = {}
local characterConns: { [Player]: RBXScriptConnection } = {}

-- Whether the player still has their once-ever first spawn to use, per player:
--   nil   -- not resolved yet (their profile hasn't been read)
--   true  -- resolved, and the first-spawn placement is still owed to them
--   false -- resolved and spent (or they'd already had it in an earlier session)
-- See takeFirstSpawn.
local firstSpawnPending: { [Player]: boolean? } = {}

-- Listeners notified when a plot is handed to / taken from a player. PlotButtonService uses
-- these to build the plot from the new owner's save data and to reset it on release. Registered
-- via onAssigned/onReleased before init() so the join sweep and every future assignment fire them.
local assignedListeners: { (Player, Instance) -> () } = {}
local releasedListeners: { (Player, Instance) -> () } = {}

-- Register a callback fired (player, plot) whenever a plot is assigned to a player. Call before init().
function PlotService.onAssigned(fn: (Player, Instance) -> ())
	table.insert(assignedListeners, fn)
end

-- Register a callback fired (player, plot) whenever a player's plot is released. Call before init().
function PlotService.onReleased(fn: (Player, Instance) -> ())
	table.insert(releasedListeners, fn)
end

-- Read the player's HasSpawnedBefore flag into firstSpawnPending. YIELDS on waitForData -- for a
-- returning player that's a real datastore round-trip -- so it's started off PlayerAdded, in
-- parallel with the character loading, and never from the spawn path itself. Once resolved it
-- stays resolved for the session, so respawns cost nothing.
local function resolveFirstSpawn(player: Player)
	if firstSpawnPending[player] ~= nil then
		return
	end
	DataService:waitForData(player)
	if not player.Parent or firstSpawnPending[player] ~= nil then
		return
	end
	firstSpawnPending[player] = DataService:get(player, { "HasSpawnedBefore" }) ~= true
end

-- Whether this spawn is the player's first EVER, claiming it if so. The profile flag is written
-- the moment we hand the placement out, not after the character lands, so a disconnect mid-spawn
-- can't earn them a second one.
--
-- NEVER yields: if the profile hasn't come back yet this returns false and the caller places the
-- player on their normal spawn part immediately (see the CharacterAdded handler, which corrects the
-- placement afterwards if the answer turns out to be yes). Making the pivot wait on the datastore is
-- what used to leave returning players falling at the world spawn for the length of the fetch.
local function takeFirstSpawn(player: Player): boolean
	if firstSpawnPending[player] ~= true then
		return false
	end
	firstSpawnPending[player] = false
	DataService:set(player, { "HasSpawnedBefore" }, true)
	return true
end

-- The plot part named `name`, looked up in the plot's teleports model first and falling back to a
-- direct child of the plot folder. The teleport pads (both spawn parts, both portal pads) are
-- grouped into that Model so they can be marked Persistent -- only a Model can be pinned against
-- StreamingEnabled, a loose part can't -- and the fallback keeps a plot whose pads haven't been
-- regrouped yet working. Every plot-teleport destination is resolved through here, PortalService's
-- pads included.
function PlotService.findPart(plot: Instance, name: string): BasePart?
	local teleports = plot:FindFirstChild(Config.PlotTeleportsModelName)
	if teleports then
		local grouped = teleports:FindFirstChild(name)
		if grouped and grouped:IsA("BasePart") then
			return grouped
		end
	end
	local direct = plot:FindFirstChild(name)
	if direct and direct:IsA("BasePart") then
		return direct
	end
	return nil
end

-- Horizontal unit direction from `position` towards the plot's warehouse, or nil if the plot has
-- no warehouse or it sits directly overhead (no horizontal facing to derive). Measured to the
-- warehouse's BOUNDING-BOX centre rather than its pivot, which on an authored Model can sit
-- anywhere and isn't reliably "where the building is".
local function warehouseDirection(plot: Instance, position: Vector3): Vector3?
	local warehouse = plot:FindFirstChild(Config.PlotWarehouseFolderName)
	if not warehouse then
		return nil
	end

	local centre: Vector3
	if warehouse:IsA("Model") then
		centre = warehouse:GetBoundingBox().Position
	elseif warehouse:IsA("BasePart") then
		centre = warehouse.Position
	else
		return nil
	end

	local flat = Vector3.new(centre.X - position.X, 0, centre.Z - position.Z)
	if flat.Magnitude < 1e-4 then
		return nil
	end
	return flat.Unit
end

-- Teleport a character onto its plot's spawn part (upright, slightly above it). `useFirstSpawn`
-- picks the plot's FirstSpawn part instead -- the one-time placement a brand-new player gets --
-- and points them (and their camera) at their warehouse rather than along the part's own
-- LookVector, so the first thing a new player sees is the building they're meant to walk to.
local function spawnCharacterAt(player: Player, character: Model, plot: Instance, useFirstSpawn: boolean?)
	local partName = if useFirstSpawn then Config.PlotFirstSpawnPartName else Config.PlotSpawnPartName
	local spawnPart = PlotService.findPart(plot, partName)
	-- A plot with no FirstSpawn part is an authoring gap, not a reason to strand a new player at
	-- the default world spawn -- fall back to the normal spawn part.
	if useFirstSpawn and not spawnPart then
		warn(string.format("[PlotService] Plot %s has no %q part; using %q for the first spawn.", plot.Name, Config.PlotFirstSpawnPartName, Config.PlotSpawnPartName))
		spawnPart = PlotService.findPart(plot, Config.PlotSpawnPartName)
	end
	if not spawnPart then
		warn(string.format("[PlotService] Plot %s has no %q part to spawn on.", plot.Name, Config.PlotSpawnPartName))
		return
	end
	character:WaitForChild("HumanoidRootPart")
	local position = spawnPart.Position + SPAWN_OFFSET

	-- On the first spawn, face the warehouse. Otherwise face the direction the spawn part's front
	-- points (its LookVector), flattened to the horizontal so the character stands upright even if
	-- the part is tilted. The warehouse lookup can come back empty (no warehouse authored), so it
	-- falls through to the LookVector rather than dropping the facing entirely.
	local facing: Vector3? = if useFirstSpawn then warehouseDirection(plot, position) else nil
	if not facing then
		local look = spawnPart.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		-- A part facing straight up/down has no horizontal facing to use; just drop them in.
		facing = if flat.Magnitude > 1e-4 then flat.Unit else nil
	end

	if facing then
		character:PivotTo(CFrame.lookAt(position, position + facing))
	else
		character:PivotTo(CFrame.new(position))
	end

	-- Turning the character doesn't turn the camera -- that's the client's. Hand it the same
	-- direction so both agree. First spawn only: a respawn shouldn't yank the player's view round.
	if useFirstSpawn and facing then
		AimSpawnCamera:FireClient(player, facing)
	end
end

-- Place a freshly added character on its plot, without ever waiting on the datastore.
--
-- If the profile hasn't come back yet the character still lands on the plot's normal spawn part on
-- the spot -- the placement that's right for everyone except a brand-new player -- and the first-ever
-- placement is applied a moment later if the profile says it's owed. A new player's profile has
-- nothing to fetch, so in practice that correction is never the visible path.
local function placeOnSpawn(player: Player, character: Model, plot: Instance)
	local resolved = firstSpawnPending[player] ~= nil
	spawnCharacterAt(player, character, plot, takeFirstSpawn(player))
	if resolved then
		return
	end

	task.spawn(function()
		resolveFirstSpawn(player)
		-- They may have died, respawned or left while the profile was in flight; a later character
		-- has its own placement, so only correct the one we just placed.
		if player.Character ~= character or not character.Parent then
			return
		end
		if takeFirstSpawn(player) then
			spawnCharacterAt(player, character, plot, true)
		end
	end)
end

-- First plot (in Plot1..PlotN order) that nobody currently owns. Plots live under
-- the shared Workspace.<PlotsFolderName> folder.
local function findFreePlot(): Instance?
	local plotsFolder = Workspace:FindFirstChild(Config.PlotsFolderName)
	if not plotsFolder then
		warn(string.format("[PlotService] No %q folder under Workspace.", Config.PlotsFolderName))
		return nil
	end
	for i = 1, Config.PlotCount do
		local plot = plotsFolder:FindFirstChild("Plot" .. i)
		if plot and not ownerByPlot[plot] then
			return plot
		end
	end
	return nil
end

local function assign(player: Player)
	local plot = findFreePlot()
	if not plot then
		warn(string.format("[PlotService] No free plot for %s; all %d are taken.", player.Name, Config.PlotCount))
		return
	end
	ownerByPlot[plot] = player
	plotByPlayer[player] = plot
	player:SetAttribute(Config.PlotAttribute, plot.Name)

	-- Start the profile read now, alongside the character loading, so the spawn path below almost
	-- always finds the answer already waiting for it.
	task.spawn(resolveFirstSpawn, player)

	-- Spawn the character on the plot now and on every future respawn. takeFirstSpawn returns true
	-- for at most one of these, so only a brand-new player's opening spawn lands on FirstSpawn.
	characterConns[player] = player.CharacterAdded:Connect(function(character)
		placeOnSpawn(player, character, plot)
	end)
	if player.Character then
		placeOnSpawn(player, player.Character :: Model, plot)
	end

	for _, fn in assignedListeners do
		task.spawn(fn, player, plot)
	end
end

local function release(player: Player)
	local conn = characterConns[player]
	if conn then
		conn:Disconnect()
		characterConns[player] = nil
	end
	firstSpawnPending[player] = nil

	local plot = plotByPlayer[player]
	if plot then
		-- Notify listeners while we still know the plot so they can reset it (hide everything).
		for _, fn in releasedListeners do
			task.spawn(fn, player, plot)
		end
		ownerByPlot[plot] = nil
		plotByPlayer[player] = nil
	end
end

-- The plot instance currently assigned to this player, or nil if none.
function PlotService.getPlot(player: Player): Instance?
	return plotByPlayer[player]
end

-- Teleport a player's current character back onto their plot's spawn part. No-op if
-- they have no plot or no living character. Used when a job finishes to send them home.
function PlotService.sendToPlotSpawn(player: Player)
	local plot = plotByPlayer[player]
	local character = player.Character
	if plot and character then
		spawnCharacterAt(player, character, plot)
	end
end

function PlotService.init()
	for _, player in Players:GetPlayers() do
		assign(player)
	end
	Players.PlayerAdded:Connect(assign)
	Players.PlayerRemoving:Connect(release)
end

return PlotService
