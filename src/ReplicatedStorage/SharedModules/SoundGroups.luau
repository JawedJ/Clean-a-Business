--!strict

-- Master volume routing for the local player's audio. Two SoundGroups live under SoundService:
-- "SFXGroup" (every SoundManager one-shot/sustained clone) and "MusicGroup" (every
-- BackgroundMusicController track). A Sound routed into a group plays at Sound.Volume *
-- group.Volume, so setting a group's Volume scales EVERY sound in it at once -- including ones
-- already playing -- which is exactly what the settings sliders want (drag = live remix).
--
-- The group Volume is the 0..1 master multiplier the player picks; individual sounds keep their
-- own authored Volume (and the music fades still tween Sound.Volume) underneath it. Client-only:
-- the groups are a local playback concern, created lazily the first time they're needed so a
-- server require of a module that pulls this in doesn't spawn stray instances.

local SoundService = game:GetService("SoundService")

local SoundGroups = {}

local SFX_GROUP_NAME = "SFXGroup"
local MUSIC_GROUP_NAME = "MusicGroup"

-- Resolve (or create once) a SoundGroup by name under SoundService. Reuses an existing one so a
-- re-require or a group left over from a previous run isn't duplicated.
local function ensureGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end
	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Volume = 1
	group.Parent = SoundService
	return group
end

-- The SoundGroup every SFX clone should route into (SoundManager sets sound.SoundGroup to this).
function SoundGroups.getSfxGroup(): SoundGroup
	return ensureGroup(SFX_GROUP_NAME)
end

-- The SoundGroup every music track should route into (BackgroundMusicController sets it).
function SoundGroups.getMusicGroup(): SoundGroup
	return ensureGroup(MUSIC_GROUP_NAME)
end

-- Set the SFX master volume (0..1). Clamped so a bad value can't push the group out of range.
function SoundGroups.setSfxVolume(volume: number)
	SoundGroups.getSfxGroup().Volume = math.clamp(volume, 0, 1)
end

-- Set the music master volume (0..1). Clamped like the SFX setter.
function SoundGroups.setMusicVolume(volume: number)
	SoundGroups.getMusicGroup().Volume = math.clamp(volume, 0, 1)
end

return SoundGroups
