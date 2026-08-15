--!strict

-- Shared client-side answer to "what does this business demand of me, and what does it pay?", plus
-- the two authored displays that show it: the level-gate label and the RequiredItems icon row.
--
-- Two screens ask the same questions of the same business, and must answer them identically:
--   * the JOB BOARD (JobUiController), where a TaskDesign row shows a business's requirements and
--     rewards and offers Wash only once they're met, and
--   * the PARTY BROWSER (PartyUiController), where a PartySlot shows the requirements and rewards of
--     the business someone else's party formed around, and offers Join on the same terms.
-- Keeping the predicates and the painters here is what stops those two drifting -- a row that says
-- green while the other says red, or a Join button that offers a party the job would then refuse.
--
-- Everything is read live from the player's replicated data (DataService), so callers just re-run a
-- painter when something changes rather than caching gate state.
--
-- The server enforces all of this again at accept/join time (BusinessService.canPlay) -- these are
-- the DISPLAY and the click guard, never the authority.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BusinessConfig = require(ReplicatedStorage.SharedModules.BusinessConfig)
local Mastery = require(ReplicatedStorage.SharedModules.Mastery)
local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local SkillsConfig = require(ReplicatedStorage.SharedModules.SkillsConfig)
local ToolConfig = require(ReplicatedStorage.SharedModules.ToolConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).client

local localPlayer = Players.LocalPlayer

local BusinessGates = {}

-- Requirement colors, shared by the level-gate label and the RequiredItems icons: green once the
-- player meets the gate (level reached / tool owned), the authored red-orange (matching the
-- Studio-authored default) while they don't.
BusinessGates.MET_COLOR = Color3.fromRGB(78, 214, 94)
BusinessGates.UNMET_COLOR = Color3.fromRGB(225, 62, 30)

-- How many Item{n} icon slots a RequiredItems frame authors. A business shows one slot per tool in
-- its BusinessConfig.RequiredItems (in order) and hides the rest, so a two-tool business lights up
-- Item1 + Item2 only.
local MAX_REQUIRED_ITEM_SLOTS = 5

-- BusinessList only holds records for businesses the player has, so index it defensively:
-- a not-yet-unlocked business simply has no entry (and so counts as locked).
function BusinessGates.isUnlocked(businessId: string): boolean
	local list = DataService:get({ "BusinessList" })
	local record = if type(list) == "table" then list[businessId] else nil
	return type(record) == "table" and record.Unlocked == true
end

-- Lifetime completions the player has on a business, read the same defensive way as isUnlocked
-- (BusinessList only holds records for businesses they have). 0 if there's no record yet.
function BusinessGates.completionsFor(businessId: string): number
	local list = DataService:get({ "BusinessList" })
	local record = if type(list) == "table" then list[businessId] else nil
	local count = if type(record) == "table" then record.Completions else nil
	return if type(count) == "number" then count else 0
end

-- The player's current multiplier for a gem-purchased skill (1.0 with none bought), read from
-- their replicated Skills data. Lets the UI predict the boosted reward a completion will pay,
-- matching what ProgressionService credits server-side.
function BusinessGates.skillMultiplier(skillName: string): number
	local level = DataService:get({ "Skills", skillName })
	return SkillsConfig.multiplier(skillName, if type(level) == "number" then level else 0)
end

-- The local player's current level (defaults to 1 before Level data is available).
function BusinessGates.playerLevel(): number
	local level = DataService:get({ "Level" })
	local current = if type(level) == "table" then level.CurrentLevel else nil
	return if type(current) == "number" then current else 1
end

-- Minimum level a business needs to be accepted (BusinessConfig.RequiredLevel, defaulting to 1).
function BusinessGates.requiredLevelFor(businessId: string): number
	local def = BusinessConfig[businessId]
	return (def and def.RequiredLevel) or 1
end

-- Tool UniqueIDs a business needs to be accepted, in display order. Empty when the business
-- declares no BusinessConfig.RequiredItems (no tool gate).
function BusinessGates.requiredItemsFor(businessId: string): { string }
	local def = BusinessConfig[businessId]
	return (def and def.RequiredItems) or {}
end

-- Whether the player owns a tool. Inventory records are seeded from the ToolConfig catalog, so a
-- missing record just means not-yet-owned -- read it as defensively as isUnlocked does.
function BusinessGates.ownsItem(toolId: string): boolean
	return DataService:get({ "Inventory", toolId, "Unlocked" }) == true
end

