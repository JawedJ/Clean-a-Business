--!strict

-- Drives the job board UI (PlayerGui.ScreenGui: Buttons.JobButton + JobFrame). The JobButton
-- toggles the JobFrame; the frame's ExitButton closes it. The frame's ScrollingFrame
-- holds one TaskDesign per business, each tagged with a "BusinessId" attribute: a row
-- shows its WashButton once the local player clears every gate on that business -- it's
-- Unlocked, they're at its RequiredLevel, and they own its RequiredItems tools -- or its
-- LockedButton if any gate fails. Pressing Wash accepts that business's job (AcceptJob), which
-- the server confirms by publishing the businessId on the ActiveJob attribute.
--
-- The row's Requirements label and RequiredItems icons show WHY a row is locked: the level line
-- and each required tool's icon go green when that gate is met, red while it isn't.
--
-- Each row also shows the business's mastery progress (StarAmount / MasteryRequirements) and a
-- Rewards line whose XP figure includes the current mastery boost, all driven off the player's
-- lifetime Completions on that business (see Mastery, and JobServer.complete which pays the boost).
--
-- The board is also where a PARTY picks its job: PartyUiController opens it through
-- openForSelection, which makes the next Wash press report that businessId back instead of starting
-- anything (the party is then created around it). See selectionHandler.
--
-- While a job is active the whole job UI hides (the Buttons frame + JobFrame) -- you can't
-- start another until this one finishes. Every other open panel is snapped shut at the same moment
-- (ExclusivePanels.hideAll): a job start takes the screen, and in a party it can be triggered by
-- someone else entirely. When the job completes the server clears ActiveJob and the Buttons frame
-- returns. So visibility of the job UI is driven off that one attribute, exactly like JobController
-- drives the overlays.
--
-- Unlock state comes from DataService and is re-read whenever BusinessList changes or the
-- frame is opened, so unlocking a business flips its row from Locked to Wash live.
--
-- Like the other HUD controllers, the ScreenGui is re-cloned into PlayerGui on every
-- respawn, so we re-bind to the fresh instances each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local Mastery = require(ReplicatedStorage.SharedModules.Mastery)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local BusinessGates = require(script.Parent.BusinessGates)
local ExclusivePanels = require(script.Parent.ExclusivePanels)

local AcceptJob = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AcceptJob") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Stable name this panel registers under with ExclusivePanels (only one exclusive panel is
-- open at a time; opening this closes the upgrades shop first, and vice versa).
local PANEL_NAME = "JobBoard"
local BUSINESS_ID_ATTRIBUTE = "BusinessId"
-- Keyboard shortcut that toggles the board, same as clicking the JobButton.
local TOGGLE_KEY = Enum.KeyCode.B
-- UI click sound played for the keyboard shortcut (the JobButton gets it automatically
-- from UiButtonController's per-GuiButton wiring; the key press doesn't).
local CLICK_SOUND = "UIClick"
-- The stacked HUD clusters (top-to-bottom: Button1, Buttons2, Buttons3) open up around whichever
-- one a button is hovered in: frames above it slide up by this much, frames below slide down, and
-- the hovered one holds. Y scale, so it tracks the screen at any resolution.
local CLUSTER_HOVER_SPREAD = 0.017
-- The RequiredItems frame each row authors, holding the per-tool icon slots BusinessGates paints.
local REQUIRED_ITEMS_FRAME = "RequiredItems"

local JobUiController = {}

-- Current top-level UI elements, refreshed each time the ScreenGui is (re)bound. All HUD
-- cluster frames (Button1: JobButton + UpgradesButton; Buttons2; Buttons3) hide during a job, so
-- no HUD buttons show mid-job.
local buttonsFrame: Frame? = nil
local buttons2Frame: Frame? = nil
local buttons3Frame: Frame? = nil
local jobFrame: Frame? = nil

-- One refresher per TaskDesign row, rebuilt on each bind; re-evaluates its lock state.
local taskRefreshers: { () -> () } = {}

-- Set while the board has been borrowed to PICK a business instead of to start one: the party flow
-- opens the same board to choose the job a party will form around (see openForSelection). While it
-- holds, a Wash press reports the businessId here and starts nothing. One-shot -- cleared by the
-- pick itself, and by closing the board without picking, so the board can never be left silently
-- refusing to start jobs.
local selectionHandler: ((string) -> ())? = nil

-- True while a finished job's JobSummary is up: the ActiveJob attribute has cleared, but we
-- keep the whole job UI hidden (the board button must NOT pop back over the summary) until the
-- player leaves the summary via GoHome, which calls releaseSummaryHold. See JobSummaryController.
local summaryHold = false

