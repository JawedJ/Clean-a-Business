--!strict

-- Opens the job board when the player walks up to their warehouse's JobBoard and closes it
-- when they walk away. The board's proximity volume is the transparent hitbox at:
--   Workspace.<PlotsFolderName>.<their Plot>.Warehouse.JobBoard.Jobs.<HitboxName>
-- (a Part; "Jobs" is a union). Detection is a per-frame point-in-box test of the character's
-- HumanoidRootPart against that hitbox -- cheap, and it gives clean enter/leave edges.
--
-- The open is EDGE-triggered: it fires only on the outside->inside transition, never every
-- frame the player stands inside. That single rule gives the requested Exit-button behaviour
-- for free -- if the player closes the board via its Exit button (or the B key) while still
-- standing in the hitbox, nothing reopens it, because there's no fresh enter edge until they
-- leave and step back in. Leaving (inside->outside) closes the board.
--
-- The actual open/close goes through JobUiController (and so the shared panel coordinator), so
-- proximity respects the same rules as the button: it won't pop the board while on a job or
-- over a job summary, and opening it still closes the upgrades shop first.
--
-- The hitbox is resolved lazily off the player's Plot attribute and re-resolved if that plot
-- changes or its warehouse isn't present yet (not every plot has a Warehouse authored). While
-- no hitbox resolves, the controller simply idles.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local JobUiController = require(script.Parent.JobUiController)

local localPlayer = Players.LocalPlayer

-- Studio-authored geometry names on the path from a plot down to the board's hitbox. The
-- leaf reuses Config.HitboxName ("Hitbox"), shared with the cleanable-decal hitboxes.
local WAREHOUSE_NAME = "Warehouse"
local JOB_BOARD_NAME = "JobBoard"
local JOBS_NAME = "Jobs"

local JobBoardProximityController = {}

-- The hitbox for the player's current plot, cached until it (or the plot) goes away.
local hitbox: BasePart? = nil
-- Whether the character was inside the hitbox last frame, so we act only on the edges.
local inside = false

-- Walk the plot -> warehouse -> board -> jobs -> hitbox path for the player's currently
-- assigned plot, returning the hitbox Part or nil if any link isn't present (e.g. the plot
-- has no Warehouse, or the model hasn't streamed in yet).
local function resolveHitbox(): BasePart?
	local plotName = localPlayer:GetAttribute(Config.PlotAttribute)
	if type(plotName) ~= "string" then
		return nil
	end
	local plotsFolder = Workspace:FindFirstChild(Config.PlotsFolderName)
	local plot = plotsFolder and plotsFolder:FindFirstChild(plotName)
	local warehouse = plot and plot:FindFirstChild(WAREHOUSE_NAME)
	local board = warehouse and warehouse:FindFirstChild(JOB_BOARD_NAME)
	local jobs = board and board:FindFirstChild(JOBS_NAME)
	local part = jobs and jobs:FindFirstChild(Config.HitboxName)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

-- Is `point` within the (possibly rotated) box of `part`? Object-space compare against the
-- half-extents, treating the character as the single HumanoidRootPart point -- fine for a
-- volume this size.
local function pointInPart(point: Vector3, part: BasePart): boolean
	local rel = part.CFrame:PointToObjectSpace(point)
	local half = part.Size * 0.5
	return math.abs(rel.X) <= half.X and math.abs(rel.Y) <= half.Y and math.abs(rel.Z) <= half.Z
end

local function step()
	local box = hitbox
	-- Re-resolve if we've lost the hitbox (plot reassigned, model streamed out, or first frame).
	if not box or not box.Parent then
		hitbox = resolveHitbox()
		box = hitbox
		-- Losing the box counts as leaving it, so a later re-resolve re-triggers a clean enter.
		if inside then
			inside = false
			JobUiController.closeBoard()
		end
		if not box then
			return
		end
	end

	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local nowInside = root ~= nil and pointInPart(root.Position, box)

	if nowInside and not inside then
		inside = true
		JobUiController.openBoard()
	elseif not nowInside and inside then
		inside = false
		-- Only bother closing if it's actually up (it may have been Exit-closed while inside).
		if JobUiController.isBoardVisible() then
			JobUiController.closeBoard()
		end
	end
end

function JobBoardProximityController.init()
	-- A fresh character means the old HumanoidRootPart is gone; treat that as having left so
	-- re-entering the hitbox after a respawn triggers a clean open again.
	localPlayer.CharacterAdded:Connect(function()
		inside = false
	end)
	-- Reassigned plot: drop the cached hitbox so it re-resolves against the new plot.
	localPlayer:GetAttributeChangedSignal(Config.PlotAttribute):Connect(function()
		hitbox = nil
		inside = false
	end)

	RunService.Heartbeat:Connect(step)
end

return JobBoardProximityController
