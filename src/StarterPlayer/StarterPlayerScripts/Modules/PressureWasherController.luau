--!strict

-- Drives the pressure washer: detects when the tool is equipped + firing,
-- raycasts from the mouse each frame, and tells the aimed CleanableSurface to
-- erase. The ray ignores the character and each business's interior/stain folders, and
-- only the surface's textured face (where the dirt overlay lives) is cleanable.
--
-- It also drives the spray VFX: the Handle's ParticleEmitter only emits while the
-- player is firing, and each frame its attachment is re-aimed so the spray shoots
-- from the nozzle toward wherever the player is pointing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(game.ReplicatedStorage.SharedModules.CleaningConfig)
local ToolConfig = require(game.ReplicatedStorage.SharedModules.ToolConfig)
local DataService = require(game.ReplicatedStorage.Packages.DataService).client
local SkillsConfig = require(game.ReplicatedStorage.SharedModules.SkillsConfig)
local SoundManager = require(game.ReplicatedStorage.SharedModules.SoundManager)
local VfxManager = require(game.ReplicatedStorage.SharedModules.VfxManager)
local CleanableSurface = require(script.Parent.CleanableSurface)
local PartyController = require(script.Parent.PartyController)

type Surface = CleanableSurface.CleanableSurface

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CleanProgress = Remotes:WaitForChild("CleanProgress") :: RemoteEvent
-- Our erase strokes, relayed by the server to the other members of a party job so their overlays
-- come clean where ours did. See the stroke queue below and JobController's receiving end.
local WallStroke = Remotes:WaitForChild("WallStroke") :: RemoteEvent

local TOOL_ID = ToolConfig.pressureWasher.UniqueID
local MAX_BRIDGE_DIST = Config.MaxBridgeWorldDistance

-- How often (seconds) we tell the server we're actively cleaning. Kept below the
-- server's reward cooldown so a fresh report is always waiting when it expires;
-- the server is the authority on the actual once-per-second payout.
local PROGRESS_REPORT_INTERVAL = 0.5

-- Seconds between reward-burst sprites while the player is actually taking dirt off (see
-- VfxManager.cleanBurst). One sprite per interval -- the burst is the wall's feedback now that the
-- floating text is gone, so it wants to read as a steady drip, not a stream.
local CLEAN_BURST_INTERVAL = 0.2

-- Live cleaning range (studs) for this player, read fresh so tool upgrades take
-- effect immediately. Falls back to the static ToolConfig default if the player's
-- inventory value isn't available yet.
local function getRange(): number
	return DataService:get({ "Inventory", TOOL_ID, "Range" }) or ToolConfig[TOOL_ID].Range
end

-- Live brush radius (studs) for this player, same fresh-read + fallback as range, then scaled by
-- their RadiusMaster skill (+5%/level) so the boost applies on top of any tool upgrade.
local function getRadius(): number
	local base = DataService:get({ "Inventory", TOOL_ID, "Radius" }) or ToolConfig[TOOL_ID].Radius
	local skillLevel = DataService:get({ "Skills", "RadiusMaster" }) or 0
	return base * SkillsConfig.multiplier("RadiusMaster", skillLevel)
end

-- Only this slice of PressureAudio is looped while firing (seconds).
local SOUND_SECTION_START = 1
local SOUND_SECTION_END = 2.5

local localPlayer = Players.LocalPlayer

-- Touch-only devices (phones/tablets). A tap can't mean "fire" here -- it's a look/aim gesture --
-- so on touch the trigger is the HUD's WashButton, held (WashJoystickController, which calls
-- setFiring). That button deliberately doesn't sink the touch it's under, so the swipe that holds it
-- still pans the camera -- which is what lets the player aim and spray at the same time, the thing
-- this platform couldn't do before. Console (gamepad) and desktop keep
-- the normal hold-to-fire off Activated/Deactivated. Evaluated once -- input capabilities don't
-- meaningfully change mid-session.
local IS_MOBILE = UserInputService.TouchEnabled
	and not UserInputService.KeyboardEnabled
	and not UserInputService.MouseEnabled
	and not UserInputService.GamepadEnabled

-- 2D firing sound: a sustained, slice-looped handle owned by SoundManager. Built
-- in init so its clone is preloaded during the startup window.
local fireSound: SoundManager.SustainedSound? = nil

local PressureWasherController = {}

local getSurface: ((BasePart) -> Surface?)? = nil
local firing = false
local equippedTool: Tool? = nil
local boundTools: { [Tool]: boolean } = {}

