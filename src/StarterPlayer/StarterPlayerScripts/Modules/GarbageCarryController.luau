--!strict

-- Picking up and carrying cleanable garbage: the INPUT + motion half of the mechanic. What we pick
-- up is never the server's authored piece -- it's this session's own local CLONE of it (see
-- GarbageVisibility), which is what keeps two players working the same building out of each other's
-- way. The server (GarbageCarryService) stays the authority on WHO holds WHICH piece, identified by
-- surfaceId, so a party member can't grab what someone else is already carrying.
--
--   * HOVER -- aiming at a piece of the active job's garbage that's within GarbageHoverRange and
--     free outlines it in white; when we're not looking at any piece, the NEAREST one in pickup
--     range is outlined instead, so garbage at our feet is offered without having to aim down at
--     it. A piece a party member is holding doesn't highlight, and clicking it does nothing: the
--     server refuses it too.
--
--     The outline is a suggestion, not the target: a CLICK is always the piece the crosshair is on
--     (see below), never whatever happens to be nearest. So the proximity outline can point at a
--     piece a click wouldn't take -- deliberately, because aiming has to stay exact.
--   * CLICK/TAP -- picks up out to the longer GarbagePickupRange, so a piece can be grabbed from
--     slightly further than the outline invites. A mouse click goes along the SAME aim ray the
--     outline is drawn from, so whatever is highlighted is exactly what a click takes. A TAP instead
--     goes through the pressed pixel, so aiming at a piece and tapping elsewhere on the screen --
--     driving, panning -- doesn't grab it. A tap that lands on nothing is forgiven by a ring of
--     samples around it, and where that ring finds SEVERAL pieces (a heap in a corner) the one
--     nearest the player wins. See aimRay, findPickupTarget and the InputBegan handler.
--     A held TOOL can't get in the way of any of this: the floating tool hangs between the camera
--     and whatever is being aimed at, so ToolFloatController takes its parts out of raycasting
--     (CanQuery) -- a tap goes straight THROUGH the broom to the garbage behind it.
--   * LETTING GO -- a mouse click drops what we're holding; a TAP never does (TOUCH_CAN_DROP), since
--     the movement stick and the camera pan region arrive here as ordinary unprocessed touches.
--     A dedicated HUD button (DropButtonController) drops as well, on every platform -- it's the
--     only way to let go on touch.
--   * CARRY -- the held piece is DRAGGED, not teleported: an AlignPosition/AlignOrientation pair
--     pulls it toward a point in front of the crosshair, keeping its authored tilt and turning with
--     the camera. Dragging it with physics rather than writing its CFrame is what makes the world's
--     collisions apply -- a piece shoved at a wall stops at the wall instead of passing through it
--     and stranding itself out of bounds. (It passes freely through CHARACTERS: the clones sit in a
--     collision group that ignores players.) The carry point is also clamped to stop short of
--     whatever we're aiming at, so looking down doesn't grind the piece into the floor.
--   * PARTY -- our clone is ours alone, so movement can't replicate by itself. Instead the carrier
--     streams its piece's CFrame (GarbageMove) and the other members position THEIR clone of the
--     same surfaceId from it, anchored while it's in someone else's hands and released -- to fall
--     under local physics -- when they let go.
--   * TOOLS -- carrying is hands-full: picking up unequips whatever tool is held, and equipping a
--     tool drops the piece. (Both directions, so the two mechanics can never overlap.)
--
-- A piece left alone for GarbageResetSeconds goes back to where it was authored, so a run of
-- kicked-about garbage tidies itself up without waiting for the next job.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local GarbageResolver = require(ReplicatedStorage.SharedModules.GarbageResolver)
local GarbageVisibility = require(script.Parent.GarbageVisibility)
local HoverHighlight = require(script.Parent.HoverHighlight)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CarryGarbage = Remotes:WaitForChild("CarryGarbage") :: RemoteEvent
local GarbageCarry = Remotes:WaitForChild("GarbageCarry") :: RemoteEvent
local GarbageMove = Remotes:WaitForChild("GarbageMove") :: RemoteEvent

local localPlayer = Players.LocalPlayer

-- How far past the ranges the aim ray is allowed to reach. The range checks themselves are done
-- from the character (not the camera), so the ray only has to be long enough to still HIT a piece
-- standing at arm's length.
local AIM_MARGIN = 4

