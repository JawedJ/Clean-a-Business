--!strict

-- Per-plot purchase progression. Each plot (Workspace.<PlotsFolderName>.Plot(i)) holds two
-- authored folders:
--   Plot(i).Buttons     -- purchase buttons, named "Button1".."ButtonN"
--   Plot(i).Spawnables  -- Models a button reveals, one per UnlockID
--
-- A button Model carries three attributes (see CleaningConfig):
--   Cost (number)       -- Cash charged when the OWNER steps on the button's Interact part
--   UnlockID (string)   -- name of the Spawnables Model this button makes visible
--   UnlockTwo (boolean) -- if true, buying reveals the NEXT TWO available buttons instead of just one
--
-- Rules:
--   * A fresh player sees only Button1 on their plot; everything else is hidden.
--   * Stepping on a visible button's Interact part, IF the owner can afford its Cost, deducts the
--     Cost, makes the button's spawnable visible, hides ("destroys") the button, and reveals the
--     next available (lowest not-yet-revealed) button -- or the next two if UnlockTwo. Buying ANY
--     button advances the chain, so out-of-order purchases never strand a button. Not enough Cash
--     -> nothing happens.
--   * Progress persists per player (DataTemplate.PlotButtonsBought). Plots are SHARED and reused,
--     so a plot is fully hidden when its owner leaves and rebuilt from the next owner's save data
--     -- buttons are never Instance:Destroy()'d, just hidden, so the plot can be handed on intact.
--   * Unlocked spawnables generate Gems each second via the GemRate attribute (0/absent = inert),
--     so the gem-generation feature just needs rates set on the spawnables.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local NumberFormat = require(ReplicatedStorage.SharedModules.NumberFormat)
local DataService = require(ReplicatedStorage.Packages.DataService).server
local GemBuff = require(script.Parent.GemBuff)
local ProgressionService = require(script.Parent.ProgressionService)
local PlotService = require(script.Parent.PlotService)

-- Fired to the plot owner when they step on a button: true if the purchase went through, false if
-- they couldn't afford it. The client plays the buy / fail SFX off this (see PlotButtonSoundController).
local PlotButtonSound = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PlotButtonSound") :: RemoteEvent

-- Fired to the plot owner each time their workers pay out gems, with (workerModels, perWorkerAmount).
-- The client floats a "💎N" popup above each worker's GUIPart (see WorkerGemPopupController).
local WorkerGemPopup = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("WorkerGemPopup") :: RemoteEvent

local PlotButtonService = {}

type ButtonEntry = {
	name: string,
	index: number,
	model: Instance,
	cost: number,
	unlockId: string,
	unlockTwo: boolean,
	interact: BasePart?,
	-- The button's billboard price label (if any) and its authored text, so we can append the
	-- " $<cost>" price (recoloured by affordability) without stacking it on every refresh.
	priceLabel: TextLabel?,
	baseText: string,
}

