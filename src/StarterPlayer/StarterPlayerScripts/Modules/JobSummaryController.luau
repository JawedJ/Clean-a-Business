--!strict

-- Drives the end-of-job summary screen (PlayerGui.ScreenGui.JobSummary). When a job ends --
-- a full clean OR a finish-early -- the server fires the JobSummary remote with the payout,
-- how much of the job was cleaned, and how long it took (see JobServer._fireSummary). We hold
-- for SHOW_DELAY seconds and then reveal the frame, populated:
--   * MoneyReward / XpReward   -- the cash + XP the completion awarded
--   * StarAmount               -- one star per 20% cleaned (5 at 100%)
--   * RatingDescription        -- flavour text for that star rating
--   * CompletionText           -- "You finished in mm:ss Minutes!"
--   * MoneyReward (outer)       -- a "(1.5X REWARDS)" badge, shown only on a bonus replay
-- and its two buttons:
--   * PlayAgain -- re-accepts the same job (which the server pays at 1.5x -- the replay bonus)
--   * GoHome    -- teleports back to the plot spawn
--
-- Like the other HUD controllers the ScreenGui is re-cloned on every respawn, so we re-bind
-- to the fresh instances each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)
local JobCameraController = require(script.Parent.JobCameraController)
local InventoryController = require(script.Parent.InventoryController)
local JobUiController = require(script.Parent.JobUiController)
local Crosshair = require(script.Parent.Crosshair)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local JobSummary = Remotes:WaitForChild("JobSummary") :: RemoteEvent
local AcceptJob = Remotes:WaitForChild("AcceptJob") :: RemoteEvent
local GoHome = Remotes:WaitForChild("GoHome") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Seconds to hold after the job ends before revealing the summary, so the finish reads for a
-- beat first. The player stays in first person across this hold; the camera only pulls back
-- once they pick GoHome.
local SHOW_DELAY = 1

-- The frame drops in from just above the screen and bounces into its authored position. Only
-- the Y changes; the tween lands on the position captured at bind time.
local DROP_TWEEN = TweenInfo.new(1.25, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)

-- Seconds the money + XP counters tick up from 0 to their real totals as the frame drops in.
local COUNT_DURATION = 3
-- Looping SFX played only while the counters are ticking.
local COUNTER_SOUND = "money_counter_loop"
-- One-shot played when the counters land on their final totals.
local END_SOUND = "JobCompletionEnd"

-- Flavour text per star rating (1..5), each 7-9 words. The 5-star line is the one authored on
-- the label; the rest describe progressively worse (partial finish-early) results.
local RATING_DESCRIPTIONS = {
	[1] = "Terrible job! The customer was extremely disappointed and upset.",
	[2] = "Sloppy work left the customer feeling rather unimpressed today.",
	[3] = "Decent job, but the customer expected a bit more.",
	[4] = "Great work! The customer was quite happy overall.",
	[5] = "Amazing Job! The customer was very satisfied!",
}

-- Payload the server sends with the JobSummary remote.
type SummaryData = {
	businessId: string,
	cash: number,
	xp: number,
	fraction: number,
	duration: number,
	bonus: boolean,
}

local JobSummaryController = {}

-- Current summary elements, refreshed each time the ScreenGui is (re)bound.
local frame: Frame? = nil
local moneyReward: TextLabel? = nil
local xpReward: TextLabel? = nil
local starAmount: TextLabel? = nil
local ratingDescription: TextLabel? = nil
local completionText: TextLabel? = nil
local bonusBadge: TextLabel? = nil
local playAgain: ImageButton? = nil
local goHome: ImageButton? = nil

-- The frame's authored (target) position, captured on bind, so the drop-in tween can land on
-- it exactly regardless of where the designer places the frame.
local targetPosition: UDim2 = UDim2.new()
-- The drop-in tween in flight, so a fresh reveal can supersede one still playing.
local dropTween: Tween? = nil

-- The RenderStepped connection ticking the money/XP counters up, and the looping SFX that
-- plays alongside it. Both live only for the COUNT_DURATION count-up; stopCount tears them down.
local countConn: RBXScriptConnection? = nil
local counterSound: SoundManager.SustainedSound? = nil

