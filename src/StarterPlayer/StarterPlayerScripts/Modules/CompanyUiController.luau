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
-- Labels suffixed with "_STATIC" (e.g. RatingText_STATIC) are designer-authored copy and are never
-- touched here -- see the CompanyUI note in the tech doc.
--
-- Like the other HUD controllers the ScreenGui is re-cloned into PlayerGui on every respawn, so we
-- re-bind to the fresh instances each time one appears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).client
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local ExclusivePanels = require(script.Parent.ExclusivePanels)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateBusinessDescription = Remotes:WaitForChild("UpdateBusinessDescription") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"
-- Stable name this panel registers under with ExclusivePanels (only one exclusive panel open at a
-- time; opening this closes the job board / shop / settings first, and vice versa).
local PANEL_NAME = "Company"
-- Placeholder shown when the player hasn't written a description (empty saved value).
local DESCRIPTION_PLACEHOLDER = "Write your own description..."
-- Most stars the rating can show (matches the JobSummary rating scale).
local MAX_STARS = 5

local CompanyUiController = {}

-- The currently-bound elements, refreshed each time the ScreenGui is (re)bound.
local starsText: TextLabel? = nil
local descriptionBox: TextBox? = nil

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
	end)

	-- Static, per-session content.
	playerInfoText.Text = string.format("%s's Business", localPlayer.DisplayName)
	loadAvatar(avatarLabel)

	-- Live content -- seed it now, then keep it fresh off the data (see init's changed signals).
	refreshStars()
	box.PlaceholderText = DESCRIPTION_PLACEHOLDER
	refreshDescription()

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
end

function CompanyUiController.init()
	-- Keep the average-rating label in sync as jobs are rated server-side (Sum + Count each move).
	DataService:getChangedSignal({ "Ratings", "Sum" }):Connect(refreshStars)
	DataService:getChangedSignal({ "Ratings", "Count" }):Connect(refreshStars)
	-- Re-apply the saved description on any confirmed write (e.g. our own persist round-trip).
	DataService:getChangedSignal({ "BusinessDescription" }):Connect(refreshDescription)

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
