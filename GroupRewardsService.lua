-- Discord: wiggledev | Roblox: WiggleDev

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local GameFolder = ReplicatedStorage:WaitForChild("Game")
local SharedFolder = GameFolder:WaitForChild("Shared")
local ListFolder = SharedFolder:WaitForChild("List")

local Knit = require(Packages:WaitForChild("Knit"))
local GroupRewardsList = require(ListFolder:WaitForChild("GroupRewards"))

local GroupRewardsService = Knit.CreateService({
	Name = "GroupRewardsService",
	Client = {
		RequestSpin = Knit.CreateSignal(),
		SelectedReward = Knit.CreateSignal(),
	},
})

local DataService
local ChallengesService
local RewardsService
local PetAbilityService

-- Tracks spins currently being processed so a player cannot trigger the same
-- reward repeatedly before the cooldown is saved by the server.
local activeSpins = {}

-- Returns the loaded profile container used by this game's data system.
-- Keeping profile access in one function avoids repeated unsafe indexing.
local function getProfileData(player)
	local profile = DataService:GetProfile(player)
	if not profile then
		return nil
	end

	return profile._Data
end

-- Waits for DataService to finish loading a player's profile. The loop stops
-- when the player leaves so an abandoned task cannot continue indefinitely.
local function waitForProfileData(player)
	while player.Parent == Players do
		local profileData = getProfileData(player)
		if profileData then
			return profileData
		end

		task.wait(0.1)
	end

	return nil
end

-- Creates missing cooldown entries without overwriting existing timestamps.
-- Each configured group reward receives its own independent cooldown value.
local function initializeRewardCooldowns(profileData)
	profileData.GroupRewardsData = profileData.GroupRewardsData or {}

	for rewardName in pairs(GroupRewardsList) do
		if profileData.GroupRewardsData[rewardName] == nil then
			profileData.GroupRewardsData[rewardName] = 0
		end
	end
end

local function initializePlayerData(player)
	task.spawn(function()
		local profileData = waitForProfileData(player)
		if not profileData then
			return
		end

		initializeRewardCooldowns(profileData)
	end)
end

local function getRewardConfiguration(rewardName)
	if typeof(rewardName) ~= "string" then
		return nil
	end

	return GroupRewardsList[rewardName]
end

local function isGroupRequirementMet(player, groupId)
	if groupId == 1 then
		return true
	end

	local success, isInGroup = pcall(function()
		return player:IsInGroup(groupId)
	end)

	if not success then
		warn(string.format(
			"[GroupRewardsService] Failed to check group membership for %s (%d)",
			player.Name,
			player.UserId
		))
		return false
	end

	return isInGroup
end

-- Validates all server-authoritative requirements before a spin is accepted.
-- The client only supplies a reward name and cannot decide eligibility itself.
local function validateSpin(player, rewardName)
	local rewardData = getRewardConfiguration(rewardName)
	if not rewardData then
		return false, "InvalidReward"
	end

	local profileData = getProfileData(player)
	if not profileData then
		return false, "ProfileNotLoaded"
	end

	initializeRewardCooldowns(profileData)

	if not isGroupRequirementMet(player, rewardData.GroupId) then
		return false, "NotInGroup"
	end

	local cooldownEndsAt = profileData.GroupRewardsData[rewardName] or 0
	if os.time() < cooldownEndsAt then
		return false, "Cooldown"
	end

	return true, rewardData, profileData
end

local function getLuckBoost(player)
	local success, boost = pcall(function()
		return PetAbilityService:GetBoostByAbility(player, "BetterLuckRewards")
	end)

	if not success or typeof(boost) ~= "number" then
		return 0
	end

	return math.max(boost, 0)
end

-- Builds adjusted weights once per spin. BetterLuckRewards only affects rewards
-- whose base chance is 8 or lower, preserving the behavior of the old service.
local function buildRewardWeights(player, rewards)
	local luckBoost = getLuckBoost(player)
	local weightedRewards = {}
	local totalWeight = 0

	for rewardIndex, rewardData in ipairs(rewards) do
		local baseChance = tonumber(rewardData.RewardChance) or 0
		local adjustedChance = baseChance

		if baseChance <= 8 then
			adjustedChance += luckBoost
		end

		if adjustedChance > 0 then
			totalWeight += adjustedChance
			table.insert(weightedRewards, {
				Index = rewardIndex,
				Weight = adjustedChance,
			})
		end
	end

	return weightedRewards, totalWeight
