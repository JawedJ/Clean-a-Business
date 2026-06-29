--!strict

-- Populates a player's plot with the businesses they own. Each business has a
-- template Model in ReplicatedStorage.Businesses named after its businessId (e.g.
-- "mcDonalds"), structured exactly like the in-plot version. On assignment we
-- clone every owned business into the plot's Businesses folder and pivot it onto
-- its matching spawn part (BusinessSpawns.<businessId>Spawn). The cleanable walls
-- inside the clone are then picked up by the client's SurfaceManager via its
-- Businesses.ChildAdded watch.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).server

local BusinessTemplates = ReplicatedStorage:WaitForChild(Config.BusinessesFolderName)

local BusinessSpawner = {}

-- Remove stain models the player has already cleaned from a freshly cloned
-- business, so cleaned stains never reappear. Walls aren't pruned here -- their
-- cleaned state is handled client-side (the overlay simply isn't rebuilt).
local function pruneCleanedStains(clone: Instance, cleanedStains: { [string]: boolean }?)
	if not cleanedStains then
		return
	end
	local cleanables = clone:FindFirstChild(Config.CleanablesFolderName)
	local decals = cleanables and cleanables:FindFirstChild(Config.DecalsFolderName)
	if not decals then
		return
	end
	for _, model in decals:GetChildren() do
		local surfaceId = model:GetAttribute(Config.SurfaceIdAttribute)
		if type(surfaceId) == "string" and cleanedStains[surfaceId] then
			model:Destroy()
		end
	end
end

-- Clone one business template onto its spawn within the plot. No-op if it has
-- already been spawned, or if the template / spawn part is missing.
local function spawnBusiness(plot: Instance, businessId: string, cleanedStains: { [string]: boolean }?)
	local businesses = plot:FindFirstChild(Config.BusinessesFolderName)
	if not businesses then
		warn(string.format("[BusinessSpawner] Plot %s has no %s folder.", plot.Name, Config.BusinessesFolderName))
		return
	end
	if businesses:FindFirstChild(businessId) then
		return -- already spawned
	end

	local template = BusinessTemplates:FindFirstChild(businessId)
	if not template or not template:IsA("Model") then
		warn(string.format("[BusinessSpawner] No template Model for business %q.", businessId))
		return
	end

	local spawns = plot:FindFirstChild(Config.SpawnsFolderName)
	local spawnName = businessId .. Config.SpawnSuffix
	local spawn = spawns and spawns:FindFirstChild(spawnName)
	if not spawn or not spawn:IsA("BasePart") then
		warn(string.format("[BusinessSpawner] No spawn part %q in plot %s.", spawnName, plot.Name))
		return
	end

	local clone = template:Clone()

	-- Drop any stains this player already cleaned before the clone is parented in.
	pruneCleanedStains(clone, cleanedStains)

	-- Translate the clone so its BasePart lands on the spawn point, keeping the
	-- template's authored orientation (a pure translation never rotates anything).
	local basePart = clone:FindFirstChild(Config.BusinessBasePartName, true)
	if basePart and basePart:IsA("BasePart") then
		clone:PivotTo(clone:GetPivot() + (spawn.Position - basePart.Position))
	else
		warn(
			string.format(
				"[BusinessSpawner] Business %q has no %q part; placing by pivot instead.",
				businessId,
				Config.BusinessBasePartName
			)
		)
		clone:PivotTo(CFrame.new(spawn.Position) * clone:GetPivot().Rotation)
	end

	clone.Parent = businesses
end

-- Remove every spawned business from a plot, returning it to its empty state so
-- the next occupant starts fresh.
function BusinessSpawner.clear(plot: Instance)
	local businesses = plot:FindFirstChild(Config.BusinessesFolderName)
	if not businesses then
		return
	end
	for _, business in businesses:GetChildren() do
		business:Destroy()
	end
end

-- Spawn every business the player owns into their assigned plot. Yields until the
-- player's data has loaded.
function BusinessSpawner.populate(player: Player, plot: Instance)
	DataService:waitForData(player)

	local businessList = DataService:get(player, { "BusinessList" })
	if type(businessList) ~= "table" then
		return
	end

	for businessId, business in businessList do
		-- "Owned" = present in the player's list and unlocked.
		if type(business) == "table" and business.Unlocked == true then
			spawnBusiness(plot, businessId, business.CleanedStains)
		end
	end
end

return BusinessSpawner
