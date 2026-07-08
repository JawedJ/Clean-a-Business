--!strict

-- Server authority for the player's persisted client settings (music / SFX volume, driven by the
-- client's SettingsUiController). The client applies volume changes locally for instant feedback,
-- but the client's own DataService writes don't replicate or save -- so to REMEMBER a setting the
-- client fires UpdateSetting on release and this re-validates and writes it through DataService,
-- which persists it to the profile (and replicates the confirmed value back).
--
-- Only the known setting keys are accepted and every value is clamped to 0..1, so a client can
-- never stuff an arbitrary key or an out-of-range volume into its save.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateSetting = Remotes:WaitForChild("UpdateSetting") :: RemoteEvent

local SettingsService = {}

-- The settings a client is allowed to write, matching the keys under DataTemplate.Settings.
local VALID_KEYS: { [string]: boolean } = {
	MusicVolume = true,
	SFXVolume = true,
}

-- Persist one setting for the player. Ignores unknown keys and non-numbers (incl. NaN); clamps
-- the value to 0..1 so the saved volume is always in range regardless of what the client sent.
local function onUpdate(player: Player, key: unknown, value: unknown)
	if type(key) ~= "string" or not VALID_KEYS[key] then
		return
	end
	if type(value) ~= "number" or value ~= value then
		return
	end
	DataService:set(player, { "Settings", key }, math.clamp(value, 0, 1))
end

function SettingsService.init()
	UpdateSetting.OnServerEvent:Connect(onUpdate)
end

return SettingsService
