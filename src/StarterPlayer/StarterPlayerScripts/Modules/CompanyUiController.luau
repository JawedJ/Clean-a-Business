--!strict

-- Drives the Company UI (PlayerGui.ScreenGui.CompanyUI). The HUD's CompanyButton
-- (HUD.AllButtons.Buttons2.CompanyButton) toggles the panel open/closed; its ExitButton closes it.
-- Open/close go through the shared ExclusivePanels coordinator (like the job board / upgrades shop /
-- settings), so at most one panel is up at a time: opening this closes whichever of those was open
-- with the SAME slide+expand / swoop+shrink motion (UiAnimations.Panel), both animating together.
--
-- The panel shows the player's business at a glance:
--   * ImageCard.ImageLabel   -- the player's avatar headshot (fetched via GetUserThumbnailAsync)
--   * InfoCard.PlayerInfoText -- "<PlayerName>'s Business"
--   * InfoCard.StarsAmtText   -- the player's AVERAGE per-job star rating (Ratings.Sum / Count,
--                                the 1-star floor before any job is rated), kept live off the data
--   * InfoCard.DescriptionEditableTxt -- an editable description the player writes; persisted across
--                                sessions via UpdateBusinessDescription (see CompanyService), the
--                                same client-edit / server-persist round-trip the settings use.
--
-- BottomSubframe holds four stat cards, each with one live label (alongside its _STATIC caption):
--   * EarningsCard.["Rate/sTxt"] -- the plot's gems/sec (GemsPerSecond, mirrored by CompanyService)
--   * CompletionCard.PercentageTxt -- % of the plot's purchase buttons bought (PlotButtonsBought
--                                over the button count authored on the player's plot)
--   * JobsCard.JobAmtTxt      -- lifetime jobs finished (summed BusinessList Completions)
--   * TimeCard.TimeAmtTxt     -- lifetime playtime (PlaytimeSeconds), as days + hours
--
-- Two of that row's cards are Robux products, both granted server-side by GemProductsService:
--   * ClaimCard   -- GemAmtTxt quotes a full day of OFFLINE-rate earnings (the plot's gems/sec over
--                    CleaningConfig.OfflineRateDivisor, times ClaimEarningsSeconds) and ClaimNowButton
--                    buys exactly that. The server recomputes the amount at receipt time; this label
--                    is only a quote, never the source of what's paid. Every open asks the server to
--                    re-mirror the rate first (RefreshCompanyStats), so the quote can't lag behind a
--                    producer the player just bought.
--   * PurchaseCard -- PurchaseButton buys the 10x gem boost (see GemBuff); the HUD countdown while
--                    it runs is GemBuffController's, not ours.
--
-- Labels suffixed with "_STATIC" (e.g. RatingText_STATIC) are designer-authored copy and are never
-- touched here -- see the CompanyUI note in the tech doc.
--
-- Like the other HUD controllers the ScreenGui is re-cloned into PlayerGui on every respawn, so we
-- re-bind to the fresh instances each time one appears.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client
local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local ExclusivePanels = require(script.Parent.ExclusivePanels)
local GemBurst = require(script.Parent.GemBurst)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateBusinessDescription = Remotes:WaitForChild("UpdateBusinessDescription") :: RemoteEvent
-- Asks CompanyService to re-mirror GemsPerSecond right now, instead of leaving the cards on
-- whatever its 15-second stats loop last wrote (see refreshOnOpen).
local RefreshCompanyStats = Remotes:WaitForChild("RefreshCompanyStats") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Stable name this panel registers under with ExclusivePanels (only one exclusive panel open at a
-- time; opening this closes the job board / shop / settings first, and vice versa).
local PANEL_NAME = "Company"
-- Placeholder shown when the player hasn't written a description (empty saved value).
local DESCRIPTION_PLACEHOLDER = "Write your own description..."
-- Most stars the rating can show (matches the JobSummary rating scale).
local MAX_STARS = 5
-- The bottom row's two Robux dev products (granted server-side -- see GemProductsService):
-- the ClaimCard's day of offline earnings and the PurchaseCard's 10x gem boost.
local CLAIM_PRODUCT_ID = 3611875543
local BOOST_PRODUCT_ID = 3611875531

local CompanyUiController = {}

-- The currently-bound elements, refreshed each time the ScreenGui is (re)bound.
local starsText: TextLabel? = nil
local descriptionBox: TextBox? = nil

