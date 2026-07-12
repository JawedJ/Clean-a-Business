--!strict

-- Plays the plot-button purchase feedback SFX for the local player. The purchase itself is
-- resolved server-side (PlotButtonService, off the button's Interact touch), so the server fires
-- the PlotButtonSound remote with whether it went through; we just map that to a one-shot sound.
--   * bought == true  -> "ButtonPurchase" (they could afford it and it was bought)
--   * bought == false -> silent (they stepped on it but couldn't afford it -- no fail SFX)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

local PlotButtonSound = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PlotButtonSound") :: RemoteEvent

local PURCHASE_SOUND = "ButtonPurchase"
-- Skip the first 0.1s of the buy sound (trims its lead-in so it feels snappier).
local PURCHASE_START_TIME = 0.1

local PlotButtonSoundController = {}

function PlotButtonSoundController.init()
	PlotButtonSound.OnClientEvent:Connect(function(bought: boolean)
		-- Only the successful buy makes a sound; a failed (can't-afford) touch stays silent.
		if bought then
			SoundManager.playOneShot(PURCHASE_SOUND, { startTime = PURCHASE_START_TIME })
		end
	end)
end

return PlotButtonSoundController
