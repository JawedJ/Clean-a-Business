--!strict

-- Server authority for the onboarding tutorial (see TutorialConfig for the step table). The
-- tutorial is its own game state: a player in it is walked through the twelve steps with the rest
-- of the game locked down, and everything about which step they're on lives HERE.
--
-- Why the server owns the step number rather than the client:
--   * Most steps end on something only the server can see -- a plot button charged, a job
--     accepted, GoHome pressed, a tool bought. Those flow in through the hooks below.
--   * The restrictions have to be enforced server-side anyway (a client-side-only lock is just a
--     suggestion), and they're derived from the current step, so the step must be here too.
--   * The Onboarding analytics funnel is a server API.
-- The client is told the current step through the StepAttribute and renders it; the two steps it
-- alone can see the end of (a text step's hold finishing, the job board appearing on screen) come
-- back over the TutorialEvent remote, validated against the step we believe is current so a
-- replayed or late message can't skip anyone ahead.
--
-- ONCE ONLY, AND ONLY FOR NEW PLAYERS. TutorialComplete is written the moment the tutorial starts,
-- not when it ends (see DataTemplate) -- a player who leaves halfway has had their run, and rejoins
-- into the ordinary unlocked game. So there is no such thing as a rejoining player in the tutorial
-- state, and no restriction can outlive a session.

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local TutorialConfig = require(ReplicatedStorage.SharedModules.TutorialConfig)
local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local PlotButtonService = require(script.Parent.PlotButtonService)

local TutorialEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("TutorialEvent") :: RemoteEvent

local TutorialService = {}

-- The step each player in the tutorial state is currently on. A player absent from this table is
-- not in the tutorial -- which is the normal case for everyone but a first-time joiner mid-run.
local currentStep: { [Player]: number } = {}

-- The current step's definition, or nil when the player isn't in the tutorial.
local function stepFor(player: Player): TutorialConfig.Step?
	local number = currentStep[player]
	return if number then TutorialConfig.get(number) else nil
end

-- Whether the player is in the tutorial game state right now.
function TutorialService.isActive(player: Player): boolean
	return currentStep[player] ~= nil
end

-- Report a step into the Onboarding funnel. Analytics are unavailable in Studio and can throw on a
-- malformed call, and a funnel write must never be able to take the tutorial down with it, so this
-- is best-effort: a failure is warned about and the step continues.
local function logFunnelStep(player: Player, step: TutorialConfig.Step)
	local ok, err = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step.number, step.name)
	end)
	if not ok then
		warn(string.format("[TutorialService] Onboarding funnel step %d (%s) failed: %s", step.number, step.name, tostring(err)))
	end
end

-- Fill a step's text placeholders. "{gems}" becomes the player's plot rate, which is what step 6
-- quotes back to them.
--
-- It has to be the LIVE rate. That step opens the instant the upgrade purchase is applied, so both
-- of the cached figures -- the profile's periodically-flushed mirror and the gem loop's
-- once-a-second snapshot -- still hold the rate from BEFORE the purchase, and the line would
-- congratulate the player on the production they just upgraded away from.
local function resolveText(player: Player, step: TutorialConfig.Step): string
	if not string.find(step.text, "{gems}", 1, true) then
		return step.text
	end
	local rate = PlotButtonService.getLiveGemsPerSecond(player)
	-- Whole rates read as plain integers ("2"); a fractional one keeps one decimal ("1.5").
	local shown = if rate == math.floor(rate) then NumberFormat.abbreviate(rate) else string.format("%.1f", rate)
	return (string.gsub(step.text, "{gems}", shown))
end

-- Leave the tutorial state: drop the player's step and clear the attributes, which is the signal
-- the client tears its restrictions down on. TutorialComplete was already written at start, so
-- nothing is persisted here -- this is purely the end of the live state.
local function finish(player: Player)
	currentStep[player] = nil
	player:SetAttribute(TutorialConfig.StepAttribute, nil)
	player:SetAttribute(TutorialConfig.ActiveAttribute, nil)
end

-- Move the player onto step `number`: log it into the funnel and publish it (with its resolved
-- text) to their client. Past the last step this finishes the tutorial instead.
local function enterStep(player: Player, number: number)
	local step = TutorialConfig.get(number)
	if not step then
		finish(player)
		return
	end

	currentStep[player] = number
	logFunnelStep(player, step)

	-- Text first, then the step number: the client reads the text off the attribute when the step
	-- changes, so writing them the other way round would render the previous step's line for a frame.
	player:SetAttribute(TutorialConfig.ActiveAttribute, true)
	player:SetAttribute(TutorialConfig.TextAttribute, resolveText(player, step))
	player:SetAttribute(TutorialConfig.StepAttribute, number)
end

-- Advance past `expected` -- but only if it really is the step we're on. Every completion path
-- funnels through here, so a duplicated report (two GoHome presses, a doubled remote) can only
-- ever advance the tutorial once.
local function advanceFrom(player: Player, expected: number)
	if currentStep[player] ~= expected then
		return
	end
	enterStep(player, expected + 1)