-- Each stat card's live label (its _STATIC caption is designer copy and never touched).
local earningsText: TextLabel? = nil
local completionText: TextLabel? = nil
local jobsText: TextLabel? = nil
local timeText: TextLabel? = nil
local claimText: TextLabel? = nil
-- The gem figure currently quoted on the ClaimCard, kept so the button can refuse to raise a Robux
-- prompt for a plot that would pay nothing (a player who's bought no gem producers yet).
local claimQuote = 0

-- How many purchase buttons the player's plot has in total (the completion denominator). Plots are
-- authored identically and never gain buttons at runtime, so this is counted once and cached.
local plotButtonTotal: number? = nil

-- Average per-job rating from the running tally: Sum / Count, or the 1-star floor before any job
-- has been rated (Count 0). Reads default to 0 while the profile is still replicating.
local function getAverageRating(): number
	local sum = DataService:get({ "Ratings", "Sum" })
	local count = DataService:get({ "Ratings", "Count" })
	sum = if type(sum) == "number" then sum else 0
	count = if type(count) == "number" then count else 0
	if count <= 0 then
		return 1
	end
	return sum / count
end

-- Repaint the stars label from the current average, as a row of ⭐ emoji like the JobSummary
-- screen (not a number) -- the average rounded to the nearest whole star, floored at 1.
local function refreshStars()
	if starsText then
		local stars = math.clamp(math.floor(getAverageRating() + 0.5), 1, MAX_STARS)
		starsText.Text = string.rep("⭐", stars)
	end
end

-- Push the saved description into the box, unless the player is mid-edit (focused) -- so a server
-- confirmation arriving while they type can't yank the text out from under them. An empty saved
-- value leaves the box empty so its placeholder shows.
local function refreshDescription()
	local box = descriptionBox
	if not box or box:IsFocused() then
		return
	end
	local saved = DataService:get({ "BusinessDescription" })
	box.Text = if type(saved) == "string" then saved else ""
end

-- Write one card's live label, if it's currently bound.
local function paintCard(label: TextLabel?, text: string)
	if label then
		label.Text = text
	end
end

-- Numeric read that tolerates a still-replicating profile (nil) or a bad type.
local function getNumber(path: { string }): number
	local value = DataService:get(path)
	return if type(value) == "number" then value else 0
end

-- The player's own plot (Workspace.Plots.Plot(i)), from the Plot attribute PlotService stamps on
-- them. Nil until they've been assigned one.
local function getPlot(): Instance?
	local plotsFolder = Workspace:FindFirstChild(Config.PlotsFolderName)
	local plotName = localPlayer:GetAttribute(Config.PlotAttribute)
	if not plotsFolder or type(plotName) ~= "string" then
		return nil
	end
	return plotsFolder:FindFirstChild(plotName)
end

-- Total purchase buttons on the player's plot, cached once a plot is actually available (a zero
-- result isn't cached, so an early call before the plot replicates just retries later).
local function getPlotButtonTotal(): number
	if plotButtonTotal then
		return plotButtonTotal
	end
	local plot = getPlot()
	local buttonsFolder = plot and plot:FindFirstChild(Config.PlotButtonsFolderName)
	if not buttonsFolder then
		return 0
	end
	local total = 0
	for _, model in buttonsFolder:GetChildren() do
		-- Same shape PlotButtonService requires: "Button<number>". Anything else isn't a button.
		if model.Name:match("%d+$") then
			total += 1
		end
	end
	if total > 0 then
		plotButtonTotal = total
	end
	return total
end

-- Percent (0..100) of the plot's buttons the player has bought. Only saved names that exist on the
-- plot count, so a name left over from an older layout can't push it past 100%.
local function getCompletionPercent(): number
	local total = getPlotButtonTotal()
	if total <= 0 then
		return 0
	end
	local bought = DataService:get({ "PlotButtonsBought" })
	if type(bought) ~= "table" then
		return 0
	end
	local plot = getPlot()
	local buttonsFolder = plot and plot:FindFirstChild(Config.PlotButtonsFolderName)
	local count = 0
	for name, isBought in bought do
		if isBought and buttonsFolder and buttonsFolder:FindFirstChild(name) then
			count += 1
		end
	end
	return math.min(count / total * 100, 100)
end

-- Lifetime jobs finished: every business's Completions summed (JobServer tallies one per FULL
-- completion, so a bailed-out job doesn't count).
local function getJobsFinished(): number
	local businesses = DataService:get({ "BusinessList" })
	if type(businesses) ~= "table" then
		return 0
	end
	local total = 0
	for _, record in businesses do
		if type(record) == "table" and type(record.Completions) == "number" then
			total += record.Completions
		end
	end
	return total
end

-- Gems/sec for the card: abbreviated once it's big (1.2k), but kept to one decimal below 1000 so
-- an early plot earning 0.5/s doesn't read as a flat "0".
local function formatRate(rate: number): string
	if rate >= 1000 then
		return NumberFormat.abbreviate(rate)
	end
	local text = string.format("%.1f", rate)
	return (text:gsub("%.0$", ""))
end

-- Playtime as days + hours only ("14 Days, 23h"), the authored TimeAmtTxt shape. Anything finer is
-- deliberately dropped, so a brand-new player reads "0 Days, 0h".
local function formatPlaytime(seconds: number): string
	local days = math.floor(seconds / 86400)
	local hours = math.floor(seconds % 86400 / 3600)
	return string.format("%d %s, %dh", days, if days == 1 then "Day" else "Days", hours)
end

-- Repaint all four stat cards off the current data. Cheap enough to run on any of the changes that
-- feed them (and again on every open).
local function refreshStats()
	local rate = getNumber({ "GemsPerSecond" })
	paintCard(earningsText, string.format("%s Gems/s", formatRate(rate)))

	paintCard(completionText, string.format("%d%%", math.floor(getCompletionPercent())))

	paintCard(jobsText, NumberFormat.commas(getJobsFinished()))

	paintCard(timeText, formatPlaytime(getNumber({ "PlaytimeSeconds" })))

	-- What the ClaimCard's product pays: a day at the reduced offline rate, off the same base rate
	-- the server recomputes it from at purchase time.
	claimQuote = math.floor(rate / Config.OfflineRateDivisor * Config.ClaimEarningsSeconds)
	paintCard(claimText, NumberFormat.abbreviate(claimQuote))
end

-- Kick off an async fetch of the local player's headshot and drop it onto the ImageCard label.
-- GetUserThumbnailAsync yields (and can error transiently), so spawn + pcall it; a failure just
-- leaves the authored placeholder image.
local function loadAvatar(imageLabel: ImageLabel)
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(
				localPlayer.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size150x150
			)
		end)
		if ok and content and imageLabel.Parent then
			imageLabel.Image = content
		end
	end)
