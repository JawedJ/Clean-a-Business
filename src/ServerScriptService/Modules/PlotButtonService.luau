--!strict

-- Per-plot purchase progression. Each plot (Workspace.<PlotsFolderName>.Plot(i)) holds two
-- authored folders:
--   Plot(i).Buttons     -- purchase buttons, named "Button1".."ButtonN"
--   Plot(i).Spawnables  -- Models a button reveals, one per UnlockID
--
-- A button Model carries three attributes (see CleaningConfig):
--   Cost (number)       -- Cash charged when the OWNER steps on the button's Interact part
--   UnlockID (string)   -- name of the Spawnables Model this button makes visible
--   UnlockTwo (boolean) -- if true, buying reveals the NEXT TWO buttons instead of just the next
--
-- Rules:
--   * A fresh player sees only Button1 on their plot; everything else is hidden.
--   * Stepping on a visible button's Interact part, IF the owner can afford its Cost, deducts the
--     Cost, makes the button's spawnable visible, hides ("destroys") the button, and reveals the
--     next button (or the next two if UnlockTwo). Not enough Cash -> nothing happens.
--   * Progress persists per player (DataTemplate.PlotButtonsBought). Plots are SHARED and reused,
--     so a plot is fully hidden when its owner leaves and rebuilt from the next owner's save data
--     -- buttons are never Instance:Destroy()'d, just hidden, so the plot can be handed on intact.
--   * Unlocked spawnables generate Gems each second via the GemRate attribute (0/absent = inert),
--     so the gem-generation feature just needs rates set on the spawnables.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.SharedModules.CleaningConfig)
local DataService = require(ReplicatedStorage.Packages.DataService).server
local ProgressionService = require(script.Parent.ProgressionService)
local PlotService = require(script.Parent.PlotService)

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
	spawnables: { [string]: Instance }, -- by Model name (== a button's UnlockID)
	available: { [string]: boolean }, -- button names currently visible + touchable
	active: { [string]: boolean }, -- spawnable names currently unlocked/visible
	debounce: { [string]: boolean }, -- per-button touch debounce
	conns: { RBXScriptConnection }, -- touch listeners + the owner's Cash-changed listener
}

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
	for _, model in buttonsFolder:GetChildren() do
		local entry = readButton(model)
		if entry then
			buttons[entry.name] = entry
			buttonsByIndex[entry.index] = entry
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
		spawnables = spawnables,
		available = {},
		active = {},
		debounce = {},
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

-- Make a spawnable visible/unlocked (idempotent). Warns on an unknown UnlockID.
local function unlockSpawnable(state: PlotState, unlockId: string)
	if unlockId == "" or state.active[unlockId] then
		return
	end
	local model = state.spawnables[unlockId]
	if not model then
		warn(string.format("[PlotButtonService] Plot %s has no spawnable %q.", state.plot.Name, unlockId))
		return
	end
	state.active[unlockId] = true
	setVisible(model, true)
end

-- Make a button (by index) visible + touchable, unless it doesn't exist or is already available.
local function revealButton(state: PlotState, index: number)
	local entry = state.buttonsByIndex[index]
	if not entry or state.available[entry.name] then
		return
	end
	state.available[entry.name] = true
	setVisible(entry.model, true)
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
	local price = string.format('<font color="%s">$%d</font>', color, entry.cost)
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
-- the next button (or next two if UnlockTwo). Runtime state only -- persistence is written by the
-- caller so a rebuild can replay it.
local function applyPurchase(state: PlotState, entry: ButtonEntry)
	state.available[entry.name] = nil
	setVisible(entry.model, false)

	unlockSpawnable(state, entry.unlockId)

	revealButton(state, entry.index + 1)
	if entry.unlockTwo then
		revealButton(state, entry.index + 2)
	end

	-- The spend just changed Cash and a new button may have appeared; recolour the prices.
	refreshPrices(state)
end

-- Owner stepped on a button's Interact part. Charge Cash and apply the purchase if they can afford
-- it and the button is currently available; otherwise do nothing.
local function tryPurchase(state: PlotState, entry: ButtonEntry)
	if not state.available[entry.name] or state.debounce[entry.name] then
		return
	end
	state.debounce[entry.name] = true

	local player = state.player
	local cash = DataService:get(player, { "Cash" })
	if type(cash) == "number" and cash >= entry.cost and state.available[entry.name] then
		-- Deduct then record + apply. Neither DataService call yields and the button is removed
		-- from `available` inside applyPurchase, so a second touch can't double-charge.
		DataService:update(player, { "Cash" }, function(current: number?)
			return (current or 0) - entry.cost
		end)
		DataService:set(player, { "PlotButtonsBought", entry.name }, true)
		applyPurchase(state, entry)
	end

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
	local revealed: { [number]: boolean } = {}
	if state.buttonsByIndex[1] then
		revealed[1] = true
	end

	for name, isBought in bought do
		if isBought then
			local entry = state.buttons[name]
			if entry then
				unlockSpawnable(state, entry.unlockId)
				revealed[entry.index + 1] = true
				if entry.unlockTwo then
					revealed[entry.index + 2] = true
				end
			end
		end
	end

	for index in revealed do
		local entry = state.buttonsByIndex[index]
		if entry and not bought[entry.name] then
			revealButton(state, entry.index)
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

-- Award Gems once per second for every unlocked spawnable, summed per plot (GemRate attribute;
-- absent/0 = nothing). Fractional rates accumulate so they eventually pay out whole gems.
-- Gems/second a plot currently produces under the worker + buff model:
--   * WORKERS (Config.PlotWorkerSpawnables) each contribute PlotWorkerBaseGemRate to the base.
--   * Every active spawnable's GemFlatPerWorker adds to each worker's base (before the multiplier);
--     every GemMultiplier scales each worker's output (stacking multiplicatively). Workers have no
--     attributes, so buffs come purely from the other unlocked spawnables.
--   * Standalone GemRate generators (if any) are added on top, outside the worker model.
-- With no workers active, buffs scale nothing and only standalone GemRate income remains.
local function computeGemsPerSecond(state: PlotState): number
	local workerCount = 0
	local flatPerWorker = 0
	local multiplier = 1
	local standalone = 0

	for name in state.active do
		local model = state.spawnables[name]
		if model then
			if Config.PlotWorkerSpawnables[name] then
				workerCount += 1
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
	return perWorker * workerCount + standalone
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
				local total = computeGemsPerSecond(state)
				if total > 0 and stateByPlot[state.plot] == state then
					local acc = (gemAccum[state.plot] or 0) + total
					local whole = math.floor(acc)
					gemAccum[state.plot] = acc - whole
					if whole > 0 then
						ProgressionService.awardGems(state.player, whole)
					end
				end
			end
		end
	end)
end

-- Register plot hooks BEFORE PlotService.init() so the join sweep and every future assignment
-- build the plot from save data.
function PlotButtonService.init()
	PlotService.onAssigned(onAssigned)
	PlotService.onReleased(onReleased)
	startGemLoop()
end

return PlotButtonService