-- PlayAgain/GoHome only work once the count-up finishes; the click handlers gate on this and
-- the buttons dim (AutoButtonColor off) while locked.
local buttonsInteractable = false

-- The business the summary is currently showing, so PlayAgain knows which job to re-accept.
local currentBusinessId: string? = nil

-- The target position raised so the whole frame sits just above the top edge (same X + any
-- offsets; only the Y scale changes). This is where the drop-in starts from.
local function offscreenAbove(target: UDim2, size: UDim2): UDim2
	return UDim2.new(target.X.Scale, target.X.Offset, -size.Y.Scale - 0.05, -size.Y.Offset)
end

-- One star per 20% cleaned, clamped to 1..5 so there's always a rating (and a description);
-- a full completion sends fraction = 1 -> 5 stars. The tiny epsilon keeps an exact 1.0 from
-- floating just under 5.
local function starsFor(fraction: number): number
	return math.clamp(math.floor(fraction * 5 + 1e-6), 1, 5)
end

local function formatDuration(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	return string.format("You finished in %02d:%02d Minutes!", math.floor(total / 60), total % 60)
end

local function formatMoney(value: number): string
	return "$" .. NumberFormat.abbreviate(value)
end

local function formatXp(value: number): string
	return string.format("+%s EXP", NumberFormat.abbreviate(value))
end

-- Lock/unlock the two buttons: the click handlers gate on the flag, and we mirror it on the
-- buttons' AutoButtonColor so a locked button doesn't light up on hover.
local function setButtonsInteractable(value: boolean)
	buttonsInteractable = value
	if playAgain then
		playAgain.AutoButtonColor = value
	end
	if goHome then
		goHome.AutoButtonColor = value
	end
end

-- Stop the count-up: drop the per-frame ticker and silence the loop. Safe to call when idle.
local function stopCount()
	if countConn then
		countConn:Disconnect()
		countConn = nil
	end
	if counterSound then
		counterSound.stop()
	end
end

-- Tick the money + XP labels up from 0 to their real totals over COUNT_DURATION, with the
-- money_counter_loop SFX playing for the duration. Supersedes any count already running.
local function animateCounts(cash: number, xp: number)
	stopCount()
	-- Buttons stay locked until the totals land.
	setButtonsInteractable(false)

	if moneyReward then
		moneyReward.Text = formatMoney(0)
	end
	if xpReward then
		xpReward.Text = formatXp(0)
	end
	if counterSound then
		counterSound.start()
	end

	local startClock = os.clock()
	countConn = RunService.RenderStepped:Connect(function()
		local t = math.clamp((os.clock() - startClock) / COUNT_DURATION, 0, 1)
		if moneyReward then
			moneyReward.Text = formatMoney(math.floor(cash * t))
		end
		if xpReward then
			xpReward.Text = formatXp(math.floor(xp * t))
		end
		if t >= 1 then
			-- Land exactly on the real totals, then stop (floor(cash * t) could round shy).
			if moneyReward then
				moneyReward.Text = formatMoney(cash)
			end
			if xpReward then
				xpReward.Text = formatXp(xp)
			end
			stopCount()
			-- Totals are in: punctuate with the finish sound and let the buttons work.
			SoundManager.playOneShot(END_SOUND)
			setButtonsInteractable(true)
		end
	end)
end

-- Fill in the labels from a payload and reveal the frame. Guards the post-respawn gap before
-- anything is bound (the reveal is delayed, so the ScreenGui could have been swapped).
local function show(data: SummaryData)
	local root = frame
	if not root or not root.Parent then
		return
	end

	currentBusinessId = data.businessId

	-- Money + XP tick up from 0 to their totals over the next few seconds (see animateCounts).
	animateCounts(data.cash, data.xp)

	local stars = starsFor(data.fraction)
	if starAmount then
		starAmount.Text = string.rep("⭐", stars)
	end
	if ratingDescription then
		ratingDescription.Text = RATING_DESCRIPTIONS[stars]
	end
	if completionText then
		completionText.Text = formatDuration(data.duration)
	end
	-- The "(1.5X REWARDS)" badge only reads true on a bonus replay.
	if bonusBadge then
		bonusBadge.Visible = data.bonus
	end

	-- Drop in from just above the screen and bounce into the authored position (Y only).
	if dropTween then
		dropTween:Cancel()
		dropTween = nil
	end
	root.Position = offscreenAbove(targetPosition, root.Size)
	root.Visible = true
	local tween = TweenService:Create(root, DROP_TWEEN, { Position = targetPosition })
	dropTween = tween
	tween:Play()

	-- We're held in first person over the summary (the camera doesn't zoom out and the
	-- inventory stays up); free the cursor so PlayAgain/GoHome are clickable, and hide the
	-- centered crosshair dot so it doesn't block the summary's UI.
	JobCameraController.freeMouseForSummary()
	Crosshair.setSuppressed(true)