end

-- Advance if the player is on a step that ends the given way. The server-side hooks below use this
-- rather than naming a step number, so the step table stays the single place the order lives.
local function advanceIf(player: Player, advance: TutorialConfig.Advance, matches: ((TutorialConfig.Step) -> boolean)?)
	local step = stepFor(player)
	if not step or step.advance ~= advance then
		return
	end
	if matches and not matches(step) then
		return
	end
	advanceFrom(player, step.number)
end

-- === Restrictions ===================================================================
-- All three read the same way: while the tutorial runs, the ONLY thing permitted is the one thing
-- the current step names, and a player who isn't in the tutorial passes every check untouched. Anything the step doesn't name is refused, so a purchase path added
-- later is locked during the tutorial by default rather than quietly escaping it.

-- May this player buy this plot button right now? (PlotButtonService's purchase gate.)
function TutorialService.canPurchasePlotButton(player: Player, buttonName: string): boolean
	local step = stepFor(player)
	if not step then
		return true -- not in the tutorial: the plot behaves normally
	end
	-- The plot is handed back partway through, once the steps that teach it are done.
	if step.number >= TutorialConfig.PlotFreeFromStep then
		return true
	end
	return step.advance == "PlotButton" and step.plotButton == buttonName
end

-- May this player buy this tool right now? (ShopService's purchase path.)
function TutorialService.canPurchaseTool(player: Player, uniqueId: string): boolean
	local step = stepFor(player)
	if not step then
		return true
	end
	return step.advance == "ToolBuy" and step.tool == uniqueId
end

-- May this player upgrade a tool right now? No step asks for an upgrade, so the whole action is
-- off for the duration -- the shop is open at step 11 for exactly one purchase.
function TutorialService.canUpgradeTool(player: Player): boolean
	return not TutorialService.isActive(player)
end

-- === Completion hooks ===============================================================
-- Called by the services that own each action. Each is a no-op unless the player is sitting on the
-- step that action ends, so they're safe to call unconditionally.

-- A plot button was bought (steps 2 and 5).
local function onPlotButtonBought(player: Player, buttonName: string)
	advanceIf(player, "PlotButton", function(step)
		return step.plotButton == buttonName
	end)
end

-- The player accepted a job (step 8).
function TutorialService.notifyJobAccepted(player: Player)
	advanceIf(player, "JobStart")
end

-- The player pressed GoHome on the job summary (step 9). Deliberately GoHome and not the job
-- ending: PlayAgain restarts the job from the same summary, and a player who replays hasn't
-- finished the step yet -- only walking away from the summary counts.
function TutorialService.notifyGoHome(player: Player)
	advanceIf(player, "JobDone")
end

-- A tool was bought (step 11 -- the broom).
function TutorialService.notifyToolPurchased(player: Player, uniqueId: string)
	advanceIf(player, "ToolBuy", function(step)
		return step.tool == uniqueId
	end)
end

-- === Client reports =================================================================

-- The client finished rendering a step it alone can see the end of. `step` is the number it
-- believes it just finished; advanceFrom drops it unless that matches the live step.
local function onClientReport(player: Player, report: unknown, step: unknown)
	if type(report) ~= "string" or type(step) ~= "number" then
		return
	end
	local current = stepFor(player)
	if not current or current.number ~= step then
		return
	end

	if report == TutorialConfig.Report.TextDone then
		if current.advance ~= "Text" then
			return
		end
	elseif report == TutorialConfig.Report.BoardOpened then
		if current.advance ~= "BoardOpen" then
			return
		end
	else
		return
	end

	advanceFrom(player, step)
end

-- === Lifecycle ======================================================================

-- Start a joining player's tutorial, if they've never been offered it. Writing TutorialComplete
-- here -- before the first step, not after the last -- is what guarantees it can never replay:
-- however this session ends, their next join reads the flag and skips straight past.
local function onPlayerAdded(player: Player)
	DataService:waitForData(player)
	-- They left again while we waited for their profile; nothing to start.
	if player.Parent == nil then
		return
	end
	if DataService:get(player, { "TutorialComplete" }) == true then
		return
	end
	DataService:set(player, { "TutorialComplete" }, true)
	enterStep(player, 1)
end

function TutorialService.init()
	-- Register the plot-button hooks before anyone can touch a button. The gate is a veto on
	-- purchases; the listener is what advances steps 2 and 5.
	PlotButtonService.setPurchaseGate(TutorialService.canPurchasePlotButton)
	PlotButtonService.onPurchased(onPlotButtonBought)

	TutorialEvent.OnServerEvent:Connect(onClientReport)

	Players.PlayerRemoving:Connect(function(player)
		currentStep[player] = nil
	end)

	-- PlayerAdded can have already fired for players present at server start (and always has in a
	-- Studio playtest), so sweep them too. Each start yields on waitForData, hence the spawn.
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return TutorialService
