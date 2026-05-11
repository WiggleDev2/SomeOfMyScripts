-- // Services \\ --

local replicatedStorage = game:GetService("ReplicatedStorage")
local players = game:GetService("Players")

-- // Object Variables \\ --

local packages = replicatedStorage:WaitForChild("Packages")

-- // Loaded Modules \\ --

local knit = require(packages:WaitForChild("Knit"))
local groupRewardsList = require(replicatedStorage:WaitForChild("Game"):WaitForChild("Shared"):WaitForChild("List"):WaitForChild("GroupRewards"))

-- // Knit Setup \\ --

local groupRewardsService = knit.CreateService{
	Name = "GroupRewardsService",
	Client = {
		RequestSpin = knit.CreateSignal(),
		SelectedReward = knit.CreateSignal()
	}
}

local dataService
local challengesService
local rewardsService
local petAbilityService
local petService

-- // Private Functions \\ --

local function initializeData(player)
	task.spawn(function()
		repeat
			task.wait(0.1)
		until dataService:GetProfile(player)

		local profile = dataService:GetProfile(player)._Data
		local groupRewardsData = profile["GroupRewardsData"]
		
		if not groupRewardsData then
			profile["GroupRewardsData"] = {}
		end
		
		for rewardName, _ in pairs(groupRewardsList) do
			if not profile["GroupRewardsData"][rewardName] then
				profile["GroupRewardsData"][rewardName] = 0
			end
		end
	end)
end

local function validatePlayer(player, rewardName)
	local rewardData = groupRewardsList[rewardName]
	
	if player:IsInGroup(rewardData["GroupId"]) or rewardData["GroupId"] == 1 then
		
		local profile = dataService:GetProfile(player)._Data
		
		if os.time() >= profile["GroupRewardsData"][rewardName] then
			return true
		else
			return false, "Cooldown"
		end
		
	else
		return false, "NotInGroup"
	end
end

local function getRandomReward(player, rewardName)
	local weight = 0
	
	for _,v in pairs (groupRewardsList[rewardName]["Rewards"]) do
		if v["RewardChance"] > 8 then
			weight += v["RewardChance"]
		else
			weight += v["RewardChance"] + petAbilityService:GetBoostByAbility(player, "BetterLuckRewards")
		end
	end
	
	local rng = Random.new():NextNumber(0, weight)
	
	for i,v in pairs (groupRewardsList[rewardName]["Rewards"]) do
		if v["RewardChance"] > 8 then
			weight -= v["RewardChance"]
		else
			weight -= v["RewardChance"] + petAbilityService:GetBoostByAbility(player, "BetterLuckRewards")
		end
		
		if (weight < rng) then
			return i
		end
	end
end

local function rewardPlayer(player, reward)
	local profile = dataService:GetProfile(player)._Data

	rewardsService:RewardPlayer(player, reward)
end

local function spin(player, rewardName)
	if rewardName then
		local rewardData = groupRewardsList[rewardName]

		if validatePlayer(player, rewardName) then
			local profile = dataService:GetProfile(player)._Data
			local randomReward = getRandomReward(player, rewardName)
			
			groupRewardsService.Client.SelectedReward:Fire(player, randomReward)

			profile["GroupRewardsData"][rewardName] = os.time() + rewardData["ResetsEvery"]
			
			rewardPlayer(player, rewardData["Rewards"][randomReward])
			
			challengesService:ProgressChallenge("GroupRewards", rewardName, 1)
		end
	end
end

-- // Public Functions \\ --

function groupRewardsService:KnitStart()
	task.wait(0.5)
	
	dataService = knit.GetService("DataService")
	petService = knit.GetService("PetService")
	challengesService = knit.GetService("ChallengesService")
	petAbilityService = knit.GetService("PetAbilityService")
	rewardsService = knit.GetService("RewardsService")
	
	groupRewardsService.Client.RequestSpin:Connect(spin)
	
	players.PlayerAdded:Connect(initializeData)
	
	for _, player in pairs(players:GetPlayers()) do
		initializeData(player)
	end
end

-- // Initialize \\ --

return groupRewardsService