end

-- Tear the summary off screen. Used by both buttons and as a safety when a new job starts.
local function hide()
	if dropTween then
		dropTween:Cancel()
		dropTween = nil
	end
	-- Kill the count-up + its loop SFX if the summary leaves mid-tick.
	stopCount()
	local root = frame
	if root then
		root.Visible = false
	end
	-- Whatever removed the summary, the crosshair can come back (a new job wants it; going
	-- home is third person where it's off anyway).
	Crosshair.setSuppressed(false)
end

local function onPlayAgain()
	if not buttonsInteractable then
		return -- locked until the count-up finishes
	end
	local businessId = currentBusinessId
	if not businessId then
		return
	end
	-- Re-accept the same job; the server pays this run at 1.5x (the replay bonus) because it
	-- was just finished. Hide now so the summary doesn't linger over the fresh job.
	hide()
	AcceptJob:FireServer(businessId)
end

local function onGoHome()
	if not buttonsInteractable then
		return -- locked until the count-up finishes
	end
	-- Only now do the teardown that a job end used to trigger instantly: pull the camera back
	-- to third person and stow the hotbar. The server sends the character home.
	hide()
	JobCameraController.releaseToIdle()
	InventoryController.stow()
	JobUiController.releaseSummaryHold()
	GoHome:FireServer()
end

local function bind(screenGui: Instance)
	local root = screenGui:WaitForChild("JobSummary") :: Frame
	local textFrame = root:WaitForChild("TextFrame")

	frame = root
	moneyReward = textFrame:WaitForChild("MoneyReward") :: TextLabel
	xpReward = textFrame:WaitForChild("XpReward") :: TextLabel
	starAmount = textFrame:WaitForChild("StarAmount") :: TextLabel
	ratingDescription = textFrame:WaitForChild("RatingDescription") :: TextLabel
	completionText = textFrame:WaitForChild("CompletionText") :: TextLabel
	-- The "(1.5X REWARDS)" badge sits at the frame root, alongside the buttons.
	bonusBadge = root:WaitForChild("MoneyReward") :: TextLabel
	playAgain = root:WaitForChild("PlayAgain") :: ImageButton
	goHome = root:WaitForChild("GoHome") :: ImageButton

	-- Where the frame lives when open; the drop-in tween lands here (Studio authors it hidden).
	targetPosition = root.Position
	root.Visible = false

	playAgain.Activated:Connect(onPlayAgain)
	goHome.Activated:Connect(onGoHome)
end

function JobSummaryController.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- One reusable looping handle for the counter SFX (preloaded up front); animateCounts
	-- start()s it and stopCount stop()s it.
	counterSound = SoundManager.createSustained(COUNTER_SOUND)

	-- Server fires this when a job ends: play the completion chime right away, then hold a
	-- beat (so the finish reads) before revealing the summary.
	JobSummary.OnClientEvent:Connect(function(data: SummaryData)
		SoundManager.playOneShot("Completion")
		task.delay(SHOW_DELAY, function()
			show(data)
		end)
	end)

	-- Safety: if a new job starts (e.g. PlayAgain, or opening the board), make sure a stale
	-- summary isn't left over the top of it.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(function()
		if type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string" then
			hide()
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

return JobSummaryController