-- Told whenever the HUD's visibility flips. For the standalone buttons authored OUTSIDE the HUD
-- clusters (PlayTogetherFrame), which no cluster hides for them: rather than each re-deriving
-- "hidden on a job, and still hidden while the summary is up", they follow the clusters through
-- here, so they appear and disappear on exactly the same frame.
local hudVisibilityListeners: { (boolean) -> () } = {}

-- Whether the local player currently holds a job (drives whole-UI visibility).
local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Render a mastery boost percent for the requirement label: whole numbers stay bare (5 -> "5"),
-- otherwise up to two decimals with trailing zeros trimmed (5.25 -> "5.25", 5.5125 -> "5.51").
local function formatBoost(percent: number): string
	local s = string.format("%.2f", percent)
	if string.find(s, "%.") then
		s = (string.gsub(s, "0+$", ""))
		s = (string.gsub(s, "%.$", ""))
	end
	return s
end

local function refreshTasks()
	for _, refresh in taskRefreshers do
		refresh()
	end
end

-- Show/hide the whole job UI off the ActiveJob attribute: hidden while on a job, back
-- when it clears (job finished). While the summary hold is up the button stays hidden too --
-- the finished job's summary owns the screen until GoHome. Guards the post-respawn gap before
-- anything is bound.
local function applyActiveJobState()
	local active = hasActiveJob()
	local visible = not active and not summaryHold
	local buttons = buttonsFrame
	if buttons and buttons.Parent then
		buttons.Visible = visible
	end
	local buttons2 = buttons2Frame
	if buttons2 and buttons2.Parent then
		buttons2.Visible = visible
	end
	local buttons3 = buttons3Frame
	if buttons3 and buttons3.Parent then
		buttons3.Visible = visible
	end
	if active then
		-- A job starting takes the screen: snap away EVERY open panel, not just the board. That
		-- matters most for a party, where the job starts on the last member's ready press rather
		-- than on anything the other members did -- they'd otherwise be dropped into the business
		-- still looking at the party window (or the shop, or the settings tab) they had up.
		ExclusivePanels.hideAll()
	end
	-- Carry the same state to the standalone buttons that live outside the clusters, so they come
	-- back on the GoHome that releases the summary hold rather than the earlier moment the job ended.
	for _, listener in hudVisibilityListeners do
		listener(visible)
	end
end

-- Whether the HUD is currently showing: false on a job, and still false while a finished job's
-- summary is up. The one definition of "the player is looking at the world, not at a job", for the
-- standalone buttons that have to match the clusters.
function JobUiController.isHudVisible(): boolean
	return not hasActiveJob() and not summaryHold
end

-- Follow the HUD's visibility. Fires immediately with the current value, so a button binding after
-- a change doesn't sit wrong until the next one.
function JobUiController.onHudVisibilityChanged(callback: (boolean) -> ())
	table.insert(hudVisibilityListeners, callback)
	callback(JobUiController.isHudVisible())
end

-- ActiveJob flipped: a job starting clears any summary hold; a job ending enters one (its
-- summary is now showing) so the board button stays hidden until GoHome releases it.
local function onActiveJobChanged()
	summaryHold = not hasActiveJob()
	applyActiveJobState()
end

-- Called when the player leaves the JobSummary via GoHome: end the hold and let the board
-- button (and B shortcut) come back.
function JobUiController.releaseSummaryHold()
	summaryHold = false
	applyActiveJobState()
end

-- Toggle the board open/closed via the shared coordinator (so opening it closes the upgrades
-- shop first, and vice versa). Shared by the JobButton and the TOGGLE_KEY shortcut. No-op
-- (returns false) while on a job, during the summary hold, or before anything is bound; returns
-- true when it actually toggled, so the key path can play its click. The board's contents are
-- refreshed via the coordinator's beforeOpen (refreshTasks) right before it opens.
local function toggleBoard(): boolean
	if hasActiveJob() or summaryHold then
		return false
	end
	-- Leaving the board any way but picking abandons a party flow's claim on it (see
	-- selectionHandler), so the next opener gets a board that starts jobs again.
	selectionHandler = nil
	return ExclusivePanels.toggle(PANEL_NAME)
end

-- Open the board from a non-button trigger (the warehouse proximity hitbox), routed through
-- the same coordinator as the JobButton so it still closes the upgrades shop first. No-op
-- (returns false) while on a job or during the summary hold, matching toggleBoard's gating.
-- Unlike toggleBoard this never closes an already-open board -- re-entering the hitbox while
-- it's up shouldn't flap it shut.
function JobUiController.openBoard(): boolean
	if hasActiveJob() or summaryHold then
		return false
	end
	return ExclusivePanels.open(PANEL_NAME)
end

-- Close the board from the same proximity trigger (walking out of the hitbox). Routed through
-- the coordinator so its open-panel bookkeeping stays in sync.
function JobUiController.closeBoard()
	ExclusivePanels.close(PANEL_NAME)
