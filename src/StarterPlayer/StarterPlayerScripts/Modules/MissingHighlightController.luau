--!strict

-- Press R (or tap the HighlightButton) while on a job to reveal everything you still have
-- left to clean: the not-yet-cleaned cleanables glow neon yellow for 10 seconds, then the
-- glow clears itself. Pressing it again re-applies against the current state and restarts
-- the timer.
--
-- Walls glow per-pixel: only the still-dirty pixels of each wall's dirt overlay light up, so
-- the glow shrinks live as the player cleans (owned by SurfaceManager/CleanableSurface, which
-- hold the editable image). Stains have no partial state -- their visible parts are switched
-- to a neon-yellow material while revealed, restored afterward. Both are cosmetic and purely
-- client-side -- they touch nothing on the server.
--
-- The on-screen button (PlayerGui.ScreenGui.HighlightButton) shows only during a job, like
-- the JobCompletion HUD. Its ScreenGui is re-cloned on every respawn, so we re-bind to the
-- fresh instances each time one appears.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local SurfaceManager = require(script.Parent.SurfaceManager)
local DecalVisibility = require(script.Parent.DecalVisibility)

local localPlayer = Players.LocalPlayer

-- Key that reveals the remaining cleanables.
local REVEAL_KEY = Enum.KeyCode.R
-- How long the glow lingers (seconds) before clearing itself.
local REVEAL_DURATION = 8
-- Neon-yellow glow for stains (walls carry their own glow via CleanableSurface).
local STAIN_GLOW_COLOR = Color3.fromRGB(255, 234, 0)
local STAIN_GLOW_TRANSPARENCY = 0.45

-- The HUD button that triggers the same reveal (PlayerGui.ScreenGui.HighlightButton).
local SCREEN_GUI_NAME = "ScreenGui"
local BUTTON_FRAME_NAME = "HighlightButton"

local MissingHighlightController = {}

-- Original look of every stain part we've recolored this reveal, so we can restore it exactly.
type PartLook = { part: BasePart, material: Enum.Material, color: Color3, transparency: number }
local glowingParts: { PartLook } = {}
-- Bumped on every reveal (and on teardown) so a stale expiry timer can tell it's been
-- superseded and skip its clear, leaving the newer reveal's glow alone.
local revealToken = 0
-- os.clock() before which a new reveal is ignored. Each reveal rebuilds every wall's glow
-- overlay (new EditableImages), so spamming the key/button churns them and hitches the game.
-- Gating for the reveal's own duration means you can only re-trigger once the current glow has
-- run its course -- which is exactly when a refresh is actually useful.
local revealCooldownUntil = 0

-- The currently bound button frame, refreshed each time the ScreenGui is (re)bound.
local buttonFrame: Frame? = nil

local function hasActiveJob(): boolean
	return type(localPlayer:GetAttribute(Config.ActiveJobAttribute)) == "string"
end

-- Drop the whole reveal: unglow the walls (per-pixel restore) and restore every stain part
-- we recolored to exactly how it was.
local function clearGlow()
	SurfaceManager.setWallsGlow(false)
	for _, look in glowingParts do
		local part = look.part
		if part.Parent then
			part.Material = look.material
			part.Color = look.color
			part.Transparency = look.transparency
		end
	end
	table.clear(glowingParts)
end

-- Switch one stain part to the neon-yellow glow, remembering its original look first.
local function glowStainPart(part: BasePart)
	table.insert(glowingParts, {
		part = part,
		material = part.Material,
		color = part.Color,
		transparency = part.Transparency,
	})
	part.Material = Enum.Material.Neon
	part.Color = STAIN_GLOW_COLOR
	part.Transparency = STAIN_GLOW_TRANSPARENCY
end

local function reveal()
	-- Cooldown: ignore re-triggers until the current glow has run its course.
	if os.clock() < revealCooldownUntil then
		return
	end
	revealCooldownUntil = os.clock() + REVEAL_DURATION

	clearGlow()

	-- Walls glow their own remaining-dirt pixels.
	SurfaceManager.setWallsGlow(true)

	-- Stains have no partial state: glow each visible part (skip the invisible Hitbox).
	for _, stain in DecalVisibility.getActiveVisibleStains() do
		for _, part in stain:GetDescendants() do
			if part:IsA("BasePart") and part.Name ~= Config.HitboxName and part.Transparency < 1 then
				glowStainPart(part)
			end
		end
	end

	revealToken += 1
	local token = revealToken
	task.delay(REVEAL_DURATION, function()
		-- Only clear if this is still the reveal we started; a newer press (or a job change)
		-- owns the glow now.
		if token == revealToken then
			clearGlow()
		end
	end)
end

-- Show the button only while a job is active (its counterpart to the job board, which hides
-- during a job). Guards the post-respawn gap before anything is bound.
local function applyButtonVisibility()
	local frame = buttonFrame
	if frame and frame.Parent then
		frame.Visible = hasActiveJob()
	end
end

-- Wire the HighlightButton in a freshly (re)cloned ScreenGui: fire the reveal on click and
-- set its starting visibility. The Activated gate mirrors the key path so a lingering button
-- (mid-teardown) can't reveal the old job.
local function bind(screenGui: Instance)
	local frame = screenGui:WaitForChild(BUTTON_FRAME_NAME) :: Frame
	local button = frame:WaitForChild("ImageButton") :: ImageButton

	buttonFrame = frame
	button.Activated:Connect(function()
		if hasActiveJob() then
			reveal()
		end
	end)

	applyButtonVisibility()
end

function MissingHighlightController.init()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		-- Ignore the key when the game already consumed it (e.g. typing in a TextBox).
		if gameProcessed or input.KeyCode ~= REVEAL_KEY then
			return
		end
		if not hasActiveJob() then
			return
		end
		reveal()
	end)

	-- If the job ends or switches mid-reveal, drop the glow: the old job's overlays/stains are
	-- being torn down underneath it. The token bump also disarms any in-flight expiry timer.
	-- Also refresh the button's visibility off the same signal, so it appears/vanishes with
	-- the job.
	localPlayer:GetAttributeChangedSignal(Config.ActiveJobAttribute):Connect(function()
		revealToken += 1
		revealCooldownUntil = 0 -- a fresh job starts with the reveal ready
		clearGlow()
		applyButtonVisibility()
	end)

	-- The ScreenGui is re-cloned each respawn; re-bind to whichever one is currently present.
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local function onChild(child: Instance)
		if child.Name == SCREEN_GUI_NAME then
			task.spawn(bind, child)
		end
	end
	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
	playerGui.ChildAdded:Connect(onChild)
end

return MissingHighlightController
