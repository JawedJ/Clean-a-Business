--!strict

-- The onboarding tutorial's step table and the constants both sides of it need. The tutorial is
-- its own game state: while it runs, the player is walked through fourteen steps and most of the
-- game's UI/purchases are locked down to just the one thing the current step asks for.
--
-- The SERVER owns the step number (TutorialService) -- it's the only side that can be trusted to
-- see a plot-button purchase, a job accept, or a tool buy, and it's the side that logs each step
-- into the Onboarding analytics funnel. It publishes the current step to the owning client through
-- the StepAttribute, and the client (TutorialController) renders it: types the text out, points the
-- beam, and shows the highlight overlays. Steps the client alone can see the end of -- a text step
-- finishing its hold, the job board coming up on screen -- are reported back over the TutorialEvent
-- remote, which the server validates against the step it believes is current.
--
-- Each step declares WHAT ENDS IT (`advance`) and WHAT IS UNLOCKED WHILE IT RUNS. Everything not
-- named by a step is locked: no panel opens, no plot button is purchasable, no tool is buyable.
-- That's why the lock rules read as an allow-list rather than a list of things to disable -- a UI
-- added later is locked during the tutorial by default rather than silently escaping it.

local TutorialConfig = {}

-- Player attributes the server publishes the tutorial state on, read by the client's controller.
--   TutorialActive -- true only while the tutorial state is running (absent otherwise)
--   TutorialStep   -- the 1-based step number currently showing (absent when not running)
--   TutorialText   -- the step's line with its placeholders already filled in (see Step.text).
--     Sent rather than read from this table because the text can depend on live server state the
--     client has no timely copy of -- step 6 quotes the player's gems/sec. ALWAYS written before
--     TutorialStep, since the step change is what the client renders off.
-- All three are set with SetAttribute on the player, so they replicate to that player only.
TutorialConfig.ActiveAttribute = "TutorialActive"
TutorialConfig.StepAttribute = "TutorialStep"
TutorialConfig.TextAttribute = "TutorialText"

-- Name of the funnel this reports into. Roblox's onboarding funnel is a single per-experience
-- funnel (AnalyticsService:LogOnboardingFunnelStepEvent), so this is documentation for the
-- analytics dashboard rather than a parameter -- the step NAMES below are what show up as rows.
TutorialConfig.FunnelName = "Onboarding"

