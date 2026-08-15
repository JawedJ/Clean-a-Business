--!strict

-- Drives the UNCLEANED readout (PlayerGui.ScreenGui.UncleanedInfo): a one-line breakdown of
-- what the active job still has left to clean, e.g.
--   UNCLEANED: 3 Floor Tiles, 2 Puddles, 3 Stains, 5 Cobwebs
-- Kinds with nothing left (or that the business doesn't have at all) are dropped from the line,
-- so it shrinks as the job is worked and never lists a kind the player can't find.
--
-- The label shows only while a job is active -- same rule (and same signal) as the JobCompletion
-- HUD, the counterpart to the job board which hides during a job. It stays hidden for the first
-- moments of a job, until the JobClient reports `loaded`: before that every total is 0, so any
-- line we could write would be a guess (and showing the last job's line is worse than showing
-- nothing).
--
-- Counts come from the active JobClient via JobController.onProgressChanged, which fires on
-- every clean (including mid-wall strokes), so we only repaint when the wording actually
-- changes. Walls count in WHOLE walls: a half-washed wall is still uncleaned.
--
-- Cleans alone aren't enough to keep it honest at the START of a job: the JobClient is created
-- from the same attribute this controller watches (order between the two connections isn't
-- guaranteed) and it loads its totals asynchronously. So while a job is active we also refresh on
-- a slow poll, which picks up the totals landing without depending on who fired first. Repaints
-- are suppressed when the wording is unchanged, so the poll costs nothing visible.
--
-- Like the other HUD controllers the ScreenGui is re-cloned on every respawn, so we re-bind to
-- the fresh instance each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local JobController = require(script.Parent.JobController)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
local LABEL_NAME = "UncleanedInfo"

-- What JobClient.getRemaining reports.
type Remaining = { walls: number, spills: number, decals: number, webs: number, garbage: number }

-- Player-facing names per cleanable kind, in the order they're listed. `plural` is used for
-- anything but exactly one.
local KINDS: { { get: (Remaining) -> number, singular: string, plural: string } } = {
	{ get = function(r) return r.walls end, singular = "Floor Tile", plural = "Floor Tiles" },
	{ get = function(r) return r.spills end, singular = "Puddle", plural = "Puddles" },
	{ get = function(r) return r.decals end, singular = "Stain", plural = "Stains" },
	{ get = function(r) return r.webs end, singular = "Cobweb", plural = "Cobwebs" },
	{ get = function(r) return r.garbage end, singular = "Piece of Trash", plural = "Pieces of Trash" },
}

-- How often (seconds) the line is re-checked while a job is on the clock. Cleans repaint it
-- instantly; this only has to catch the job's totals loading, so it can be lazy.
local POLL_INTERVAL = 0.25

local UncleanedInfoController = {}

-- The currently bound label, refreshed each time the ScreenGui is (re)bound.
local label: TextLabel? = nil
-- Last text written, so a burst of mid-wall progress callbacks doesn't re-assign the same line.
local lastText: string? = nil

local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Build the readout from `remaining`, or nil if nothing is left to list.
local function buildText(remaining: Remaining): string?
	local parts: { string } = {}
	for _, kind in KINDS do
		local count = kind.get(remaining)
		if count > 0 then
			table.insert(parts, string.format("%d %s", count, if count == 1 then kind.singular else kind.plural))
		end
	end
	if #parts == 0 then
		return nil
	end
	return "UNCLEANED: " .. table.concat(parts, ", ")
end

-- Reconcile the label with the current job: visible with an up-to-date line while a loaded job
-- is on the clock, hidden otherwise. Guards the post-respawn gap before anything is bound, and
-- leaves the text alone when the wording hasn't changed.
local function render()
	local text = label
	if not text or not text.Parent then
		return
	end

	local job = JobController.getJob()
	-- Wait for the totals before showing anything: an unloaded job reports 0 of everything.
	-- `line` is nil once nothing dirty is left, which hides the label the same way -- there's
	-- nothing to list.
	local line = if hasActiveJob() and job and job.loaded then buildText(job:getRemaining()) else nil
	if not line then
		text.Visible = false
		-- The next job starts from a clean slate, so don't suppress its first line if it happens
		-- to match this one's.
		lastText = nil
		return
	end

	text.Visible = true
	if line ~= lastText then
		lastText = line
		text.Text = line
	end
end

-- Bumped whenever the job changes so at most one poll loop is live.
local pollToken = 0

-- While a job is on the clock, re-render on a slow tick. This is what makes a job START land:
-- the JobClient's totals arrive asynchronously (and possibly before this controller even hears
-- about the job), so neither the attribute change nor the next clean is a reliable first paint.
-- The loop exits as soon as the job ends or another one supersedes it.
local function startPolling()
	pollToken += 1
	local token = pollToken
	task.spawn(function()
		while token == pollToken and hasActiveJob() do
			render()
			task.wait(POLL_INTERVAL)
		end
	end)
end

-- The job changed (started, switched, or ended): repaint now and (re)arm the poll.
local function onActiveJobChanged()
	render()
	if hasActiveJob() then
		startPolling()
	else
		pollToken += 1 -- stop the loop; nothing to track between jobs
	end
end

local function bind(screenGui: Instance)
	label = screenGui:WaitForChild(LABEL_NAME) :: TextLabel
	lastText = nil
	onActiveJobChanged()
end

function UncleanedInfoController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Persistent subscriptions; each reads whichever label is currently bound.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(onActiveJobChanged)
	JobController.onProgressChanged(render)

	local function onChild(child: Instance)
		if child.Name == SCREEN_GUI_NAME then
			task.spawn(bind, child)
		end
	end
	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
	playerGui.ChildAdded:Connect(onChild)
end

return UncleanedInfoController
