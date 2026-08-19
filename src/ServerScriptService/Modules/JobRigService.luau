--!strict

-- Swaps the player's CHARACTER for the job rig (ReplicatedStorage.Rigs.Black."Black Cat") while
-- they're on the clock, and back to their own avatar on the trip home. Unlike the first-person arms
-- (ViewmodelController, which are a client-only prop hung off the camera), this is the real
-- character -- it walks, carries, cleans and is seen by everyone, which is exactly why it's built
-- here on the server rather than on the client.
--
-- SWAPPED IN PLACE. applyToJob doesn't decide WHERE the player ends up: it drops the rig at the
-- pose their previous character was standing in and lets whoever called it own the position. That
-- keeps one definition of "where a job puts you" (JobService teleports onto the building's
-- TeleportPart, then swaps) and means a mid-job respawn -- which PlotService has already placed on
-- the plot spawn -- simply becomes a cat standing there, still on the clock.
--
-- THE ANIMATOR IS MADE HERE, ON PURPOSE. The rig's animations are played by the OWNER'S client
-- (JobRigController), which is what makes them replicate out to everybody else, exactly like the
-- default character animations. That replication only happens through an Animator the SERVER
-- created: had the client made its own, the animations would play for the owner alone and every
-- other player would see a cat gliding around frozen.
--
-- RESPAWNS. A character added while the player is still on a job is swapped too (they died, or
-- something else respawned them), so being on the clock and being a cat can't drift apart. The
-- clone is marked with Config.JobRigAttribute, which is both how we avoid swapping a rig for
-- another rig and how PlotService knows not to drag it off to the plot spawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

local JobRigService = {}

-- The rig template, or nil if it isn't authored. Resolved on demand (not cached at init) so
-- re-authoring the rig in Studio takes effect on the next job rather than needing a restart.
local function template(): Model?
	local rigs = ReplicatedStorage:FindFirstChild(Config.RigsFolderName)
	local set = rigs and rigs:FindFirstChild(Config.RigSetName)
	local model = set and set:FindFirstChild(Config.JobRigName)
	return if model and model:IsA("Model") then model else nil
end

-- Whether `character` is one of our rigs rather than the player's own avatar.
local function isJobRig(character: Instance?): boolean
	return character ~= nil and character:GetAttribute(Config.JobRigAttribute) == true
end

-- Whether this player is currently wearing the job rig.
function JobRigService.isWearingRig(player: Player): boolean
	return isJobRig(player.Character)
end

-- Build a character-ready clone of the rig: named for the player (the engine and every name-based
-- lookup in the game expect character.Name == player.Name), free of the animation editor's saved
-- KeyframeSequences, rooted on an UNANCHORED HumanoidRootPart -- it's anchored in the template, and
-- an anchored root is a character that cannot move -- and carrying the Animator the owner's client
-- will play through.
local function buildRig(player: Player): Model?
	local source = template()
	if not source then
		warn(string.format(
			"[JobRigService] ReplicatedStorage.%s.%s.%s not found; leaving %s in their own character.",
			Config.RigsFolderName,
			Config.RigSetName,
			Config.JobRigName,
			player.Name
		))
		return nil
	end

	local rig = source:Clone()
	rig.Name = player.Name
	rig:SetAttribute(Config.JobRigAttribute, true)

	local saves = rig:FindFirstChild("AnimSaves")
	if saves then
		saves:Destroy()
	end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local root = rig.PrimaryPart or rig:FindFirstChild("HumanoidRootPart")
	if not humanoid or not (root and root:IsA("BasePart")) then
		warn("[JobRigService] rig has no Humanoid / HumanoidRootPart; leaving the player as they are.")
		rig:Destroy()
		return nil
	end
	rig.PrimaryPart = root
	root.Anchored = false

	-- See the header: the owner's client plays through this, and only a server-made Animator
	-- replicates what it plays to everyone else.
	if not humanoid:FindFirstChildOfClass("Animator") then
		local animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	return rig
end

-- How far a character's root sits above the ground it's standing on: the Humanoid's HipHeight plus
-- half the root part. Used to swap bodies FEET-first -- the cat is a taller rig than a player avatar
-- (a bigger root and a higher hip), so dropping its root where the avatar's root was would bury its
-- legs in the floor and leave the physics to shove it back out.
local function rootHeight(character: Model): number
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
	local hip = if humanoid then humanoid.HipHeight else 0
	local half = if root and root:IsA("BasePart") then root.Size.Y / 2 else 0
	return hip + half
end

-- Put `player` in the job rig, standing exactly where their current character stands. No-op if they
-- already wear it, have no character to take the pose from, or the rig isn't authored.
--
-- Their equipped tool is unequipped first: a tool sits INSIDE the character while equipped, so it
-- would otherwise be destroyed along with the body it was welded to. Unequipping puts it back in
-- the Backpack, which survives the swap untouched.
function JobRigService.applyToJob(player: Player)
	local previous = player.Character
	if not previous or isJobRig(previous) then
		return
	end
	local humanoid = previous:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:UnequipTools()
	end

	local rig = buildRig(player)
	if not rig then
		return
	end
	-- Same spot and facing, lifted by the difference in build so both bodies stand on the same floor.
	rig:PivotTo(previous:GetPivot() + Vector3.new(0, rootHeight(rig) - rootHeight(previous), 0))
	rig.Parent = Workspace

	-- Assigning Character is what hands the client control of the rig and fires CharacterAdded for
	-- everything that rebinds per character (walk-speed pin, collision group, tools).
	player.Character = rig
	previous:Destroy()

	-- Belt and braces on control: player characters are normally handed to their owner
	-- automatically, and saying so outright costs nothing and rules out a rig the client can't move.
	local root = rig.PrimaryPart
	if root then
		pcall(function()
			root:SetNetworkOwner(player)
		end)
	end

	-- Drop the engine's default Animate script if it ever lands in the rig. The rig's animations are
	-- ours (JobRigController) and Animate would play the standard R15 walk/run/idle over the top of
	-- them on a body they were never authored for. Kept as a watcher, not a one-off check, for the
	-- same reason ToolFloatController keeps dropping the RightGrip weld: whether the engine adds it
	-- is its business, and a watcher is right either way.
	local function dropAnimate(desc: Instance)
		if desc:IsA("BaseScript") and desc.Name == "Animate" then
			desc:Destroy()
		end
	end
	for _, desc in rig:GetDescendants() do
		dropAnimate(desc)
	end
	rig.DescendantAdded:Connect(dropAnimate)
end

-- Give `player` their own avatar back. Returns true if a rig was actually swapped out, so the
-- caller can tell whether the respawn it triggers is going to place the player (PlotService puts
-- every freshly added character on its plot spawn) or whether it still has to do that itself.
--
-- LoadCharacter, rather than rebuilding the avatar by hand: it's the engine's own path back to the
-- player's real appearance, and it lands them on their plot through the same CharacterAdded
-- placement every respawn uses.
function JobRigService.restore(player: Player): boolean
	if not isJobRig(player.Character) then
		return false
	end
	player:LoadCharacter()
	return true
end

function JobRigService.init()
	-- Still on the clock with a fresh character (a mid-job respawn): put the rig back on. Placement
	-- is left alone -- PlotService has already put them on their plot spawn, and the swap keeps
	-- whatever pose it finds.
	local function watch(player: Player)
		player.CharacterAdded:Connect(function()
			if type(player:GetAttribute(Config.ActiveJobAttribute)) == "string" then
				JobRigService.applyToJob(player)
			end
		end)
	end

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)
end

return JobRigService
