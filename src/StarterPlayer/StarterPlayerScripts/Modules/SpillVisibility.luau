--!strict

-- Owns the visibility of every cleanable spill on the LOCAL client. Like stains (see
-- DecalVisibility), spills are shared, server-authored Models replicated to everyone -- but a
-- player should only SEE (and mop) a business's spills while they're on that business's job.
-- So by default this hides every spill (reparenting it off-world, which also makes it
-- non-raycastable) and shows a business's spills only while it is the active job.
--
-- Two things differ from stains, both because the mop cleans a spill by fading its parts'
-- Transparency toward 1 (client-side) rather than a server timer hiding it wholesale:
--   * Cleaning a spill fully (Transparency == 1) hides it via hideOne (per-client), same as a
--     stain -- but it may also be left PARTIALLY faded if the player stops mid-clean.
--   * Re-showing a business's spills (a redo) therefore RESETS every one of its spills back to
--     its authored Transparency, so a partly- or fully-mopped spill is dirty again for the redo.
--
-- Reparenting (rather than destroying) keeps the shared server model + its authored CFrame
-- intact, so it stays in place server-side for clean validation and can be restored exactly.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local SpillResolver = require(ReplicatedStorage.SharedModules.SpillResolver)

local SpillVisibility = {}

-- Off-world holder for hidden spills. Its Parent stays nil so its contents aren't rendered or
-- raycastable; this module's reference keeps them alive across jobs.
local holder = Instance.new("Folder")
holder.Name = "HiddenSpills"

-- Each hidden spill -> where it came from + which business it belongs to.
local hidden: { [Model]: { parent: Instance, businessId: string } } = {}
-- Every spill we've seen (so we count each once) + per-business totals (for UI).
local seen: { [Model]: boolean } = {}
local counts: { [string]: number } = {}
-- Authored Transparency of every spill part, snapshotted the first time we see the spill (before
-- any mopping), so a redo can restore it exactly.
local originalTransparency: { [BasePart]: number } = {}

-- The business whose spills are currently shown, or nil (none shown).
local activeBusinessId: string? = nil

-- Snapshot each part's authored Transparency once, before any cleaning fades it.
local function recordOriginals(model: Model)
	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") and originalTransparency[desc] == nil then
			originalTransparency[desc] = desc.Transparency
		end
	end
end

-- Restore a spill's parts to their authored Transparency (undo any mop fade), for a redo.
local function resetTransparency(model: Model)
	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			local original = originalTransparency[desc]
			if original ~= nil then
				desc.Transparency = original
			end
		end
	end
end

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
	-- Whether it was reparented back or merely left in place partly-mopped, make it dirty again.
	resetTransparency(model)
end

-- Inspect an instance: if it's a cleanable spill, count it once (snapshotting its transparency)
-- and hide it unless its business is the active job. Used on the initial scan and for stream-ins.
local function consider(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	local identity = SpillResolver.resolve(inst)
	if not identity then
		return
	end
	if not seen[inst] then
		seen[inst] = true
		counts[identity.businessId] = (counts[identity.businessId] or 0) + 1
		recordOriginals(inst)
	end
	if identity.businessId ~= activeBusinessId then
		hideModel(inst, identity.businessId)
	end
end

-- Number of cleanable spills a business has (for completion % / UI).
function SpillVisibility.getSpillCount(businessId: string): number
	return counts[businessId] or 0
end

-- Every spill of the active job still dirty on this client -- i.e. shown, not hidden. A spill is
-- hidden exactly when it's been fully mopped (or doesn't belong to the active job), so the
-- visible ones are precisely what's left. For the remaining-cleanables highlight.
function SpillVisibility.getActiveVisibleSpills(): { Model }
	local result: { Model } = {}
	if not activeBusinessId then
		return result
	end
	for model in seen do
		if not hidden[model] and model.Parent then
			local identity = SpillResolver.resolve(model)
			if identity and identity.businessId == activeBusinessId then
				table.insert(result, model)
			end
		end
	end
	return result
end

-- Hide a single spill that was just fully mopped on this client.
function SpillVisibility.hideOne(model: Model)
	local identity = SpillResolver.resolve(model)
	hideModel(model, if identity then identity.businessId else (activeBusinessId or ""))
end

-- Show one business's spills (dirty again -- transparency reset) and hide the previously-active
-- one's. Pass nil to hide all (no active job). Showing restores even spills mopped on a previous
-- run -- that's the redo.
function SpillVisibility.setActiveBusiness(businessId: string?)
	local oldId = activeBusinessId
	activeBusinessId = businessId

	if businessId then
		-- Reparent hidden spills back AND reset every one of this business's spills to dirty,
		-- covering both fully-mopped (hidden) and partly-mopped (still in place) ones.
		for model in seen do
			local identity = SpillResolver.resolve(model)
			-- resolve() fails for a hidden (off-world) model, so fall back to the recorded owner.
			local ownerId = if identity then identity.businessId else (hidden[model] and hidden[model].businessId)
			if ownerId == businessId then
				if hidden[model] then
					showModel(model)
				elseif model.Parent then
					resetTransparency(model)
				end
			end
		end
	end

	if oldId and oldId ~= businessId then
		local businesses = Workspace:FindFirstChild(Config.BusinessesFolderName)
		if businesses then
			for _, desc in businesses:GetDescendants() do
				if desc:IsA("Model") then
					local identity = SpillResolver.resolve(desc)
					if identity and identity.businessId == oldId then
						hideModel(desc, oldId)
					end
				end
			end
		end
	end
end

function SpillVisibility.init()
	-- Don't block the caller: the Businesses folder may not exist/replicate yet.
	task.spawn(function()
		local businesses = Workspace:WaitForChild(Config.BusinessesFolderName)
		for _, desc in businesses:GetDescendants() do
			consider(desc)
		end
		businesses.DescendantAdded:Connect(consider)
	end)
end

return SpillVisibility
