--!strict

-- Chat commands, parsed server-side off Player.Chatted (which still fires under the default
-- TextChatService), so nothing is exposed to the client.
--
-- Everything here is owner-only (OWNER_ID) EXCEPT the public commands listed first, which any
-- player may run -- they're player-facing features that happen to be typed rather than clicked, so
-- they live with the other chat parsing rather than in a second Chatted hook.
--
-- Public commands:
--   /skiptutorial
--     Ends the caller's tutorial immediately, exactly as finishing it does: the profile is marked
--     complete (so it never runs again) and every UI lock the current step had armed is dropped.
--     Does nothing if they aren't in the tutorial.
--
-- Owner-only commands:
--   /completejob <businessId> <amount>
--     Adds `amount` (default 1) to the player's lifetime Completions on <businessId>, which is
--     what drives job mastery (stars + the compounding XP boost -- see Mastery/BusinessService),
--     so mastery can be tested without grinding the clean. Bumps the tally only; it does NOT pay
--     the per-completion Cash/XP.
--   /addcash <amount>
--     Adds `amount` (default 1) Cash to the owner's balance for testing.
--   /addgems <amount>
--     Adds `amount` (default 1) Gems to the owner's balance for testing. Granted literally, NOT
--     through ProgressionService.awardGems -- an admin grant shouldn't be silently inflated by the
--     Hoarding skill when you asked for an exact number.
--   /setlevel <level>
--     Sets the owner's level outright (and zeroes XP, which counts WITHIN a level -- see Leveling),
--     so level-gated content can be reached without grinding XP. Goes down as well as up.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local BusinessConfig = require(ReplicatedStorage.SharedModules.BusinessConfig)
local ProgressionService = require(script.Parent.ProgressionService)
local TutorialService = require(script.Parent.TutorialService)

local AdminCommands = {}

-- Roblox UserId permitted to run commands. Everyone else's chat is ignored.
local OWNER_ID = 168921043
-- Cap a single command so a typo can't balloon the tally.
local MAX_AMOUNT = 10000000
-- Ceiling for /setlevel, purely so a fat-fingered number can't push the profile somewhere
-- absurd. Nothing in Leveling caps the real progression.
local MAX_PLAYER_LEVEL = 1000

-- /completejob <businessId> <amount>: add `amount` completions to the business's tally.
local function completeJob(player: Player, businessId: string?, amountText: string?)
	if type(businessId) ~= "string" or not BusinessConfig[businessId] then
		warn(string.format("[AdminCommands] /completejob: unknown business %q", tostring(businessId)))
		return
	end
	local amount = math.floor(tonumber(amountText) or 1)
	amount = math.clamp(amount, 1, MAX_AMOUNT)

	DataService:update(player, { "BusinessList", businessId, "Completions" }, function(current: number?)
		return (current or 0) + amount
	end)
	print(string.format("[AdminCommands] +%d completions on %s for %s", amount, businessId, player.Name))
end

-- /addcash <amount>: add `amount` Cash to the owner's balance.
local function addCash(player: Player, amountText: string?)
	local amount = math.floor(tonumber(amountText) or 1)
	amount = math.clamp(amount, 1, MAX_AMOUNT)

	DataService:update(player, { "Cash" }, function(current: number?)
		return (current or 0) + amount
	end)
	print(string.format("[AdminCommands] +%d cash for %s", amount, player.Name))
end

-- /addgems <amount>: add `amount` Gems to the owner's balance. Written straight to the balance
-- rather than through ProgressionService.awardGems, which would scale the amount by the Hoarding
-- skill -- a test grant should land on exactly the number that was typed.
local function addGems(player: Player, amountText: string?)
	local amount = math.floor(tonumber(amountText) or 1)
	amount = math.clamp(amount, 1, MAX_AMOUNT)

	DataService:update(player, { "Gems" }, function(current: number?)
		return (current or 0) + amount
	end)
	print(string.format("[AdminCommands] +%d gems for %s", amount, player.Name))
end

-- /setlevel <level>: set the owner's level outright, clearing XP. XP is progress WITHIN the current
-- level (Leveling.addXp counts it from 0 toward xpForLevel), so carrying the old value over would
-- leave the player part-way through a level they never earned -- and if it exceeded the new level's
-- requirement, the next XP award would instantly re-level them.
--
-- Writing the whole { "Level" } table is also what makes this take effect everywhere: BusinessService
-- watches that path and re-resolves business unlocks, so levelling up here grants any business whose
-- RequiredLevel is now met. Note that unlocks are never revoked, so setting the level back DOWN
-- leaves already-granted businesses unlocked.
local function setLevel(player: Player, levelText: string?)
	local level = tonumber(levelText)
	if not level then
		warn(string.format("[AdminCommands] /setlevel: expected a number, got %q", tostring(levelText)))
		return
	end
	level = math.clamp(math.floor(level), 1, MAX_PLAYER_LEVEL)

	DataService:set(player, { "Level" }, { CurrentLevel = level, XP = 0 })
	print(string.format("[AdminCommands] set %s to level %d", player.Name, level))
end

local function onChatted(player: Player, message: string)
	-- Tokenize on whitespace runs (tolerates extra spaces): {command, arg1, arg2, ...}.
	local tokens = {}
	for token in string.gmatch(message, "%S+") do
		table.insert(tokens, token)
	end

	local command = string.lower(tokens[1] or "")

	-- Public commands, handled before the owner gate.
	if command == "/skiptutorial" then
		TutorialService.skip(player)
		return
	end

	if player.UserId ~= OWNER_ID then
		return
	end

	if command == "/completejob" then
		completeJob(player, tokens[2], tokens[3])
	elseif command == "/addcash" then
		addCash(player, tokens[2])
	elseif command == "/addgems" then
		addGems(player, tokens[2])
	elseif command == "/setlevel" then
		setLevel(player, tokens[2])
	end
end

function AdminCommands.init()
	local function hook(player: Player)
		player.Chatted:Connect(function(message)
			onChatted(player, message)
		end)
	end
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)
end

return AdminCommands
