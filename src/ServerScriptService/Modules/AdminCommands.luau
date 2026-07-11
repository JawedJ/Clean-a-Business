--!strict

-- Owner-only chat commands for dev/testing. Parsed server-side off Player.Chatted (which still
-- fires under the default TextChatService), so nothing is exposed to the client and only the
-- OWNER_ID can trigger anything.
--
-- Commands:
--   /completejob <businessId> <amount>
--     Adds `amount` (default 1) to the player's lifetime Completions on <businessId>, which is
--     what drives job mastery (stars + the compounding XP boost -- see Mastery/BusinessService),
--     so mastery can be tested without grinding the clean. Bumps the tally only; it does NOT pay
--     the per-completion Cash/XP.
--   /addcash <amount>
--     Adds `amount` (default 1) Cash to the owner's balance for testing.
--   /addcash <amount>
--     Adds `amount` (default 1) Cash to the owner's balance for testing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local BusinessConfig = require(ReplicatedStorage.SharedModules.BusinessConfig)
local ProgressionService = require(script.Parent.ProgressionService)

local AdminCommands = {}

-- Roblox UserId permitted to run commands. Everyone else's chat is ignored.
local OWNER_ID = 168921043
-- Cap a single command so a typo can't balloon the tally.
local MAX_AMOUNT = 100000

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

local function onChatted(player: Player, message: string)
	if player.UserId ~= OWNER_ID then
		return
	end

	-- Tokenize on whitespace runs (tolerates extra spaces): {command, arg1, arg2, ...}.
	local tokens = {}
	for token in string.gmatch(message, "%S+") do
		table.insert(tokens, token)
	end

	local command = string.lower(tokens[1] or "")
	if command == "/completejob" then
		completeJob(player, tokens[2], tokens[3])
	elseif command == "/addcash" then
		addCash(player, tokens[2])
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
