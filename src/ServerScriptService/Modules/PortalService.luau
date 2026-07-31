--!strict

-- The Portal spawnable's teleport behaviour (see CleaningConfig's Portal* names).
--
-- Each plot may hold one Portal under its Spawnables folder, with two ends:
--   Spawnables.Portal.TouchDetector              -- touching it lands the player on Teleport2
--   Spawnables.Portal.SecondPortal.TouchDetector -- touching it lands the player on Teleport1
-- Both landing pads are parts directly under that same plot, so a portal only ever moves a player
-- around inside the plot it belongs to.
--
-- Notes:
--   * No ownership check: whoever walks into a portal rides it. The portal is only touchable once
--     the plot's owner has bought it -- PlotButtonService hides a locked spawnable with
--     CanTouch = false, which stops Touched firing entirely.
--   * Plots are never rebuilt (just hidden/shown), so the connections made here at init last for
--     the server's lifetime.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

local PortalService = {}

-- Stud offset above the landing pad so the character drops onto it instead of clipping through.
local ARRIVE_OFFSET = Vector3.new(0, 4, 0)

-- Seconds a player is ignored by every portal after riding one. Guards against the arrival
-- overlapping a detector (and against a single walk-through firing Touched repeatedly).
local COOLDOWN = 1.5

-- os.clock() before which each player's touches are ignored.
local readyAt: { [Player]: number } = {}

Players.PlayerRemoving:Connect(function(player)
	readyAt[player] = nil
end)

-- Drop `character` onto `pad`, upright and facing the pad's front. Mirrors PlotService's plot
-- spawn: the pad may be tilted, so the facing is flattened to the horizontal, and a pad pointing
-- straight up/down leaves the character's facing alone.
local function arriveAt(character: Model, pad: BasePart)
	local position = pad.Position + ARRIVE_OFFSET
	local look = pad.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 1e-4 then
		character:PivotTo(CFrame.lookAt(position, position + flat.Unit))
	else
		character:PivotTo(CFrame.new(position))
	end
end

-- Wire one portal end: touching `detector` sends the toucher to the plot part named `padName`.
local function connectEnd(plot: Instance, detector: BasePart, padName: string)
	detector.Touched:Connect(function(hit: BasePart)
		local character = hit:FindFirstAncestorOfClass("Model")
		if not character then
			return
		end
		local player = Players:GetPlayerFromCharacter(character)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not player or not humanoid or humanoid.Health <= 0 then
			return
		end

		local now = os.clock()
		if now < (readyAt[player] or 0) then
			return
		end

		local pad = plot:FindFirstChild(padName)
		if not pad or not pad:IsA("BasePart") then
			warn(string.format("[PortalService] Plot %s has no %q part to teleport to.", plot.Name, padName))
			return
		end

		readyAt[player] = now + COOLDOWN
		arriveAt(character, pad)
	end)
end

-- Wire both ends of the portal in `plot`, if it has one. Missing pieces are a no-op (a plot
-- simply may not have a portal authored).
local function setupPlot(plot: Instance)
	local spawnables = plot:FindFirstChild(Config.PlotSpawnablesFolderName)
	local portal = spawnables and spawnables:FindFirstChild(Config.PortalModelName)
	if not portal then
		return
	end

	local first = portal:FindFirstChild(Config.PortalTouchPartName)
	if first and first:IsA("BasePart") then
		connectEnd(plot, first, Config.PortalDestinationFromFirst)
	else
		warn(string.format("[PortalService] Plot %s: %s has no %q part.", plot.Name, Config.PortalModelName, Config.PortalTouchPartName))
	end

	local second = portal:FindFirstChild(Config.PortalSecondModelName)
	local secondDetector = second and second:FindFirstChild(Config.PortalTouchPartName)
	if secondDetector and secondDetector:IsA("BasePart") then
		connectEnd(plot, secondDetector, Config.PortalDestinationFromSecond)
	elseif second then
		warn(string.format("[PortalService] Plot %s: %s has no %q part.", plot.Name, Config.PortalSecondModelName, Config.PortalTouchPartName))
	end
end

function PortalService.init()
	local plotsFolder = Workspace:FindFirstChild(Config.PlotsFolderName)
	if not plotsFolder then
		warn(string.format("[PortalService] No %q folder under Workspace.", Config.PlotsFolderName))
		return
	end
	for i = 1, Config.PlotCount do
		local plot = plotsFolder:FindFirstChild("Plot" .. i)
		if plot then
			setupPlot(plot)
		end
	end
end

return PortalService
