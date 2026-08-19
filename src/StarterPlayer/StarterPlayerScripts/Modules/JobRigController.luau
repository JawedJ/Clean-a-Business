--!strict

-- The JOB RIG on the local player's screen: the full-body character (the cat) the server swaps them
-- into for the duration of a job. The rig itself is built server-side by JobRigService; this module
-- owns two things about it, both client-side -- its ANIMATIONS, and the fact that its owner never
-- sees it.
--
-- WHY THE OWNER'S CLIENT PLAYS THE ANIMATIONS. Animations played through a character's Animator by
-- the client that owns that character replicate out to the server and to every other player --
-- exactly how Roblox's own Animate script drives a normal avatar. Playing them here therefore
-- animates the rig for everybody, and does it against the movement the player is actually feeling
-- on their own machine rather than a replicated echo of it. (This depends on the Animator having
-- been created by the SERVER, which is why JobRigService makes it rather than leaving it to us.)
--
-- THE STATES. The tail is always swishing, for as long as the rig is worn. Underneath it the body is
-- either idle or walking, off the same MovementState the first-person arms use, so the two rigs
-- always agree.
--
-- Tail sits BELOW idle/walk in priority on purpose. The tail animation carries LowerTorso and
-- HumanoidRootPart tracks alongside the tail joints; keeping it under the body animations means
-- those two joints are won by whatever the body is doing, while the tail chain -- which idle and
-- walk don't touch at all -- is still driven entirely by the tail. Same result as authoring them to
-- not overlap, without depending on the animations to stay that way.
--
-- THE OWNER NEVER SEES THEIR OWN RIG. What they see of themselves is the first-person arms
-- (ViewmodelController) and nothing else -- a cat body and tail swinging through their own view
-- would only fight the hands. Hiding is per-part LocalTransparencyModifier, the client-only knob the
-- engine itself uses to hide your body in first person (the same one HidePlayersController uses to
-- hide OTHER players); it doesn't replicate, so everyone else still sees the whole cat. It's
-- re-asserted every frame just after the camera has run, because the engine's own first/third-person
-- transparency pass writes the same property and would otherwise hand parts back at any moment the
-- camera pulls out. An equipped TOOL is deliberately left alone -- it's floated into view on purpose
-- (ToolFloatController), and the player needs to see what they're cleaning with.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local MovementState = require(script.Parent.MovementState)

local localPlayer = Players.LocalPlayer

-- Played for as long as the rig is worn.
local TAIL_ANIMATION_ID = "rbxassetid://117293777206602"

-- One per movement state (see MovementState).
local ANIMATION_IDS: { [string]: string } = {
	idle = "rbxassetid://122237710473147",
	walk = "rbxassetid://103463222229278",
}

-- The body animations run at Action so they beat the tail (and anything the engine might layer on)
-- on the joints they share; the tail runs below them -- see the header.
local BODY_PRIORITY = Enum.AnimationPriority.Action
local TAIL_PRIORITY = Enum.AnimationPriority.Movement

-- Cross-fade between idle and walk (seconds).
local FADE_TIME = 0.15

-- Just after the camera (and with it the engine's own transparency pass) has run for this frame,
-- so our hiding is what ends up on screen.
local RENDER_BIND_NAME = "JobRigHide"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local JobRigController = {}

-- The rig we're currently animating + hiding, and everything held against it. All nil between jobs;
-- all replaced wholesale when a new rig is worn, since its tracks belong to its own Animator.
local currentRig: Model? = nil
local tracks: { [string]: AnimationTrack } = {}
local tailTrack: AnimationTrack? = nil
local currentState: string? = nil
-- The rig's Humanoid, once it has replicated in. The camera is pointed at it -- see followCamera.
local rigHumanoid: Humanoid? = nil
-- The rig's own parts (never a tool's -- see the header), cached so the per-frame hide is a walk of
-- a list rather than a fresh GetDescendants every frame.
local hiddenParts: { BasePart } = {}
local descendantConns: { RBXScriptConnection } = {}
-- Bumped every time the worn rig changes, so a load still waiting on the rig's Animator can tell
-- it's been superseded and drop what it was doing.
local generation = 0
local bound = false

-- A part of the rig's BODY, as opposed to one belonging to a tool it's holding.
local function isBodyPart(inst: Instance): boolean
	return inst:IsA("BasePart") and inst:FindFirstAncestorWhichIsA("Tool") == nil
end

local function trackPart(part: BasePart)
	table.insert(hiddenParts, part)
	part.LocalTransparencyModifier = 1
end

local function loadTrack(animator: Animator, id: string, priority: Enum.AnimationPriority): AnimationTrack
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local track = animator:LoadAnimation(animation)
	track.Looped = true
	track.Priority = priority
	return track
end

-- Cross-fade the body to `state`, or to nothing at all (nil) when the rig comes off.
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

