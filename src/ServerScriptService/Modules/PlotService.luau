--!strict

-- Assigns each player one of the workspace plots (Plot1..Plot(PlotCount)) on join
-- and frees it on leave. The owner is told which plot is theirs through a player
-- attribute so the client only makes that plot's walls cleanable. Other systems
-- call getPlot to authorize actions against a player's own plot.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local BusinessSpawner = require(script.Parent.BusinessSpawner)

local PlotService = {}

-- Stud offset above the spawn part so the character drops in instead of clipping.
local SPAWN_OFFSET = Vector3.new(0, 5, 0)

local ownerByPlot: { [Instance]: Player } = {}
local plotByPlayer: { [Player]: Instance } = {}
local characterConns: { [Player]: RBXScriptConnection } = {}

-- Teleport a character onto its plot's spawn part (upright, slightly above it).
local function spawnCharacterAt(character: Model, plot: Instance)
	local spawnPart = plot:FindFirstChild(Config.PlotSpawnPartName)
	if not spawnPart or not spawnPart:IsA("BasePart") then
		warn(string.format("[PlotService] Plot %s has no %q part to spawn on.", plot.Name, Config.PlotSpawnPartName))
		return
	end
	character:WaitForChild("HumanoidRootPart")
	character:PivotTo(CFrame.new(spawnPart.Position + SPAWN_OFFSET))
end

-- First plot (in Plot1..PlotN order) that nobody currently owns.
local function findFreePlot(): Instance?
	for i = 1, Config.PlotCount do
		local plot = Workspace:FindFirstChild("Plot" .. i)
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

	-- Fill the plot with the player's owned businesses. Spawned in its own thread
	-- since it yields for data to load; the plot is already assigned by now.
	task.spawn(BusinessSpawner.populate, player, plot)

	-- Spawn the character on the plot now and on every future respawn.
	characterConns[player] = player.CharacterAdded:Connect(function(character)
		spawnCharacterAt(character, plot)
	end)
	if player.Character then
		task.spawn(spawnCharacterAt, player.Character, plot)
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
		ownerByPlot[plot] = nil
		plotByPlayer[player] = nil
		-- Empty the plot so the next player to take it starts fresh.
		BusinessSpawner.clear(plot)
	end
end

-- The plot instance currently assigned to this player, or nil if none.
function PlotService.getPlot(player: Player): Instance?
	return plotByPlayer[player]
end

function PlotService.init()
	for _, player in Players:GetPlayers() do
		assign(player)
	end
	Players.PlayerAdded:Connect(assign)
	Players.PlayerRemoving:Connect(release)
end

return PlotService
