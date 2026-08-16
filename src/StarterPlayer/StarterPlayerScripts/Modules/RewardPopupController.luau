--!strict

-- Cash chime on a tool reward. When the server grants one it fires RewardPopup with
-- (xp, cash); a cash gain plays a short reward sound.
--
-- This used to also spawn floating "+N XP!" / "+N Cash!" labels near the crosshair.
-- Those are gone: the payout is shown in the world now, as coins bursting out of the
-- cleanable and flying into the player (VfxManager.cleanBurst / rewardBurst, fired by
-- the tool controllers). The SOUND stays here -- it's the completion audio the reward
-- always had, and the coins don't replace it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundManager = require(ReplicatedStorage.SharedModules.SoundManager)

local RewardPopup = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RewardPopup") :: RemoteEvent

-- Cash gains play a quick chime: just the first slice of the Reward sound.
local CASH_SOUND = "Reward"
local CASH_SOUND_DURATION = 0.55

local RewardPopupController = {}

function RewardPopupController.init()
	RewardPopup.OnClientEvent:Connect(function(_xp: number, cash: number)
		if cash > 0 then
			SoundManager.playOneShot(CASH_SOUND, { duration = CASH_SOUND_DURATION })
		end
	end)
end

return RewardPopupController