type PlotState = {
	player: Player,
	plot: Instance,
	buttons: { [string]: ButtonEntry }, -- by button name
	buttonsByIndex: { [number]: ButtonEntry },
	maxButtonIndex: number, -- highest button index present, so reveal walks can't loop past the last
	spawnables: { [string]: Instance }, -- by Model name (== a button's UnlockID)
	available: { [string]: boolean }, -- button names currently visible + touchable
	bought: { [string]: boolean }, -- button names already purchased (never reveal these again)
	active: { [string]: boolean }, -- spawnable names currently unlocked/visible
	debounce: { [string]: boolean }, -- per-button touch debounce
	readyAt: { [string]: number }, -- earliest os.clock() a button may be purchased (reveal cooldown)
	conns: { RBXScriptConnection }, -- touch listeners + the owner's Cash-changed listener
}

-- Grace period after a button is revealed before its Interact part can fire a purchase. Buying a
-- button reveals the next one right where the owner is standing, so without this a stray Touched
-- from that same footstep could instantly buy the freshly-revealed button.
local REVEAL_COOLDOWN = 1

-- RichText colours for the appended price: green when the owner can afford it, red when not.
local AFFORD_COLOR = "#37D67A"
local DENY_COLOR = "#FF4136"

-- Authored (Studio) visual/interaction props, captured the FIRST time each instance is seen so a
-- later hide can never overwrite the true values. Persists for the server's lifetime; plots are
-- reused, not recreated, so one snapshot is enough.
local originalProps: { [Instance]: { [string]: any } } = {}

-- A price label's authored text, captured once so appending the price on a rebuild never stacks
-- onto a value we already appended in a previous session (we mutate the live label in place).
local baseTextByLabel: { [TextLabel]: string } = {}

local stateByPlot: { [Instance]: PlotState } = {}
-- Bumped on every assign/release so an in-flight build (which yields on waitForData) can detect it
-- was superseded and bail instead of painting a plot for the wrong owner.
local plotGen: { [Instance]: number } = {}
-- Fractional gem carry per plot, so sub-1/sec rates still eventually pay out.
local gemAccum: { [Instance]: number } = {}
-- Latest gems/sec each owner's plot is producing, refreshed every tick of the gem loop and read by
-- AfkEarningsService at leave to snapshot the player's offline earning rate. Keyed by player (not
-- plot) so it survives the plot teardown that release triggers. WEAK keys so an entry is reclaimed
-- automatically once the player is gone -- deliberately NOT cleared on release, because release can
-- fire before the leave snapshot reads this (their PlayerRemoving handlers race), which would zero
-- the rate; the weak table needs no manual cleanup anyway.
local gemsPerSecondByPlayer: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: { [Player]: number }

-- Record an instance's authored visual props once. `props` is the set we restore on show.
local function snapshot(inst: Instance)
	if originalProps[inst] then
		return
	end
	if inst:IsA("BasePart") then
		originalProps[inst] = {
			Transparency = inst.Transparency,
			CanCollide = inst.CanCollide,
			CanTouch = inst.CanTouch,
			CanQuery = inst.CanQuery,
		}
	elseif inst:IsA("Decal") or inst:IsA("Texture") then
		originalProps[inst] = { Transparency = inst.Transparency }
	elseif
		inst:IsA("ParticleEmitter")
		or inst:IsA("Beam")
		or inst:IsA("Trail")
		or inst:IsA("Light")
		or inst:IsA("BillboardGui")
		or inst:IsA("SurfaceGui")
	then
		originalProps[inst] = { Enabled = inst.Enabled }
	end
end

-- Show or hide a whole Model. Hidden = invisible, non-colliding, and non-touchable (so a hidden
-- button's Interact part can't fire). Snapshots authored props on first show so restore is exact.
local function setVisible(model: Instance, visible: boolean)
	for _, d in model:GetDescendants() do
		snapshot(d)
		if d:IsA("BasePart") then
			if visible then
				local o = originalProps[d]
				if o then
					d.Transparency = o.Transparency
					d.CanCollide = o.CanCollide
					d.CanTouch = o.CanTouch
					d.CanQuery = o.CanQuery
				end
			else
				d.Transparency = 1
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
			end
		elseif d:IsA("Decal") or d:IsA("Texture") then
			d.Transparency = if visible then (originalProps[d] and originalProps[d].Transparency or 0) else 1
		elseif
			d:IsA("ParticleEmitter")
			or d:IsA("Beam")
			or d:IsA("Trail")
			or d:IsA("Light")
			or d:IsA("BillboardGui")
			or d:IsA("SurfaceGui")
		then
			d.Enabled = if visible then (originalProps[d] and originalProps[d].Enabled or true) else false
		end
	end
	-- The model itself may be a BasePart; GetDescendants doesn't include it.
	if model:IsA("BasePart") then
		snapshot(model)
		local o = originalProps[model]
		if visible then
			if o then
				model.Transparency = o.Transparency
				model.CanCollide = o.CanCollide
				model.CanTouch = o.CanTouch
				model.CanQuery = o.CanQuery
			end
		else
			model.Transparency = 1
			model.CanCollide = false
			model.CanTouch = false
			model.CanQuery = false
		end
	end
end