-- Whether the player may play this business right now: it's unlocked, they're high enough level,
-- and they own every tool it requires. The single predicate behind both the board's Wash button and
-- the party browser's Join button, so those can never disagree with each other -- or with the
-- server, which enforces the same three gates in BusinessService.canPlay.
function BusinessGates.canPlay(businessId: string): boolean
	if not BusinessGates.isUnlocked(businessId) or BusinessGates.playerLevel() < BusinessGates.requiredLevelFor(businessId) then
		return false
	end
	for _, toolId in BusinessGates.requiredItemsFor(businessId) do
		if not BusinessGates.ownsItem(toolId) then
			return false
		end
	end
	return true
end

-- Paint a level-gate line: text from the business's RequiredLevel, green when the player meets it
-- and red-orange while they're still short.
function BusinessGates.paintRequirements(label: TextLabel, businessId: string)
	local required = BusinessGates.requiredLevelFor(businessId)
	label.Text = string.format("REQUIRED: Level %d", required)
	label.TextColor3 = if BusinessGates.playerLevel() >= required
		then BusinessGates.MET_COLOR
		else BusinessGates.UNMET_COLOR
end

-- Paint a RequiredItems frame: one slot per tool the business requires, showing that tool's catalog
-- icon over a green background when the player owns it and red while they don't. Unused slots (a
-- business needing fewer tools than the frame authors) are hidden.
function BusinessGates.paintRequiredItems(frame: Frame, businessId: string)
	local required = BusinessGates.requiredItemsFor(businessId)
	for slot = 1, MAX_REQUIRED_ITEM_SLOTS do
		local slotFrame = frame:FindFirstChild("Item" .. slot) :: Frame?
		local toolId = required[slot]
		if slotFrame then
			slotFrame.Visible = toolId ~= nil
			if toolId then
				slotFrame.BackgroundColor3 = if BusinessGates.ownsItem(toolId)
					then BusinessGates.MET_COLOR
					else BusinessGates.UNMET_COLOR
				local icon = slotFrame:FindFirstChild("ImageLabel") :: ImageLabel?
				local def = ToolConfig[toolId]
				if icon and def and def.Image then
					icon.Image = def.Image
				end
			end
		end
	end
end

-- The "$cash    +xp EXP" line a completion of this business will pay the LOCAL player: cash boosted
-- by their Greed skill, XP by both their mastery star level on this business and their Inteligence
-- skill -- matching what JobServer.complete + ProgressionService actually credit. Empty for a
-- business with no catalog entry.
function BusinessGates.rewardsText(businessId: string): string
	local def = BusinessConfig[businessId]
	if not def then
		return ""
	end
	local stars = Mastery.starsForCompletions(BusinessGates.completionsFor(businessId))
	local cash = math.floor(def.BaseReward * BusinessGates.skillMultiplier("Greed"))
	local xp = math.floor(def.XpReward * Mastery.xpMultiplier(stars) * BusinessGates.skillMultiplier("Inteligence"))
	return string.format("$%s    +%s EXP", NumberFormat.commas(cash), NumberFormat.commas(xp))
end

-- A business's display name, from the catalog. Falls back to the id so a UI line never renders
-- blank for a business the catalog is missing.
function BusinessGates.displayName(businessId: string): string
	local def = BusinessConfig[businessId]
	return (def and def.Name) or businessId
end

-- A business's artwork, taken from the job board's own row for it (TaskDesign.BusinessImg, keyed by
-- the row's BusinessId attribute). The image lives on the authored row rather than in BusinessConfig,
-- so anything that wants to picture a business -- the party screen's JobImg -- reads it from there,
-- and re-arting a business stays a one-place change in Studio. "" when there's no such row.
function BusinessGates.imageFor(screenGui: Instance, businessId: string): string
	local jobFrame = screenGui:FindFirstChild("JobFrame")
	local scroll = jobFrame and jobFrame:FindFirstChild("ScrollingFrame")
	if not scroll then
		return ""
	end
	for _, row in scroll:GetChildren() do
		if row:GetAttribute("BusinessId") == businessId then
			local image = row:FindFirstChild("BusinessImg") :: ImageLabel?
			return if image then image.Image else ""
		end
	end
	return ""
end

-- Every DataService path that can change a gate or a predicted reward: unlocking a business, gaining
-- a level, buying a tool, buying a Greed/Inteligence skill. Callers subscribe to all of them to keep
-- their rows live -- one list, so no screen forgets one and goes stale.
function BusinessGates.onChanged(callback: () -> ()): { RBXScriptConnection }
	local connections: { RBXScriptConnection } = {}
	for _, path in { "BusinessList", "Level", "Inventory", "Skills" } do
		table.insert(connections, DataService:getChangedSignal({ path }):Connect(callback))
	end
	return connections
end

return BusinessGates
