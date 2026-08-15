--!strict

-- The party SCREENS (PlayerGui.ScreenGui: PartySelectionUI, PartyUI, JoinPartyUI), driven off the
-- roster PartyController mirrors from the server. Three panels making one flow, entered from the
-- PlayTogether button:
--
--   PartySelectionUI -- create or browse.
--     * CreatePartyBtn borrows the JOB BOARD to pick the business (JobUiController.openForSelection),
--       and the pick is what creates the party, with the picker as leader. There's no separate party
--       job picker: it's the board the player already knows, so a business can never be offered here
--       on terms the board wouldn't offer it on.
--     * JoinPartyBtn opens the browser.
--   PartyUI -- the party you're in: its job (image, map, rewards), its roster with each member's
--     ready state, ready-up, leave, and the leader's per-member kick buttons. Readying up is what
--     starts the job -- the server launches it the moment EVERY member is ready.
--   JoinPartyUI -- one PartySlot per joinable party, cloned from the authored template: whose party
--     it is, what it's playing, what that pays, and what it demands of YOU (the same requirement
--     painting the board's rows use, via BusinessGates). Join is offered only for parties whose job
--     you qualify for -- the server refuses the rest, because a party can't start a job one of its
--     members isn't entitled to.
--
-- MOVEMENT BETWEEN THESE PANELS IS INSTANT (ExclusivePanels.openInstant): stepping selection ->
-- board -> party room should read as one window changing, not as three panels swooping past each
-- other. Animation is for entering and LEAVING the flow: the HUD button's open, its press again to
-- close (openEntry toggles), and an exit-button close.
--
-- Everything here is a VIEW. No local copy of the roster is kept: every button sends an action and
-- the screens redraw from the next server push, so a refused action simply doesn't change anything.
-- That push is also what keeps the browser honest -- the server re-broadcasts to everyone whenever
-- any party is created, filled, emptied or starts a job, so a party that stops being joinable
-- disappears from the list under everyone looking at it.
--
-- The ScreenGui is re-cloned on every respawn, so we re-bind to the fresh instances each time one
-- appears (same pattern as the other HUD controllers).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PartyConfig = require(ReplicatedStorage.SharedModules.PartyConfig)
local UiAnimations = require(ReplicatedStorage.SharedModules.UiAnimations)

local BusinessGates = require(script.Parent.BusinessGates)
local ExclusivePanels = require(script.Parent.ExclusivePanels)
local JobUiController = require(script.Parent.JobUiController)
local PartyController = require(script.Parent.PartyController)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"

-- Stable names these panels register under with ExclusivePanels (only one exclusive panel is open at
-- a time, so opening any of these closes the shop/board/settings first, and vice versa).
local SELECTION_PANEL = "PartySelection"
local ROOM_PANEL = "PartyRoom"
local BROWSER_PANEL = "JoinParty"

-- The roster slots PartyUI authors, one per possible member. Slots past the party's size are hidden,
-- so this must be at least PartyConfig.MaxSize for a full party to render.
local MAX_MEMBER_SLOTS = 6

-- Ready/not-ready are rendered inside the member line as rich text, so the status can be coloured
-- without the name being coloured with it. Same green/red as every other met/unmet gate.
local READY_MARKUP = '<font color="#4ED65E">READY</font>'
local NOT_READY_MARKUP = '<font color="#E13E1E">NOT READY</font>'

local PartyUiController = {}

-- One bound ScreenGui's party elements, rebuilt on every respawn. nil before the first bind, which
-- every entry point guards on.
type Bound = {
	screenGui: Instance,
	-- PartyUI's job display + roster slots.
	jobImage: ImageLabel,
	rewardsText: TextLabel,
	mapText: TextLabel,
	memberSlots: { Frame },
	-- JoinPartyUI's list: the authored PartySlot, kept hidden as the template every row is cloned
	-- from, and the frame those clones are parented to.
	slotTemplate: Frame,
	slotParent: ScrollingFrame,
}

local bound: Bound? = nil

-- The business the local player picked on the board for the party they're creating, held only until
-- the server confirms the party (whose businessId is then the authority). Without it the party room
-- would render blank for the one frame between picking and the roster landing.
local pendingBusinessId: string? = nil

-- Whether the last server push had us in a party. The party room watches the FALL from true to false
-- -- kicked, or the party disbanded -- rather than "not in a party", which is also what's true in the
-- moment between creating one and being told about it.
local wasInParty = false

