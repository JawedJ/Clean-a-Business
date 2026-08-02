--!strict

-- Builds the three physical leaderboard walls in workspace.Leaderboard from the data
-- LeaderboardService broadcasts (see it for where the rankings come from).
--
-- Each model owns a part named "Display"; we hang a SurfaceGui on that part's LEFT face -- the
-- thin axis of every Display is X, so Left/Right are its two big faces -- and fill it with a
-- scrollable top-100 list. Which board is which is read off the MODEL's name (STAT_KEYS), so the
-- three models are interchangeable and adding a fourth board only needs a name and a store.
--
-- The whole UI is built CLIENT-side rather than by the server for two reasons: 300 rows of
-- instances never touch replication, and each player scrolls their own board independently
-- (CanvasPosition on a server-owned GUI would be a local-only change fighting the server anyway).
--
-- Rows are rebuilt wholesale on every update. That's ~100 instances per board every
-- REFRESH_INTERVAL (two minutes), which is far cheaper than diffing and keeps rank/colour/value
-- from ever drifting out of step with each other.
--
-- STREAMING: the place has StreamingEnabled, so a Display part is NOT a fixture we can look up
-- once. It arrives whenever the player gets close enough and is destroyed on the client the
-- moment they walk away -- taking the SurfaceGui we parented to it with it -- and comes back as a
-- brand-new instance next time. So we never walk the folder once at init; each model is WATCHED
-- (ChildAdded/ChildRemoved) and its board is rebuilt on every arrival from the cached payload.
-- The models themselves are also set to ModelStreamingMode.Persistent in the place, which keeps
-- them resident and makes the rebuild path a rarity rather than a per-approach event -- but the
-- watcher is what makes the controller correct either way.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local LeaderboardUpdate = Remotes:WaitForChild("LeaderboardUpdate") :: RemoteEvent

-- Studs -> pixels for the SurfaceGuis. Every size below is in those pixels, so the bigger Jobs
-- board simply shows more rows at the same physical text size rather than scaling everything up.
local PIXELS_PER_STUD = 50

local HEADER_HEIGHT = 86
local ROW_HEIGHT = 56
local ROW_PADDING = 4

local BACKGROUND = Color3.fromRGB(20, 23, 33)
local HEADER_COLOR = Color3.fromRGB(31, 36, 51)
local ROW_COLOR = Color3.fromRGB(30, 34, 48)
local ROW_ALT_COLOR = Color3.fromRGB(25, 29, 41)
local TEXT_COLOR = Color3.fromRGB(236, 240, 248)
local MUTED_COLOR = Color3.fromRGB(148, 158, 178)
local VALUE_COLOR = Color3.fromRGB(126, 226, 168)

-- Rank tints for the podium; every other rank uses MUTED_COLOR.
local RANK_COLORS: { [number]: Color3 } = {
	[1] = Color3.fromRGB(255, 213, 74),
	[2] = Color3.fromRGB(213, 220, 230),
	[3] = Color3.fromRGB(224, 150, 79),
}

-- Which stat a model drives, matched as a lowercase substring of the model's name (first hit
-- wins, so order matters only if two keywords could both appear). Keeping this loose means
-- "LeaderboardJobs" and "LeaderboardJobsCompleted" are the same board.
local STAT_KEYS: { { match: string, stat: string, title: string } } = {
	{ match = "gem", stat = "Gems", title = "MOST GEMS" },
	{ match = "playtime", stat = "Playtime", title = "MOST PLAYTIME" },
	{ match = "time", stat = "Playtime", title = "MOST PLAYTIME" },
	{ match = "job", stat = "Jobs", title = "MOST JOBS COMPLETED" },
}

local LeaderboardController = {}

type Board = { stat: string, scroll: ScrollingFrame }

-- The boards currently BUILT, keyed by their model, so an incoming payload can refill them
-- without re-walking the workspace. Keyed rather than an array because streaming adds and removes
-- entries continually -- a model whose Display has streamed out simply isn't in here.
local boards: { [Instance]: Board } = {}

-- Last payload received, kept so a board built after the broadcast (slow replication of the
-- Leaderboard folder) can still fill itself in.
local latest: { [string]: { { userId: number, name: string, value: number } } } = {}