-- Read one button Model into a ButtonEntry, or nil if it isn't a valid "Button<number>".
local function readButton(model: Instance): ButtonEntry?
	local num = model.Name:match("(%d+)$")
	local index = num and tonumber(num)
	if not index then
		warn(string.format("[PlotButtonService] Button %q has no trailing number; skipping.", model.Name))
		return nil
	end
	local cost = model:GetAttribute(Config.PlotButtonCostAttribute)
	local unlockId = model:GetAttribute(Config.PlotButtonUnlockIdAttribute)
	local unlockTwo = model:GetAttribute(Config.PlotButtonUnlockTwoAttribute)
	local interact = model:FindFirstChild(Config.PlotButtonInteractPartName, true)
	local label = model:FindFirstChildWhichIsA("TextLabel", true) :: TextLabel?
	if label and baseTextByLabel[label] == nil then
		baseTextByLabel[label] = label.Text
	end
	return {
		name = model.Name,
		index = index,
		model = model,
		cost = if type(cost) == "number" then cost else 0,
		unlockId = if type(unlockId) == "string" then unlockId else "",
		unlockTwo = unlockTwo == true,
		interact = if interact and interact:IsA("BasePart") then interact else nil,
		priceLabel = label,
		baseText = if label then baseTextByLabel[label] else "",
	}
end

-- Build the button/spawnable registry for a plot from its live folders. Does not change visibility.
local function buildRegistry(plot: Instance): PlotState?
	local buttonsFolder = plot:FindFirstChild(Config.PlotButtonsFolderName)
	local spawnablesFolder = plot:FindFirstChild(Config.PlotSpawnablesFolderName)
	if not buttonsFolder then
		warn(string.format("[PlotButtonService] Plot %s has no %q folder.", plot.Name, Config.PlotButtonsFolderName))
		return nil
	end

	local buttons: { [string]: ButtonEntry } = {}
	local buttonsByIndex: { [number]: ButtonEntry } = {}
	local maxButtonIndex = 0
	for _, model in buttonsFolder:GetChildren() do
		local entry = readButton(model)
		if entry then
			buttons[entry.name] = entry
			buttonsByIndex[entry.index] = entry
			if entry.index > maxButtonIndex then
				maxButtonIndex = entry.index
			end
		end
	end

	local spawnables: { [string]: Instance } = {}
	if spawnablesFolder then
		for _, model in spawnablesFolder:GetChildren() do
			spawnables[model.Name] = model
		end
	end

	return {
		player = nil :: any,
		plot = plot,
		buttons = buttons,
		buttonsByIndex = buttonsByIndex,
		maxButtonIndex = maxButtonIndex,
		spawnables = spawnables,
		available = {},
		bought = {},
		active = {},
		debounce = {},
		readyAt = {},
		conns = {},
	}
end

-- Hide every button and spawnable in a plot (its fully reset state).
local function hideAll(state: PlotState)
	for _, entry in state.buttons do
		setVisible(entry.model, false)
	end
	for _, model in state.spawnables do
		setVisible(model, false)
	end
end

-- Spawn-in drop animation tunables: how long it takes, how far above its resting spot it starts,
-- and how transparent it starts before fading to its authored look.
local SPAWN_ANIM_DURATION = 1
local SPAWN_ANIM_HEIGHT = 8
local SPAWN_ANIM_START_TRANSPARENCY = 0.9

-- Reservation parts are created spread across this many frames instead of all on one frame, so a
-- spawnable with many parts/sub-models doesn't cause a spawn-time hitch.
local HITBOX_SPAWN_FRAMES = 4

-- Build one invisible collision blocker that reserves a chunk of a spawnable's final footprint
-- during its drop-in, so a player standing where it lands isn't trapped by the falling
-- (non-colliding) model. Parented OUTSIDE the model so moving the model doesn't drag it. Named
-- "Hitbox" per spec; removed when the drop finishes.
local function makeLandingHitbox(parent: Instance, cframe: CFrame, size: Vector3): BasePart
	local hitbox = Instance.new("Part")
	hitbox.Name = "Hitbox"
	hitbox.Size = size
	hitbox.CFrame = cframe
	hitbox.Anchored = true
	hitbox.CanCollide = true
	hitbox.CanTouch = false
	hitbox.CanQuery = false
	hitbox.Transparency = 1
	hitbox.Parent = parent
	return hitbox