-- Let go automatically if the carried piece ends up this far (studs) from the player. Measured off
-- the carry distance so raising how far out the piece floats can't make the guard start misfiring on
-- a perfectly normal carry; the slack covers the piece lagging behind a sprinting player. What it's
-- actually for is a piece wedged behind geometry while the player walks off, which would otherwise
-- be towed around the building by a constraint pulling through a wall.
local MAX_CARRY_DISTANCE = Config.GarbageCarryDistance + 15

-- Drag tuning. The pull is deliberately FINITE: an infinitely strong constraint would win against
-- the collision solver and shove the piece through whatever it's pressed against, which is the
-- behaviour these constraints exist to avoid. Both forces are scaled by the piece's own mass so a
-- heavy model is carried as responsively as a light one.
local CARRY_GRAVITIES = 20 -- pull force, in multiples of the piece's weight
-- Capped well below what the pull could otherwise reach: a small part moving fast enough covers more
-- than a floor's thickness in a single physics step and tunnels straight through it.
local CARRY_MAX_VELOCITY = 35
local CARRY_RESPONSIVENESS = 60
local CARRY_TORQUE_PER_MASS = 1500
local CARRY_MIN_TORQUE = 5000

-- The carry point is pulled back to just short of whatever the aim ray hits, and never closer than
-- this to the camera. Without it, looking down at the floor puts the target UNDERGROUND and the
-- constraint spends every frame trying to shove the piece through the ground -- which it eventually
-- wins, dropping the garbage out of the world.
local CARRY_SURFACE_BUFFER = 1.5
local CARRY_MIN_DISTANCE = 2.5

-- How often (seconds) the carried piece's position is streamed to the rest of the party, and how far
-- it must have moved to be worth a packet. A party member's copy is a smoothed follow, not a
-- frame-exact mirror, so this is deliberately far below the frame rate.
local RELAY_INTERVAL = 1 / 20
local RELAY_MIN_DISTANCE = 0.05

-- After letting go, how long we wait for the piece to fall and settle before reporting where it
-- actually ended up. The relay stops the instant we drop, so without this last word the server still
-- thinks the piece is up where we released it -- and would refuse a perfectly reasonable re-grab
-- from beside where it landed.
local SETTLE_REPORT_DELAY = 2

-- How often (seconds) the idle-reset sweep runs. It only has to notice a piece has been sitting
-- untouched for a minute, so it can be lazy.
local RESET_SWEEP_INTERVAL = 2

local TOOL_ID_ATTRIBUTE = "ToolId"

-- Touch-only devices aim from the screen centre (crosshair) rather than the last tap -- same rule
-- as ToolFloatController.
local IS_MOBILE = UserInputService.TouchEnabled
	and not UserInputService.KeyboardEnabled
	and not UserInputService.MouseEnabled
	and not UserInputService.GamepadEnabled

-- A TAP never drops what the player is holding -- only a mouse click does, and the HUD's drop button
-- (DropButtonController) calls GarbageCarryController.drop().
--
-- Touches can't be trusted to mean "let go" here: the default dynamic thumbstick and the camera pan
-- region read raw input rather than sitting behind a GuiButton, so `gameProcessed` is false for them
-- and driving or panning arrived as a click. Picking up is safe from the same problem because it
-- needs the tap to land ON a piece of garbage, which a stick or a camera swipe never does.
local TOUCH_CAN_DROP = false

-- FINGER TOLERANCE. A tap is nowhere near as precise as a cursor, and a piece of garbage is a small
-- target on a phone -- so a tap that lands just OFF a piece still picks it up. The pressed pixel is
-- tried first; if it hits nothing, a ring of samples around it is tried before giving up.
--
-- This is what keeps "the tap must land on the garbage" from making pickup fiddly. The radius is a
-- fraction of viewport height (floored in pixels) so a fingertip covers about the same share of the
-- screen on a phone as on a tablet.
local TAP_TOLERANCE_SCALE = 0.02
local TAP_TOLERANCE_MIN_PIXELS = 14
local TAP_TOLERANCE_SAMPLES = 8

local GarbageCarryController = {}

-- The piece the SERVER says we're holding (a surfaceId), and our clone of it. Set only from the
-- GarbageCarry confirmation, so we never drive a piece we weren't actually given.
local carriedId: string? = nil
local carried: PVInstance? = nil
-- The carried piece's authored rotation and the camera yaw at pickup: the piece keeps its own tilt
-- and turns with us, rather than snapping to face the camera.
local carriedRotation = CFrame.identity
local carriedYaw = 0
-- The constraints dragging the carried piece, and the attachment they act on. All three are ours,
-- built on pickup and destroyed on drop.
local carryAttachment: Attachment? = nil
local alignPosition: AlignPosition? = nil
local alignOrientation: AlignOrientation? = nil
-- Relay bookkeeping: when we last sent, and from where.
local lastRelayAt = 0
local lastRelayPosition: Vector3? = nil

