--!strict

-- Plays a continuous background-music playlist for the local player, 2D.
--
-- Every Sound under ReplicatedStorage.Audios.BackgroundMusic is a track. Tracks
-- are played one at a time, back to back, forever, cycling through the folder (in
-- a shuffled order each pass so it doesn't sound the same every session).
--
-- Transitions: each track eases IN over its first FADE seconds (from silent up to
-- the template's authored Volume) and eases OUT over its last FADE seconds (back
-- down to silent) before the next track begins. This is client-only playback --
-- like the rest of SoundManager, music parented on the server would be heard by
-- everyone.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")

local SoundGroups = require(ReplicatedStorage.SharedModules.SoundGroups)

-- Length of the fade-in and fade-out ramps, in seconds.
local FADE = 4
-- Fallback volume if a template doesn't set one (Roblox default is 0.5).
local DEFAULT_VOLUME = 0.5
-- How long to wait for a freshly-played track to report a real TimeLength before
-- giving up on it (asset failed to load / bad id) and moving on.
local LOAD_TIMEOUT = 10

local BackgroundMusicController = {}

-- Collects the Sound templates under Audios.BackgroundMusic, or an empty list
-- (with a warning) if the folder is missing.
local function getTracks(): { Sound }
	local audios = ReplicatedStorage:FindFirstChild("Audios")
	local folder = audios and audios:FindFirstChild("BackgroundMusic")
	if not folder then
		warn("BackgroundMusicController: no folder ReplicatedStorage.Audios.BackgroundMusic")
		return {}
	end

	local tracks: { Sound } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("Sound") then
			table.insert(tracks, child)
		end
	end
	return tracks
end

-- Returns a shuffled copy of the list (Fisher-Yates) so playback order varies.
local function shuffled(list: { Sound }): { Sound }
	local copy = table.clone(list)
	for i = #copy, 2, -1 do
		local j = math.random(1, i)
		copy[i], copy[j] = copy[j], copy[i]
	end
	return copy
end

-- Fades a sound's Volume to `target` over `duration` seconds and waits for it to
-- finish (linearly; music volume reads best as a straight ramp).
local function fadeTo(sound: Sound, target: number, duration: number)
	if duration <= 0 then
		sound.Volume = target
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(duration, Enum.EasingStyle.Linear), { Volume = target })
	tween:Play()
	tween.Completed:Wait()
end

-- Plays one track start to finish: clone it, ease in, hold, then ease out over the
-- last FADE seconds. Blocks until the track is done (or is skipped for failing to
-- load). Returns once it's safe to start the next track.
local function playTrack(template: Sound)
	local fullVolume = template.Volume
	if fullVolume <= 0 then
		fullVolume = DEFAULT_VOLUME
	end

	local sound = template:Clone()
	sound.Looped = false
	sound.Volume = 0
	sound.SoundGroup = SoundGroups.getMusicGroup() -- scale by the player's music master volume
	sound.Parent = SoundService -- 2D playback for this client only
	sound:Play()

	-- Wait for the asset to decode so TimeLength is real; bail if it never loads.
	local waited = 0
	while sound.TimeLength <= 0 and waited < LOAD_TIMEOUT do
		waited += RunService.Heartbeat:Wait()
	end
	local length = sound.TimeLength
	if length <= 0 then
		warn(`BackgroundMusicController: track '{template.Name}' failed to load; skipping`)
		sound:Destroy()
		return
	end

	-- Short tracks can't fit two full FADE ramps; split the length between them.
	local ramp = math.min(FADE, length / 2)

	fadeTo(sound, fullVolume, ramp) -- ease in

	-- Hold at full volume until only `ramp` seconds remain, watching TimePosition
	-- (robust against playback lag) and stopping early if we've been told to.
	while sound.IsPlaying and sound.TimePosition < length - ramp do
		RunService.Heartbeat:Wait()
	end

	if sound.IsPlaying then
		fadeTo(sound, 0, ramp) -- ease out
	end
	sound:Destroy()
end

function BackgroundMusicController.init()
	if not RunService:IsClient() then
		return
	end

	local tracks = getTracks()
	if #tracks == 0 then
		return
	end

	-- Decode the tracks up front so the first fade-in isn't stalled waiting on load.
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(tracks)
		end)
	end)

	task.spawn(function()
		-- Reseed so the shuffle isn't identical across clients/sessions.
		math.randomseed(os.clock() * 1e6 + Players.LocalPlayer.UserId)
		while true do
			for _, template in shuffled(tracks) do
				playTrack(template)
			end
		end
	end)
end

return BackgroundMusicController
