--!strict

-- Owns the visibility of every cleanable web on the LOCAL client. Webs are shared, server-authored
-- instances replicated to everyone -- but a player should only SEE a business's webs while they're
-- on that business's job. So by default this hides every web (reparenting it off-world, which also
-- makes it non-raycastable) and shows a business's webs only while it is the active job. Vacuuming
-- a web hides it again (per-client), and re-accepting the job shows them all for a clean redo.
--
-- Mirrors DecalVisibility: webs are cleaned WHOLESALE (a server timer removes them, like stains),
-- not faded like spills, so there's no per-part transparency to snapshot/restore. Unlike stains a
-- web may be a single BasePart or a Model, so we work in Instances (the direct child of the
-- CleanableWebs folder) rather than Models specifically.
--
-- Reparenting (rather than destroying) keeps the shared server instance and its authored CFrame
-- intact, so it can be restored exactly and stays in place server-side for the authoritative
-- timer/validation.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local WebResolver = require(ReplicatedStorage.SharedModules.WebResolver)

local WebVisibility = {}

-- Off-world holder for hidden webs. Its Parent stays nil so its contents aren't rendered or
-- raycastable; this module's reference keeps them alive across jobs.
local holder = Instance.new("Folder")
holder.Name = "HiddenWebs"

-- Each hidden web -> where it came from + which business it belongs to.
local hidden: { [Instance]: { parent: Instance, businessId: string } } = {}
-- Every web we've seen (so we count each once) + the per-business totals (for UI).
local seen: { [Instance]: boolean } = {}
local counts: { [string]: number } = {}

-- The business whose webs are currently shown, or nil (none shown).
local activeBusinessId: string? = nil

-- True if `inst` is a web authored directly in a CleanableWebs folder (the resolver only accepts
-- the folder's direct child, so this ignores a web's inner parts -- each web is considered once).
local function isWebRoot(inst: Instance): boolean
	local parent = inst.Parent
	return parent ~= nil and parent.Name == Config.WebsFolderName
end

local function hideWeb(web: Instance, businessId: string)
	if hidden[web] then
		return
	end
	local parent = web.Parent
	if not parent then
		return
	end
	hidden[web] = { parent = parent, businessId = businessId }
	web.Parent = holder
end

local function showWeb(web: Instance)
	local info = hidden[web]
	if info then
		web.Parent = info.parent
		hidden[web] = nil
	end
end

-- Inspect an instance: if it's a cleanable web (a direct child of a CleanableWebs folder), count it
-- once and hide it unless its business is the active job. Used on the initial scan and stream-ins.
local function consider(inst: Instance)
	if not isWebRoot(inst) then
		return
	end
	local identity = WebResolver.resolve(inst)
	if not identity then
		return
	end
	if not seen[inst] then
		seen[inst] = true
		counts[identity.businessId] = (counts[identity.businessId] or 0) + 1
	end
	if identity.businessId ~= activeBusinessId then
		hideWeb(inst, identity.businessId)
	end
end

-- Number of cleanable webs a business has (for completion % / UI).
function WebVisibility.getWebCount(businessId: string): number
	return counts[businessId] or 0
end

-- Every web of the active job still dirty on this client -- i.e. shown, not hidden. A web is hidden
-- exactly when it's been cleaned (or doesn't belong to the active job), so the visible ones are
-- precisely what's left to clean. For the remaining-cleanables highlight.
function WebVisibility.getActiveVisibleWebs(): { Instance }
	local result: { Instance } = {}
	if not activeBusinessId then
		return result
	end
	for web in seen do
		-- Skip hidden (cleaned) webs and any that have since been destroyed (Parent nil).
		if not hidden[web] and web.Parent then
			local identity = WebResolver.resolve(web)
			if identity and identity.businessId == activeBusinessId then
				table.insert(result, web)
			end
		end
	end
	return result
end

-- Hide a single web that was just cleaned on this client.
function WebVisibility.hideOne(web: Instance)
	local identity = WebResolver.resolve(web)
	hideWeb(web, if identity then identity.businessId else (activeBusinessId or ""))
end

-- Show one business's webs and hide the previously-active one's. Pass nil to hide all (no active
-- job). Showing restores even webs cleaned on a previous run -- that's the redo.
function WebVisibility.setActiveBusiness(businessId: string?)
	local oldId = activeBusinessId
	activeBusinessId = businessId

	if businessId then
		for web, info in hidden do
			if info.businessId == businessId then
				showWeb(web)
			end
		end
	end

	if oldId and oldId ~= businessId then
		local businesses = Workspace:FindFirstChild(Config.BusinessesFolderName)
		if businesses then
			for _, desc in businesses:GetDescendants() do
				if isWebRoot(desc) then
					local identity = WebResolver.resolve(desc)
					if identity and identity.businessId == oldId then
						hideWeb(desc, oldId)
					end
				end
			end
		end
	end
end

function WebVisibility.init()
	-- Don't block the caller: the Businesses folder may not exist/replicate yet.
	task.spawn(function()
		local businesses = Workspace:WaitForChild(Config.BusinessesFolderName)
		for _, desc in businesses:GetDescendants() do
			consider(desc)
		end
		businesses.DescendantAdded:Connect(consider)
	end)
end

return WebVisibility
