--!strict

-- The game's two PROGRESSION analytics funnels, both reported with
-- AnalyticsService:LogFunnelStepEvent. Kept in one module, apart from the systems they watch, so
-- adding or retuning a funnel never means editing gameplay code -- each funnel here is a listener
-- on an existing hook plus a step number.
--
--   * PLOT_FUNNEL ("PlotCompletion") -- one step per 10% of the player's plot purchase buttons
--     bought, so step 1 is 10% and step 10 is 100%. Driven off PlotButtonService.onPurchased,
--     since buying a button is the only thing that moves plot completion.
--   * JOBS_FUNNEL ("JobsUnlocked") -- one step per business unlocked. Driven off the player's
--     BusinessList changing, which is where BusinessService's unlocks land -- so this needs no hook
--     of its own and picks up an unlock however it was earned (a level-up, a tool purchase, or the
--     resolve that runs on join).
--
-- These are LIFETIME funnels: a player's progress through them spans every session they ever play.
-- Two things follow from that, and they're the whole design:
--
--   * The funnelSessionId is the player's UserId, not a per-session id. A new id each session would
--     start them a fresh run of the funnel on every join, and a funnel nobody ever finishes in one
--     sitting would read as pure drop-off.
--   * The highest step already reported is PERSISTED (DataTemplate.FunnelProgress), so a rejoin
--     can't re-report steps the player passed months ago.
--
-- Steps are always reported CONTIGUOUSLY: advancing to step N reports every step from the stored
-- mark + 1 up to N. That covers a jump past a threshold (a single button on a small plot can cross
-- two 10% marks) and, once, a player who was already mid-progression when these funnels were added
-- -- they report the steps they'd genuinely passed rather than appearing to enter partway through,
-- which a funnel would otherwise count as never having entered at all.
--
-- Analytics are unavailable in Studio and can throw on a malformed call, and no funnel write may
-- ever take a purchase or an unlock down with it, so every report is best-effort: a failure is
-- warned about and the game carries on. Same policy as the tutorial's Onboarding funnel.

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local PlotButtonService = require(script.Parent.PlotButtonService)

local FunnelService = {}

-- Funnel names as they appear on the analytics dashboard, each paired with the FunnelProgress key
-- holding that funnel's high-water mark.
local PLOT_FUNNEL = "PlotCompletion"
local PLOT_PROGRESS_KEY = "PlotCompletion"
local JOBS_FUNNEL = "JobsUnlocked"
local JOBS_PROGRESS_KEY = "JobsUnlocked"

-- How many steps the plot funnel has: one per 10% of the plot bought.
local PLOT_STEP_COUNT = 10

-- Group every session's steps into ONE run of the funnel per player (see the header).
local function sessionId(player: Player): string
	return tostring(player.UserId)
end

-- Report a single step, best-effort.
local function logStep(player: Player, funnelName: string, stepNumber: number, stepName: string)
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, funnelName, sessionId(player), stepNumber, stepName)
	end)
	if not ok then
		warn(string.format("[FunnelService] %s step %d (%s) failed: %s", funnelName, stepNumber, stepName, tostring(err)))
	end
end

-- Move a player up to `target` in one funnel: report every step they haven't reported yet, in
-- order, then persist the new high-water mark. A target at or below the mark is a no-op, which is
-- what makes this safe to call on every purchase / every BusinessList change rather than only when
-- something is known to have changed.
--
-- The mark is written only AFTER the steps are reported, so a report that throws partway leaves the
-- mark where it was and the next advance retries from there -- losing a duplicate rather than a step.
local function advance(player: Player, progressKey: string, funnelName: string, target: number, stepName: (number) -> string)
	local stored = DataService:get(player, { "FunnelProgress", progressKey })
	local reported = if type(stored) == "number" then stored else 0
	if target <= reported then
		return
	end

	for step = reported + 1, target do
		logStep(player, funnelName, step, stepName(step))
	end
	DataService:set(player, { "FunnelProgress", progressKey }, target)
end

-- "10% Plot Complete" .. "100% Plot Complete". Derived from the step COUNT rather than hardcoding
-- 10 per step, so retuning PLOT_STEP_COUNT relabels the funnel instead of silently mislabelling it.
local function plotStepName(step: number): string
	return string.format("%d%% Plot Complete", math.floor(step * 100 / PLOT_STEP_COUNT))
end

local function jobsStepName(step: number): string
	return string.format("%d %s Unlocked", step, if step == 1 then "Job" else "Jobs")
end

-- Report however much of the plot the player has now built. Called after each button purchase.
-- A plotless player (or a plot with no buttons) reports nothing -- there's no completion to measure
-- and dividing by that total would error.
local function reportPlotCompletion(player: Player)
	local bought, total = PlotButtonService.getPlotProgress(player)
	if total <= 0 then
		return
	end
	-- Floor to the last 10% mark actually reached: 3 of 7 buttons is 42%, i.e. step 4.
	local step = math.floor(bought / total * PLOT_STEP_COUNT)
	advance(player, PLOT_PROGRESS_KEY, PLOT_FUNNEL, math.min(step, PLOT_STEP_COUNT), plotStepName)
end

-- Report how many businesses the player has unlocked. Counted from their profile rather than
-- tracked incrementally, so it stays right however the unlock happened and can't drift.
local function reportJobsUnlocked(player: Player)
	local list = DataService:get(player, { "BusinessList" })
	if type(list) ~= "table" then
		return
	end
	local unlocked = 0
	for _, record in list do
		if type(record) == "table" and record.Unlocked == true then
			unlocked += 1
		end
	end
	advance(player, JOBS_PROGRESS_KEY, JOBS_FUNNEL, unlocked, jobsStepName)
end

-- Watch one player's BusinessList for the rest of their session. Their profile has to be loaded
-- before it can be read or subscribed to, and the first read covers whatever BusinessService's
-- join-time resolve already unlocked (which may have run before we got here).
local function watchPlayer(player: Player)
	DataService:waitForData(player)
	reportJobsUnlocked(player)
	DataService:getChangedSignal(player, { "BusinessList" }):Connect(function()
		reportJobsUnlocked(player)
	end)
end

-- Register the plot listener BEFORE players can buy (PlotButtonService.onPurchased's contract), so
-- init this alongside the other services rather than lazily.
function FunnelService.init()
	PlotButtonService.onPurchased(function(player: Player)
		reportPlotCompletion(player)
	end)

	local function hookPlayer(player: Player)
		task.spawn(watchPlayer, player)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
end

return FunnelService
