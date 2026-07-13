-- Discord: wiggledev | Roblox: WiggleDev

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Game = ReplicatedStorage:WaitForChild("Game")
local Shared = Game:WaitForChild("Shared")
local Lists = Shared:WaitForChild("List")

local Knit = require(Packages:WaitForChild("Knit"))
local SpinWheelData = require(Lists:WaitForChild("SpinWheel"))

local PROFILE_WAIT_INTERVAL = 0.1
local ROBUX_SPIN_DELAY = 0.1
local LUCK_THRESHOLD = 8
local LUCK_ABILITY_NAME = "BetterLuckRewards"
local SPIN_CHALLENGE_NAME = "Spin The Wheel"

local SpinWheelService = Knit.CreateService({
	Name = "SpinWheelService",
	Client = {
		Spin = Knit.CreateSignal(),
		SelectedReward = Knit.CreateSignal(),
		SpinFromServer = Knit.CreateSignal(),
	},
})

local DataService
local ChallengesService
local RewardsService
local PetAbilityService

-- Tracks players currently processing a normal spin.
-- This prevents duplicated remote requests from granting multiple rewards.
local activeSpins = {}

local function getProfileContainer(player)
	local profile = DataService:GetProfile(player)
	if not profile then
		return nil
	end

	return profile._Data
end

local function waitForProfile(player)
	while player.Parent == Players do
		local profile = getProfileContainer(player)
		if profile then
			return profile
		end

		task.wait(PROFILE_WAIT_INTERVAL)
	end

	return nil
end

local function getSpinWheelContainer(profile)
	local container = profile.SpinWheelData
	if container then
		return container
	end

	container = {}
	profile.SpinWheelData = container

	return container
end

-- Ensures every configured wheel has a stored cooldown timestamp.
-- Existing values are preserved so rejoining does not reset cooldowns.
local function initializeWheelEntries(profile)
	local wheelContainer = getSpinWheelContainer(profile)

	for wheelName in pairs(SpinWheelData) do
		if wheelContainer[wheelName] == nil then
			wheelContainer[wheelName] = 0
		end
	end
end

local function initializeData(player)
	task.spawn(function()
		local profile = waitForProfile(player)
		if not profile then
			return
		end

		initializeWheelEntries(profile)
	end)
end

local function getWheelData(spinName)
	if type(spinName) ~= "string" then
		return nil
	end

	return SpinWheelData[spinName]
end

local function isPlayerInRequiredGroup(player, wheelData)
	local groupId = wheelData.GroupId
	if not groupId then
		return true
	end

	local success, result = pcall(function()
		return player:IsInGroup(groupId)
	end)

	if not success then
		warn(
			"[SpinWheelService] Group membership check failed for",
			player.Name,
			"group",
			groupId
		)

		return false
	end

	return result
end

local function getCooldownTimestamp(profile, spinName)
	local wheelContainer = getSpinWheelContainer(profile)
	local timestamp = wheelContainer[spinName]

	if type(timestamp) ~= "number" then
		timestamp = 0
		wheelContainer[spinName] = timestamp
	end

	return timestamp
end

local function isCooldownReady(profile, spinName)
	return os.time() >= getCooldownTimestamp(profile, spinName)
end

local function validatePlayer(player, spinName)
	local wheelData = getWheelData(spinName)
	if not wheelData then
		return false, "InvalidWheel"
	end

	local profile = getProfileContainer(player)
	if not profile then
		return false, "ProfileNotLoaded"
	end

	if not isPlayerInRequiredGroup(player, wheelData) then
		return false, "NotInGroup"
	end

	if not isCooldownReady(profile, spinName) then
		return false, "Cooldown"
	end

	return true, nil, profile, wheelData
end

local function getLuckBoost(player)
	local success, result = pcall(function()
		return PetAbilityService:GetBoostByAbility(
			player,
			LUCK_ABILITY_NAME
		)
	end)

	if not success then
		warn(
			"[SpinWheelService] Failed to read luck boost for",
			player.Name
		)

		return 0
	end

	if type(result) ~= "number" then
		return 0
	end

	return math.max(result, 0)
end

local function getAdjustedRewardWeight(reward, luckBoost)
	local rewardChance = reward.RewardChance
	if type(rewardChance) ~= "number" then
		return 0
	end

	if rewardChance >= LUCK_THRESHOLD then
		return math.max(rewardChance, 0)
	end

	return math.max(rewardChance + luckBoost, 0)
end

local function buildWeightedRewardList(player, rewards)
	local weightedRewards = {}
	local totalWeight = 0
	local luckBoost = getLuckBoost(player)

	for rewardIndex, reward in pairs(rewards) do
		local adjustedWeight = getAdjustedRewardWeight(
			reward,
			luckBoost
		)

		if adjustedWeight > 0 then
			totalWeight += adjustedWeight

			table.insert(weightedRewards, {
				Index = rewardIndex,
				Weight = adjustedWeight,
			})
		end
	end

	return weightedRewards, totalWeight
end

