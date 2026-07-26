--!strict

-- Server authority for the player's persisted business description (the DescriptionEditableTxt box
-- in the Company UI). Mirrors SettingsService: the client edits the box locally for instant
-- feedback, but a client's own DataService writes neither replicate nor save -- so to REMEMBER the
-- text the client fires UpdateBusinessDescription on focus-lost and this re-validates and writes it
-- through DataService, which persists it and replicates the confirmed value back.
--
-- The raw value is coerced to a string, trimmed, and capped at MAX_LENGTH so a client can't stuff a
-- non-string or an unbounded blob into its profile.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateBusinessDescription = Remotes:WaitForChild("UpdateBusinessDescription") :: RemoteEvent

-- Longest description we persist. The box is small; this just bounds what a client can write.
local MAX_LENGTH = 200

local CompanyService = {}

-- Trim leading/trailing whitespace so an all-spaces submission saves as empty (-> placeholder).
local function trim(text: string): string
	return (text:gsub("^%s*(.-)%s*$", "%1"))
end

local function onUpdate(player: Player, value: unknown)
	if type(value) ~= "string" then
		return
	end
	local clean = trim(value)
	if #clean > MAX_LENGTH then
		clean = clean:sub(1, MAX_LENGTH)
	end
	DataService:set(player, { "BusinessDescription" }, clean)
end

function CompanyService.init()
	UpdateBusinessDescription.OnServerEvent:Connect(onUpdate)
end

return CompanyService