-- Told whenever our own hands go from empty to full or back (see onCarryingChanged) -- the drop
-- button is shown off this. Party members' carries never reach these: they're about OUR hands.
local carryListeners: { (boolean) -> () } = {}
local lastCarryState = false

-- surfaceId -> the party member holding it, so we don't offer their piece for pickup and know to
-- drive our copy of it from their relay rather than local physics.
local carriedByOthers: { [string]: Player } = {}

-- surfaceId -> os.clock() when it was last picked up or dropped by anyone on the session. A piece
-- untouched for GarbageResetSeconds goes home.
local lastTouched: { [string]: number } = {}

-- The piece currently outlined, and the shared white hover outline doing it (see HoverHighlight --
-- the same effect every other cleanable uses).
local hovered: Instance? = nil
local highlight: HoverHighlight.HoverHighlight? = nil

-- The aim ray ignores our own character (we're standing right next to what we're aiming at). The
-- filter is refreshed on each respawn rather than rebuilt per frame -- the hover check runs every
-- frame, and a fresh table each time is pure collector churn.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshRayFilter()
	local model = localPlayer.Character
	rayParams.FilterDescendantsInstances = if model then { model } else {}
end

-- The carry ray ignores our character AND the piece we're holding (it sits in the way of its own
-- target). Rebuilt on pickup, not per frame.
local carryRayParams = RaycastParams.new()
carryRayParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshCarryRayFilter(garbage: PVInstance?)
	local model = localPlayer.Character
	local exclude: { Instance } = {}
	if model then
		table.insert(exclude, model)
	end
	if garbage then
		table.insert(exclude, garbage)
	end
	carryRayParams.FilterDescendantsInstances = exclude
end

local function activeJob(): string?
	local id = localPlayer:GetAttribute(Config.ActiveJobAttribute)
	return if type(id) == "string" then id else nil
end

local function humanoid(): Humanoid?
	local model = localPlayer.Character
	return if model then model:FindFirstChildOfClass("Humanoid") else nil
end

-- Where the player is standing, for the range checks (the same point the server measures from).
local function rootPosition(): Vector3?
	local model = localPlayer.Character
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

-- The aim ray: origin + direction, through `screenPoint` if one is given, else through wherever the
-- player is aiming (the crosshair on touch, the cursor everywhere else).
--
-- The override is what a PICKUP passes: on touch there is no cursor, so the hover outline has to run
-- off the screen centre -- but a tap has a real position, and a piece is only picked up if the tap
-- landed ON it. Without that, tapping anywhere on the screen while a piece happened to be under the
-- crosshair grabbed it, which on mobile means every look-drag and mis-tap picks up garbage.
local function aimRay(screenPoint: Vector2?): Ray?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local point = screenPoint
		or (if IS_MOBILE then cam.ViewportSize / 2 else UserInputService:GetMouseLocation())
	return cam:ViewportPointToRay(point.X, point.Y)
end

-- Free/anchor a piece's parts. A piece being driven from a party member's relay is anchored, so our
-- local physics doesn't fight the positions we're being told; ours (and any piece nobody holds) is
-- free to fall and settle.
local function setPieceAnchored(garbage: PVInstance, anchored: boolean)
	for _, part in GarbageResolver.getParts(garbage) do
		part.Anchored = anchored
		if anchored then
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

-- The piece of garbage under the crosshair within `range` studs of the player, or nil. Also
-- requires a live job, the piece belonging to it, and no party member holding it. Called with the
-- (shorter) hover range for the outline and the pickup range for a click. Returns the clone and its
-- surfaceId -- the id is what the server speaks in.
local function findTarget(range: number, screenPoint: Vector2?): (PVInstance?, string?)
	local businessId = activeJob()
	if not businessId then
		return nil, nil
	end
	local ray = aimRay(screenPoint)
	local from = rootPosition()
	if not ray or not from then
		return nil, nil
	end

	local result = Workspace:Raycast(ray.Origin, ray.Direction * (range + AIM_MARGIN), rayParams)
	if not result then
		return nil, nil
	end

	local identity = GarbageResolver.resolve(result.Instance)
	if not identity or identity.businessId ~= businessId then
		return nil, nil
	end
	if carriedByOthers[identity.surfaceId] then
		return nil, nil
	end

	local position = GarbageResolver.getPosition(identity.garbage)
	if not position or (from - position).Magnitude > range then
		return nil, nil
	end
	-- The resolver only ever returns a BasePart or a Model.
	return identity.garbage :: PVInstance, identity.surfaceId