-- Selects a reward using a cumulative weighted roll.
-- The original reward key is returned so array and dictionary configs both work.
local function getRandomReward(player, spinName)
	local wheelData = getWheelData(spinName)
	if not wheelData then
		return nil
	end

	local rewards = wheelData.Rewards
	if type(rewards) ~= "table" then
		return nil
	end

	local weightedRewards, totalWeight =
		buildWeightedRewardList(player, rewards)

	if totalWeight <= 0 then
		return nil
	end

	local roll = Random.new():NextNumber(0, totalWeight)
	local cumulativeWeight = 0

	for _, weightedReward in ipairs(weightedRewards) do
		cumulativeWeight += weightedReward.Weight

		if roll <= cumulativeWeight then
			return weightedReward.Index
		end
	end

	local fallbackReward = weightedRewards[#weightedRewards]
	return fallbackReward and fallbackReward.Index or nil
end

local function setCooldown(profile, spinName, wheelData)
	local wheelContainer = getSpinWheelContainer(profile)
	local resetDuration = wheelData.ResetsEvery

	if type(resetDuration) ~= "number" then
		resetDuration = 0
	end

	wheelContainer[spinName] = os.time() + math.max(resetDuration, 0)
end

local function resetCooldown(profile, spinName)
	local wheelContainer = getSpinWheelContainer(profile)
	wheelContainer[spinName] = 0
end

local function rewardPlayer(player, reward)
	if type(reward) ~= "table" then
		return false
	end

	local success, result = pcall(function()
		return RewardsService:RewardPlayer(player, reward)
	end)

	if not success then
		warn(
			"[SpinWheelService] Failed to reward",
			player.Name,
			result
		)

		return false
	end

	if result == false then
		return false
	end

	return true
end

local function progressSpinChallenge(player, spinName, amount)
	local success, errorMessage = pcall(function()
		ChallengesService:ProgressChallenge(
			player,
			SPIN_CHALLENGE_NAME,
			spinName,
			amount
		)
	end)

	if not success then
		warn(
			"[SpinWheelService] Failed to progress challenge:",
			errorMessage
		)
	end
end

local function fireSelectedReward(player, rewardIndex)
	SpinWheelService.Client.SelectedReward:Fire(
		player,
		rewardIndex
	)
end

local function processSpinReward(player, spinName, wheelData)
	local rewardIndex = getRandomReward(player, spinName)
	if rewardIndex == nil then
		return false, "NoReward"
	end

	local reward = wheelData.Rewards[rewardIndex]
	if not reward then
		return false, "InvalidReward"
	end

	fireSelectedReward(player, rewardIndex)

	if not rewardPlayer(player, reward) then
		return false, "RewardFailed"
	end

	progressSpinChallenge(player, spinName, 1)

	return true
end

local function beginSpin(player)
	if activeSpins[player] then
		return false
	end

	activeSpins[player] = true
	return true
end

local function endSpin(player)
	activeSpins[player] = nil
end

local function spin(player, spinName)
	if not beginSpin(player) then
		return
	end

	local success, errorMessage = pcall(function()
		local isValid, _, profile, wheelData =
			validatePlayer(player, spinName)

		if not isValid then
			return
		end

		setCooldown(profile, spinName, wheelData)

		local rewardGranted =
			processSpinReward(player, spinName, wheelData)

		if not rewardGranted then
			resetCooldown(profile, spinName)
		end
	end)

	endSpin(player)

	if not success then
		warn(
			"[SpinWheelService] Spin processing failed for",
			player.Name,
			errorMessage
		)
	end
end

function SpinWheelService:RobuxSpin(player, spinName)
	local wheelData = getWheelData(spinName)
	if not wheelData then
		return false, "InvalidWheel"
	end

	local profile = getProfileContainer(player)
	if not profile then
		return false, "ProfileNotLoaded"
	end

	local rewardIndex = getRandomReward(player, spinName)
	if rewardIndex == nil then
		return false, "NoReward"
	end

	local reward = wheelData.Rewards[rewardIndex]
	if not reward then
		return false, "InvalidReward"
	end

	-- Robux spins bypass the normal cooldown, but still keep the stored
	-- wheel state reset so the free spin remains immediately available.
	resetCooldown(profile, spinName)

	self.Client.SpinFromServer:Fire(player, spinName)

	task.wait(ROBUX_SPIN_DELAY)

	fireSelectedReward(player, rewardIndex)

	if not rewardPlayer(player, reward) then
		return false, "RewardFailed"
	end

	progressSpinChallenge(player, spinName, 1)

	return true
end

local function onPlayerRemoving(player)
	activeSpins[player] = nil
end

function SpinWheelService:KnitStart()
	DataService = Knit.GetService("DataService")
	ChallengesService = Knit.GetService("ChallengesService")
	RewardsService = Knit.GetService("RewardsService")
	PetAbilityService = Knit.GetService("PetAbilityService")

	self.Client.Spin:Connect(spin)

	Players.PlayerAdded:Connect(initializeData)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in ipairs(Players:GetPlayers()) do
		initializeData(player)
	end
end

return SpinWheelService
