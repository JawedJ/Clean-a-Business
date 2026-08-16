--!strict

-- Keeps the coin reward VFX out of the shredders. Every BasePart under an instance tagged
-- "shredder" is put in a "Shredder" collision group, and that group is made non-collidable with the
-- "CoinVfx" group the burst sprites use (VfxManager.buildBurstParts).
--
-- Collision groups are registered and replicated by the SERVER, which is the only reason this exists
-- server-side at all: the sprites themselves are client-only instances, and a client can't create
-- the group it wants to put them in. Registering here means the group is already known by the time
-- any client spawns a coin.
--
-- The tag is watched rather than read once: a business's shredder streams in with its building, so
-- the parts usually don't exist yet when this runs.

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")

-- The authored tag on a shredder model, and the two groups it gates.
local SHREDDER_TAG = "shredder"
local SHREDDER_GROUP = "Shredder"

local ShredderCollisionService = {}

-- The group the client puts its coin sprites in. Exposed so VfxManager's name can't drift from the
-- one registered here without the mismatch being obvious.
ShredderCollisionService.COIN_GROUP = "CoinVfx"

local function applyToShredder(inst: Instance)
	if inst:IsA("BasePart") then
		inst.CollisionGroup = SHREDDER_GROUP
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = SHREDDER_GROUP
		end
	end
	-- Parts added later (a rebuilt machine, a streamed-in child) join the group too.
	inst.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = SHREDDER_GROUP
		end
	end)
end

function ShredderCollisionService.init()
	-- pcall-guarded so a live-reload (the group already exists) doesn't error.
	pcall(function()
		PhysicsService:RegisterCollisionGroup(SHREDDER_GROUP)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(ShredderCollisionService.COIN_GROUP)
	end)
	PhysicsService:CollisionGroupSetCollidable(SHREDDER_GROUP, ShredderCollisionService.COIN_GROUP, false)

	for _, inst in CollectionService:GetTagged(SHREDDER_TAG) do
		applyToShredder(inst)
	end
	CollectionService:GetInstanceAddedSignal(SHREDDER_TAG):Connect(applyToShredder)
end

return ShredderCollisionService