end

-- Uses a cumulative weighted roll, which is easier to verify than repeatedly
-- subtracting from the total weight while iterating through the reward table.
local function selectRandomReward(player, rewards)
	local weightedRewards, totalWeight = buildRewardWeights(player, rewards)
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

	return weightedRewards[#weightedRewards].Index
end

local function grantReward(player, rewardData)
	local success, result = pcall(function()
		return RewardsService:RewardPlayer(player, rewardData)
	end)

	if not success then
		warn(string.format(
			"[GroupRewardsService] Failed to reward %s: %s",
			player.Name,
			tostring(result)
		))
		return false
	end

	-- Some reward services do not return a value on success. Only an explicit
	-- false is treated as failure so both API styles remain compatible.
	if result == false then
		warn(string.format(
			"[GroupRewardsService] RewardsService rejected reward for %s",
			player.Name
		))
		return false
	end

	return true
end

local function progressChallenge(player, rewardName)
	local success, err = pcall(function()
		-- Preserve the existing ChallengesService call signature used by the game.
		ChallengesService:ProgressChallenge("GroupRewards", rewardName, 1)
	end)

	if not success then
		warn(string.format(
			"[GroupRewardsService] Failed to progress challenge for %s: %s",
			player.Name,
			tostring(err)
		))
	end
end

local function getSpinKey(player, rewardName)
	return string.format("%d:%s", player.UserId, rewardName)
end

local function processSpin(player, rewardName)
	local isValid, rewardDataOrReason, profileData = validateSpin(player, rewardName)
	if not isValid then
		return false, rewardDataOrReason
	end

	local rewardData = rewardDataOrReason
	local rewards = rewardData.Rewards

	if typeof(rewards) ~= "table" or #rewards == 0 then
		warn(string.format(
			"[GroupRewardsService] Reward list '%s' has no configured rewards",
			rewardName
		))
		return false, "NoRewards"
	end

	local selectedRewardIndex = selectRandomReward(player, rewards)
	if not selectedRewardIndex then
		return false, "InvalidWeights"
	end

	local selectedReward = rewards[selectedRewardIndex]
	local previousCooldown = profileData.GroupRewardsData[rewardName] or 0
	local resetDuration = math.max(tonumber(rewardData.ResetsEvery) or 0, 0)

	-- Reserve the cooldown before granting the reward. This closes the small
	-- window in which multiple remote requests could otherwise all pass validation.
	profileData.GroupRewardsData[rewardName] = os.time() + resetDuration

	local rewardGranted = grantReward(player, selectedReward)
	if not rewardGranted then
		profileData.GroupRewardsData[rewardName] = previousCooldown
		return false, "RewardFailed"
	end

	GroupRewardsService.Client.SelectedReward:Fire(player, selectedRewardIndex)
	progressChallenge(player, rewardName)

	return true
end

local function spin(player, rewardName)
	local rewardData = getRewardConfiguration(rewardName)
	if not rewardData then
		return
	end

	local spinKey = getSpinKey(player, rewardName)
	if activeSpins[spinKey] then
		return
	end

	activeSpins[spinKey] = true

	local success, err = pcall(function()
		processSpin(player, rewardName)
	end)

	activeSpins[spinKey] = nil

	if not success then
		warn(string.format(
			"[GroupRewardsService] Unexpected spin error for %s: %s",
			player.Name,
			tostring(err)
		))
	end
end

local function clearPlayerState(player)
	local keyPrefix = tostring(player.UserId) .. ":"

	for spinKey in pairs(activeSpins) do
		if string.sub(spinKey, 1, #keyPrefix) == keyPrefix then
			activeSpins[spinKey] = nil
		end
	end
end

function GroupRewardsService:KnitStart()
	task.wait(0.5)

	DataService = Knit.GetService("DataService")
	ChallengesService = Knit.GetService("ChallengesService")
	PetAbilityService = Knit.GetService("PetAbilityService")
	RewardsService = Knit.GetService("RewardsService")

	self.Client.RequestSpin:Connect(spin)
	Players.PlayerAdded:Connect(initializePlayerData)
	Players.PlayerRemoving:Connect(clearPlayerState)

	for _, player in ipairs(Players:GetPlayers()) do
		initializePlayerData(player)
	end
end

return GroupRewardsService
