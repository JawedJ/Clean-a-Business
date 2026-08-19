--!strict

-- The first-person arms (the "viewmodel"): a custom rig, authored in
-- ReplicatedStorage.Rigs.Black.Viewmodel, shown in front of the local player's camera for the duration
-- of a job and taken away when the job ends. Driven by the same ActiveJob attribute as the rest of
-- the job client (JobController / JobCameraController), which is also what locks the camera to
-- first person -- the two go together: the arms only make sense while the view is down the barrel.
--
-- NOBODY ELSE SEES IT. The rig is a CLIENT-SIDE clone parented to Workspace.CurrentCamera. Nothing
-- a client creates replicates, and the camera is outside Workspace entirely, so the rig is invisible
-- to every other player, casts no shadows, and -- the reason the camera is the right parent rather
-- than Workspace -- cannot be hit by any of the game's aim raycasts (cleaning, garbage hover, the
-- mobile tap). It hangs directly between the camera and whatever the player is aiming at, so a rig
-- that WERE raycastable would swallow every shot; the same problem is solved for floating tools in
-- ToolFloatController (CanQuery).
--
-- HOW IT IS POSED. The rig carries a CameraPart (a Motor6D child of its HumanoidRootPart) that the
-- animations move alongside the arms. Rather than moving the real camera with it -- the camera
-- belongs to JobCameraController and to the player's own aim -- we pin the CameraPart ONTO the
-- camera every frame and let the root fall out of that: the animator's camera track then reads as
-- the arms swaying against a steady view, which is what a viewmodel wants. A rig with no CameraPart
-- falls back to pinning its root directly.
--
-- The rig is built once, on the first job, and then simply parented in and out of the camera --
-- animation tracks stay loaded, so a second job doesn't re-fetch them mid-play.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local MovementState = require(script.Parent.MovementState)

local localPlayer = Players.LocalPlayer

-- The rig part the animations move as if it were the camera (see the header). Optional.
local CAMERA_PART_NAME = "CameraPart"
-- Authoring leftovers (the saved KeyframeSequences the animation editor writes into the rig).
-- Dropped from the clone -- they're a couple of hundred instances of pure dead weight at runtime.
local ANIM_SAVES_NAME = "AnimSaves"

-- The movement animations, keyed by the state that plays them.
local ANIMATION_IDS: { [string]: string } = {
	idle = "rbxassetid://87295065174941",
	walk = "rbxassetid://106896367817869",
}

-- Idle sits at Core so the walk always wins over it.
local ANIMATION_PRIORITIES: { [string]: Enum.AnimationPriority } = {
	idle = Enum.AnimationPriority.Core,
	walk = Enum.AnimationPriority.Movement,
}

-- Cross-fade between states (seconds). Short enough to feel responsive on a stop/start, long
-- enough that the hands don't snap.
local FADE_TIME = 0.15

-- Fixed nudge applied to the camera before the rig is pinned to it, for tuning where the arms sit:
-- +X right, +Y up, -Z forward (into the screen). Identity = exactly where the rig was animated.
local VIEW_OFFSET = CFrame.identity

-- Bound just AFTER the camera has been placed for this frame, so the arms are pinned to the final
-- view rather than to last frame's -- anything later and they visibly lag the mouse.
local RENDER_BIND_NAME = "ViewmodelRender"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local ViewmodelController = {}

-- The one rig clone and its parts, built lazily on the first job and kept (parented out of the
-- camera) between jobs. nil until then, or if the rig isn't in ReplicatedStorage at all.
local rig: Model? = nil
local rigCameraPart: BasePart? = nil
local tracks: { [string]: AnimationTrack } = {}
local currentState: string? = nil

-- Whether the rig is currently shown (on a job) and the render bind is live.
local shown = false

-- Strip the clone down to something safe to hang off the camera: no collision, no raycast hits
-- (see the header), no shadows, and no weight -- massless parts mean nothing about the rig can
-- reach the character's physics even if it were ever reparented into the world.
local function prepareParts(model: Model, root: BasePart)
	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CanTouch = false
			desc.Massless = true
			desc.CastShadow = false
			-- Only the root is placed by us; every other part rides its Motor6D chain.
			desc.Anchored = desc == root
		end
	end
end