-- Paint a player's headshot onto a portrait label, via the engine's own thumbnail cache -- the same
-- rbxthumb route the leaderboard rows use. Deliberately NOT GetUserThumbnailAsync: that yields per
-- call, and the browser rebuilds its whole list on every server push (parties change constantly as
-- people join and leave), so every row would be re-requesting an avatar it just fetched and sitting
-- blank until it landed. rbxthumb is assigned synchronously and survives the rebuild for free.
--
-- Only for a REAL account, though. Players in a Studio local multi-player test carry negative
-- UserIds, which no thumbnail exists for -- pointing the label at one resolves to nothing and leaves
-- an empty box, which reads as a broken portrait rather than as a test artifact. Those keep whatever
-- image the slot was authored with, so the row still looks like a row while testing.
local function paintPortrait(portrait: ImageLabel, userId: number)
	if userId > 0 then
		portrait.Image = `rbxthumb://type=AvatarHeadShot&id={userId}&w=150&h=150`
	end
end

-- The business the party screens should be showing: the confirmed party's, else the one we've just
-- picked and are waiting on. nil when there's neither (nothing to draw).
local function currentBusinessId(): string?
	local party = PartyController.getParty()
	if party then
		return party.businessId
	end
	return pendingBusinessId
end

-- Repaint PartyUI: the job it's for, and one line per member with their ready state. Kick buttons
-- are the leader's only, and never appear against the leader themselves -- a leader who wants out
-- uses Leave, which hands the party on rather than dissolving it (see PartyService.kick).
local function renderRoom()
	local current = bound
	if not current then
		return
	end

	local businessId = currentBusinessId()
	if businessId then
		current.jobImage.Image = BusinessGates.imageFor(current.screenGui, businessId)
		current.rewardsText.Text = BusinessGates.rewardsText(businessId)
		current.mapText.Text = string.format("Map: %s", BusinessGates.displayName(businessId))
	end

	local party = PartyController.getParty()
	local members = if party then party.members else { localPlayer }
	local isLeader = party ~= nil and party.leader == localPlayer

	for index, slot in current.memberSlots do
		local member = members[index]
		slot.Visible = member ~= nil
		if not member then
			continue
		end

		local label = slot:FindFirstChild("PartyMemberTxt") :: TextLabel?
		if label then
			local ready = party ~= nil and PartyController.isReady(party, member)
			label.Text = string.format("%s: %s", member.DisplayName, if ready then READY_MARKUP else NOT_READY_MARKUP)
		end

		local kick = slot:FindFirstChild("ImageButton") :: ImageButton?
		if kick then
			kick.Visible = isLeader and party ~= nil and member ~= party.leader
		end
	end
end

-- Fill one cloned PartySlot with a party's details, as seen by the LOCAL player: whose party it is,
-- what it's playing and pays, and whether they clear that job's gates. Join is hidden when they
-- don't -- the requirement lines stay, in red, so the row explains itself rather than just refusing.
local function fillSlot(slot: Frame, party: PartyController.PartyState)
	local leaderText = slot:FindFirstChild("PartyLeaderTxt") :: TextLabel?
	if leaderText then
		leaderText.Text = string.format("%s's Party", party.leader.DisplayName)
	end

	local mapText = slot:FindFirstChild("MapTxt") :: TextLabel?
	if mapText then
		mapText.Text = string.format("Map: %s", BusinessGates.displayName(party.businessId))
	end

	local rewards = slot:FindFirstChild("Rewards") :: TextLabel?
	if rewards then
		rewards.Text = BusinessGates.rewardsText(party.businessId)
	end

	local requirements = slot:FindFirstChild("Requirements") :: TextLabel?
	if requirements then
		BusinessGates.paintRequirements(requirements, party.businessId)
	end

	local requiredItems = slot:FindFirstChild("RequiredItems") :: Frame?
	if requiredItems then
		BusinessGates.paintRequiredItems(requiredItems, party.businessId)
	end

	local portrait = slot:FindFirstChild("PlayerPortrait") :: ImageLabel?
	if portrait then
		paintPortrait(portrait, party.leader.UserId)
	end

	local join = slot:FindFirstChild("JoinButton") :: ImageButton?
	if join then
		-- The server publishes only parties with room left, so the only gate the row itself has to
		-- apply is entitlement -- and it's the same one the board applies to its Wash button.
		join.Visible = #party.members < PartyConfig.MaxSize and BusinessGates.canPlay(party.businessId)
		join.Activated:Connect(function()
			PartyController.send(PartyConfig.Actions.Join, party.id)
		end)
	end
end