-- Seconds -> the coarsest two units that still say something: "3d 4h", "5h 12m", "42m", "18s".
local function formatDuration(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	local days = total // 86400
	local hours = (total % 86400) // 3600
	local minutes = (total % 3600) // 60
	if days > 0 then
		return `{days}d {hours}h`
	elseif hours > 0 then
		return `{hours}h {minutes}m`
	elseif minutes > 0 then
		return `{minutes}m`
	end
	return `{total}s`
end

local function formatValue(stat: string, value: number): string
	if stat == "Playtime" then
		return formatDuration(value)
	elseif stat == "Gems" then
		return NumberFormat.abbreviate(value)
	end
	return NumberFormat.commas(value)
end

local function statForModel(model: Instance): (string?, string?)
	local name = model.Name:lower()
	for _, entry in STAT_KEYS do
		if string.find(name, entry.match, 1, true) then
			return entry.stat, entry.title
		end
	end
	return nil, nil
end

local function makeRow(rank: number, entry: { userId: number, name: string, value: number }, stat: string): Frame
	local row = Instance.new("Frame")
	row.Name = `Rank{rank}`
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundColor3 = if rank % 2 == 0 then ROW_ALT_COLOR else ROW_COLOR
	row.BorderSizePixel = 0
	row.LayoutOrder = rank

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = row

	local rankLabel = Instance.new("TextLabel")
	rankLabel.Name = "RankTxt"
	rankLabel.BackgroundTransparency = 1
	rankLabel.Position = UDim2.new(0, 8, 0, 0)
	rankLabel.Size = UDim2.new(0, 44, 1, 0)
	rankLabel.Font = Enum.Font.GothamBold
	rankLabel.Text = `#{rank}`
	rankLabel.TextColor3 = RANK_COLORS[rank] or MUTED_COLOR
	rankLabel.TextScaled = true
	rankLabel.TextXAlignment = Enum.TextXAlignment.Left
	rankLabel.Parent = row

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 12)
	padding.PaddingBottom = UDim.new(0, 12)
	padding.Parent = rankLabel

	-- rbxthumb resolves the headshot straight from the engine's thumbnail cache -- no
	-- GetUserThumbnailAsync call, which at 100 rows x 3 boards would be a web request storm.
	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.BackgroundColor3 = Color3.fromRGB(46, 52, 70)
	avatar.BorderSizePixel = 0
	avatar.Position = UDim2.new(0, 54, 0.5, 0)
	avatar.AnchorPoint = Vector2.new(0, 0.5)
	avatar.Size = UDim2.new(0, ROW_HEIGHT - 14, 0, ROW_HEIGHT - 14)
	avatar.Image = `rbxthumb://type=AvatarHeadShot&id={entry.userId}&w=48&h=48`
	avatar.Parent = row

	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatar

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameTxt"
	nameLabel.BackgroundTransparency = 1
	nameLabel.Position = UDim2.new(0, 54 + ROW_HEIGHT, 0, 0)
	-- Whatever the rank, avatar and value column don't take. The value column is a SCALE width so
	-- the narrow Gems/Playtime boards and the wider Jobs board both give it a sane share.
	nameLabel.Size = UDim2.new(0.7, -(54 + ROW_HEIGHT) - 10, 1, 0)
	nameLabel.Font = Enum.Font.GothamMedium
	nameLabel.Text = entry.name
	nameLabel.TextColor3 = TEXT_COLOR
	nameLabel.TextScaled = true
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = row

	local namePadding = Instance.new("UIPadding")
	namePadding.PaddingTop = UDim.new(0, 14)
	namePadding.PaddingBottom = UDim.new(0, 14)
	namePadding.Parent = nameLabel

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "ValueTxt"
	valueLabel.BackgroundTransparency = 1
	valueLabel.AnchorPoint = Vector2.new(1, 0)
	valueLabel.Position = UDim2.new(1, -10, 0, 0)
	valueLabel.Size = UDim2.new(0.3, -10, 1, 0)
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.Text = formatValue(stat, entry.value)
	valueLabel.TextColor3 = VALUE_COLOR
	valueLabel.TextScaled = true
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Parent = row

	local valuePadding = Instance.new("UIPadding")
	valuePadding.PaddingTop = UDim.new(0, 14)
	valuePadding.PaddingBottom = UDim.new(0, 14)
	valuePadding.Parent = valueLabel

	return row
end

-- Replace a board's rows with `entries`. An empty/absent list leaves a single placeholder line so
-- a board that has no data yet reads as "still loading" rather than as a broken blank wall.
local function fill(board: Board, entries: { { userId: number, name: string, value: number } }?)
	-- The board's part can stream out at any moment, taking the whole GUI with it. If that lands
	-- between a payload arriving and us getting here, there's nothing left to write into.
	if not board.scroll.Parent then
		return
	end

	for _, child in board.scroll:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	if not entries or #entries == 0 then
		local empty = Instance.new("TextLabel")
		empty.Name = "EmptyTxt"
		empty.BackgroundTransparency = 1
		empty.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		empty.Font = Enum.Font.GothamMedium
		empty.Text = "Loading..."
		empty.TextColor3 = MUTED_COLOR
		empty.TextScaled = true
		empty.Parent = board.scroll

		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 16)
		pad.PaddingBottom = UDim.new(0, 16)
		pad.Parent = empty
		return
	end

	for rank, entry in entries do
		makeRow(rank, entry, board.stat).Parent = board.scroll
	end