-- Point the camera at the rig's Humanoid.
--
-- THIS IS NOT AUTOMATIC. The engine sets Camera.CameraSubject as part of its own spawn path
-- (LoadCharacter); a character handed over by assigning Player.Character -- which is how the rig
-- arrives -- never goes through it. Left alone, the camera stays locked to the humanoid of the body
-- that was just destroyed, so the player is teleported into the job while their view sits back where
-- they came from. Re-asserted per frame rather than set once, because we're racing the engine's own
-- handling of the character change: whatever it settles on a moment later, the subject ends up being
-- the body the player is actually driving.
local function followCamera()
	local humanoid = rigHumanoid
	local camera = Workspace.CurrentCamera
	if humanoid and camera and camera.CameraSubject ~= humanoid then
		camera.CameraSubject = humanoid
	end
end

-- Per frame while a rig is worn: keep the camera on it, hold it invisible to its owner, and keep the
-- body animation in step with how they're moving. All re-asserted rather than set once -- see above
-- and the header.
local function onRender()
	followCamera()
	for _, part in hiddenParts do
		if part.LocalTransparencyModifier ~= 1 then
			part.LocalTransparencyModifier = 1
		end
	end
	playState(MovementState.get())
end

local function stopAnimating()
	generation += 1
	if bound then
		RunService:UnbindFromRenderStep(RENDER_BIND_NAME)
		bound = false
	end
	for _, conn in descendantConns do
		conn:Disconnect()
	end
	descendantConns = {}
	-- Hand the parts back to the engine's own transparency pass. The rig is usually on its way to
	-- being destroyed, but a restore that leaves nothing of ours behind is what makes this safe to
	-- run against a character that outlives us.
	for _, part in hiddenParts do
		if part.Parent then
			part.LocalTransparencyModifier = 0
		end
	end
	hiddenParts = {}
	-- The camera is left where it is: whatever character comes next (a restored avatar arrives
	-- through LoadCharacter) brings its own subject with it.
	rigHumanoid = nil
	playState(nil)
	if tailTrack then
		tailTrack:Stop(FADE_TIME)
		tailTrack = nil
	end
	tracks = {}
	currentRig = nil
end

-- Take over a rig: hide it from its owner straight away, then load and start its animations. The
-- animation half yields on the Animator, which the server creates as part of building the rig and
-- which therefore has to replicate to us first; the hiding must not wait on that.
local function startAnimating(rig: Model)
	stopAnimating()
	currentRig = rig
	local mine = generation

	for _, desc in rig:GetDescendants() do
		if isBodyPart(desc) then
			trackPart(desc :: BasePart)
		end
	end
	-- Anything that appears later (a tool being equipped brings parts we skip; accessories and
	-- rig pieces still replicating in do not).
	table.insert(
		descendantConns,
		rig.DescendantAdded:Connect(function(desc)
			if isBodyPart(desc) then
				trackPart(desc :: BasePart)
			end
		end)
	)
	table.insert(
		descendantConns,
		rig.DescendantRemoving:Connect(function(desc)
			local index = table.find(hiddenParts, desc :: any)
			if index then
				table.remove(hiddenParts, index)
			end
		end)
	)

	RunService:BindToRenderStep(RENDER_BIND_NAME, RENDER_PRIORITY, onRender)
	bound = true

	task.spawn(function()
		local humanoid = rig:WaitForChild("Humanoid", 10)
		if not humanoid or not humanoid:IsA("Humanoid") or generation ~= mine then
			return
		end
		-- Before the animations: the camera being on the right body matters immediately, and
		-- shouldn't wait on an Animator that's still replicating.
		rigHumanoid = humanoid
		followCamera()

		local animator = humanoid:WaitForChild("Animator", 10)
		-- Superseded (they took the rig off, or respawned into another) while we waited.
		if not animator or not animator:IsA("Animator") or generation ~= mine then
			return
		end

		for state, id in ANIMATION_IDS do
			tracks[state] = loadTrack(animator, id, BODY_PRIORITY)
		end
		local tail = loadTrack(animator, TAIL_ANIMATION_ID, TAIL_PRIORITY)
		tailTrack = tail
		tail:Play(FADE_TIME)
		playState(MovementState.get())
	end)
end

-- A character became ours: take it over if it's a job rig, and make sure we're not still driving
-- whatever came before if it isn't.
local function onCharacter(character: Model?)
	if character and character:GetAttribute(Config.JobRigAttribute) == true then
		if character ~= currentRig then
			startAnimating(character)
		end
	else
		stopAnimating()
	end
end

function JobRigController.init()
	localPlayer.CharacterAdded:Connect(onCharacter)
	localPlayer.CharacterRemoving:Connect(function()
		stopAnimating()
	end)
	onCharacter(localPlayer.Character)
end

return JobRigController
