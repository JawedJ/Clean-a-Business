--!strict

-- Owns the visibility of every cleanable stain on the LOCAL client. Stains are shared,
-- server-authored Models replicated to everyone -- but a player should only SEE a
-- business's stains while they're on that business's job. So by default this hides every
-- stain (reparenting it off-world, which also makes it non-raycastable) and shows a
-- business's stains only while it is the active job. Cleaning a stain hides it again
-- (per-client), and re-accepting the job shows them all for a clean redo.
--
-- Reparenting (rather than destroying) keeps the shared server model and its authored
-- CFrame intact, so it can be restored exactly and stays in place server-side for the
-- authoritative timer/validation.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DecalResolver = require(ReplicatedStorage.SharedModules.DecalResolver)

local DecalVisibility = {}

-- Off-world holder for hidden stains. Its Parent stays nil so its contents aren't rendered
-- or raycastable; this module's reference keeps them alive across jobs.
local holder = Instance.new("Folder")
holder.Name = "HiddenStains"

-- Each hidden stain -> where it came from + which business it belongs to.
local hidden: { [Model]: { parent: Instance, businessId: string } } = {}
-- Every stain we've seen (so we count each once) + the per-business totals (for UI).
local seen: { [Model]: boolean } = {}
local counts: { [string]: number } = {}

-- The business whose stains are currently shown, or nil (none shown).
local activeBusinessId: string? = nil

local function hideModel(model: Model, businessId: string)
	if hidden[model] then
		return
	end
	local parent = model.Parent
	if not parent then
		return
	end
	hidden[model] = { parent = parent, businessId = businessId }
	model.Parent = holder
end

local function showModel(model: Model)
	local info = hidden[model]
	if info then
		model.Parent = info.parent
		hidden[model] = nil
	end
end

-- Inspect an instance: if it's a cleanable stain, count it once and hide it unless its
-- business is the active job. Used on the initial scan and for stream-ins.
local function consider(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	local identity = DecalResolver.resolve(inst)
	if not identity then
		return
	end
	if not seen[inst] then
		seen[inst] = true
		counts[identity.businessId] = (counts[identity.businessId] or 0) + 1
	end
	if identity.businessId ~= activeBusinessId then
		hideModel(inst, identity.businessId)
	end
end

-- Number of cleanable stains a business has (for completion % / UI).
function DecalVisibility.getStainCount(businessId: string): number
	return counts[businessId] or 0
end

-- Hide a single stain that was just cleaned on this client.
function DecalVisibility.hideOne(model: Model)
	local identity = DecalResolver.resolve(model)
	hideModel(model, if identity then identity.businessId else (activeBusinessId or ""))
end

-- Show one business's stains and hide the previously-active one's. Pass nil to hide all
-- (no active job). Showing restores even stains cleaned on a previous run -- that's the redo.
function DecalVisibility.setActiveBusiness(businessId: string?)
	local oldId = activeBusinessId
	activeBusinessId = businessId

	if businessId then
		for model, info in hidden do
			if info.businessId == businessId then
				showModel(model)
			end
		end
	end

	if oldId and oldId ~= businessId then
		local businesses = Workspace:FindFirstChild(Config.BusinessesFolderName)
		if businesses then
			for _, desc in businesses:GetDescendants() do
				if desc:IsA("Model") then
					local identity = DecalResolver.resolve(desc)
					if identity and identity.businessId == oldId then
						hideModel(desc, oldId)
					end
				end
			end
		end
	end
end

function DecalVisibility.init()
	-- Don't block the caller: the Businesses folder may not exist/replicate yet.
	task.spawn(function()
		local businesses = Workspace:WaitForChild(Config.BusinessesFolderName)
		for _, desc in businesses:GetDescendants() do
			consider(desc)
		end
		businesses.DescendantAdded:Connect(consider)
	end)
end

return DecalVisibility