end

-- Can the player actually SEE this piece? The proximity outline below doesn't come from a ray, so
-- without this the piece OFFERED can be one on the far side of a wall -- pointing the player at
-- something they can't see, and (before the outline was made Occluded) drawing its highlight
-- straight through that wall.
--
-- Cast from the CAMERA, not the character: the question is what the player can see, and in third
-- person those are different points. The piece itself is excluded (it's the ray's destination), and
-- a hit landing within LOS_SLACK of it still counts as clear -- a piece resting on the floor or
-- pressed against a wall sits close enough to that geometry that an exact test would call it hidden.
local LOS_SLACK = 1.5

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
-- Reused rather than rebuilt: this runs per frame, and a fresh table each time is collector churn.
local losFilter: { Instance } = {}

local function canSee(piece: PVInstance, position: Vector3): boolean
	local camera = Workspace.CurrentCamera
	if not camera then
		return true
	end
	local origin = camera.CFrame.Position
	local delta = position - origin
	local distance = delta.Magnitude
	if distance <= LOS_SLACK then
		return true
	end

	table.clear(losFilter)
	local model = localPlayer.Character
	if model then
		table.insert(losFilter, model)
	end
	table.insert(losFilter, piece)
	losParams.FilterDescendantsInstances = losFilter

	local result = Workspace:Raycast(origin, delta, losParams)
	return result == nil or result.Distance >= distance - LOS_SLACK
end

-- The piece of this job's garbage NEAREST the player within `range`, or nil. The fallback for when
-- the player isn't looking at any piece in particular: standing next to a bag of litter offers it
-- without having to put the crosshair on it, which is what makes picking up off the floor -- where
-- garbage mostly is, and where it's an awkward thing to aim at -- comfortable.
--
-- Ties go to whichever the loop reaches first. That's stable enough in practice: two pieces at the
-- SAME distance to the stud is a coincidence, and stepping either way settles it.
local function findNearest(range: number): (PVInstance?, string?)
	if not activeJob() then
		return nil, nil
	end
	local from = rootPosition()
	if not from then
		return nil, nil
	end

	local nearest: PVInstance? = nil
	local nearestId: string? = nil
	local nearestDistance = math.huge
	-- Only the active job's clones are in here at all, and a piece already fed into the shredder has
	-- been taken out of it -- so being in this table is most of "can be picked up".
	for surfaceId, piece in GarbageVisibility.getPieces() do
		if carriedByOthers[surfaceId] then
			continue
		end
		local position = GarbageResolver.getPosition(piece)
		if not position then
			continue
		end
		-- canSee LAST: it's the only expensive test here, and it's only worth asking about a piece
		-- that would actually win.
		local distance = (from - position).Magnitude
		if distance <= range and distance < nearestDistance and canSee(piece, position) then
			nearest, nearestId, nearestDistance = piece, surfaceId, distance
		end
	end
	return nearest, nearestId
end

-- Outline `garbage` in white, or clear the outline when nil.
local function setHovered(garbage: PVInstance?)
	if garbage == hovered then
		return
	end
	hovered = garbage

	local outline = highlight
	if outline then
		outline:set(garbage)
	end
end

-- Put away any held tool. Carrying is hands-full, so picking up empties them.
local function unequipTools()
	local human = humanoid()
	if human then
		human:UnequipTools()
	end
end

-- The part the drag acts on: the piece itself when it's a bare BasePart, else the Model's assembly
-- root (its PrimaryPart's assembly, or any part's). Pulling the assembly root moves everything
-- welded to it.
local function dragPart(garbage: PVInstance): BasePart?
	local part: BasePart? = if garbage:IsA("BasePart")
		then garbage
		else (garbage :: Model).PrimaryPart or garbage:FindFirstChildWhichIsA("BasePart", true)
	if not part then
		return nil
	end
	return part.AssemblyRootPart or part
end

-- Tear down the drag (on drop, on losing the piece, on respawn).
local function releaseDrag()
	refreshCarryRayFilter(nil)
	if alignPosition then
		alignPosition:Destroy()
		alignPosition = nil
	end
	if alignOrientation then
		alignOrientation:Destroy()
		alignOrientation = nil
	end
	if carryAttachment then
		carryAttachment:Destroy()
		carryAttachment = nil
	end
