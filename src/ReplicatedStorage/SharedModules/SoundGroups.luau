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

-- Slider value the authored ("normal default") volume sits at: the mid-slider default. A slider
-- value v maps to a group multiplier of v / MID, so 0.5 -> 1x (authored), 1.0 -> 2x (boost) and
-- 0 -> silent -- the player picks a mix relative to the intended level, not a fraction of it.
local MID_SLIDER = 0.5

-- Translate a 0..1 slider value into the SoundGroup multiplier (see MID_SLIDER), clamped so a bad
-- value can't push the group out of range.
local function sliderToVolume(slider: number): number
	return math.clamp(slider / MID_SLIDER, 0, 2)
end

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

-- Set the SFX master volume from a 0..1 slider value (0.5 = authored/normal level; see sliderToVolume).
function SoundGroups.setSfxVolume(volume: number)
	SoundGroups.getSfxGroup().Volume = sliderToVolume(volume)
end

-- Set the music master volume from a 0..1 slider value, mapped like the SFX setter.
function SoundGroups.setMusicVolume(volume: number)
	SoundGroups.getMusicGroup().Volume = sliderToVolume(volume)
end

return SoundGroups
