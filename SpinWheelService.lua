-- // Services \\ --

local replicatedStorage = game:GetService("ReplicatedStorage")
local players = game:GetService("Players")

-- // Object Variables \\ --

local packages = replicatedStorage:WaitForChild("Packages")

-- // Loaded Modules \\ --

local knit = require(packages:WaitForChild("Knit"))
local spinWheelData = require(replicatedStorage:WaitForChild("Game"):WaitForChild("Shared"):WaitForChild("List"):WaitForChild("SpinWheel"))

-- // Knit Setup \\ --

local spinWheelService = knit.CreateService{
	Name = "SpinWheelService",
	Client = {
		Spin = knit.CreateSignal(),
		SelectedReward = knit.CreateSignal(),
		SpinFromServer = knit.CreateSignal()
	}
}

local dataService
local petService
local challengesService
local rewardsService
local petAbilityService

-- // Private Functions \\ --

local function initializeData(player)
	task.spawn(function()
		repeat
			task.wait(0.1)
		until dataService:GetProfile(player)
		
		local profile = dataService:GetProfile(player)._Data

		if not profile["SpinWheelData"] then
			profile["SpinWheelData"] = {}
		end

		for wheelName, wheelData in pairs(spinWheelData) do
			if not profile["SpinWheelData"][wheelName] then
				profile["SpinWheelData"][wheelName] = 0
			end
		end
	end)
end

local function validatePlayer(player, rewardName)
	local rewardData = spinWheelData[rewardName]

	if (rewardData["GroupId"] and player:IsInGroup(rewardData["GroupId"])) or not rewardData["GroupId"] then

		local profile = dataService:GetProfile(player)._Data

		if os.time() >= profile["SpinWheelData"][rewardName] then
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

	for _,v in pairs (spinWheelData[rewardName]["Rewards"]) do
		if v["RewardChance"] >= 8 then
			weight += v["RewardChance"]
		else
			local extraBoost = petAbilityService:GetBoostByAbility(player, "BetterLuckRewards")
			
			weight += v["RewardChance"] + extraBoost
		end
	end

	local rng = Random.new():NextNumber(0, weight)
	for i,v in pairs (spinWheelData[rewardName]["Rewards"]) do
		
		if v["RewardChance"] >= 8 then
			weight -= v["RewardChance"]
		else
			local extraBoost = petAbilityService:GetBoostByAbility(player, "BetterLuckRewards")

			weight -= v["RewardChance"] + extraBoost
		end
		
		if (weight < rng) then
			return i
		end
	end
end

local function rewardPlayer(player, reward)
	rewardsService:RewardPlayer(player, reward)
end

local function spin(player, spinName)
	if spinName then
		local spinData = spinWheelData[spinName]

		if validatePlayer(player, spinName) then
			local profile = dataService:GetProfile(player)._Data
			local randomReward = getRandomReward(player, spinName)

			spinWheelService.Client.SelectedReward:Fire(player, randomReward)

			profile["SpinWheelData"][spinName] = os.time() + spinData["ResetsEvery"]

			challengesService:ProgressChallenge(player, "Spin The Wheel", spinName, 1)

			rewardPlayer(player, spinData["Rewards"][randomReward])
		end
	end
end

-- // Public Functions \\ --

function spinWheelService:RobuxSpin(player, spinName)
	local profile = dataService:GetProfile(player)._Data
	local randomReward = getRandomReward(player, spinName)
	local spinData = spinWheelData[spinName]
	
	profile["SpinWheelData"][spinName] = 0
	
	spinWheelService.Client.SpinFromServer:Fire(player, spinName)
	
	task.wait(0.1)
	
	challengesService:ProgressChallenge(player, "Spin The Wheel", spinName)
	
	spinWheelService.Client.SelectedReward:Fire(player, randomReward)

	rewardPlayer(player, spinData["Rewards"][randomReward])
end

function spinWheelService:KnitStart()
	task.wait(0.5)
	
	dataService = knit.GetService("DataService")
	petService = knit.GetService("PetService")
	challengesService = knit.GetService("ChallengesService")
	petAbilityService = knit.GetService("PetAbilityService")
	rewardsService = knit.GetService("RewardsService")
	
	spinWheelService.Client.Spin:Connect(spin)
	
	players.PlayerAdded:Connect(initializeData)
	
	for _, player in pairs(players:GetPlayers()) do
		initializeData(player)
	end
end

-- // Initialize \\ --

return spinWheelService