end

-- Build the drag for a piece the server just handed us: an attachment sitting at the piece's pivot,
-- and the two constraints that pull that attachment to wherever we're aiming.
local function buildDrag(garbage: PVInstance)
	releaseDrag()
	refreshCarryRayFilter(garbage)

	local part = dragPart(garbage)
	if not part then
		return
	end

	-- Anchor the drag at the piece's PIVOT rather than the part's centre, so what floats in front of
	-- the crosshair is the piece as a whole (matters for a multi-part model).
	local attachment = Instance.new("Attachment")
	attachment.Name = "GarbageCarryAttachment"
	attachment.CFrame = part.CFrame:Inverse() * garbage:GetPivot()
	attachment.Parent = part
	carryAttachment = attachment

	-- Enough force to lift the piece briskly, not enough to win against a wall (see CARRY_GRAVITIES).
	local mass = math.max(part.AssemblyMass, 0.1)
	local position = Instance.new("AlignPosition")
	position.Name = "GarbageCarryPosition"
	position.Mode = Enum.PositionAlignmentMode.OneAttachment
	position.Attachment0 = attachment
	position.RigidityEnabled = false
	position.ApplyAtCenterOfMass = true
	position.MaxForce = mass * Workspace.Gravity * CARRY_GRAVITIES
	position.MaxVelocity = CARRY_MAX_VELOCITY
	position.Responsiveness = CARRY_RESPONSIVENESS
	position.Position = garbage:GetPivot().Position
	position.Parent = part
	alignPosition = position

	local orientation = Instance.new("AlignOrientation")
	orientation.Name = "GarbageCarryOrientation"
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orientation.Attachment0 = attachment
	orientation.RigidityEnabled = false
	orientation.MaxTorque = math.max(mass * CARRY_TORQUE_PER_MASS, CARRY_MIN_TORQUE)
	orientation.Responsiveness = CARRY_RESPONSIVENESS
	orientation.CFrame = garbage:GetPivot().Rotation
	orientation.Parent = part
	alignOrientation = orientation
end

-- Announce a change in whether we're holding anything, deduped: the paths that clear the carry
-- overlap (a drop, a respawn, a job ending all land here), and a listener showing a button shouldn't
-- have to filter repeats of the state it's already in.
local function notifyCarrying()
	local carrying = carriedId ~= nil
	if carrying == lastCarryState then
		return
	end
	lastCarryState = carrying
	for _, callback in carryListeners do
		task.spawn(callback, carrying)
	end
end

-- Watch whether the local player is holding a piece. Fires immediately with the current state, then
-- on every flip -- same shape as JobUiController.onHudVisibilityChanged.
function GarbageCarryController.onCarryingChanged(callback: (boolean) -> ())
	table.insert(carryListeners, callback)
	callback(lastCarryState)
end

-- True while we're holding a piece of garbage.
function GarbageCarryController.isCarrying(): boolean
	return carriedId ~= nil
end

-- Ask the server to pick a piece up, or (nil) to let go of what we're holding. The server answers on
-- GarbageCarry; nothing moves until it does.
local function request(surfaceId: string?)
	CarryGarbage:FireServer(surfaceId)
end

-- Let go of whatever we're holding, from anywhere. This is the mobile drop button's entry point,
-- since a tap never drops (see TOUCH_CAN_DROP); harmless to call with empty hands. The server still
-- decides -- we only ask, and act on the GarbageCarry confirmation like every other path here.
function GarbageCarryController.drop()
	if carriedId then
		request(nil)
	end
end

-- Click / tap: drop what we're carrying, else pick up whatever the crosshair is on.
-- How far a piece can be grabbed from. Touch reaches further -- see GarbagePickupRangeTouchBonus.
local function pickupRange(): number
	return Config.GarbagePickupRange + (if IS_MOBILE then Config.GarbagePickupRangeTouchBonus else 0)
end

