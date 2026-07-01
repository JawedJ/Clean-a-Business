--!strict

-- Central library for playing cosmetic sounds. Lives in ReplicatedStorage so any
-- context can require it, BUT playback is CLIENT-EXECUTED only: a one-shot is
-- played 2D for the local player. If the SERVER played one by parenting a Sound
-- into the world it would be audible to everyone, so playback guards against the
-- server. For a server-triggered sound, fire a RemoteEvent to the target client
-- and have a client-side listener call into here.
--
-- Sounds are looked up by name under ReplicatedStorage.Audios. Two flavours:
--   * playOneShot: fire-and-forget. Clones the template, plays it 2D, and destroys
--     the clone once it finishes. Pass { duration = n } to play only the first n
--     seconds, stopping (and cleaning up) early.
--   * createSustained: returns a controllable handle (start/stop/destroy) for a
--     looping sound, e.g. a tool's firing loop. Optionally loops only a slice of
--     the source by holding playback inside [loopStart, loopEnd].

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local ContentProvider = game:GetService("ContentProvider")

-- Folder under ReplicatedStorage holding the Sound templates.
local AUDIOS_FOLDER = "Audios"
-- Backstop cleanup if a clone's Ended never fires (e.g. the asset failed to load).
local MAX_LIFETIME = 30

-- A controllable looping sound. All methods are safe to call repeatedly and on a
-- handle whose template was missing (in which case they're no-ops).
export type SustainedSound = {
	start: () -> (),
	stop: () -> (),
	destroy: () -> (),
}

-- Options for createSustained. loopStart/loopEnd (seconds) restrict looping to a
-- slice of the source; omit both to loop the whole sound. preload defaults to true.
export type SustainedConfig = {
	loopStart: number?,
	loopEnd: number?,
	preload: boolean?,
}

-- Options for playOneShot. startTime (seconds) begins playback partway into the source
-- instead of at 0. duration (seconds) cuts playback short, stopping and destroying the
-- clone after that long; omit both to play the whole sound from the start.
export type OneShotConfig = {
	startTime: number?,
	duration: number?,
}

local SoundManager = {}

-- Resolves a Sound template by name under ReplicatedStorage.Audios, warning (and
-- returning nil) if it's missing so a typo can't crash the caller.
local function findTemplate(soundName: string): Sound?
	local audios = ReplicatedStorage:FindFirstChild(AUDIOS_FOLDER)
	local template = audios and audios:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then
		warn(`SoundManager: no Sound named '{soundName}' under ReplicatedStorage.{AUDIOS_FOLDER}`)
		return nil
	end
	return template
end

-- Plays the named sound once, 2D, for the local player. No-op (with a warning) if
-- the template is missing so a typo can't crash the caller. Pass a config with a
-- duration to play only the first `duration` seconds.
function SoundManager.playOneShot(soundName: string, config: OneShotConfig?)
	-- Client-only: a server-played sound would be heard by everyone.
	if not RunService:IsClient() then
		warn("SoundManager.playOneShot called on the server; sounds must play on the client")
		return
	end

	local template = findTemplate(soundName)
	if not template then
		return
	end

	local sound = template:Clone()
	sound.Looped = false
	sound.Parent = SoundService -- 2D playback for this client only
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, MAX_LIFETIME) -- safety net if Ended never fires
	sound:Play()

	-- Skip into the source if asked (set after Play so it isn't reset on playback start).
	local startTime = config and config.startTime
	if startTime then
		sound.TimePosition = startTime
	end

	-- Cut playback short if asked: Stop() doesn't fire Ended, so destroy here too.
	local duration = config and config.duration
	if duration then
		task.delay(duration, function()
			if sound.Parent then
				sound:Stop()
				sound:Destroy()
			end
		end)
	end
end

-- A handle whose methods do nothing; returned when a sustained sound can't be set
-- up, so callers never need nil checks.
local NOOP_SUSTAINED: SustainedSound = {
	start = function() end,
	stop = function() end,
	destroy = function() end,
}

-- Creates a controllable 2D looping sound for the local player. Returns a handle
-- with start/stop/destroy; the clone is created (and preloaded) up front so the
-- first start() doesn't hitch. Returns a no-op handle if not on the client or the
-- template is missing.
function SoundManager.createSustained(soundName: string, config: SustainedConfig?): SustainedSound
	if not RunService:IsClient() then
		warn("SoundManager.createSustained called on the server; sounds must play on the client")
		return NOOP_SUSTAINED
	end

	local cfg = config or {}
	local template = findTemplate(soundName)
	if not template then
		return NOOP_SUSTAINED
	end

	local sound = template:Clone()
	sound.Looped = true
	sound.Parent = SoundService -- 2D playback for this client only

	if cfg.preload ~= false then
		-- Decode now (during the startup window) so the first Play() doesn't trigger
		-- a one-off decode spike mid-game.
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync({ sound })
			end)
		end)
	end

	local loopStart, loopEnd = cfg.loopStart, cfg.loopEnd
	local maintainConn: RBXScriptConnection? = nil

	-- While playing, hold playback inside the [loopStart, loopEnd] slice by snapping
	-- TimePosition back to the start whenever it drifts past the slice.
	local function startMaintain()
		if not (loopStart and loopEnd) or maintainConn then
			return
		end
		maintainConn = RunService.Heartbeat:Connect(function()
			if sound.IsPlaying and (sound.TimePosition >= loopEnd or sound.TimePosition < loopStart) then
				sound.TimePosition = loopStart
			end
		end)
	end
	local function stopMaintain()
		if maintainConn then
			maintainConn:Disconnect()
			maintainConn = nil
		end
	end

	return {
		start = function()
			if not sound.IsPlaying then
				if loopStart then
					sound.TimePosition = loopStart
				end
				sound:Play()
				startMaintain()
			end
		end,
		stop = function()
			if sound.IsPlaying then
				sound:Stop()
			end
			stopMaintain()
		end,
		destroy = function()
			stopMaintain()
			sound:Destroy()
		end,
	}
end

return SoundManager
