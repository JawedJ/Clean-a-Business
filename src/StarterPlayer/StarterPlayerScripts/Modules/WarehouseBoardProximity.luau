--!strict

-- Opens/closes each warehouse board's UI as the player walks in and out of its hitbox. Two
-- boards share this behaviour, so they're driven data-driven from one Heartbeat loop:
--   * JobBoard  ->  Jobs union      ->  Hitbox  ->  the job board UI    (JobUiController)
--   * UpgradesBoard -> Upgrades union -> Hitbox ->  the upgrades shop UI (UpgradesUiController)
-- all under Workspace.<PlotsFolderName>.<their Plot>.Warehouse.<board>.<union>.<HitboxName>.
--
-- Detection is a per-frame point-in-box test of the character's HumanoidRootPart against each
-- hitbox -- cheap, with clean enter/leave edges. The open is EDGE-triggered: it fires only on
-- the outside->inside transition, never every frame the player stands inside. That single rule
-- gives the Exit-button behaviour for free -- closing a panel via its Exit button (or its key)
-- while still standing in the hitbox won't reopen it, because there's no fresh enter edge until
-- the player leaves and steps back in. Leaving (inside->outside) closes the panel.
--
-- Open/close go through the UI controllers (and so the shared panel coordinator), so proximity
-- respects the same rules as the buttons: no popping while on a job, and opening one board's
-- panel still closes the other's first.
--
-- Each hitbox is resolved lazily off the player's Plot attribute and re-resolved if that plot
-- changes or its warehouse isn't present yet (not every plot has a Warehouse authored). While a
-- board's hitbox doesn't resolve, that board simply idles.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local JobUiController = require(script.Parent.JobUiController)
local UpgradesUiController = require(script.Parent.UpgradesUiController)

local localPlayer = Players.LocalPlayer

-- Studio-authored model name that holds every board inside a plot.
local WAREHOUSE_NAME = "Warehouse"

-- One proximity-driven board: the Studio path pieces from the warehouse down to its hitbox
-- (boardModel -> union -> Config.HitboxName), the panel hooks it drives, and its live state.
type Board = {
	boardName: string,
	unionName: string,
	open: () -> boolean,
	close: () -> (),
	isVisible: () -> boolean,
	-- Optional SoundManager sound to one-shot when the player walks in and this board opens.
	openSound: string?,
	-- Cached hitbox for the player's current plot, held until it (or the plot) goes away.
	hitbox: BasePart?,
	-- Whether the character was inside this hitbox last frame, so we act only on the edges.
	inside: boolean,
}

local boards: { Board } = {
	{
		boardName = "JobBoard",
		unionName = "Jobs",
		open = JobUiController.openBoard,
		close = JobUiController.closeBoard,
		isVisible = JobUiController.isBoardVisible,
		openSound = "UIClick",
		hitbox = nil,
		inside = false,
	},
	{
		boardName = "UpgradesBoard",
		unionName = "Upgrades",
		open = UpgradesUiController.openShop,
		close = UpgradesUiController.closeShop,
		isVisible = UpgradesUiController.isShopVisible,
		openSound = "UIClick",
		hitbox = nil,
		inside = false,
	},
}

local WarehouseBoardProximity = {}

-- Walk plot -> warehouse -> board -> union -> hitbox for the player's assigned plot, returning
-- the hitbox Part or nil if any link isn't present (e.g. the plot has no Warehouse, or the
-- model hasn't streamed in yet).
local function resolveHitbox(board: Board): BasePart?
	local plotName = localPlayer:GetAttribute(Config.PlotAttribute)
	if type(plotName) ~= "string" then
		return nil
	end
	local plotsFolder = Workspace:FindFirstChild(Config.PlotsFolderName)
	local plot = plotsFolder and plotsFolder:FindFirstChild(plotName)
	local warehouse = plot and plot:FindFirstChild(WAREHOUSE_NAME)
	local model = warehouse and warehouse:FindFirstChild(board.boardName)
	local union = model and model:FindFirstChild(board.unionName)
	local part = union and union:FindFirstChild(Config.HitboxName)
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

local function stepBoard(board: Board, rootPosition: Vector3?)
	local box = board.hitbox
	-- Re-resolve if we've lost the hitbox (plot reassigned, model streamed out, or first frame).
	if not box or not box.Parent then
		box = resolveHitbox(board)
		board.hitbox = box
		-- Losing the box counts as leaving it, so a later re-resolve re-triggers a clean enter.
		if board.inside then
			board.inside = false
			board.close()
		end
		if not box then
			return
		end
	end

	local nowInside = rootPosition ~= nil and pointInPart(rootPosition, box)
	if nowInside and not board.inside then
		board.inside = true
		-- Only chime if the panel actually opened (open() is a no-op while on a job, etc.).
		if board.open() and board.openSound then
			SoundManager.playOneShot(board.openSound)
		end
	elseif not nowInside and board.inside then
		board.inside = false
		-- Only bother closing if it's actually up (it may have been Exit-closed while inside).
		if board.isVisible() then
			board.close()
		end
	end
end

local function step()
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local rootPosition = if root then root.Position else nil
	for _, board in boards do
		stepBoard(board, rootPosition)
	end
end

function WarehouseBoardProximity.init()
	-- A fresh character means the old HumanoidRootPart is gone; treat every board as left so
	-- re-entering a hitbox after a respawn triggers a clean open again.
	localPlayer.CharacterAdded:Connect(function()
		for _, board in boards do
			board.inside = false
		end
	end)
	-- Reassigned plot: drop the cached hitboxes so they re-resolve against the new plot.
	localPlayer:GetAttributeChangedSignal(Config.PlotAttribute):Connect(function()
		for _, board in boards do
			board.hitbox = nil
			board.inside = false
		end
	end)

	RunService.Heartbeat:Connect(step)
end

return WarehouseBoardProximity