-- A pickup at `screenPoint` -- or, when nil, wherever the player is AIMING, which is the same ray
-- the outline is drawn from. Forgives a near-miss when `tolerant` (a finger, not a cursor): the
-- exact pixel first, then a ring around it. See the TAP_TOLERANCE constants.
--
-- The exact pixel always wins outright -- a tap that lands ON a piece means that piece, even if
-- another is closer. It's only the forgiveness ring, where the tap hit nothing and we're guessing at
-- what was meant, that has to choose: there the CLOSEST piece to the player wins rather than
-- whichever sample happened to run first. With a heap of garbage in one corner the ring routinely
-- catches two or three pieces at once, and taking them in sample order picked an arbitrary one --
-- often one further back, behind the piece the player was obviously reaching for.
local function findPickupTarget(screenPoint: Vector2?, tolerant: boolean): (PVInstance?, string?)
	local garbage, surfaceId = findTarget(pickupRange(), screenPoint)
	if surfaceId or not tolerant or not screenPoint then
		return garbage, surfaceId
	end

	local camera = Workspace.CurrentCamera
	local radius = math.max(
		TAP_TOLERANCE_MIN_PIXELS,
		(if camera then camera.ViewportSize.Y else 0) * TAP_TOLERANCE_SCALE
	)
	local from = rootPosition()

	local nearest: PVInstance? = nil
	local nearestId: string? = nil
	local nearestDistance = math.huge
	for i = 1, TAP_TOLERANCE_SAMPLES do
		local angle = (i / TAP_TOLERANCE_SAMPLES) * math.pi * 2
		local sample = screenPoint + Vector2.new(math.cos(angle), math.sin(angle)) * radius
		local hit, hitId = findTarget(pickupRange(), sample)
		if hit and hitId then
			-- No character to measure from (mid-respawn): first hit is as good as any.
			if not from then
				return hit, hitId
			end
			local position = GarbageResolver.getPosition(hit)
			local distance = if position then (from - position).Magnitude else math.huge
			if distance < nearestDistance then
				nearest, nearestId, nearestDistance = hit, hitId, distance
			end
		end
	end
	if nearestId then
		return nearest, nearestId
	end
	return nil, nil
end