-- What the client sends back over the TutorialEvent remote. Each carries the step number the
-- client believes it just finished, so a late/duplicated message can't skip the server ahead.
TutorialConfig.Report = {
	-- A text-only step finished typing and served its TextHoldSeconds hold.
	TextDone = "textDone",
	-- The step's target board UI came up on the player's screen (step 7's job board).
	BoardOpened = "boardOpened",
}

-- Typewriter tuning. Each character appears SecondsPerCharacter apart and plays TypingSound, so
-- the SFX is the type rate. After the last character a text-only step holds TextHoldSeconds
-- before it reports itself done.
TutorialConfig.SecondsPerCharacter = 0.03
TutorialConfig.TextHoldSeconds = 2
TutorialConfig.TypingSound = "TypingAudio"

-- The guidance beam drawn from the player to whatever the current step wants them to walk to.
-- The arrow texture is tiled along the beam and scrolled toward the target (positive TextureSpeed
-- runs from Attachment0 -> Attachment1, and the beam is built player -> target) so the arrows
-- read as "go that way".
TutorialConfig.BeamTexture = "rbxassetid://153287167"
TutorialConfig.BeamTextureSpeed = 2
TutorialConfig.BeamTextureLength = 4
TutorialConfig.BeamWidth = 1.6
TutorialConfig.BeamColor = Color3.fromRGB(255, 226, 92)
-- Studs above the HumanoidRootPart / target origin the beam's two ends sit at, so it floats over
-- the ground rather than clipping through it.
TutorialConfig.BeamPlayerHeight = 1
TutorialConfig.BeamTargetHeight = 3

-- Names of the TutorialGui elements the steps drive.
TutorialConfig.TextLabelName = "TutorialText"
TutorialConfig.GuiName = "TutorialGui"

-- Where each TutorialGui overlay parks itself: centred on one specific control inside a panel.
-- The overlays live in their OWN ScreenGui, so they can't be laid out relative to the control they
-- point at -- and the panels they sit over slide and scale through their open animation, are
-- aspect-ratio constrained, and build their rows dynamically. So rather than authoring a fixed
-- position that would only line up at one screen size, the client re-centres each overlay on its
-- target's live AbsolutePosition (see TutorialController.trackHighlight).
--
-- Rows/slots are found by the same tagging attribute their own controllers use (BusinessId on a
-- job board row, UniqueID on a shop slot), so a reordered board still resolves.
export type HighlightTarget = {
	-- ScreenGui child holding the panel, and the container inside it holding the tagged rows.
	frame: string,
	container: string,
	-- Attribute each row/slot carries, and the value identifying the one we want.
	attribute: string,
	id: string,
	-- The control inside that row/slot to centre on.
	button: string,
}

TutorialConfig.HighlightTargets = {
	-- SelectJob: the Wash button on the gas station's row -- the only job a level-1 player can take.
	WashButtonHighlight = {
		frame = "JobFrame",
		container = "ScrollingFrame",
		attribute = "BusinessId",
		id = "gasStation",
		button = "WashButton",
	},
	-- BuyBroom: the broom slot's buy/upgrade button in the shop.
	UnlockHighlight = {
		frame = "UpgradesFrame",
		container = "Slots",
		attribute = "UniqueID",
		id = "startingBroom",
		button = "InteractButton",
	},
} :: { [string]: HighlightTarget }

-- Where a step's beam points. All resolved client-side, but against two different things.
--
-- The player's own PLOT, by name:
--   PlotButton -- Plots.<plot>.Buttons.<name>.Interact (the pad they step on)
--   Board      -- Plots.<plot>.Warehouse.<name>.<union>.Hitbox (the board's walk-in volume)
--
-- The business they are ON A JOB in, with nothing to name -- there is one shredder per building, and
-- which piece of garbage is "the" one is a live question rather than an authored answer:
--   Shredder   -- Businesses.<job>.Shredder.p1, the machine's mouth
--   Garbage    -- the piece of this job's remaining cleanable garbage NEAREST the player. It is the
--                 client's own clone (see GarbageVisibility), so this can only ever be resolved
--                 client-side, and the set shrinks live as pieces are shredded.
export type BeamTarget = {
	kind: "PlotButton" | "Board" | "Shredder" | "Garbage",
	-- Button model name for PlotButton; board model name for Board. The job-relative kinds have
	-- nothing to name.
	name: string?,
	-- Board only: the union inside the board model holding the hitbox.
	union: string?,
}

-- How a step ends.
--   Text          -- types out, holds, then the client reports TextDone
--   PlotButton    -- the player buys the named plot button (server sees the purchase)
--   BoardOpen     -- the named panel comes up on screen (client reports BoardOpened)
--   JobStart      -- the player accepts a job (server sees the accept)
--   GarbagePickup -- the player picks up any piece of cleanable garbage (server sees the carry)
--   GarbageShred  -- the player feeds a piece into the shredder (server sees the shred). This is the
--                    one step that can go BACKWARD: emptying their hands without shredding puts them
--                    back on the GarbagePickup step before it (see TutorialService).
--   JobDone       -- the player finishes a job AND picks GoHome on the summary (server sees GoHome)
--   ToolBuy       -- the player buys the named tool (server sees the purchase)
export type Advance =
	"Text" | "PlotButton" | "BoardOpen" | "JobStart" | "GarbagePickup" | "GarbageShred" | "JobDone" | "ToolBuy"

export type Step = {
	-- 1-based step number; also the funnel step number.
	number: number,
	-- Funnel step name (what shows as the row in the Onboarding funnel).
	name: string,
	-- The line typed into TutorialText. May contain "{gems}", replaced with the player's live
	-- gems/sec (the server sends the figure with the step).
	text: string,
	advance: Advance,
	-- PlotButton advance: which plot button must be bought (and the ONLY one purchasable).
	plotButton: string?,
	-- ToolBuy advance: which tool must be bought (and the ONLY one purchasable).
	tool: string?,
	-- Beam target while this step runs, or nil for no beam.
	beam: BeamTarget?,
	-- ExclusivePanels name this step lets the player open. Everything else stays locked.
	panel: string?,
	-- Whether that panel, once open, refuses to close (exit button, toggle, walking out of the
	-- board hitbox). A job starting still snaps it away -- that path bypasses the coordinator.
	panelCloseLocked: boolean?,
	-- Lock the job board's ScrollingFrame so the player can't scroll past the first row.
	lockJobScroll: boolean?,
	-- TutorialGui overlay shown while this step runs ("WashButtonHighlight"/"UnlockHighlight"),
	-- or nil. For the Upgrades one it only appears once the shop is actually open (see
	-- highlightNeedsPanel).
	highlight: string?,
	-- The highlight only shows while `panel` is open, rather than for the whole step.
	highlightNeedsPanel: boolean?,
	-- Every lock is dropped for this step onward: the game is fully playable again while the last
	-- line is still on screen. Set on the closing step so finishing the final interactive task --
	-- not sitting through the last sentence -- is what gives the player their game back.
	unrestricted: boolean?,
	-- Clear the line off screen this many seconds after it finishes typing, while STAYING on the
	-- step. For a long step the player plays through (the job) -- the instruction has been read
	-- long before the step ends, and leaving it up just occludes the screen they're working on.
	-- Nothing else changes: the step still ends on its own trigger, and the next step's line
	-- brings the label back. Omitted = the line stays up for the whole step.
	hideTextAfter: number?,
}

-- The fourteen steps, in order. Index == step.number == funnel step number.
TutorialConfig.Steps = {
	{
		number = 1,
		name = "Welcome",
		text = "Welcome to Clean A Business!",
		advance = "Text",
	},
	{
		number = 2,
		name = "BuyWorker",
		text = "Walk over to your plot and purchase a Worker!",
		advance = "PlotButton",
		plotButton = "Button1",
		beam = { kind = "PlotButton", name = "Button1" },
	},
	{
		number = 3,
		name = "WorkersProduceGems",
		text = "Each worker produces gems for you!",
		advance = "Text",
	},
	{
		number = 4,
		name = "UpgradeIntro",
		text = "Great, now lets buy an upgrade to increase our gem production.",
		advance = "Text",
	},
	{
		number = 5,
		name = "BuyUpgrade",
		text = "Walk over to the button and purchase the plot upgrade.",
		advance = "PlotButton",
		plotButton = "Button3",
		beam = { kind = "PlotButton", name = "Button3" },
	},
	{
		number = 6,
		name = "GemProduction",
		text = "Awesome! Now you produce {gems} gems each second.",
		advance = "Text",
	},
	{
		number = 7,
		name = "OpenJobBoard",
		text = "Now lets start our first job, Walk over to the jobs board.",
		advance = "BoardOpen",
		beam = { kind = "Board", name = "JobBoard", union = "Jobs" },
		panel = "JobBoard",
		panelCloseLocked = true,
		lockJobScroll = true,
	},
	{
		number = 8,
		name = "SelectJob",
		text = "Select the first available job",
		advance = "JobStart",
		panel = "JobBoard",
		panelCloseLocked = true,
		lockJobScroll = true,
		highlight = "WashButtonHighlight",
	},
	-- Steps 9-11 all run INSIDE the job the step above starts (see isInJob): they teach the garbage
	-- mechanic -- pick a piece up, carry it to the shredder -- before turning the player loose on the
	-- walls. The two garbage steps are quick, so unlike the wash step their lines stay up throughout.
	{
		number = 9,
		name = "PickUpGarbage",
		text = "Pick up some garbage by clicking on it",
		advance = "GarbagePickup",
		beam = { kind = "Garbage" },
	},
	{
		number = 10,
		name = "ShredGarbage",
		text = "Bring the garbage to the shredder",
		advance = "GarbageShred",
		beam = { kind = "Shredder" },
	},
	{
		number = 11,
		name = "CleanJob",
		text = "Clean the dirt until 100% Completion!",
		advance = "JobDone",
		-- The player is on the clock here until they finish and go home, which is far longer than
		-- the line needs to be readable -- so it clears itself rather than sitting over the job.
		hideTextAfter = 8,
	},
	{
		number = 12,
		name = "WorkersKeptWorking",
		text = "Great Job! While you were busy working, your workers kept making gems!",
		advance = "Text",
	},
	{
		number = 13,
		name = "BuyBroom",
		text = "Now go to the upgrades board and purchase your next tool.",
		advance = "ToolBuy",
		tool = "startingBroom",
		beam = { kind = "Board", name = "UpgradesBoard", union = "Upgrades" },
		panel = "Upgrades",
		panelCloseLocked = true,
		highlight = "UnlockHighlight",
		highlightNeedsPanel = true,
	},
	{
		number = 14,
		name = "Complete",
		text = "You completed the tutorial! Complete more jobs to earn more cash!",
		advance = "Text",
		unrestricted = true,
	},
} :: { Step }

TutorialConfig.StepCount = #TutorialConfig.Steps

-- From this step onward the plot stops being locked down and every button on it is purchasable
-- again, even though the tutorial is still running. The plot-building half of the tutorial is done
-- by then (they've bought a worker and an upgrade and been shown what those do), and the steps
-- after it are all about jobs and the shop -- so there's no reason to keep holding the plot back,
-- and a player who wants to keep building while being walked through the rest can. The UI locks
-- are unaffected; they run to the end (see Step.unrestricted).
TutorialConfig.PlotFreeFromStep = 7

-- The step at `number`, or nil when it's past the end (which means the tutorial is finished).
function TutorialConfig.get(number: number): Step?
	return TutorialConfig.Steps[number]
end

-- Steps that can ONLY be finished while the player is on a job -- carrying a piece of garbage,
-- feeding the shredder, cleaning to 100%. They're the steps that assume a world state the player can
-- lose without finishing them: the job doesn't survive a disconnect, and it doesn't survive bailing
-- out early either. Nothing can re-arm it for them (the job board is locked shut while they run), so
-- a player who loses the job on one of these would be stranded on a step that can never end.
--
-- Both escapes -- rejoining, and going home -- therefore treat the whole run of them as done and
-- skip past it (see afterJob, and TutorialService.notifyGoHome). They were doing the job when they
-- dropped out, which is the same generosity the wash step alone used to get.
local IN_JOB_ADVANCE: { [string]: boolean } = {
	GarbagePickup = true,
	GarbageShred = true,
	JobDone = true,
}

function TutorialConfig.isInJob(step: Step): boolean
	return IN_JOB_ADVANCE[step.advance] == true
end

-- The first step at or after `number` that doesn't need a job -- `number` itself when it already
-- doesn't. May be one past the end of the table, which enterStep reads as "the tutorial is over".
function TutorialConfig.afterJob(number: number): number
	local at = number
	while true do
		local step = TutorialConfig.get(at)
		if not step or not TutorialConfig.isInJob(step) then
			return at
		end
		at += 1
	end
end

-- Where a player who left partway through should pick the tutorial back up, given the step they
-- were on. Usually that step exactly -- but two kinds of step can't simply be re-entered, because
-- they assume a world state a fresh join doesn't have:
--
--   * A step that runs INSIDE A JOB (see isInJob). The job doesn't survive the disconnect, and a
--     respawn always puts the player back on their plot rather than in the business, so the step
--     could never end on its own trigger -- it would strand them. They were doing the job when they
--     dropped, so the whole run of in-job steps counts as done and they resume after it. Past the
--     first, not just past this one: the step after an in-job step is usually another in-job step,
--     which would strand them exactly the same way.
--
--   * A step that runs with a PANEL already open (it names a `panel` but isn't the step that has
--     them open it). Nothing is open on a fresh join, so its highlight would point at a panel
--     that isn't there. They go back to the step that walks them to that panel and opens it --
--     the nearest earlier step on the SAME panel ending on BoardOpen. A panel step with no such
--     predecessor (the shop, which is opened and used within one step) is re-entered as-is: its
--     own beam already walks them back to the board.
--
-- Derived from the step table rather than hardcoding numbers, so reordering or inserting steps
-- keeps the resume rules right.
function TutorialConfig.resumeStep(number: number): number
	local step = TutorialConfig.get(number)
	if not step then
		return number
	end

	if TutorialConfig.isInJob(step) then
		return TutorialConfig.afterJob(number)
	end

	if step.panel and step.advance ~= "BoardOpen" then
		for earlier = number - 1, 1, -1 do
			local candidate = TutorialConfig.Steps[earlier]
			if candidate and candidate.panel == step.panel and candidate.advance == "BoardOpen" then
				return earlier
			end
		end
	end

	return number
end

return TutorialConfig
