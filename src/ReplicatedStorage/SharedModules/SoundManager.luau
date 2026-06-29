--!strict

-- Central library for playing cosmetic sounds. Lives in ReplicatedStorage so any
-- context can require it, BUT playback is CLIENT-EXECUTED only: a one-shot is
-- played 2D for the local player. If the SERVER played one by parenting a Sound
-- into the world it would be audible to everyone, so playback guards against the
-- server. For a server-triggered sound, fire a RemoteEvent to the target client
-- and have a client-side listener call into here.
--
-- Sounds are looked up by name under ReplicatedStorage.Audios. Each one-shot is
-- fire-and-forget: it clones the template, plays it 2D via SoundService, and
-- destroys the clone once it finishes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

-- Folder under ReplicatedStorage holding the Sound templates.
local AUDIOS_FOLDER = "Audios"
-- Backstop cleanup if a clone's Ended never fires (e.g. the asset failed to load).
local MAX_LIFETIME = 30

local SoundManager = {}

-- Plays the named sound once, 2D, for the local player. No-op (with a warning) if
-- the template is missing so a typo can't crash the caller.
function SoundManager.playOneShot(soundName: string)
	-- Client-only: a server-played sound would be heard by everyone.
	if not RunService:IsClient() then
		warn("SoundManager.playOneShot called on the server; sounds must play on the client")
		return
	end

	local audios = ReplicatedStorage:FindFirstChild(AUDIOS_FOLDER)
	local template = audios and audios:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then
		warn(`SoundManager: no Sound named '{soundName}' under ReplicatedStorage.{AUDIOS_FOLDER}`)
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
end

return SoundManager