-- Build the rig clone, load its animations and leave it parented out of the world. Returns false
-- if the rig (or a piece we need from it) isn't there, in which case the whole module stays a
-- no-op rather than erroring on every job.
local function buildRig(): boolean
	if rig then
		return true
	end
	local rigsFolder = ReplicatedStorage:FindFirstChild(Config.RigsFolderName)
	local rigSet = rigsFolder and rigsFolder:FindFirstChild(Config.RigSetName)
	local template = rigSet and rigSet:FindFirstChild(Config.ViewmodelRigName)
	if not template or not template:IsA("Model") then
		warn(string.format(
			"[ViewmodelController] ReplicatedStorage.%s.%s.%s not found",
			Config.RigsFolderName,
			Config.RigSetName,
			Config.ViewmodelRigName
		))
		return false
	end

	local model = template:Clone()
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		warn("[ViewmodelController] rig has no HumanoidRootPart")
		model:Destroy()
		return false
	end
	model.PrimaryPart = root

	local saves = model:FindFirstChild(ANIM_SAVES_NAME)
	if saves then
		saves:Destroy()
	end
	prepareParts(model, root)

	-- THE HUMANOID GOES. A Humanoid is what makes the engine treat a model as a CHARACTER: it runs a
	-- state machine against it, hunts for the floor under it, and lets the character controller act
	-- on its parts. This rig is a prop hanging off the camera -- teleported every frame, sitting
	-- inside the player's own body -- and none of that has any business running against it. An
	-- AnimationController drives Motor6Ds exactly as well, which is all a viewmodel ever needed.
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end
	local controller = Instance.new("AnimationController")
	controller.Parent = model
	local animator = Instance.new("Animator")
	animator.Parent = controller

	rig = model
	local cameraPart = model:FindFirstChild(CAMERA_PART_NAME)
	rigCameraPart = if cameraPart and cameraPart:IsA("BasePart") then cameraPart else nil

	-- LOADED ONLY ONCE THE RIG IS IN THE DATAMODEL, never before. A track loaded against an Animator
	-- inside a model parented to nil never resolves -- measured: its Length sits at 0 forever, and it
	-- plays nothing. Loading them here, after the rig is under the camera, is the difference between
	-- animated hands and a rig frozen in its authored rest pose (arms straight out to the sides,
	-- i.e. nowhere near the view).
	model.Parent = Workspace.CurrentCamera
	for state, id in ANIMATION_IDS do
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		animation.Name = state
		animation.Parent = model
		local track = animator:LoadAnimation(animation)
		track.Looped = true
		track.Priority = ANIMATION_PRIORITIES[state] or Enum.AnimationPriority.Movement
		tracks[state] = track
	end

	return true
end

-- Cross-fade to `state` ("idle" / "walk"), or to nothing at all (nil) when the rig is put
-- away. Re-asking for the state that's already playing is a no-op, so this is safe every frame.
local function playState(state: string?)
	if state == currentState then
		return
	end
	local previous = if currentState then tracks[currentState] else nil
	if previous then
		previous:Stop(FADE_TIME)
	end
	currentState = state
	local wanted = if state then tracks[state] else nil
	if wanted then
		wanted:Play(FADE_TIME)
	end
end

-- Per frame while shown: pin the rig to the camera and pick the animation.
--
-- The rig is placed with PivotTo rather than by assigning the root part's CFrame. Off in the
-- camera the rig isn't a physics assembly, so moving the root does NOT drag the Motor6D chain
-- along with it -- the arms would stay behind at the origin. PivotTo moves every part of the model
-- explicitly, preserving the relative pose the animation put them in.
local function onRender()
	local model = rig
	local camera = Workspace.CurrentCamera
	if not model or not camera then
		return
	end

	local target = camera.CFrame * VIEW_OFFSET
	local cameraPart = rigCameraPart
	if cameraPart then
		-- Where the animation currently holds the CameraPart relative to the rig's pivot (its
		-- root). Pinning the CameraPart at the camera and solving the pivot back out of that is
		-- what turns the animated camera motion into arm sway instead of a moving view -- see the
		-- header.
		local pivotToCameraPart = model:GetPivot():ToObjectSpace(cameraPart.CFrame)
		model:PivotTo(target * pivotToCameraPart:Inverse())
	else
		model:PivotTo(target)
	end

	playState(MovementState.get())
end

local function show()
	if shown or not buildRig() then
		return
	end
	shown = true
	local model = rig :: Model
	-- A no-op on the job that built it (buildRig has to parent the rig before it can load a single
	-- animation); this is for every job after, which the last hide left parented out.
	model.Parent = Workspace.CurrentCamera
	-- Place + pose it before the first frame renders, so it can't flash in at its old position.
	onRender()
	RunService:BindToRenderStep(RENDER_BIND_NAME, RENDER_PRIORITY, onRender)
end

local function hide()
	if not shown then
		return
	end
	shown = false
	RunService:UnbindFromRenderStep(RENDER_BIND_NAME)
	playState(nil)
	if rig then
		-- Kept rather than destroyed, so the next job doesn't reload the animations.
		rig.Parent = nil
	end
end

local function sync()
	if type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string" then
		show()
	else
		hide()
	end
end

-- The rig model, or nil when it hasn't been built (no job yet). For anything that wants to hang off
-- the arms later -- welding an equipped tool into RightHand, say.
function ViewmodelController.getRig(): Model?
	return rig
end

function ViewmodelController.init()
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(sync)
	-- The engine swaps CurrentCamera on respawn, which would leave the rig parented to the old one
	-- where it renders nothing; re-home it.
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if shown and rig and Workspace.CurrentCamera then
			rig.Parent = Workspace.CurrentCamera
		end
	end)
	sync()
end

return ViewmodelController