end

-- Open the board to PICK a business rather than to start one: the next Wash press calls `handler`
-- with that businessId and starts no job. Used by the party flow, where choosing the job is what
-- creates the party -- so the player picks from the one board they already know rather than a second
-- copy of it that would have to be kept in step with this one.
--
-- Opened INSTANTLY (see ExclusivePanels.openInstant), because it's a step within the party screens
-- rather than a panel of its own: the party window simply becomes the board. Refused, with the claim
-- left unset, while on a job or during the summary hold -- exactly what toggleBoard refuses on.
function JobUiController.openForSelection(handler: (string) -> ()): boolean
	if hasActiveJob() or summaryHold then
		return false
	end
	if not ExclusivePanels.openInstant(PANEL_NAME) then
		return false
	end
	selectionHandler = handler
	return true
end

-- Whether the board frame is currently shown -- lets the proximity trigger skip a redundant
-- close when the board isn't up (e.g. the player closed it via Exit and is still inside).
function JobUiController.isBoardVisible(): boolean
	local frame = jobFrame
	return frame ~= nil and frame.Parent ~= nil and frame.Visible
end

-- Wire one TaskDesign row and return its refresher, or nil if it isn't a real row
-- (skips the UIListLayout/constraints, which carry no BusinessId + buttons).
local function bindTask(row: Instance): (() -> ())?
	local businessId = row:GetAttribute(BUSINESS_ID_ATTRIBUTE)
	if type(businessId) ~= "string" then
		return nil
	end
	local wash = row:FindFirstChild("WashButton") :: ImageButton?
	local locked = row:FindFirstChild("LockedButton") :: ImageButton?
	if not wash or not locked then
		return nil
	end
	local washButton, lockedButton = wash, locked

	-- The hover grow itself comes from UiButtonController's PlayerGui-wide sweep. But a button
	-- swapped out from under the pointer (a row going Locked -> Wash while hovered) may never get
	-- its MouseLeave, which would leave it grown the next time it's shown. Reset the one being
	-- hidden back to rest.
	local function resetHoverScale(button: GuiButton)
		local scale = button:FindFirstChildOfClass("UIScale")
		if scale then
			scale.Scale = 1
		end
	end

	-- Mastery labels (optional -- a row without them just skips the mastery display): the stars
	-- earned, the requirement/next-boost line, and the Rewards line we rewrite so its XP figure
	-- reflects the current mastery boost.
	local starAmount = row:FindFirstChild("StarAmount") :: TextLabel?
	local masteryRequirements = row:FindFirstChild("MasteryRequirements") :: TextLabel?
	local rewards = row:FindFirstChild("Rewards") :: TextLabel?
	-- The level-gate line ("REQUIRED: Level N"), turned green once the gate is met.
	local requirements = row:FindFirstChild("Requirements") :: TextLabel?
	-- The tool-gate icons (optional, like the mastery labels).
	local requiredItems = row:FindFirstChild(REQUIRED_ITEMS_FRAME) :: Frame?

	-- Redraw the mastery stars, the Rewards line's boosted XP, and the next-milestone
	-- requirement from the player's lifetime completions on this business.
	local function refreshMastery()
		local completions = BusinessGates.completionsFor(businessId)
		local stars = Mastery.starsForCompletions(completions)

		if starAmount then
			-- No stars yet: show "0/MAX" so the row still communicates the mastery track
			-- exists and how many stars it holds, rather than rendering blank.
			if stars <= 0 then
				starAmount.Text = string.format("0/%d", Mastery.MAX_STARS)
			else
				starAmount.Text = string.rep("⭐", stars)
			end
		end

		-- Rewards line: cash boosted by the Greed skill, and XP boosted by both the mastery star
		-- level and the Inteligence skill -- matching what a completion at this star level will
		-- actually pay (see JobServer.complete + ProgressionService's skill boosts).
		if rewards then
			rewards.Text = BusinessGates.rewardsText(businessId)
		end

		-- Requirement line: once every star is earned there's nothing left to unlock, so hide it;
		-- otherwise show the next tier's completion goal, tier progress, and the total boost that
		-- star grants (cumulative: +5% per star -> +5/+10/+15/...).
		if masteryRequirements then
			local boost = Mastery.nextTotalBoostPercent(stars)
			if boost == nil then
				masteryRequirements.Visible = false
			else
				local requirement = Mastery.nextTierRequirement(stars)
				local progress = Mastery.tierProgress(completions, stars)
				masteryRequirements.Visible = true
				masteryRequirements.Text = string.format(
					"Achieve 100%% %d times to Unlock: +%s%% EXP (%d/%d)",
					requirement,
					formatBoost(boost),
					progress,
					requirement
				)
			end
		end
	end

	local function refresh()
		-- Repaint the gate displays first (they own the row's requirement visuals), then offer the
		-- Wash button only if every gate passes; otherwise show the Locked button. Both the painting
		-- and the predicate come from BusinessGates, which the party browser paints its own slots
		-- with -- so a row and a party for the same business always agree.
		if requirements then
			BusinessGates.paintRequirements(requirements, businessId)
		end
		if requiredItems then
			BusinessGates.paintRequiredItems(requiredItems, businessId)
		end
		local playable = BusinessGates.canPlay(businessId)
		washButton.Visible = playable
		lockedButton.Visible = not playable
		resetHoverScale(if playable then lockedButton else washButton)
		refreshMastery()
	end

	washButton.Activated:Connect(function()
		if not BusinessGates.canPlay(businessId) or hasActiveJob() then
			return
		end
		-- Someone borrowed the board to PICK a business rather than to start one (the party flow --
		-- see openForSelection): hand them the pick and start nothing. The claim is one-shot, so the
		-- board is back to its normal behaviour immediately.
		local handler = selectionHandler
		if handler then
			selectionHandler = nil
			handler(businessId)
			return
		end
		-- On success the server sets ActiveJob, which hides the whole job UI via
		-- applyActiveJobState -- so there's nothing to close here.
		AcceptJob:FireServer(businessId)
	end)

	refresh()
	return refresh
end

-- Resolve one ScreenGui's job elements, wire the buttons + rows, then apply current
-- state (lock rows + active-job visibility). Yields on WaitForChild for a fresh clone.
local function bind(screenGui: Instance)
	local allButtons = screenGui:WaitForChild("HUD"):WaitForChild("AllButtons")
	local button1 = allButtons:WaitForChild("Button1")
	local buttons2 = allButtons:WaitForChild("Buttons2")
	local buttons3 = allButtons:WaitForChild("Buttons3")
	local button = button1:WaitForChild("JobButton") :: ImageButton
	local frame = screenGui:WaitForChild("JobFrame") :: Frame
	local exitButton = frame:WaitForChild("ExitButton") :: ImageButton
	local scroll = frame:WaitForChild("ScrollingFrame")

	local panel = UiAnimations.Panel.new(frame)
	buttonsFrame = button1 :: Frame
	buttons2Frame = buttons2 :: Frame
	buttons3Frame = buttons3 :: Frame
	jobFrame = frame
	frame.Visible = false

	-- Register with the coordinator so open/close is sequenced against the other panels; it
	-- refreshes the task rows (beforeOpen) right before showing.
	ExclusivePanels.register(PANEL_NAME, panel, refreshTasks)

	button.Activated:Connect(toggleBoard)

	-- The HUD clusters are the one exception to UiButtonController's PlayerGui-wide hover grow
	-- (which skips them): their buttons share a UIGridLayout, so they need the grid-aware variant
	-- that also pushes row-neighbours aside via the grid's padding, keeping a constant gap
	-- instead of overlapping them.
	UiAnimations.hoverGrowCluster(button1 :: GuiObject)
	UiAnimations.hoverGrowCluster(buttons2 :: GuiObject)
	UiAnimations.hoverGrowCluster(buttons3 :: GuiObject)

	-- While a button in one cluster is hovered, push the others away from it (clusters above slide
	-- up, those below slide down) so the stack opens up around the hovered one.
	UiAnimations.spreadStackOnHover({
		button1 :: GuiObject,
		buttons2 :: GuiObject,
		buttons3 :: GuiObject,
	}, CLUSTER_HOVER_SPREAD)

	exitButton.Activated:Connect(function()
		-- Closing without picking abandons any party flow's claim on the board (see selectionHandler).
		selectionHandler = nil
		ExclusivePanels.close(PANEL_NAME)
	end)

	taskRefreshers = {}
	for _, child in scroll:GetChildren() do
		local refresh = bindTask(child)
		if refresh then
			table.insert(taskRefreshers, refresh)
		end
	end

	applyActiveJobState()
end

function JobUiController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Persistent subscriptions; each reads whichever elements/rows are currently bound.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(onActiveJobChanged)
	-- Re-run the rows whenever anything they display can have moved: unlocking a business, leveling
	-- up past a gate, buying a required tool, or buying a Greed/Inteligence skill that changes the
	-- reward they predict. The party browser watches the same list for the same reasons.
	BusinessGates.onChanged(refreshTasks)

	-- TOGGLE_KEY opens/closes the board just like the JobButton. Ignore it when the
	-- keystroke was already consumed by the game (e.g. typing in a TextBox).
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == TOGGLE_KEY and toggleBoard() then
			SoundManager.playOneShot(CLICK_SOUND)
		end
	end)

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

return JobUiController