end

local function bind(screenGui: Instance)
	local hud = screenGui:WaitForChild("HUD")
	local companyButton = hud:WaitForChild("AllButtons"):WaitForChild("Buttons2"):WaitForChild("CompanyButton") :: ImageButton

	local ui = screenGui:WaitForChild("CompanyUI") :: Frame
	local mainFrame = ui:WaitForChild("MainFrame")
	local exitButton = mainFrame:WaitForChild("ExitButton") :: ImageButton

	local topSubframe = mainFrame:WaitForChild("TopSubframe")
	local avatarLabel = topSubframe:WaitForChild("ImageCard"):WaitForChild("ImageLabel") :: ImageLabel
	local infoCard = topSubframe:WaitForChild("InfoCard")
	local playerInfoText = infoCard:WaitForChild("PlayerInfoText") :: TextLabel
	local box = infoCard:WaitForChild("DescriptionEditableTxt") :: TextBox

	starsText = infoCard:WaitForChild("StarsAmtText") :: TextLabel
	descriptionBox = box

	local bottomSubframe = mainFrame:WaitForChild("BottomSubframe")
	earningsText = bottomSubframe:WaitForChild("EarningsCard"):WaitForChild("Rate/sTxt") :: TextLabel
	completionText = bottomSubframe:WaitForChild("CompletionCard"):WaitForChild("PercentageTxt") :: TextLabel
	jobsText = bottomSubframe:WaitForChild("JobsCard"):WaitForChild("JobAmtTxt") :: TextLabel
	timeText = bottomSubframe:WaitForChild("TimeCard"):WaitForChild("TimeAmtTxt") :: TextLabel

	local claimCard = bottomSubframe:WaitForChild("ClaimCard")
	claimText = claimCard:WaitForChild("GemAmtTxt") :: TextLabel
	local claimButton = claimCard:WaitForChild("ClaimNowButton") :: ImageButton
	local boostButton = bottomSubframe:WaitForChild("PurchaseCard"):WaitForChild("PurchaseButton") :: ImageButton

	-- Build the shared open/close animation off the frame's authored (resting) geometry, then snap
	-- it hidden. (The frame is authored hidden in Studio too, but its Position/Size are still the
	-- rest values, which is what Panel.new captures as the open state.)
	local panel = UiAnimations.Panel.new(ui)
	ui.Visible = false

	-- Register with the coordinator so open/close is sequenced against the other panels; it runs
	-- refreshOnOpen (beforeOpen) to make the live labels current right before the panel springs in.
	ExclusivePanels.register(PANEL_NAME, panel, function()
		refreshStars()
		refreshDescription()
		-- Paint immediately off the data we already have so the panel never springs in blank or
		-- mid-change...
		refreshStats()
		-- ...and ask the server to re-mirror the plot rate, since its stats loop only writes every
		-- 15 seconds -- a player who just bought a producer would otherwise open to a stale rate and
		-- a stale 24-hour quote. The reply lands as a GemsPerSecond change, which repaints again.
		RefreshCompanyStats:FireServer()
	end)

	-- Static, per-session content.
	playerInfoText.Text = string.format("%s's Business", localPlayer.DisplayName)
	loadAvatar(avatarLabel)

	-- The box is authored Active = false; on TOUCH devices an inactive TextBox never receives the
	-- tap, so it can't focus or raise the keyboard (on desktop a click focuses it regardless). Force
	-- it active so mobile players can edit it -- same reason the settings controls are set active.
	box.Active = true

	-- Live content -- seed it now, then keep it fresh off the data (see init's changed signals).
	refreshStars()
	box.PlaceholderText = DESCRIPTION_PLACEHOLDER
	refreshDescription()
	refreshStats()

	-- Persist the description on commit (focus lost / Enter). The server sanitizes + saves and
	-- replicates the confirmed value back, which refreshDescription re-applies.
	box.FocusLost:Connect(function()
		UpdateBusinessDescription:FireServer(box.Text)
	end)

	-- Toggle open/closed through the coordinator: opening this closes whichever other panel was up
	-- (both animate together), and the exit button closes it. The coordinator handles all the
	-- mid-animation gating + queueing.
	companyButton.Activated:Connect(function()
		ExclusivePanels.toggle(PANEL_NAME)
	end)
	exitButton.Activated:Connect(function()
		ExclusivePanels.close(PANEL_NAME)
	end)

	-- Both cards just raise the Robux prompt; the server grants off the receipt (GemProductsService),
	-- so a cancelled or failed purchase needs nothing from us. The panel stays open either way.
	claimButton.Activated:Connect(function()
		-- A plot with no gem producers quotes 0, and the server would grant 0 for real Robux. Don't
		-- raise the prompt at all until there's something to buy.
		if claimQuote <= 0 then
			return
		end
		MarketplaceService:PromptProductPurchase(localPlayer, CLAIM_PRODUCT_ID)
	end)
	boostButton.Activated:Connect(function()
		MarketplaceService:PromptProductPurchase(localPlayer, BOOST_PRODUCT_ID)
	end)
end

function CompanyUiController.init()
	-- A completed 24-hour earnings purchase showers gems into the HUD counter, exactly as claiming
	-- offline earnings does -- the gems themselves are granted server-side off the receipt, so this
	-- is purely the payoff animation. Connected once here rather than per-bind so it never stacks.
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(_userId, productId, isPurchased)
		if productId == CLAIM_PRODUCT_ID and isPurchased then
			GemBurst.play()
		end
	end)

	-- Keep the average-rating label in sync as jobs are rated server-side (Sum + Count each move).
	DataService:getChangedSignal({ "Ratings", "Sum" }):Connect(refreshStars)
	DataService:getChangedSignal({ "Ratings", "Count" }):Connect(refreshStars)
	-- Re-apply the saved description on any confirmed write (e.g. our own persist round-trip).
	DataService:getChangedSignal({ "BusinessDescription" }):Connect(refreshDescription)

	-- Keep the stat cards live off their sources: the mirrored plot rate and accrued playtime (both
	-- written by CompanyService), and plot purchases. Jobs finished has no single path to watch --
	-- it's summed across BusinessList -- so it refreshes on open like the rest.
	DataService:getChangedSignal({ "GemsPerSecond" }):Connect(refreshStats)
	DataService:getChangedSignal({ "PlaytimeSeconds" }):Connect(refreshStats)
	DataService:getChangedSignal({ "PlotButtonsBought" }):Connect(refreshStats)

	local playerGui = localPlayer:WaitForChild("PlayerGui")
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

return CompanyUiController