-- `screenPoint` is where a TAP landed: on touch, picking up requires it to be on (or near) the piece
-- itself, so tapping elsewhere while a piece sits under the crosshair doesn't grab it. A MOUSE click
-- passes nil instead and picks up along the aim ray -- see the InputBegan handler for why.
-- `canDrop` is what separates a mouse click (which lets go of what we're holding) from a touch
-- (which never does -- see TOUCH_CAN_DROP).
local function onClick(screenPoint: Vector2?, canDrop: boolean, tolerant: boolean)
	if carriedId then
		if canDrop then
			request(nil)
		end
		return
	end
	local _, surfaceId = findPickupTarget(screenPoint, tolerant)
	if not surfaceId then
		return
	end
	-- Empty our hands up front rather than waiting for the confirmation, so the tool is already
	-- away by the time the piece appears in front of us.
	unequipTools()
	request(surfaceId)
end

-- Stop carrying locally: drop the drag and forget the piece. The server has its own copy of this
-- state; this is only our end of it.
local function clearCarry()
	carriedId = nil
	carried = nil
	lastRelayPosition = nil
	releaseDrag()
	notifyCarrying()
end

-- Tell the server where a piece we just dropped came to rest, once it's had time to fall. Skipped if
-- it's back in someone's hands by then -- their carry is a fresher truth than our settle.
local function reportWhereItLanded(surfaceId: string)
	task.delay(SETTLE_REPORT_DELAY, function()
		if carriedId == surfaceId or carriedByOthers[surfaceId] then
			return
		end
		local piece = GarbageVisibility.getPiece(surfaceId)
		if piece and piece.Parent then
			GarbageMove:FireServer(surfaceId, piece:GetPivot())
		end
	end)
end

-- The server confirmed a carry state for someone on our session. `surfaceId` nil = they let go.
local function onCarryChanged(player: Player, surfaceId: string?)
	-- Either way this piece has just been handled, so its idle reset starts over.
	if surfaceId then
		lastTouched[surfaceId] = os.clock()
	end

	if player == localPlayer then
		if not surfaceId then
			local dropped = carriedId
			if dropped then
				lastTouched[dropped] = os.clock()
				reportWhereItLanded(dropped)
			end
			clearCarry()
			return
		end

		local piece = GarbageVisibility.getPiece(surfaceId)
		if not piece then
			return
		end
		carriedId = surfaceId
		carried = piece
		-- Ours to simulate again (it may have been anchored while a member carried it).
		setPieceAnchored(piece, false)
		-- Snapshot the piece's authored tilt + our current yaw, so it keeps its orientation and
		-- simply turns with the camera while carried. The yaw comes off the same aim ray the carry
		-- uses, so the piece doesn't twitch on the first frame it's held.
		carriedRotation = piece:GetPivot().Rotation
		local ray = aimRay()
		local look = if ray then ray.Direction else Vector3.new(0, 0, -1)
		carriedYaw = math.atan2(-look.X, -look.Z)
		buildDrag(piece)
		-- Whatever we were about to grab, we're holding something now.
		setHovered(nil)
		notifyCarrying()
		return
	end

	-- A party member. Forget anything they were holding before, then take up the new piece: ours is
	-- anchored and driven by their relay for as long as it's in their hands.
	for id, holder in carriedByOthers do
		if holder == player then
			carriedByOthers[id] = nil
			local piece = GarbageVisibility.getPiece(id)
			if piece then
				-- Released: let it fall and settle on our side too.
				setPieceAnchored(piece, false)
				lastTouched[id] = os.clock()
			end
		end
	end
	if surfaceId then
		carriedByOthers[surfaceId] = player
		local piece = GarbageVisibility.getPiece(surfaceId)
		if piece then
			setPieceAnchored(piece, true)
		end
		if hovered and hovered == GarbageVisibility.getPiece(surfaceId) then
			setHovered(nil)
		end
	end
end

-- Stream the carried piece's position to the rest of the party, throttled -- it's a follow, not a
-- frame-exact mirror.
local function relay(garbage: PVInstance, surfaceId: string)
	local now = os.clock()
	if now - lastRelayAt < RELAY_INTERVAL then
		return
	end
	local pivot = garbage:GetPivot()
	if lastRelayPosition and (pivot.Position - lastRelayPosition).Magnitude < RELAY_MIN_DISTANCE then
		return
	end
	lastRelayAt = now
	lastRelayPosition = pivot.Position
	GarbageMove:FireServer(surfaceId, pivot)
end

-- Per frame: outline what we're aiming at, or aim the drag holding what we're carrying.
local function onRenderStepped()
	local garbage = carried
	local surfaceId = carriedId
	if not garbage or not surfaceId then
		-- What we're LOOKING at, else simply the nearest piece in reach -- so garbage on the floor
		-- beside us is offered without having to aim down at it. See findNearest.
		local target = findTarget(Config.GarbageHoverRange) or findNearest(pickupRange())
		setHovered(target)
		return
	end

	-- The job (or the piece) can end under us; the server drops the carry, but stop driving it the
	-- moment it's gone rather than waiting for the round trip.
	if not garbage.Parent or not activeJob() then
		return
	end

	local position = alignPosition
	local orientation = alignOrientation
	if not position or not orientation then
		return
	end

	local ray = aimRay()
	if not ray then
		return
	end

	-- Hold the piece at the carry distance, but never PAST a surface: if the aim ray hits something
	-- closer than that (the floor when looking down, a wall when facing one), the carry point stops
	-- short of it. Otherwise the target sits inside the geometry and the constraint grinds the piece
	-- into it until it pops through -- which is how carried garbage ends up under the map.
	local direction = ray.Direction.Unit
	local distance = Config.GarbageCarryDistance
	local blocked = Workspace:Raycast(ray.Origin, direction * distance, carryRayParams)
	if blocked then
		distance = math.max(blocked.Distance - CARRY_SURFACE_BUFFER, CARRY_MIN_DISTANCE)
	end
	position.Position = ray.Origin + direction * distance
	-- Turn the piece with the camera (about world up) from the yaw it was picked up at, keeping its
	-- authored tilt intact.
	local yaw = math.atan2(-direction.X, -direction.Z)
	orientation.CFrame = CFrame.Angles(0, yaw - carriedYaw, 0) * carriedRotation

	relay(garbage, surfaceId)

	-- Wedged and left behind (see MAX_CARRY_DISTANCE): let go rather than tow it through the level.
	local from = rootPosition()
	if from and (from - garbage:GetPivot().Position).Magnitude > MAX_CARRY_DISTANCE then
		request(nil)
	end
end

-- Put any piece that's been sitting untouched for GarbageResetSeconds back where it was authored, so
-- garbage kicked into a corner tidies itself up without waiting for the next job. Pieces in anyone's
-- hands are left alone.
local function sweepIdlePieces()
	local now = os.clock()
	for surfaceId, piece in GarbageVisibility.getPieces() do
		local touched = lastTouched[surfaceId]
		if not touched or now - touched < Config.GarbageResetSeconds then
			continue
		end
		if surfaceId == carriedId or carriedByOthers[surfaceId] then
			continue
		end
		local home = GarbageVisibility.getHome(surfaceId)
		if home and piece.Parent then
			piece:PivotTo(home)
			for _, part in GarbageResolver.getParts(piece) do
				if not part.Anchored then
					part.AssemblyLinearVelocity = Vector3.zero
					part.AssemblyAngularVelocity = Vector3.zero
				end
			end
		end
		lastTouched[surfaceId] = nil
	end
end

-- Equipping a tool drops the piece: the two are mutually exclusive.
local boundTools: { [Tool]: boolean } = {}

local function tryBindTool(inst: Instance)
	if not inst:IsA("Tool") or inst:GetAttribute(TOOL_ID_ATTRIBUTE) == nil or boundTools[inst] then
		return
	end
	boundTools[inst] = true
	inst.Equipped:Connect(function()
		if carriedId then
			request(nil)
		end
	end)
end

local function watchTools(root: Instance)
	root.DescendantAdded:Connect(tryBindTool)
	for _, desc in root:GetDescendants() do
		tryBindTool(desc)
	end
end

function GarbageCarryController.init()
	-- One reusable outline, re-adorned per hover (see HoverHighlight).
	highlight = HoverHighlight.new("GarbageHover")

	GarbageCarry.OnClientEvent:Connect(function(player, surfaceId, businessId)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return
		end
		if surfaceId ~= nil and type(surfaceId) ~= "string" then
			return
		end
		-- A PICKUP is only honoured on the job it was made on. Attribute replication (which is how we
		-- learn a job started or ended) and this remote are separate channels with no ordering between
		-- them, so a pickup sent just before a job ended can arrive after we've torn that job down and
		-- built the next job's clones -- and acting on it would drag the fresh clone of that surfaceId
		-- into someone's hands the moment the new job began, with nobody having touched it. A DROP is
		-- never filtered: letting go has to apply no matter when it lands.
		if surfaceId and businessId ~= activeJob() then
			return
		end
		onCarryChanged(player, surfaceId)
	end)

	-- A party member's carried piece moved: put OUR clone of it there. It's anchored for as long as
	-- they hold it (see onCarryChanged), so this is the only thing moving it.
	GarbageMove.OnClientEvent:Connect(function(player, surfaceId, cframe)
		if type(surfaceId) ~= "string" or typeof(cframe) ~= "CFrame" then
			return
		end
		if carriedByOthers[surfaceId] ~= player then
			return
		end
		local piece = GarbageVisibility.getPiece(surfaceId)
		if piece and piece.Parent then
			piece:PivotTo(cframe)
		end
	end)

	-- InputObject.Position is in the same screen space ViewportPointToRay takes, so a TAP's ray goes
	-- through the exact pixel that was pressed.
	local function inputPoint(input: InputObject): Vector2
		return Vector2.new(input.Position.X, input.Position.Y)
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- A mouse click picks up along the AIM RAY -- the very ray the outline is drawn from --
			-- rather than through the click's own pixel. On a mouse the two are meant to be the same
			-- point, but in first person the cursor is hidden and locked to the centre, and the
			-- click's reported position and the aim don't agree to the pixel there. That gap is
			-- invisible in the middle of a piece and decides it at the edges: the corner outlines,
			-- the click lands just off it, and nothing gets picked up. Sharing the ray makes
			-- "highlighted" and "clickable" the same question by construction, so anything the
			-- outline offers can be taken -- corners included.
			--
			-- The pixel still matters on TOUCH, where there's no cursor and a tap anywhere would
			-- otherwise grab whatever sits under the crosshair.
			onClick(nil, true, false)
		elseif input.UserInputType == Enum.UserInputType.Touch then
			onClick(inputPoint(input), TOUCH_CAN_DROP, true)
		end
	end)

	-- A job ending drops the piece server-side, and GarbageVisibility throws every clone away; clear
	-- our own state (and the outline) with them.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(function()
		clearCarry()
		table.clear(carriedByOthers)
		table.clear(lastTouched)
		setHovered(nil)
	end)

	watchTools(localPlayer)
	localPlayer.CharacterAdded:Connect(function(model)
		-- A fresh character holds nothing; the server drops the carry on CharacterRemoving.
		clearCarry()
		setHovered(nil)
		refreshRayFilter()
		watchTools(model)
	end)
	refreshRayFilter()
	if localPlayer.Character then
		watchTools(localPlayer.Character)
	end

	RunService.RenderStepped:Connect(onRenderStepped)

	task.spawn(function()
		while true do
			task.wait(RESET_SWEEP_INTERVAL)
			sweepIdlePieces()
		end
	end)
end

return GarbageCarryController