-- Spray VFX for the equipped tool: the emitter and the attachment it sits on, so we
-- can toggle emission with firing and re-aim it each frame. Resolved on equip.
local sprayEmitter: ParticleEmitter? = nil
local sprayAttachment: Attachment? = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Instances the pressure washer ray ignores: the local character plus every business's
-- Interior folder (windows/props that sit in front of the walls) and CleanableDecals
-- folder (stain hitboxes are broom targets, so the ray passes THROUGH them to the wall
-- overlay behind). Excluding these lets the wash reach the wall no matter what's in the
-- way. Rebuilt when the character respawns or a new folder streams in; assigned to
-- rayParams then (the engine copies the array on assign, so a rebuild must reassign).
local ignoredFolders: { Instance } = {}
local rayExclude: { Instance } = {}

-- Folder names (directly under a business's Cleanables) whose descendants the ray skips.
local IGNORED_FOLDER_NAMES: { [string]: boolean } = {
	[Config.InteriorFolderName] = true,
	[Config.DecalsFolderName] = true,
	-- Cleanable spills sit ON the walls/floors; their query-only hitboxes would otherwise block
	-- the wash from reaching the wall behind/under them, so the ray passes through them too.
	[Config.SpillsFolderName] = true,
	-- Cleanable webs (vacuum targets) sit in front of the walls; the ray passes through them so
	-- a web can't block the wash from reaching the wall behind it.
	[Config.WebsFolderName] = true,
}

local function rebuildRayExclude()
	table.clear(rayExclude)
	if localPlayer.Character then
		table.insert(rayExclude, localPlayer.Character)
	end
	for _, folder in ignoredFolders do
		table.insert(rayExclude, folder)
	end
	rayParams.FilterDescendantsInstances = rayExclude
end

-- Collect every business's ignored folders (and any that stream in later) into the ray
-- exclude list. Mirrors DecalVisibility's Businesses-folder scan.
local function watchIgnoredFolders()
	task.spawn(function()
		local businesses = Workspace:WaitForChild(Config.BusinessesFolderName)
		local function consider(desc: Instance)
			if desc:IsA("Folder") and IGNORED_FOLDER_NAMES[desc.Name] and not table.find(ignoredFolders, desc) then
				table.insert(ignoredFolders, desc)
				rebuildRayExclude()
			end
		end
		for _, desc in businesses:GetDescendants() do
			consider(desc)
		end
		businesses.DescendantAdded:Connect(consider)
	end)
end

-- Stroke state, so we can bridge between consecutive cleaning frames.
local lastSurface: Surface? = nil
local lastWorldPos: Vector3? = nil
local missedLast = true

-- os.clock() of the last CleanProgress report, for client-side throttling.
local lastProgressReport = 0
-- os.clock() of the last reward burst, so the sprites keep to CLEAN_BURST_INTERVAL.
local lastCleanBurst = 0

-- === Stroke relay (party jobs only) ===
-- Every erase we perform is queued as { part, to, from?, radius } and shipped in batches, so a
-- party member's client can replay the exact same brush path onto its own overlay for that wall
-- (there's no way to send the pixels themselves -- see CleaningService's header). We batch rather
-- than send per frame because cleaning runs on Heartbeat: one message per stroke would be ~60/s per
-- firing player. A batch keeps the full path -- every stamp is still in there, just delivered
-- together -- so the replay is as accurate as sending each one.
local STROKE_FLUSH_INTERVAL = 0.1
-- Hard cap on a single batch. Only reachable if a flush is somehow starved for a second or more;
-- past this we drop strokes rather than send an unbounded table (the server caps its relay too).
local MAX_QUEUED_STROKES = 60

local strokeQueue: { { part: BasePart, to: Vector3, from: Vector3?, radius: number } } = {}
local lastStrokeFlush = 0

-- Record one erase for relay. No-op when nobody would receive it, so a solo player's cleaning costs
-- nothing extra.
local function queueStroke(part: BasePart, to: Vector3, from: Vector3?, radius: number)
	if not PartyController.hasCompany() then
		return
	end
	if #strokeQueue >= MAX_QUEUED_STROKES then
		return
	end
	table.insert(strokeQueue, { part = part, to = to, from = from, radius = radius })
end

-- Ship whatever has accumulated. Called every frame (not just while firing) so the tail of a stroke
-- still goes out after the player lets go of the trigger.
local function flushStrokes()
	if #strokeQueue == 0 then
		return
	end
	local now = os.clock()
	if now - lastStrokeFlush < STROKE_FLUSH_INTERVAL then
		return
	end
	lastStrokeFlush = now
	WallStroke:FireServer(strokeQueue)
	-- A fresh table, not table.clear: the queue was handed to the remote and is being serialized.
	strokeQueue = {}
end

local function resetStroke()
	lastSurface = nil
	lastWorldPos = nil
	missedLast = true
end

local function startSound()
	if fireSound then
		fireSound.start()
	end
end

local function stopSound()
	if fireSound then
		fireSound.stop()
	end
end

-- Depth bias (studs) pulling the spray particles toward the camera in the transparency
-- sort. The stream reaches the wall, so its particles end up coplanar with the wall's
-- dirt SurfaceGui overlay; without a bias the sort is ambiguous and particles sometimes
-- draw BEHIND the overlay. A small positive ZOffset makes them reliably render in front
-- without moving them physically.
local SPRAY_Z_OFFSET = 1

-- Find the equipped tool's spray emitter + the attachment it lives on, and start it
-- disabled so there's no VFX until the player actually fires.
local function resolveSpray(tool: Tool)
	local handle = tool:FindFirstChild("Handle")
	local emitter = handle and handle:FindFirstChildWhichIsA("ParticleEmitter", true)
	sprayEmitter = emitter :: ParticleEmitter?
	local parent = emitter and emitter.Parent
	sprayAttachment = if parent and parent:IsA("Attachment") then parent else nil
	if sprayEmitter then
		sprayEmitter.Enabled = false
		sprayEmitter.ZOffset = SPRAY_Z_OFFSET
	end
end

local function startSpray()
	if sprayEmitter then
		sprayEmitter.Enabled = true
	end
end

local function stopSpray()
	if sprayEmitter then
		sprayEmitter.Enabled = false
	end
end

-- Re-aim the spray: point the emitter's attachment from the nozzle toward `target`
-- so particles (EmissionDirection = Front => the attachment's look axis) shoot that
-- way. Keeps the attachment's position; only its orientation changes.
local function aimSpray(target: Vector3)
	local att = sprayAttachment
	if not att or not att.Parent then
		return
	end
	local origin = att.WorldPosition
	if (target - origin).Magnitude < 0.05 then
		return
	end
	att.WorldCFrame = CFrame.lookAt(origin, target)
end

local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Start/stop the spray, deduped so repeat calls are free.
local function startFiring()
	if firing then
		return
	end
	firing = true
	startSound()
	startSpray()
end

local function stopFiring()
	if not firing then
		return
	end
	firing = false
	resetStroke()
	stopSound()
	stopSpray()
end

-- Told whenever the washer goes in or out of our hands -- the touch WashButton is shown off this.
local equipListeners: { (boolean) -> () } = {}
local lastEquipState = false

local function notifyEquipped()
	local equipped = equippedTool ~= nil
	if equipped == lastEquipState then
		return
	end
	lastEquipState = equipped
	for _, callback in equipListeners do
		task.spawn(callback, equipped)
	end
end

-- Watch whether the pressure washer is equipped. Fires immediately with the current state, then on
-- every flip (same shape as GarbageCarryController.onCarryingChanged).
function PressureWasherController.onEquippedChanged(callback: (boolean) -> ())
	table.insert(equipListeners, callback)
	callback(lastEquipState)
end

function PressureWasherController.isEquipped(): boolean
	return equippedTool ~= nil
end

-- The touch trigger (WashJoystickController holding the WashButton). Firing still needs the tool in
-- hand and a LIVE job: the washer stays equipped through the end-of-job JobSummary, so equip alone
-- can't gate it -- otherwise the spray would keep running over the summary.
function PressureWasherController.setFiring(on: boolean)
	if on and equippedTool and hasActiveJob() then
		startFiring()
	else
		stopFiring()
	end
end

local function bindTool(tool: Tool)
	tool.Equipped:Connect(function()
		equippedTool = tool
		resolveSpray(tool)
		notifyEquipped()
	end)
	tool.Activated:Connect(function()
		-- On touch a tap is a look/aim gesture, never the trigger -- that's the WashButton.
		if IS_MOBILE then
			return
		end
		if equippedTool == tool then
			startFiring()
		end
	end)
	tool.Deactivated:Connect(function()
		if IS_MOBILE then
			return
		end
		stopFiring()
	end)
	tool.Unequipped:Connect(function()
		if equippedTool == tool then
			equippedTool = nil
			stopFiring()
			sprayEmitter = nil
			sprayAttachment = nil
			notifyEquipped()
		end
	end)
end

local function tryBind(inst: Instance)
	if inst:IsA("Tool") and inst:GetAttribute("ToolId") == TOOL_ID and not boundTools[inst] then
		boundTools[inst] = true
		bindTool(inst)
	end
end

local function watch(root: Instance)
	root.DescendantAdded:Connect(tryBind)
	for _, d in root:GetDescendants() do
		tryBind(d)
	end
end

-- Raycasts from the aim point. Returns the hit (if any) and the camera ray, so callers
-- can fall back to a point along the ray when nothing was hit. On mobile the washer fires
-- continuously from the crosshair, so we aim from the center of the screen instead of the
-- touch point (GetMouseLocation returns the last tap, which would clean wherever they poke).
local function aim(): (RaycastResult?, Ray?)
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil, nil
	end
	local point = if IS_MOBILE then cam.ViewportSize / 2 else UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(point.X, point.Y)
	return Workspace:Raycast(ray.Origin, ray.Direction * getRange(), rayParams), ray
end

local function onHeartbeat()
	-- Outside the `firing` gate so the last batch of a stroke still ships once the player stops.
	flushStrokes()

	if not firing then
		return
	end

	local result, ray = aim()

	-- Aim the spray wherever the player points -- at the hit if there is one, else a
	-- point out along the ray -- regardless of whether it landed on a cleanable wall.
	if ray then
		local target = if result then result.Position else ray.Origin + ray.Direction * getRange()
		aimSpray(target)
	end

	local gs = getSurface
	if not gs then
		return
	end

	if not result then
		resetStroke()
		return
	end

	local part = result.Instance
	if not part or not part:IsA("BasePart") then
		resetStroke()
		return
	end

	-- Only walls on the local player's plot have a surface registered here.
	local surface = gs(part)
	if not surface or surface.cleaned then
		resetStroke()
		return
	end

	-- Overlay face only: reject hits on any other face (edges/back), where the dirt
	-- isn't. The surface knows which face it's on; its world normal is the part-local
	-- face direction rotated into world space.
	local faceNormal = part.CFrame:VectorToWorldSpace(Vector3.fromNormalId(surface.face))
	if result.Normal:Dot(faceNormal) < 0.99 then
		resetStroke()
		return
	end

	-- Bridge from the previous hit so fast strokes leave no holes -- including
	-- across the seam between two adjacent parts. Skip the bridge if the aim
	-- jumped too far (a genuine teleport to a different wall), so we don't smear
	-- an unrelated surface.
	local fromPos: Vector3? = nil
	if not missedLast and lastWorldPos and (result.Position - lastWorldPos).Magnitude <= MAX_BRIDGE_DIST then
		fromPos = lastWorldPos
	end

	local radius = getRadius()

	-- When the stroke crossed onto a new part, also extend the part we just left
	-- toward this hit so its edge by the seam gets cleaned too.
	if fromPos and lastSurface and lastSurface ~= surface and not lastSurface.cleaned then
		lastSurface:clean(result.Position, fromPos, radius)
		queueStroke(lastSurface.part, result.Position, fromPos, radius)
	end

	local erasedBefore = surface.cleanedCount
	surface:clean(result.Position, fromPos, radius)
	-- Relay the identical stamp to any party members (no-op when we're alone on the job).
	queueStroke(part, result.Position, fromPos, radius)

	-- Only report when dirt actually came off (the player is genuinely modifying the
	-- image, not aiming at already-clean pixels), throttled to keep traffic low. The
	-- server re-validates and enforces the real once-per-second reward.
	if surface.cleanedCount > erasedBefore then
		local now = os.clock()
		if now - lastProgressReport >= PROGRESS_REPORT_INTERVAL then
			lastProgressReport = now
			CleanProgress:FireServer(part)
		end

		-- Reward feedback, tied to dirt genuinely coming off for the same reason the report is:
		-- spraying already-clean pixels shouldn't pay out sprites.
		if now - lastCleanBurst >= CLEAN_BURST_INTERVAL then
			lastCleanBurst = now
			VfxManager.cleanBurst(result.Position)
		end
	end

	lastSurface = surface
	lastWorldPos = result.Position
	missedLast = false

	if surface.cleaned then
		resetStroke()
	end
end

function PressureWasherController.init(surfaceGetter: (BasePart) -> Surface?)
	getSurface = surfaceGetter

	fireSound = SoundManager.createSustained("PressureAudio", {
		loopStart = SOUND_SECTION_START,
		loopEnd = SOUND_SECTION_END,
	})

	watch(localPlayer)
	localPlayer.CharacterAdded:Connect(watch)
	if localPlayer.Character then
		watch(localPlayer.Character)
	end

	-- A job ending cuts the spray mid-hold: the washer stays equipped through the JobSummary, and the
	-- trigger (a held WashButton, or a held mouse button) doesn't let go by itself.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(function()
		if not hasActiveJob() then
			stopFiring()
		end
	end)

	-- Keep the ray exclude list current with the character and the streamed-in folders.
	localPlayer.CharacterAdded:Connect(rebuildRayExclude)
	watchIgnoredFolders()
	rebuildRayExclude()

	RunService.Heartbeat:Connect(onHeartbeat)
end

return PressureWasherController
