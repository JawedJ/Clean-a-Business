--!strict

-- Floating gem income popup above each worker. When the plot owner's workers pay out gems the
-- server fires WorkerGemPopup with (workerModels, perWorkerAmount); for each worker we reveal its
-- authored GUIPart.BillboardGui.TextLabel, set it to "💎<amount>", then float it 4 studs up while
-- fading it out over 1.2s before hiding it again, and play a 3D "plop" from the worker. Cosmetic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ContentProvider = game:GetService("ContentProvider")

local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local SoundGroups = require(ReplicatedStorage.SharedModules.SoundGroups)

local WorkerGemPopup = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("WorkerGemPopup") :: RemoteEvent

-- Same gem emoji the upgrade shop prefixes to its costs (see UpgradesUiController).
local GEM_ICON = "💎"

-- A worker only becomes visible (and its GUIPart replicates) when the player buys it, which can be
-- the instant they load in -- so the first popup may arrive before the car's parts have streamed to
-- the client. WaitForChild (up to this long) covers that gap; a present part resolves instantly.
local PART_WAIT = 6

-- 3D "plop" played from each worker's GUIPart when its popup fires.
-- >>> Tune the clip here: PLOP_START is where playback begins (seconds into the sound) and PLOP_END
-- is where it's cut off. Set PLOP_END = nil to play all the way to the end of the source.
local PLOP_SOUND = "McPlop"
local PLOP_START = 2.2
local PLOP_END: number? = 2.8

-- Pink tint, matching the upgrade shop's affordable cost colour. Applied via a UIGradient (not
-- TextColor3) because a gradient multiplies over the whole label INCLUDING the emoji glyph, so the
-- 💎 tints pink too -- TextColor3 leaves emoji their native colour.
local TINT = ColorSequence.new(Color3.fromRGB(255, 90, 200))

-- How far up (world studs) and how long the popup drifts/fades before it's hidden again.
local RISE = Vector3.new(0, 4, 0)
local ANIM = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local WorkerGemPopupController = {}

-- Per-billboard token so a newer popup supersedes an older one: only the latest run's Completed
-- callback is allowed to hide the label, otherwise an in-flight animation would be cut off.
local seq: { [BillboardGui]: number } = {}

-- Lazily-resolved SFX folder. Kept OUT of module scope (not a top-level WaitForChild) so a slow-to-
-- replicate Audios folder can never stall this module's require -- which would block the whole client
-- bootstrap and leave the WorkerGemPopup listener unconnected (the "queue exhausted" drops).
local sfxFolder: Instance? = nil
local function getPlopTemplate(): Sound?
	if not sfxFolder then
		local audios = ReplicatedStorage:WaitForChild("Audios", 10)
		sfxFolder = audios and audios:WaitForChild("SFX", 10)
	end
	local template = sfxFolder and sfxFolder:FindFirstChild(PLOP_SOUND)
	if template and template:IsA("Sound") then
		return template
	end
	return nil
end

-- Reveal and animate one worker's billboard label. No-op if the worker lacks the authored parts,
-- so a plot whose cars haven't had a GUIPart added simply shows nothing.
local function popup(workerModel: Instance, amount: number)
	-- Wait for each part to stream in (see PART_WAIT); a freshly-bought car may not have replicated
	-- its GUIPart yet on the tick the first popup fires.
	local guiPart = workerModel:WaitForChild("GUIPart", PART_WAIT)
	local billboard = guiPart and guiPart:WaitForChild("BillboardGui", PART_WAIT)
	local label = billboard and billboard:WaitForChild("TextLabel", PART_WAIT)
	if not (guiPart and guiPart:IsA("BasePart") and billboard and billboard:IsA("BillboardGui")) then
		return
	end
	if not (label and label:IsA("TextLabel")) then
		return
	end
	local stroke = label:FindFirstChildWhichIsA("UIStroke")

	-- 3D plop emitted from the worker: a Sound parented to the GUIPart plays positionally, and being
	-- client-created only the local player hears it. Plays the PLOP_START..PLOP_END slice.
	local plopTemplate = getPlopTemplate()
	if guiPart:IsA("BasePart") and plopTemplate then
		local plop = plopTemplate:Clone()
		plop.Looped = false
		plop.SoundGroup = SoundGroups.getSfxGroup() -- scale by the player's SFX master volume
		plop.Parent = guiPart
		plop.Ended:Once(function()
			plop:Destroy()
		end)
		Debris:AddItem(plop, plop.TimeLength + 1) -- safety net if Ended never fires
		plop:Play()
		plop.TimePosition = PLOP_START -- set after Play so it isn't reset on playback start
		-- Cut it off at PLOP_END (Stop() skips Ended, so destroy the clone ourselves).
		if PLOP_END then
			task.delay(math.max(PLOP_END - PLOP_START, 0), function()
				plop:Destroy()
			end)
		end
	end

	local token = (seq[billboard] or 0) + 1
	seq[billboard] = token

	-- Pink tint over the whole label (numbers + 💎). Reuse a UIGradient if one is authored,
	-- otherwise add one once; setting the Color each time is cheap and keeps it correct.
	local gradient = label:FindFirstChildWhichIsA("UIGradient")
	if not gradient then
		local created = Instance.new("UIGradient")
		created.Parent = label
		gradient = created
	end
	gradient.Color = TINT

	-- Reset to the resting pose, then reveal, so overlapping ticks always start from the bottom.
	-- Force Enabled/Visible on: the server's show/hide can leave the billboard disabled, which
	-- would silently swallow the popup even with the label made Visible.
	label.Text = GEM_ICON .. NumberFormat.abbreviate(amount)
	billboard.Enabled = true
	billboard.StudsOffsetWorldSpace = Vector3.zero
	label.TextTransparency = 0
	if stroke then
		stroke.Transparency = 0
	end
	label.Visible = true

	TweenService:Create(billboard, ANIM, { StudsOffsetWorldSpace = RISE }):Play()
	if stroke then
		TweenService:Create(stroke, ANIM, { Transparency = 1 }):Play()
	end
	local fade = TweenService:Create(label, ANIM, { TextTransparency = 1 })
	fade.Completed:Once(function()
		-- Only hide if a newer popup hasn't taken over this billboard in the meantime.
		if seq[billboard] == token then
			label.Visible = false
			billboard.StudsOffsetWorldSpace = Vector3.zero
		end
	end)
	fade:Play()
end

function WorkerGemPopupController.init()
	-- Connect the listener FIRST, before any yield, so the server's per-second events aren't dropped
	-- ("queue exhausted") while we set anything else up.
	WorkerGemPopup.OnClientEvent:Connect(function(workers: { Instance }, amount: number)
		if type(workers) ~= "table" or type(amount) ~= "number" then
			return
		end
		for _, worker in workers do
			if typeof(worker) == "Instance" then
				-- Own thread per worker: popup may WaitForChild on a not-yet-replicated car, and one
				-- car waiting shouldn't hold up the other's popup.
				task.spawn(popup, worker, amount)
			end
		end
	end)

	-- Preload the plop off-thread so its first play isn't swallowed by load time.
	task.spawn(function()
		local plopTemplate = getPlopTemplate()
		if plopTemplate then
			pcall(function()
				ContentProvider:PreloadAsync({ plopTemplate })
			end)
		end
	end)
end

return WorkerGemPopupController
