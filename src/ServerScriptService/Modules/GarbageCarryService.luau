--!strict

-- Server side of CARRYING cleanable garbage. Cleanable garbage is authored in the shared business
-- buildings:
--   Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableGarbage.<garbage>
--
-- WHAT MOVES IS NOT WHAT'S AUTHORED. Garbage is the one cleanable that moves, and a shared instance
-- has one position for the whole server -- so two sessions working the same building would drag each
-- other's pieces around. Instead every client hides the authored pieces and works with its own local
-- CLONES of them (see GarbageVisibility), which is what makes two simultaneous jobs independent. The
-- authored instances are therefore templates: this service pins them still (anchored, non-colliding)
-- at startup and never moves them again.
--
-- That leaves this service owning the two things clones can't decide for themselves:
--   * WHO HOLDS WHAT, per session. A piece is identified by its surfaceId (every session's clone of
--     a piece shares it), so one member of a party can't grab what another member is already
--     holding. Sessions are independent: two sessions may hold "the same" piece at once, because
--     they are physically different objects.
--   * THE RELAY. The carrier streams its clone's CFrame (GarbageMove); we forward it to the OTHER
--     members of their session, who drive their own clone from it. That's what lets a party watch a
--     piece move in a member's hands. It never leaves the session, so nobody else's garbage twitches.
--
-- A carry is dropped for the player automatically when they leave the job, respawn/die, or leave the
-- game, so a session can never be left thinking a piece is spoken for.
--
-- The CLEANING half of the mechanic -- feeding a piece into the business's shredder -- lives in
-- GarbageShredService, which borrows two things from here: dropPiece (a swallowed piece leaves its
-- carrier's hands) and isPiece (a shred request has to name a real piece of that building's garbage).

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local GarbageResolver = require(ReplicatedStorage.SharedModules.GarbageResolver)
local JobService = require(script.Parent.JobService)
local PlayerCollisionService = require(script.Parent.PlayerCollisionService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
-- Client -> server: a surfaceId asks to pick that piece up, nil asks to let go.
local CarryGarbage = Remotes:WaitForChild("CarryGarbage") :: RemoteEvent
-- Server -> clients on the session: (carrier, surfaceId-or-nil).
local GarbageCarry = Remotes:WaitForChild("GarbageCarry") :: RemoteEvent
-- Client -> server -> the rest of the session: (carrier, surfaceId, cframe), the carried piece's
-- live position.
local GarbageMove = Remotes:WaitForChild("GarbageMove") :: RemoteEvent

-- Slack (studs) added to GarbagePickupRange when validating a pickup. The client checks the same
-- range against the same points, but it moves between sending the click and us handling it, so a
-- pickup at the edge shouldn't fail on half a ping of walking.
local RANGE_TOLERANCE = 3

-- Collision group the garbage clones live in (set client-side, on the clones). Registered here --
-- and paired against the players' group -- so the rule is declared once, on the authority.
local GARBAGE_GROUP = "CleanableGarbage"

local GarbageCarryService = {}

-- A session's carry state. Keyed by the JobServer the players share, WEAKLY: when a session ends its
-- JobServer becomes garbage and its state goes with it, so nothing has to be swept up by hand.
type SessionState = {
	-- surfaceId -> the member holding it.
	carriedBy: { [string]: Player },
	-- surfaceId -> where that session last saw the piece. Seeded from the authored position and
	-- updated by the relay, so a pickup can be range-checked against where the piece actually IS for
	-- this session rather than where it started.
	lastCFrame: { [string]: CFrame },
	-- surfaceId -> the member who last had it. They keep the right to report where it ended up until
	-- somebody else picks it up: the relay stops the instant they let go, so without this a piece
	-- dropped down a stairwell would still be recorded up at the railing, and a perfectly legitimate
	-- re-grab from beside it would fail the range check.
	lastCarrier: { [string]: Player },
}
local sessions: { [any]: SessionState } = setmetatable({}, { __mode = "k" }) :: any

-- What each player is holding right now (a surfaceId), and the session they were holding it on --
-- remembered because a drop usually happens as they LEAVE the job, when the session is gone from
-- JobService and we could no longer find the state to clear.
local carrying: { [Player]: string } = {}
local carriedOn: { [Player]: SessionState } = {}

-- Who was told about each carrier's pickup, so the drop reaches exactly the same people even after
-- the player has left the session.
local audience: { [Player]: { Player } } = {}

-- The authored CFrame of every piece, by businessId and surfaceId. This is what a client's clones are
-- built at, so it's also what a pickup's range check measures against before the piece has moved.
local homeCFrame: { [string]: { [string]: CFrame } } = {}

local function sessionFor(player: Player): SessionState?
	local job = JobService.getJob(player)
	if not job then
		return nil
	end
	local state = sessions[job]
	if not state then
		state = { carriedBy = {}, lastCFrame = {}, lastCarrier = {} }
		sessions[job] = state
	end
	return state
end

-- Pin an authored piece: it is a template, not a prop. Anchored so the server never simulates it
-- (an unanchored one would fall out of the world and eventually be destroyed, taking the clients'
-- clone source with it) and non-colliding so it can't affect anything while it sits there.
local function pinTemplate(garbage: Instance)
	for _, part in GarbageResolver.getParts(garbage) do
		part.Anchored = true
		part.CanCollide = false
	end
end

-- Record a piece's authored position and pin it. Idempotent.
local function register(inst: Instance)
	local identity = GarbageResolver.resolve(inst)
	if not identity or identity.garbage ~= inst then
		return
	end
	local business = homeCFrame[identity.businessId]
	if not business then
		business = {}
		homeCFrame[identity.businessId] = business
	end
	if business[identity.surfaceId] then
		return
	end
	business[identity.surfaceId] = (inst :: PVInstance):GetPivot()
	pinTemplate(inst)
end

-- Tell `listeners` who is carrying what.
local function broadcast(listeners: { Player }, player: Player, surfaceId: string?)
	for _, member in listeners do
		GarbageCarry:FireClient(member, player, surfaceId)
	end
end

-- Everyone who should hear about `player`'s carry: their session (which is just them when solo),
-- always including the player themselves -- a player already off the job has no session at all.
local function sessionAudience(player: Player): { Player }
	local listeners = JobService.getSessionMembers(player)
	if not table.find(listeners, player) then
		table.insert(listeners, player)
	end
	return listeners
end

-- Let go of whatever `player` is carrying and publish the drop. Their client lets its clone fall
-- under its own physics; the other members' clients do the same with theirs. Safe to call when
-- they're carrying nothing.
function GarbageCarryService.drop(player: Player)
	local surfaceId = carrying[player]
	if not surfaceId then
		return
	end
	carrying[player] = nil

	local state = carriedOn[player]
	carriedOn[player] = nil
	if state and state.carriedBy[surfaceId] == player then
		state.carriedBy[surfaceId] = nil
	end

	-- Tell whoever heard the pickup, plus anyone on the session now (a member who joined since).
	local listeners = audience[player] or {}
	audience[player] = nil
	for _, member in sessionAudience(player) do
		if not table.find(listeners, member) then
			table.insert(listeners, member)
		end
	end
	broadcast(listeners, player, nil)
end

-- Let go of a specific piece on `player`'s session, whoever is holding it (which may be a party
-- member, not `player`). Used by GarbageShredService: a piece fed into the shredder stops being
-- anybody's to carry the moment it's swallowed. No-op if nobody has it.
function GarbageCarryService.dropPiece(player: Player, surfaceId: string)
	local state = sessionFor(player)
	local holder = state and state.carriedBy[surfaceId]
	if holder then
		GarbageCarryService.drop(holder)
	end
