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

local PlotService = {}

-- Stud offset above the spawn part so the character drops in instead of clipping.
local SPAWN_OFFSET = Vector3.new(0, 5, 0)

local ownerByPlot: { [Instance]: Player } = {}
local plotByPlayer: { [Player]: Instance } = {}
local characterConns: { [Player]: RBXScriptConnection } = {}

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

-- Teleport a character onto its plot's spawn part (upright, slightly above it).
local function spawnCharacterAt(character: Model, plot: Instance)
	local spawnPart = plot:FindFirstChild(Config.PlotSpawnPartName)
	if not spawnPart or not spawnPart:IsA("BasePart") then
		warn(string.format("[PlotService] Plot %s has no %q part to spawn on.", plot.Name, Config.PlotSpawnPartName))
		return
	end
	character:WaitForChild("HumanoidRootPart")
	local position = spawnPart.Position + SPAWN_OFFSET
	-- Face the direction the spawn part's front points (its LookVector), flattened to the
	-- horizontal so the character stands upright even if the part is tilted. If the part
	-- happens to face straight up/down there's no horizontal facing to use, so just drop in.
	local look = spawnPart.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 1e-4 then
		character:PivotTo(CFrame.lookAt(position, position + flat.Unit))
	else
		character:PivotTo(CFrame.new(position))
	end
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

	-- Spawn the character on the plot now and on every future respawn.
	characterConns[player] = player.CharacterAdded:Connect(function(character)
		spawnCharacterAt(character, plot)
	end)
	if player.Character then
		task.spawn(spawnCharacterAt, player.Character, plot)
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
		spawnCharacterAt(character, plot)
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