end

-- A landing-footprint box to be created: where and how big. Collected up front (cheap property
-- reads) so the actual Hitbox parts can be spawned spread across a few frames.
type BoxSpec = { cframe: CFrame, size: Vector3 }

-- Compute a spawnable's landing-footprint boxes WITHOUT creating any parts yet. A single box around
-- the whole spawnable spans the empty gap between sub-models that sit apart from each other, so
-- instead we descend to each *leaf* model (one with no Models of its own) and give it its own box,
-- plus a box per loose BasePart that isn't inside any sub-model. A spawnable with no sub-models is
-- itself a leaf and gets the one box it always did. The caller turns these specs into real parts.
local function collectLandingBoxSpecs(model: Instance): { BoxSpec }
	local specs: { BoxSpec } = {}

	local function addBox(cframe: CFrame, size: Vector3)
		-- Empty models report a zero-size box; nothing to reserve.
		if size.Magnitude > 0 then
			table.insert(specs, { cframe = cframe, size = size })
		end
	end

	local function descend(inst: Instance)
		if inst:IsA("BasePart") then
			addBox(inst.CFrame, inst.Size)
			return
		end
		if not inst:IsA("Model") then
			return
		end

		local hasSubModel = false
		for _, child in inst:GetChildren() do
			if child:IsA("Model") then
				hasSubModel = true
				break
			end
		end
		if not hasSubModel then
			addBox(inst:GetBoundingBox())
			return
		end

		-- Mixed contents: recurse into sub-models, and box any loose parts alongside them.
		for _, child in inst:GetChildren() do
			if child:IsA("Model") or child:IsA("BasePart") then
				descend(child)
			end
		end
	end

	descend(model)
	return specs
end

local function destroyHitboxes(hitboxes: { BasePart })
	for _, hitbox in hitboxes do
		hitbox:Destroy()
	end
end