end

-- True if `surfaceId` names a piece of garbage actually authored in `businessId`. The authored set is
-- exactly what this service registered at startup, so this is also the check that a shred request
-- names something real rather than an id a client made up.
function GarbageCarryService.isPiece(businessId: string, surfaceId: string): boolean
	local business = homeCFrame[businessId]
	return business ~= nil and business[surfaceId] ~= nil
end

-- Where this session last saw a piece: the relayed position if it has been carried, else where it
-- was authored (which is where every client's clone was built).
local function knownPosition(state: SessionState, businessId: string, surfaceId: string): Vector3?
	local last = state.lastCFrame[surfaceId]
	if last then
		return last.Position
	end
	local business = homeCFrame[businessId]
	local home = business and business[surfaceId]
	return if home then home.Position else nil
end

local function tryPickUp(player: Player, surfaceId: string)
	-- One piece at a time: a request to grab another is a request to swap, so let go first.
	GarbageCarryService.drop(player)

	local businessId = JobService.getActiveJob(player)
	local state = sessionFor(player)
	if not businessId or not state then
		return
	end
	-- Spoken for by a party member. (Another SESSION holding "the same" piece is irrelevant -- their
	-- clone is a different object entirely.)
	if state.carriedBy[surfaceId] then
		return
	end

	local model = player.Character
	local root = model and model:FindFirstChild("HumanoidRootPart")
	local position = knownPosition(state, businessId, surfaceId)
	if not root or not root:IsA("BasePart") or not position then
		return
	end
	if (root.Position - position).Magnitude > Config.GarbagePickupRange + RANGE_TOLERANCE then
		return
	end

	state.carriedBy[surfaceId] = player
	state.lastCarrier[surfaceId] = player
	carrying[player] = surfaceId
	carriedOn[player] = state

	local listeners = sessionAudience(player)
	audience[player] = listeners
	broadcast(listeners, player, surfaceId)
end

-- Find every authored piece: remember where it belongs and pin it. Also catches pieces that
-- stream/replicate in later.
local function registerAll()
	task.spawn(function()
		local businesses = Workspace:WaitForChild(Config.BusinessesFolderName)
		for _, desc in businesses:GetDescendants() do
			register(desc)
		end
		businesses.DescendantAdded:Connect(register)
	end)
end

function GarbageCarryService.init()
	-- Garbage collides with the building but never with a character. Registering is guarded so a
	-- live-reload can't error on the group already existing (same shape as PlayerCollisionService,
	-- whose group must already be registered -- it inits first, see Main.server).
	pcall(function()
		PhysicsService:RegisterCollisionGroup(GARBAGE_GROUP)
	end)
	PhysicsService:CollisionGroupSetCollidable(GARBAGE_GROUP, PlayerCollisionService.GROUP, false)

	registerAll()

	CarryGarbage.OnServerEvent:Connect(function(player, surfaceId)
		-- Anything that isn't a surfaceId = "let go".
		if type(surfaceId) ~= "string" then
			GarbageCarryService.drop(player)
			return
		end
		tryPickUp(player, surfaceId)
	end)

	-- The carried piece's live position, forwarded to the rest of the carrier's session. Only the
	-- player actually holding the piece may move it, and it never reaches another session.
	GarbageMove.OnServerEvent:Connect(function(player, surfaceId, cframe)
		if type(surfaceId) ~= "string" or typeof(cframe) ~= "CFrame" then
			return
		end

		local holding = carrying[player] == surfaceId
		local state = if holding then carriedOn[player] else sessionFor(player)
		if not state then
			return
		end
		-- Either they're holding it, or they're the last person who did and it's still free -- the
		-- settle report that says where it came to rest (see lastCarrier).
		if not holding and (state.carriedBy[surfaceId] or state.lastCarrier[surfaceId] ~= player) then
			return
		end

		state.lastCFrame[surfaceId] = cframe
		-- Only a live carry is worth relaying onward: the settle report is for our own bookkeeping,
		-- and the other members' copies are falling to the same place under their own physics.
		if holding then
			for _, member in JobService.getOtherMembers(player) do
				GarbageMove:FireClient(member, player, surfaceId, cframe)
			end
		end
	end)

	local function watch(player: Player)
		-- Leaving (or switching) a job drops what they're holding: the piece belongs to a business
		-- they're no longer working, and their clones are torn down the moment the job ends.
		--
		-- Nothing is reset here: a job STARTING rebuilds that client's clones at their authored
		-- positions (GarbageVisibility.setActiveBusiness), which is the reset -- and it happens per
		-- session, so it can't disturb anyone else's run.
		player:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(function()
			GarbageCarryService.drop(player)
		end)
		-- A respawning/dying character can't hold anything either.
		player.CharacterRemoving:Connect(function()
			GarbageCarryService.drop(player)
		end)
	end

	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		GarbageCarryService.drop(player)
	end)
end

return GarbageCarryService
