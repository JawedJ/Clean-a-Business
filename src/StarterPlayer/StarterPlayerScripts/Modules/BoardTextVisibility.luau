--!strict

-- Makes each plot's warehouse board text (the JobBoard / UpgradesBoard BillboardGuis) show ONLY on
-- the client of the player who owns that plot. Every plot authors these billboards visible, so on a
-- given client we enable the two on the local player's assigned plot and disable them on every other
-- plot -- another player's board text never shows on your screen, and yours never shows on theirs.
--
--   Workspace.<PlotsFolderName>.Plot(i).Warehouse.<boardName>.<unionName>.BillboardGui
--
-- This is a purely client-side view tweak (BillboardGui.Enabled is local), so it lives here and not
-- on the server. It re-applies whenever the local player's plot changes (PlotAttribute), and a light
-- DescendantAdded guard corrects a board that streams in or is rebuilt after the last refresh.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

local localPlayer = Players.LocalPlayer

-- Studio-authored model name holding every board inside a plot (matches WarehouseBoardProximity).
local WAREHOUSE_NAME = "Warehouse"
-- The text-bearing GUI's authored name inside each board's union.
local BILLBOARD_NAME = "BillboardGui"

-- The boards to gate: the model name under the Warehouse and the union that holds its BillboardGui.
local BOARDS = {
	{ board = "JobBoard", union = "Jobs" },
	{ board = "UpgradesBoard", union = "Upgrades" },
}

local BoardTextVisibility = {}

-- Resolve a plot's board BillboardGui, or nil if any link isn't present (plot has no Warehouse, or
-- the board hasn't streamed in yet).
local function billboardFor(plot: Instance, board: string, union: string): BillboardGui?
	local warehouse = plot:FindFirstChild(WAREHOUSE_NAME)
	local boardModel = warehouse and warehouse:FindFirstChild(board)
	local unionPart = boardModel and boardModel:FindFirstChild(union)
	local gui = unionPart and unionPart:FindFirstChild(BILLBOARD_NAME)
	if gui and gui:IsA("BillboardGui") then
		return gui
	end
	return nil
end

-- Enable the owned plot's board billboards, disable everyone else's.
local function refresh()
	local ownedName = localPlayer:GetAttribute(Config.PlotAttribute)
	local plotsFolder = Workspace:FindFirstChild(Config.PlotsFolderName)
	if not plotsFolder then
		return
	end
	for _, plot in plotsFolder:GetChildren() do
		local mine = plot.Name == ownedName
		for _, entry in BOARDS do
			local gui = billboardFor(plot, entry.board, entry.union)
			if gui then
				gui.Enabled = mine
			end
		end
	end
end

function BoardTextVisibility.init()
	refresh()
	-- Re-apply when the local player is assigned a (new) plot.
	localPlayer:GetAttributeChangedSignal(Config.PlotAttribute):Connect(refresh)

	-- A board that streams in (or is rebuilt) after the last refresh authors its billboard visible;
	-- correct it the moment its BillboardGui appears rather than waiting for the next plot change.
	local plotsFolder = Workspace:FindFirstChild(Config.PlotsFolderName)
	if plotsFolder then
		plotsFolder.DescendantAdded:Connect(function(inst: Instance)
			if inst.Name == BILLBOARD_NAME and inst:IsA("BillboardGui") then
				refresh()
			end
		end)
	end
end

return BoardTextVisibility