-- Rebuild the browser from the parties the server currently publishes as joinable. A full rebuild
-- per push rather than a diff: the list is short, it changes on clicks rather than per frame, and
-- rebuilding is what guarantees a party that filled up or started its job leaves the list the moment
-- it stops being joinable.
local function renderBrowser()
	local current = bound
	if not current then
		return
	end

	for _, child in current.slotParent:GetChildren() do
		if child:IsA("GuiObject") and child ~= current.slotTemplate then
			child:Destroy()
		end
	end

	local available = table.clone(PartyController.getAvailable())
	-- Party ids are assigned in creation order, so sorting by them lists the oldest parties first and
	-- keeps a row from jumping around the list as other parties come and go.
	table.sort(available, function(a, b)
		return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
	end)

	for index, party in available do
		local slot = current.slotTemplate:Clone()
		slot.Name = "PartySlot" .. party.id
		slot.LayoutOrder = index
		fillSlot(slot, party)
		slot.Visible = true
		slot.Parent = current.slotParent
	end
end

-- Redraw whichever party screen is up, and move the player off the party room when the party under
-- them is gone. Runs on every server push and on every data change that can move a requirement.
local function render()
	local party = PartyController.getParty()
	if party then
		-- Confirmed: the party's own businessId is the authority from here on.
		pendingBusinessId = nil
	end

	if ExclusivePanels.isOpen(ROOM_PANEL) then
		if not party and wasInParty then
			-- We HAD a party and now don't: kicked, or the leader disbanded it. Step back to the
			-- selection screen rather than leaving them looking at an empty room. Guarded on having
			-- had one so the gap between creating a party and being told about it doesn't bounce us.
			ExclusivePanels.openInstant(SELECTION_PANEL)
		else
			renderRoom()
		end
	elseif ExclusivePanels.isOpen(BROWSER_PANEL) then
		if party then
			-- Our join landed: the browser has nothing left to show us (a player in a party is
			-- offered no parties), so step into the room.
			ExclusivePanels.openInstant(ROOM_PANEL)
		else
			renderBrowser()
		end
	end

	wasInParty = party ~= nil
end