-- Drop a spawnable in over SPAWN_ANIM_DURATION: it starts SPAWN_ANIM_HEIGHT studs up and nearly
-- transparent, then eases (Quad-out) down to its authored spot and fades to its authored look.
-- "Hitbox" parts reserve the landing footprint for the duration so the falling model (parts set
-- non-colliding for the drop) can't trap a player. Runs in its own task so purchases don't block on
-- it, and cancels cleanly (restoring the resting pose) if the plot is reset mid-drop.
local function animateSpawnIn(state: PlotState, model: Instance)
	-- Resting pose is wherever the model is authored -- it hasn't been moved, so its current pivot
	-- IS the target. Fall back to a plain show for anything without geometry.
	local finalPivot: CFrame
	if model:IsA("Model") then
		finalPivot = model:GetPivot()
	elseif model:IsA("BasePart") then
		finalPivot = (model :: BasePart).CFrame
	else
		setVisible(model, true)
		return
	end

	local parent = model.Parent
	local boxSpecs = if parent then collectLandingBoxSpecs(model) else {}
	local hitboxes: { BasePart } = {}

	-- Everything we fade, with its authored (target) transparency captured at build in originalProps.
	-- Start each a fixed amount MORE transparent than its target (never less, so a semi-transparent
	-- part doesn't briefly turn opaque).
	local fades: { { inst: any, from: number, to: number } } = {}
	local function collectFade(inst: Instance)
		if inst:IsA("BasePart") or inst:IsA("Decal") or inst:IsA("Texture") then
			local o = originalProps[inst]
			local target = if o and type(o.Transparency) == "number" then o.Transparency else inst.Transparency
			table.insert(fades, { inst = inst, from = math.max(target, SPAWN_ANIM_START_TRANSPARENCY), to = target })
		end
	end
	if model:IsA("BasePart") then
		collectFade(model)
	end
	for _, d in model:GetDescendants() do
		collectFade(d)
	end

	-- Reveal the structure, then override for the drop: faded, non-colliding (the Hitbox holds the
	-- space), lifted up by SPAWN_ANIM_HEIGHT.
	setVisible(model, true)
	for _, f in fades do
		f.inst.Transparency = f.from
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
		end
	end
	if model:IsA("BasePart") then
		(model :: BasePart).CanCollide = false
	end

	local startPivot = finalPivot + Vector3.new(0, SPAWN_ANIM_HEIGHT, 0)
	model:PivotTo(startPivot)

	task.spawn(function()
		local elapsed = 0
		-- Spawn the reservation parts a chunk per frame over the first HITBOX_SPAWN_FRAMES frames
		-- rather than all at once, so a many-part spawnable doesn't spike on a single frame. The
		-- model starts SPAWN_ANIM_HEIGHT studs up and only nears the ground late in the drop, so
		-- reaching full coverage a few frames in can't trap anyone.
		local created = 0
		local perFrame = math.max(1, math.ceil(#boxSpecs / HITBOX_SPAWN_FRAMES))
		while elapsed < SPAWN_ANIM_DURATION do
			local dt = RunService.Heartbeat:Wait()
			-- Cancelled (plot reset or this spawnable no longer active): restore the resting pose,
			-- match the plot's hidden state, and drop the reservation.
			if stateByPlot[state.plot] ~= state or not state.active[model.Name] then
				model:PivotTo(finalPivot)
				setVisible(model, false)
				destroyHitboxes(hitboxes)
				return
			end
			if created < #boxSpecs and parent then
				local stop = math.min(created + perFrame, #boxSpecs)
				for i = created + 1, stop do
					local spec = boxSpecs[i]
					table.insert(hitboxes, makeLandingHitbox(parent, spec.cframe, spec.size))
				end
				created = stop
			end
			elapsed += dt
			local alpha = math.min(elapsed / SPAWN_ANIM_DURATION, 1)
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			model:PivotTo(startPivot:Lerp(finalPivot, eased))
			for _, f in fades do
				f.inst.Transparency = f.from + (f.to - f.from) * eased
			end
		end
		-- Landed: snap to the exact authored pose + visuals (restores collision/particles/etc) and
		-- remove the footprint reservation.
		model:PivotTo(finalPivot)
		setVisible(model, true)
		destroyHitboxes(hitboxes)
	end)
end

-- Make a spawnable visible/unlocked (idempotent). Warns on an unknown UnlockID. `animate` plays the
-- drop-in (used on a live purchase); a rebuild from save reveals it instantly (animate = false).
local function unlockSpawnable(state: PlotState, unlockId: string, animate: boolean)
	if unlockId == "" or state.active[unlockId] then
		return
	end
	local model = state.spawnables[unlockId]
	if not model then
		warn(string.format("[PlotButtonService] Plot %s has no spawnable %q.", state.plot.Name, unlockId))
		return
	end
	state.active[unlockId] = true
	if animate then
		animateSpawnIn(state, model)
	else
		setVisible(model, true)
	end
end

-- Make a button (by index) visible + touchable, unless it doesn't exist or is already available.
local function revealButton(state: PlotState, index: number)
	local entry = state.buttonsByIndex[index]
	-- Skip if there's no such button, it's already showing, or it's already been bought -- a bought
	-- button is cleared from `available`, so without the bought guard a later neighbour's reveal
	-- (e.g. Button2 revealing index+1=Button3 after Button3 was already purchased) resurrects it.
	if not entry or state.available[entry.name] or state.bought[entry.name] then
		return
	end
	state.available[entry.name] = true
	-- Arm the reveal cooldown: the button can't be purchased for REVEAL_COOLDOWN after appearing.
	state.readyAt[entry.name] = os.clock() + REVEAL_COOLDOWN
	setVisible(entry.model, true)
end

-- Highest button index that's currently revealed -- either still available or already bought. Reveals
-- always fill the slots ABOVE this, so which button was just purchased never matters, only how far the
-- chain has been opened so far.
local function highestRevealedIndex(state: PlotState): number
	local maxIdx = 0
	for name in state.available do
		local entry = state.buttons[name]
		if entry and entry.index > maxIdx then
			maxIdx = entry.index
		end
	end
	for name in state.bought do
		local entry = state.buttons[name]
		if entry and entry.index > maxIdx then
			maxIdx = entry.index
		end
	end
	return maxIdx
end

-- Reveal the next `count` not-yet-revealed buttons in index order (skipping any gaps in numbering),
-- regardless of which button triggered them. This makes buying ANY button open the next available
-- button(s), so out-of-order purchases can't leave a gap that only a specific later button would fill.
local function revealNext(state: PlotState, count: number)
	local idx = highestRevealedIndex(state)
	local revealed = 0
	while revealed < count and idx < state.maxButtonIndex do
		idx += 1
		local entry = state.buttonsByIndex[idx]
		if entry and not state.bought[entry.name] and not state.available[entry.name] then
			revealButton(state, idx)
			revealed += 1
		end
	end
end

-- Set a button's billboard label to its authored text plus a " $<cost>" price, coloured green if
-- `cash` covers the cost and red otherwise (RichText, so only the price is coloured). No-op for a
-- button without a label.
local function updateButtonPrice(entry: ButtonEntry, cash: number)
	local label = entry.priceLabel
	if not label then
		return
	end
	label.RichText = true
	local color = if cash >= entry.cost then AFFORD_COLOR else DENY_COLOR
	local price = string.format('<font color="%s">$%s</font>', color, NumberFormat.abbreviate(entry.cost))
	local base = entry.baseText
	label.Text = if base == "" then price else base .. " " .. price
end

-- Repaint the price/affordability on every currently-available button off the owner's live Cash.
local function refreshPrices(state: PlotState)
	local cash = DataService:get(state.player, { "Cash" })
	local cashNum = if type(cash) == "number" then cash else 0
	for name in state.available do
		local entry = state.buttons[name]
		if entry then
			updateButtonPrice(entry, cashNum)
		end
	end
end

-- Apply a completed purchase of `entry`: hide the bought button, unlock its spawnable, and reveal
-- the next available button (or next two if UnlockTwo). Runtime state only -- persistence is written
-- by the caller so a rebuild can replay it.
local function applyPurchase(state: PlotState, entry: ButtonEntry)
	state.available[entry.name] = nil
	state.bought[entry.name] = true
	setVisible(entry.model, false)

	unlockSpawnable(state, entry.unlockId, true)

	revealNext(state, if entry.unlockTwo then 2 else 1)

	-- The spend just changed Cash and a new button may have appeared; recolour the prices.
	refreshPrices(state)
end

-- Owner stepped on a button's Interact part. Charge Cash and apply the purchase if they can afford
-- it and the button is currently available; otherwise do nothing.
local function tryPurchase(state: PlotState, entry: ButtonEntry)
	if not state.available[entry.name] or state.debounce[entry.name] then
		return
	end
	-- Still within the reveal cooldown: ignore the touch entirely (no buy, no fail SFX) so it
	-- can't be purchased the instant it appears.
	local readyAt = state.readyAt[entry.name]
	if readyAt and os.clock() < readyAt then
		return
	end
	state.debounce[entry.name] = true

	local player = state.player
	local cash = DataService:get(player, { "Cash" })
	local purchased = type(cash) == "number" and cash >= entry.cost and state.available[entry.name] == true
	if purchased then
		-- Deduct then record + apply. Neither DataService call yields and the button is removed
		-- from `available` inside applyPurchase, so a second touch can't double-charge.
		DataService:update(player, { "Cash" }, function(current: number?)
			return (current or 0) - entry.cost
		end)
		DataService:set(player, { "PlotButtonsBought", entry.name }, true)
		applyPurchase(state, entry)
	end

	-- Tell the owner's client to play the buy SFX on success, the fail SFX if they couldn't afford it.
	PlotButtonSound:FireClient(player, purchased)

	-- Short cooldown so a failed (too-poor) attempt can be retried without spamming touches.
	task.delay(0.5, function()
		state.debounce[entry.name] = nil
	end)
end

-- Wire each button's Interact part so only the plot owner's character triggers it.
local function connectTouches(state: PlotState)
	for _, entry in state.buttons do
		local interact = entry.interact
		if interact then
			local conn = interact.Touched:Connect(function(hit: BasePart)
				local character = hit and hit.Parent
				local player = character and Players:GetPlayerFromCharacter(character)
				if player == state.player then
					tryPurchase(state, entry)
				end
			end)
			table.insert(state.conns, conn)
		end
	end
end

-- Reconstruct a plot's visible state from the player's saved purchases: unlock every bought
-- button's spawnable, then reveal the buttons that are unlocked-but-not-yet-bought (Button1 is the
-- baseline entry point). Fresh player (no purchases) -> only Button1 visible.
local function replayFromSave(state: PlotState, bought: { [string]: boolean })
	-- Reveals fill the next open slot regardless of purchase order, so the total number of revealed
	-- buttons only depends on WHICH buttons were bought, not the sequence: Button1 (the baseline entry
	-- point) plus one slot per purchase, or two for an UnlockTwo button.
	local revealBudget = if state.maxButtonIndex >= 1 then 1 else 0
	for name, isBought in bought do
		if isBought then
			local entry = state.buttons[name]
			if entry then
				state.bought[name] = true
				unlockSpawnable(state, entry.unlockId, false)
				revealBudget += if entry.unlockTwo then 2 else 1
			end
		end
	end

	-- Spend the budget across the lowest button indices in order: each existing button consumes a
	-- slot, and the ones that weren't bought become the currently-visible (available) buttons.
	local idx = 0
	while revealBudget > 0 and idx < state.maxButtonIndex do
		idx += 1
		local entry = state.buttonsByIndex[idx]
		if entry then
			revealBudget -= 1
			if not bought[entry.name] then
				revealButton(state, entry.index)
			end
		end
	end
end

-- Tear down a plot: drop touch connections, hide everything, and forget its state. Called on
-- release and before a rebuild.
local function reset(plot: Instance)
	local state = stateByPlot[plot]
	if state then
		for _, conn in state.conns do
			conn:Disconnect()
		end
		hideAll(state)
	end
	stateByPlot[plot] = nil
	gemAccum[plot] = nil
end

-- Build a plot for its new owner from that player's save data.
local function onAssigned(player: Player, plot: Instance)
	plotGen[plot] = (plotGen[plot] or 0) + 1
	local token = plotGen[plot]

	reset(plot)

	-- Save data must be loaded before we can read the player's purchases.
	DataService:waitForData(player)
	-- A newer assign/release happened while we waited; the plot is no longer ours to paint.
	if plotGen[plot] ~= token then
		return
	end

	local state = buildRegistry(plot)
	if not state then
		return
	end
	state.player = player
	stateByPlot[plot] = state

	hideAll(state)

	local bought = DataService:get(player, { "PlotButtonsBought" })
	replayFromSave(state, if type(bought) == "table" then bought else {})

	connectTouches(state)

	-- Paint initial prices, and keep every visible button's colour in sync as Cash changes.
	refreshPrices(state)
	local cashConn = DataService:getChangedSignal(player, { "Cash" }):Connect(function()
		if stateByPlot[plot] == state then
			refreshPrices(state)
		end
	end)
	table.insert(state.conns, cashConn)
end

local function onReleased(_player: Player, plot: Instance)
	plotGen[plot] = (plotGen[plot] or 0) + 1
	reset(plot)
end

-- The gems/sec the player's plot is currently producing (0 if they have no plot / it earns
-- nothing). Refreshed each second by the gem loop; read by AfkEarningsService to snapshot the
-- player's offline earning rate when they leave.
function PlotButtonService.getGemsPerSecond(player: Player): number
	return gemsPerSecondByPlayer[player] or 0
end

-- Award Gems once per second for every unlocked spawnable, summed per plot (GemRate attribute;
-- absent/0 = nothing). Fractional rates accumulate so they eventually pay out whole gems.
-- Gems/second a plot currently produces under the worker + buff model:
--   * WORKERS (Config.PlotWorkerSpawnables) each contribute PlotWorkerBaseGemRate to the base.
--   * Every active spawnable's BaseAdd adds to each worker's base (before the multiplier);
--     every BaseMultiplier scales each worker's output (stacking multiplicatively). Workers have no
--     attributes, so buffs come purely from the other unlocked spawnables.
--   * Standalone GemRate generators (if any) are added on top, outside the worker model.
-- With no workers active, buffs scale nothing and only standalone GemRate income remains.
-- Returns the plot's total gems/sec, the per-worker gems/sec (what each worker contributes, for
-- the floating popup), and the list of active worker models.
local function computeGemsPerSecond(state: PlotState): (number, number, { Instance })
	local workers: { Instance } = {}
	local flatPerWorker = 0
	local multiplier = 1
	local standalone = 0

	for name in state.active do
		local model = state.spawnables[name]
		if model then
			if Config.PlotWorkerSpawnables[name] then
				table.insert(workers, model)
			end
			local flat = model:GetAttribute(Config.PlotSpawnableGemFlatAttribute)
			if type(flat) == "number" then
				flatPerWorker += flat
			end
			local mult = model:GetAttribute(Config.PlotSpawnableGemMultiplierAttribute)
			if type(mult) == "number" then
				multiplier *= mult
			end
			local rate = model:GetAttribute(Config.PlotSpawnableGemRateAttribute)
			if type(rate) == "number" then
				standalone += rate
			end
		end
	end

	local perWorker = (Config.PlotWorkerBaseGemRate + flatPerWorker) * multiplier
	return perWorker * #workers + standalone, perWorker, workers
end

local function startGemLoop()
	task.spawn(function()
		while true do
			task.wait(1)
			-- Snapshot states first: awarding could yield and states can be reset concurrently.
			local states: { PlotState } = {}
			for _, state in stateByPlot do
				table.insert(states, state)
			end
			for _, state in states do
				local total, perWorker, workers = computeGemsPerSecond(state)
				if stateByPlot[state.plot] == state then
					-- Record the BASE rate (even 0) so a leave can snapshot it for offline earnings.
					-- Deliberately pre-boost: the offline payout applies the boost itself, for
					-- exactly the slice of the absence the boost still covered, and the Company UI
					-- quotes this rate for its 24-hour claim.
					gemsPerSecondByPlayer[state.player] = total
				end

				-- The purchased 10x boost scales what the plot actually pays out (and the per-worker
				-- popup with it), without touching the base rate recorded above.
				local boost = GemBuff.getMultiplier(state.player)
				total *= boost
				perWorker *= boost

				if total > 0 and stateByPlot[state.plot] == state then
					local acc = (gemAccum[state.plot] or 0) + total
					local whole = math.floor(acc)
					gemAccum[state.plot] = acc - whole
					if whole > 0 then
						ProgressionService.awardGems(state.player, whole)
						-- Float a per-worker "💎N" popup above each worker on the owner's client.
						if perWorker > 0 and #workers > 0 then
							WorkerGemPopup:FireClient(state.player, workers, perWorker)
						end
					end
				end
			end
		end
	end)
end

-- Hide every plot at server start, before any client can replicate it.
--
-- Plots are authored in their FINAL, fully-bought, visible state (setVisible snapshots those
-- authored values on first sight and restores them on show -- see snapshot). Without this sweep they
-- stay visible from server start until the first owner's onAssigned runs, which yields on
-- waitForData -- so an early joiner sees every plot fully built for a moment. Hiding here happens
-- before any player joins, so clients only ever receive the hidden state.
--
-- This also takes the authored snapshot, which is why it MUST run before anything mutates
-- transparency. The temporary registries are deliberately not stored in stateByPlot: these plots
-- have no owner yet, and onAssigned rebuilds from scratch anyway.
local function hideAllPlotsAtStartup()
	local plotsFolder = Workspace:FindFirstChild(Config.PlotsFolderName)
	if not plotsFolder then
		warn(string.format("[PlotButtonService] No %q folder under Workspace; cannot pre-hide plots.", Config.PlotsFolderName))
		return
	end
	for i = 1, Config.PlotCount do
		local plot = plotsFolder:FindFirstChild("Plot" .. i)
		if plot then
			local state = buildRegistry(plot)
			if state then
				hideAll(state)
			end
		end
	end
end

-- Register plot hooks BEFORE PlotService.init() so the join sweep and every future assignment
-- build the plot from save data.
function PlotButtonService.init()
	hideAllPlotsAtStartup()
	PlotService.onAssigned(onAssigned)
	PlotService.onReleased(onReleased)
	startGemLoop()
end

return PlotButtonService
