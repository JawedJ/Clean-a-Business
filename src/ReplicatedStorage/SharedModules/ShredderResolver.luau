--!strict

-- Finds a business's shredder -- the machine cleanable garbage is fed into. Every business that has
-- cleanable garbage authors one, directly in the building (NOT under Cleanables, since it isn't
-- itself a cleanable):
--   Workspace.<BusinessesFolderName>.<businessId>.<ShredderModelName>
--     .<ShredderHitboxName>    -- touching this with a piece feeds it in
--     .<ShredderEntryPartName> -- p1, the mouth: where the piece is held for a beat
--     .<ShredderExitPartName>  -- p2, inside the machine: where the piece is destroyed
--
-- Shared so the client (GarbageShredController, which watches the hitbox and animates the piece
-- between p1 and p2) and the server (GarbageShredService, which validates that the business it was
-- told about actually HAS a shredder) agree on the same layout.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)

export type Shredder = {
	model: Model,
	hitbox: BasePart,
	-- p1 / p2: the two CFrames the disposal animation draws the piece through.
	entry: BasePart,
	exit: BasePart,
}

local ShredderResolver = {}

local function partIn(parent: Instance, name: string): BasePart?
	local child = parent:FindFirstChild(name)
	return if child and child:IsA("BasePart") then child else nil
end

-- The shredder for a business, or nil if the building isn't loaded or has no (complete) shredder.
-- A business with no cleanable garbage simply doesn't author one.
function ShredderResolver.find(businessId: string): Shredder?
	local businesses = Workspace:FindFirstChild(Config.BusinessesFolderName)
	local building = businesses and businesses:FindFirstChild(businessId)
	local model = building and building:FindFirstChild(Config.ShredderModelName)
	if not model or not model:IsA("Model") then
		return nil
	end

	local hitbox = partIn(model, Config.ShredderHitboxName)
	local entry = partIn(model, Config.ShredderEntryPartName)
	local exit = partIn(model, Config.ShredderExitPartName)
	if not hitbox or not entry or not exit then
		return nil
	end

	return { model = model, hitbox = hitbox, entry = entry, exit = exit }
end

return ShredderResolver
