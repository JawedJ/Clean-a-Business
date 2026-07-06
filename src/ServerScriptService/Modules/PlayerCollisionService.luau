--!strict

-- Players never collide with each other -- anywhere, job or not. Every character is placed in
-- a "Players" collision group that doesn't collide with itself, so no one can push, block, or
-- stand on anyone else. The group still collides with Default, so characters stand on floors
-- and can't walk through walls as normal.
--
-- Collision is mutual and physics-authoritative, so it belongs here on the server (a client
-- CanCollide=false on a remote character just gets overwritten by replication). The matching
-- VISUAL side -- hiding same-job players and drawing them as a blue highlight -- is per-viewer
-- and lives on the client (JobGhostController); that stays job-only.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

-- Our non-self-colliding group for every player character.
local PLAYER_GROUP = "Players"

local PlayerCollisionService = {}

local function applyToCharacter(character: Model)
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = PLAYER_GROUP
		end
	end
	-- Parts that stream in later (accessories, an equipped tool) join the group too.
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = PLAYER_GROUP
		end
	end)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(applyToCharacter)
	if player.Character then
		applyToCharacter(player.Character)
	end
end

function PlayerCollisionService.init()
	-- Register the group (idempotent-guarded so a live-reload doesn't error) and make it
	-- ignore itself. It still collides with Default, so characters stand on floors/walls.
	pcall(function()
		PhysicsService:RegisterCollisionGroup(PLAYER_GROUP)
	end)
	PhysicsService:CollisionGroupSetCollidable(PLAYER_GROUP, PLAYER_GROUP, false)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
end

return PlayerCollisionService