-- The PlayTogether button's action, a TOGGLE over the whole flow: it opens the party you're in (or
-- the create/browse choice if you aren't in one), and pressing it again while ANY of the three party
-- screens is up closes that screen instead. Whichever one is showing is the one the button put you
-- on -- so from the player's side it's the same button undoing itself, wherever in the flow they got
-- to.
--
-- Both directions ANIMATE: this is the flow being entered and left from the HUD, not a step inside
-- it (those steps snap -- see openInstant).
function PartyUiController.openEntry()
	if not bound then
		return
	end
	for _, name in { SELECTION_PANEL, ROOM_PANEL, BROWSER_PANEL } do
		if ExclusivePanels.isOpen(name) then
			ExclusivePanels.close(name)
			return
		end
	end
	if PartyController.inParty() then
		ExclusivePanels.open(ROOM_PANEL)
	else
		ExclusivePanels.open(SELECTION_PANEL)
	end
end

-- A business was picked on the borrowed job board: that's the party being created, around it. The
-- room is opened straight away on the pending id, and fills in properly the moment the server
-- confirms the party.
local function onJobPicked(businessId: string)
	pendingBusinessId = businessId
	PartyController.send(PartyConfig.Actions.Create, businessId)
	ExclusivePanels.openInstant(ROOM_PANEL)
end

local function bind(screenGui: Instance)
	local selectionUi = screenGui:WaitForChild("PartySelectionUI") :: Frame
	local roomUi = screenGui:WaitForChild("PartyUI") :: Frame
	local browserUi = screenGui:WaitForChild("JoinPartyUI") :: Frame

	local selectionMain = selectionUi:WaitForChild("MainFrame")
	local browserMain = browserUi:WaitForChild("MainFrame")
	local slotParent = browserMain:WaitForChild("ScrollingFrame") :: ScrollingFrame
	local slotTemplate = slotParent:WaitForChild("PartySlot") :: Frame
	local playersFrame = roomUi:WaitForChild("Players")

	local memberSlots: { Frame } = {}
	for index = 1, MAX_MEMBER_SLOTS do
		local slot = playersFrame:FindFirstChild("Player" .. index) :: Frame?
		if slot then
			table.insert(memberSlots, slot)
			-- The member line colours its READY / NOT READY half without colouring the name, which
			-- needs rich text. Authored plain, so it's turned on here rather than relying on the
			-- markup silently rendering as literal text if the flag were ever cleared in Studio.
			local label = slot:FindFirstChild("PartyMemberTxt") :: TextLabel?
			if label then
				label.RichText = true
			end
		end
	end

	local jobImage = roomUi:WaitForChild("JobImg") :: ImageLabel
	local rewardsText = roomUi:WaitForChild("RewardsTxt") :: TextLabel
	local mapText = roomUi:WaitForChild("SelectedMapTxt") :: TextLabel

	-- The template is never shown; every row in the list is a clone of it. Hidden rather than
	-- removed so the list's look stays authored in Studio.
	slotTemplate.Visible = false

	-- The list's height is whatever the rows add up to, so the canvas has to follow it -- the
	-- authored CanvasSize was for the single template.
	local layout = slotParent:WaitForChild("UIListLayout") :: UIListLayout
	local function fitCanvas()
		slotParent.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y)
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fitCanvas)
	fitCanvas()

	selectionUi.Visible = false
	roomUi.Visible = false
	browserUi.Visible = false

	bound = {
		screenGui = screenGui,
		jobImage = jobImage,
		rewardsText = rewardsText,
		mapText = mapText,
		memberSlots = memberSlots,
		slotTemplate = slotTemplate,
		slotParent = slotParent,
	}

	-- Registered so these participate in the one-panel-at-a-time rule (opening one closes the shop or
	-- the board), and so a job starting snaps them away with everything else. Each refreshes itself
	-- right before it shows, so a panel opened after a change it wasn't up for is never stale.
	ExclusivePanels.register(SELECTION_PANEL, UiAnimations.Panel.new(selectionUi))
	ExclusivePanels.register(ROOM_PANEL, UiAnimations.Panel.new(roomUi), renderRoom)
	ExclusivePanels.register(BROWSER_PANEL, UiAnimations.Panel.new(browserUi), renderBrowser)

	local selectionExit = selectionMain:WaitForChild("ExitButton") :: ImageButton
	local browserExit = browserMain:WaitForChild("ExitButton") :: ImageButton
	local createButton = selectionMain:WaitForChild("CreatePartyBtn") :: ImageButton
	local joinBrowserButton = selectionMain:WaitForChild("JoinPartyBtn") :: ImageButton
	local readyButton = roomUi:WaitForChild("ReadyUpButton") :: ImageButton
	local leaveButton = roomUi:WaitForChild("LeavePartyButton") :: ImageButton

	selectionExit.Activated:Connect(function()
		ExclusivePanels.close(SELECTION_PANEL)
	end)
	browserExit.Activated:Connect(function()
		ExclusivePanels.close(BROWSER_PANEL)
	end)

	createButton.Activated:Connect(function()
		-- Hands the board over; the pick comes back through onJobPicked, which is where the party is
		-- actually created. Nothing happens here if the board refuses to open (on a job).
		JobUiController.openForSelection(onJobPicked)
	end)
	joinBrowserButton.Activated:Connect(function()
		ExclusivePanels.openInstant(BROWSER_PANEL)
	end)

	readyButton.Activated:Connect(function()
		-- A toggle, resolved server-side. Readying the last un-ready member is what starts the job.
		PartyController.send(PartyConfig.Actions.Ready)
	end)
	leaveButton.Activated:Connect(function()
		PartyController.send(PartyConfig.Actions.Leave)
		-- Back to the choice we came from. Not driven off the server's reply: leaving is the one exit
		-- we asked for ourselves, so it shouldn't wait on a round trip to look like it worked.
		ExclusivePanels.openInstant(SELECTION_PANEL)
	end)

	for index, slot in memberSlots do
		local kick = slot:FindFirstChild("ImageButton") :: ImageButton?
		if kick then
			kick.Activated:Connect(function()
				-- Resolved at click time against the CURRENT roster, so a slot whose occupant changed
				-- between renders can't kick whoever used to be in it.
				local party = PartyController.getParty()
				local member = party and party.members[index]
				if party and member and party.leader == localPlayer and member ~= party.leader then
					PartyController.send(PartyConfig.Actions.Kick, member)
				end
			end)
		end
	end

	-- Draw whatever the roster already says; the snapshot may well have landed before this bind.
	wasInParty = PartyController.inParty()
	renderRoom()
end

function PartyUiController.init()
	-- Every server push (any party created, joined, left, kicked, readied, started or disbanded --
	-- the server broadcasts to everyone on all of them) redraws whichever screen is up. Fires once
	-- immediately, which is harmless before the first bind.
	PartyController.onChanged(render)

	-- The browser paints each party's requirements against the LOCAL player, so anything that moves
	-- a gate (a level, a bought tool) or a predicted reward has to repaint the rows too.
	BusinessGates.onChanged(function()
		if ExclusivePanels.isOpen(BROWSER_PANEL) then
			renderBrowser()
		elseif ExclusivePanels.isOpen(ROOM_PANEL) then
			renderRoom()
		end
	end)

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

return PartyUiController
