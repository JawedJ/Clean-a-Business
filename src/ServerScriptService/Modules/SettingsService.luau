--!strict

-- Server authority for the player's persisted client settings (music / SFX volume, driven by the
-- client's SettingsUiController). The client applies volume changes locally for instant feedback,
-- but the client's own DataService writes don't replicate or save -- so to REMEMBER a setting the
-- client fires UpdateSetting on release and this re-validates and writes it through DataService,
-- which persists it to the profile (and replicates the confirmed value back).
--
-- Only the known setting keys are accepted, and each is coerced to its expected type/range before
-- saving (volumes clamped to 0..1, HidePlayers forced to a boolean), so a client can never stuff
-- an arbitrary key or an out-of-range/wrong-typed value into its save.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService).server

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateSetting = Remotes:WaitForChild("UpdateSetting") :: RemoteEvent

local SettingsService = {}

-- The settings a client is allowed to write, matching the keys under DataTemplate.Settings. Each
-- sanitizer validates + coerces the raw client value, returning the value to save or nil to reject.
local SANITIZERS: { [string]: (value: unknown) -> unknown? } = {
	-- Volumes: a real number (reject NaN) clamped into range.
	MusicVolume = function(value)
		return if type(value) == "number" and value == value then math.clamp(value, 0, 1) else nil
	end,
	SFXVolume = function(value)
		return if type(value) == "number" and value == value then math.clamp(value, 0, 1) else nil
	end,
	-- Hide-other-players toggle: must arrive as a boolean.
	HidePlayers = function(value)
		return if type(value) == "boolean" then value else nil
	end,
}

-- Persist one setting for the player. Ignores unknown keys and values that fail their sanitizer.
local function onUpdate(player: Player, key: unknown, value: unknown)
	if type(key) ~= "string" then
		return
	end
	local sanitizer = SANITIZERS[key]
	if not sanitizer then
		return
	end
	local clean = sanitizer(value)
	if clean == nil then
		return
	end
	DataService:set(player, { "Settings", key }, clean)
end

function SettingsService.init()
	UpdateSetting.OnServerEvent:Connect(onUpdate)
end

return SettingsService
