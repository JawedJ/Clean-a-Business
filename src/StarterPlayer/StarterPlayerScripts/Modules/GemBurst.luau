--!strict

-- The gem-shower effect played whenever a pile of gems lands in the player's balance: GEM_COUNT
-- copies of the ScreenGui's GemImg template scattered around screen centre over SPAWN_WINDOW
-- seconds, each holding in place before flying to the HUD gem counter and fading out.
--
-- Shared because more than one thing pays out gems in a lump: claiming offline earnings
-- (AfkEarningsController) and buying the Company UI's 24-hour earnings product
-- (CompanyUiController). Callers just call play().
--
-- Like the HUD controllers this re-binds to the fresh ScreenGui on every respawn; play() is a no-op
-- until something is bound, so it can never error on a caller.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

local localPlayer = Players.LocalPlayer

local SCREEN_GUI_NAME = "ScreenGui"

-- GEM_COUNT gems are spawned over SPAWN_WINDOW seconds; each holds GEM_HOLD in place, then flies to
-- the HUD gem counter over GEM_FLY while fading out, and is destroyed. The scatter half-extents (px)
-- are kept tight so the gems overlap slightly rather than spreading thin.
local GEM_COUNT = 30
local SPAWN_WINDOW = 0.7
local GEM_HOLD = 0.35
local GEM_FLY = 0.9
local SPREAD_X = 150
local SPREAD_Y = 120
local GEM_FLY_TWEEN = TweenInfo.new(GEM_FLY, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
-- Above the panels (ZIndex 1) so the burst reads over everything as it flies to the HUD.
local GEM_Z_INDEX = 100

local GemBurst = {}

-- The GemImg template (hidden, cloned per gem) and the two instances the burst needs -- the
-- ScreenGui the clones parent under and the HUD gem counter they fly toward. Rebound each respawn.
local gemTemplate: ImageLabel? = nil
local screenGuiRef: Instance? = nil
local gemDisplay: GuiObject? = nil

-- Animate one gem: clone the template into the ScreenGui at `spawnPos` (scale-based, near screen
-- centre), hold it there, then fly it to the HUD gem counter while fading out, and destroy it. The
-- fly target is computed after the hold as a pixel delta from the gem's own rendered centre to the
-- counter's, so it lands correctly regardless of the parent's coordinate origin.
local function flyGem(template: ImageLabel, screenGui: Instance, target: GuiObject, spawnPos: UDim2)
	local gem = template:Clone()
	gem.Visible = true
	gem.ZIndex = GEM_Z_INDEX
	gem.AnchorPoint = Vector2.new(0.5, 0.5)
	gem.Position = spawnPos
	gem.Parent = screenGui

	task.spawn(function()
		task.wait(GEM_HOLD)
		if not gem.Parent or not target.Parent then
			gem:Destroy()
			return
		end
		local delta = (target.AbsolutePosition + target.AbsoluteSize / 2)
			- (gem.AbsolutePosition + gem.AbsoluteSize / 2)
		local tween = TweenService:Create(gem, GEM_FLY_TWEEN, {
			Position = gem.Position + UDim2.fromOffset(delta.X, delta.Y),
			ImageTransparency = 0.8,
		})
		tween:Play()
		tween.Completed:Wait()
		SoundManager.playOneShot("plop")
		gem:Destroy()
	end)
end

-- Scatter the burst: GEM_COUNT gems spawned over SPAWN_WINDOW, each flying to the HUD gem counter.
-- No-op if anything it needs isn't bound. Returns immediately -- the effect runs on its own thread.
function GemBurst.play()
	local template = gemTemplate
	local screenGui = screenGuiRef
	local target = gemDisplay
	if not template or not screenGui or not target then
		return
	end

	task.spawn(function()
		for _ = 1, GEM_COUNT do
			local sx = (math.random() * 2 - 1) * SPREAD_X
			local sy = (math.random() * 2 - 1) * SPREAD_Y
			flyGem(template, screenGui, target, UDim2.new(0.5, sx, 0.5, sy))
			task.wait(SPAWN_WINDOW / GEM_COUNT)
		end
	end)
end

local function bind(screenGui: Instance)
	local allDisplays = screenGui:WaitForChild("HUD"):WaitForChild("AllDisplays")
	gemTemplate = screenGui:WaitForChild("GemImg") :: ImageLabel
	gemDisplay = allDisplays:WaitForChild("GemDisplay") :: GuiObject
	screenGuiRef = screenGui
end

function GemBurst.init()
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

return GemBurst