end

local function buildBoard(model: Instance, display: BasePart, stat: string, title: string)
	local existing = display:FindFirstChild("LeaderboardGui")
	if existing then
		existing:Destroy() -- rebuilt on respawn/rejoin; never stack two
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "LeaderboardGui"
	gui.Face = Enum.NormalId.Left
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD
	-- Input has to be enabled explicitly on a world SurfaceGui or the ScrollingFrame below can't
	-- be dragged or wheeled -- which is the whole point of a 100-entry board.
	gui.Active = true
	gui.LightInfluence = 0
	gui.ZOffset = 0.05
	gui.ResetOnSpawn = false

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = BACKGROUND
	root.BorderSizePixel = 0
	root.Parent = gui

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	header.BackgroundColor3 = HEADER_COLOR
	header.BorderSizePixel = 0
	header.Parent = root

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "TitleTxt"
	titleLabel.BackgroundTransparency = 1
	titleLabel.Position = UDim2.new(0, 0, 0, 8)
	titleLabel.Size = UDim2.new(1, 0, 0, 42)
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.Text = title
	titleLabel.TextColor3 = TEXT_COLOR
	titleLabel.TextScaled = true
	titleLabel.Parent = header

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "SubtitleTxt"
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.new(0, 0, 0, 52)
	subtitle.Size = UDim2.new(1, 0, 0, 24)
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.Text = "GLOBAL TOP 100"
	subtitle.TextColor3 = MUTED_COLOR
	subtitle.TextScaled = true
	subtitle.Parent = header

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Rows"
	scroll.Position = UDim2.new(0, 0, 0, HEADER_HEIGHT)
	scroll.Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Active = true
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = MUTED_COLOR
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, ROW_PADDING)
	layout.Parent = scroll

	local scrollPadding = Instance.new("UIPadding")
	scrollPadding.PaddingTop = UDim.new(0, 8)
	scrollPadding.PaddingBottom = UDim.new(0, 8)
	scrollPadding.PaddingLeft = UDim.new(0, 8)
	scrollPadding.PaddingRight = UDim.new(0, 12)
	scrollPadding.Parent = scroll

	gui.Parent = display

	local board: Board = { stat = stat, scroll = scroll }
	boards[model] = board
	-- Fill from whatever the last broadcast left us. A board that streams in between refreshes
	-- must not sit on "Loading..." for up to REFRESH_INTERVAL when we already have the data.
	fill(board, latest[stat])
end

-- Follow one model's Display part for as long as the model exists. Under streaming the part is
-- destroyed and recreated as the player moves, so this is a subscription, not a one-shot lookup:
-- every arrival rebuilds the board, every departure drops it from `boards` so a later payload
-- isn't written into a ScrollingFrame that no longer has a DataModel.
local function watchModel(model: Instance)
	local stat, title = statForModel(model)
	if not stat or not title then
		warn(`LeaderboardController: {model.Name} matches no known stat; skipping`)
		return
	end

	local function consider(child: Instance)
		if child.Name == "Display" and child:IsA("BasePart") then
			buildBoard(model, child, stat :: string, title :: string)
		end
	end

	model.ChildAdded:Connect(consider)
	model.ChildRemoved:Connect(function(child: Instance)
		if child.Name == "Display" then
			boards[model] = nil
		end
	end)

	local display = model:FindFirstChild("Display")
	if display then
		consider(display)
	end
end

local function onUpdate(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	latest = payload :: any
	for _, board in boards do
		fill(board, latest[board.stat])
	end
end

function LeaderboardController.init()
	LeaderboardUpdate.OnClientEvent:Connect(onUpdate)

	-- Off the init thread: the folder is a container (not itself streamed), but waiting on it
	-- must never hold up the rest of the client's startup sequence.
	task.spawn(function()
		local folder = workspace:WaitForChild("Leaderboard", 30)
		if not folder then
			warn("LeaderboardController: workspace.Leaderboard never replicated")
			return
		end
		folder.ChildAdded:Connect(watchModel)
		for _, model in folder:GetChildren() do
			watchModel(model)
		end
	end)
end

return LeaderboardController
