--!strict

-- Stamps each plot's warehouse sign with its owner's name. The sign is the TextBox at
--   Plot(i).Warehouse.<PlotSignPath...>   (see CleaningConfig)
-- set to "<Owner>'s Warehouse" when the plot is assigned and blanked when it's released --
-- plots are SHARED and reused, so a stale name must never outlive its owner.
--
-- Possessive: a name already ending in "s" takes no apostrophe and no extra "s"
-- ("Jonas Warehouse"); anything else takes "'s" ("plazm's Warehouse").

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local PlotService = require(script.Parent.PlotService)

local PlotSignService = {}

-- The sign TextBox for a plot, or nil if any link isn't authored (not every plot has a
-- Warehouse). Walked rather than indexed so a missing link warns instead of erroring.
local function findSign(plot: Instance): TextBox?
	local node: Instance? = plot:FindFirstChild(Config.PlotWarehouseFolderName)
	for _, segment in Config.PlotSignPath do
		if not node then
			break
		end
		node = node:FindFirstChild(segment)
	end
	if node and node:IsA("TextBox") then
		return node
	end
	return nil
end

-- "plazm" -> "plazm's Warehouse"; "Jonas" -> "Jonas Warehouse".
local function signTextFor(player: Player): string
	local name = player.Name
	if string.sub(string.lower(name), -1) == "s" then
		return name .. " Warehouse"
	end
	return name .. "'s Warehouse"
end

local function setSign(plot: Instance, text: string)
	local sign = findSign(plot)
	if not sign then
		warn(string.format("[PlotSignService] Plot %s has no warehouse sign TextBox.", plot.Name))
		return
	end
	sign.Text = text
end

function PlotSignService.init()
	PlotService.onAssigned(function(player, plot)
		setSign(plot, signTextFor(player))
	end)
	PlotService.onReleased(function(_player, plot)
		setSign(plot, "")
	end)
end

return PlotSignService
