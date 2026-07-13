-- Discord: wiggledev | Roblox: WiggleDev

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local BadgeService = game:GetService("BadgeService")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local BadgesList = require(Knit.Shared.List.Badges)
local NPCList = require(Knit.Shared.List.NPC)

local BadgesService = Knit.CreateService({
	Name = "BadgesService",
	Client = {
		SpokenToNPC = Knit.CreateSignal(),
		ClaimReward = Knit.CreateSignal(),
	},
})

local DataService
local RewardsService

-- Runtime caches avoid repeatedly scanning the full configuration during gameplay.
-- Requirements are indexed by their actual stat name, while named badge data supports direct awards.
local badgeRequirementsByStat = {}
local badgeDataByName = {}
local requiredNPCs = {}

local function getReplica(player)
	local profile = DataService:GetProfile(player)
	if not profile then
		return nil
	end

	return profile._Replica
end

-- Player profiles can load after the Player object appears, so initialization waits without blocking KnitStart.
local function waitForReplica(player)
	local replica = getReplica(player)

	while not replica and player.Parent do
		task.wait(0.5)
		replica = getReplica(player)
	end

	return replica
end

local function contains(array, value)
	return table.find(array, value) ~= nil
end

local function ensureArray(replica, key)
	if replica.Data[key] then
		return
	end

	replica:SetValue(key, {})
end

-- Older profiles may not contain fields introduced after their original save was created.
local function ensureBadgeData(replica)
	ensureArray(replica, "AwardedBadges")
	ensureArray(replica, "ClaimedBadges")
	ensureArray(replica, "SpokenNPCs")
end

local function hasAwardedBadge(replica, badgeName)
	return contains(replica.Data.AwardedBadges, badgeName)
end

local function hasClaimedBadge(replica, badgeName)
	return contains(replica.Data.ClaimedBadges, badgeName)
end

local function addAwardedBadge(replica, badgeName)
	if hasAwardedBadge(replica, badgeName) then
		return
	end

	replica:ArrayInsert("AwardedBadges", badgeName)
end

local function addClaimedBadge(replica, badgeName)
	if hasClaimedBadge(replica, badgeName) then
		return
	end

	replica:ArrayInsert("ClaimedBadges", badgeName)
end

-- BadgeService calls are wrapped because Roblox API requests can fail temporarily.
local function getRobloxBadgeInfo(badgeId)
	local success, result = pcall(BadgeService.GetBadgeInfoAsync, BadgeService, badgeId)
	if success then
		return result
	end

	warn(string.format("Failed to load badge info for BadgeId %s: %s", tostring(badgeId), tostring(result)))
	return nil
end

local function userHasRobloxBadge(player, badgeId)
	local success, result = pcall(BadgeService.UserHasBadgeAsync, BadgeService, player.UserId, badgeId)
	if success then
		return result
	end

	warn(string.format("Failed to check badge ownership for BadgeId %s: %s", tostring(badgeId), tostring(result)))
	return nil
end

local function awardRobloxBadge(player, badgeId)
	local success, result = pcall(BadgeService.AwardBadge, BadgeService, player.UserId, badgeId)
	if success then
		return result
	end

	warn(string.format("Failed to award BadgeId %s: %s", tostring(badgeId), tostring(result)))
	return nil
end

local function registerBadge(badgeName, badgeData)
	badgeDataByName[badgeName] = badgeData

	if not badgeData.Category or not badgeData.AwardAt then
		return
	end

	local badgeInfo = getRobloxBadgeInfo(badgeData.Id)
	if not badgeInfo then
		return
	end

	local statName = badgeData.Category
	badgeRequirementsByStat[statName] = badgeRequirementsByStat[statName] or {}
	table.insert(badgeRequirementsByStat[statName], {
		AwardAt = badgeData.AwardAt,
		BadgeId = badgeData.Id,
		BadgeName = badgeInfo.Name,
	})
end

local function prepareBadges()
	table.clear(badgeRequirementsByStat)
	table.clear(badgeDataByName)

	for _, badges in pairs(BadgesList.BadgesInfo) do
		for badgeName, badgeData in pairs(badges) do
			registerBadge(badgeName, badgeData)
		end
	end
end

local function createRewardPayload(badgeName)
	local badgeInfo = BadgesList.GetBadgeInfo(badgeName)
	if not badgeInfo then
		return nil
	end

	return {
		RewardType = badgeInfo.RewardType,
		RewardName = badgeInfo.RewardName,
		RewardValue = badgeInfo.RewardValue,
		PetCraft = badgeInfo.PetCraft,
	}
end

local function rewardBadge(player, badgeName)
	local replica = getReplica(player)
	if not replica then
		return
	end

	if not hasAwardedBadge(replica, badgeName) then
		return
	end

	if hasClaimedBadge(replica, badgeName) then
		return
	end

	local rewardPayload = createRewardPayload(badgeName)
	if not rewardPayload then
		warn("No reward configuration found for badge: " .. tostring(badgeName))
		return
	end

	-- The claim is persisted only after the reward call succeeds, preventing lost rewards on errors.
	local success, result = pcall(RewardsService.RewardPlayer, RewardsService, player, rewardPayload)
	if not success then
		warn(string.format("Failed to reward badge %s: %s", tostring(badgeName), tostring(result)))
		return
	end

	if result == false then
		warn("RewardsService rejected reward for badge: " .. tostring(badgeName))
		return
	end

	addClaimedBadge(replica, badgeName)
end

local function hasSpokenToAllRequiredNPCs(replica)
	for _, npcName in ipairs(requiredNPCs) do
		if not contains(replica.Data.SpokenNPCs, npcName) then
			return false
		end
	end

	return true
end

local function checkNPCBadge(player, replica)
	if not hasSpokenToAllRequiredNPCs(replica) then
		return
	end

	BadgesService:AwardBadge(player, "People's Person")
end

local function speakToNPC(player, npcName)
	if not NPCList.Get(npcName) then
		return
	end

	local replica = getReplica(player)
	if not replica then
		return
	end

	if contains(replica.Data.SpokenNPCs, npcName) then
		return
	end

	replica:ArrayInsert("SpokenNPCs", npcName)
	checkNPCBadge(player, replica)
end

local function syncOwnedBadge(replica, badgeName)
	addAwardedBadge(replica, badgeName)
end

local function restoreMissingRobloxBadge(player, replica, badgeId, badgeName)
	local result = awardRobloxBadge(player, badgeId)
	if not result then
		return
	end

	addAwardedBadge(replica, badgeName)
end

-- Reconciliation keeps Roblox badge ownership and persistent profile data consistent in both directions.
local function reconcileBadge(player, replica, badgeData)
	local badgeInfo = getRobloxBadgeInfo(badgeData.Id)
	if not badgeInfo then
		return
	end

	local ownsRobloxBadge = userHasRobloxBadge(player, badgeData.Id)
	if ownsRobloxBadge == nil then
		return
	end

	local ownsLocalBadge = hasAwardedBadge(replica, badgeInfo.Name)

	if ownsRobloxBadge then
		syncOwnedBadge(replica, badgeInfo.Name)
		return
	end

	if not ownsLocalBadge then
		return
	end

	restoreMissingRobloxBadge(player, replica, badgeData.Id, badgeInfo.Name)
end

local function reconcileAllBadges(player, replica)
	for _, badges in pairs(BadgesList.BadgesInfo) do
		for badgeName, badgeData in pairs(badges) do
			reconcileBadge(player, replica, badgeData)
		end
	end
end

local function reconcileData(player)
	task.spawn(function()
		local replica = waitForReplica(player)
		if not replica then
			return
		end

		ensureBadgeData(replica)
		reconcileAllBadges(player, replica)
		checkNPCBadge(player, replica)
	end)
end

local function awardBadgeLocally(replica, badgeName)
	addAwardedBadge(replica, badgeName)
end

local function awardBadgeNormally(player, replica, badgeId, badgeName)
	local result = awardRobloxBadge(player, badgeId)
	if not result then
		return false
	end

	addAwardedBadge(replica, badgeName)
	return true
end

-- Studio cannot reliably grant live Roblox badges, so tests record them only in profile data.
local function awardConfiguredBadge(player, replica, badgeId, badgeName)
	if RunService:IsStudio() then
		awardBadgeLocally(replica, badgeName)
		return true
	end

	return awardBadgeNormally(player, replica, badgeId, badgeName)
end

local function shouldAwardRequirement(replica, statValue, requirement)
	if statValue < requirement.AwardAt then
		return false
	end

	return not hasAwardedBadge(replica, requirement.BadgeName)
end

function BadgesService:BadgeCheckup(player, changedStat)
	local replica = getReplica(player)
	if not replica then
		return
	end

	local requirements = badgeRequirementsByStat[changedStat]
	if not requirements then
		return
	end

	local statValue = replica.Data[changedStat]
	if type(statValue) ~= "number" then
		return
	end

	for _, requirement in ipairs(requirements) do
		if shouldAwardRequirement(replica, statValue, requirement) then
			awardConfiguredBadge(player, replica, requirement.BadgeId, requirement.BadgeName)
		end
	end
end

function BadgesService:AwardBadge(player, badgeName)
	local replica = getReplica(player)
	if not replica then
		return false
	end

	if hasAwardedBadge(replica, badgeName) then
		return true
	end

	local badgeData = badgeDataByName[badgeName]
	if not badgeData or not badgeData.Id then
		warn("Badge configuration not found for: " .. tostring(badgeName))
		return false
	end

	return awardConfiguredBadge(player, replica, badgeData.Id, badgeName)
end

local function findNPCFolder(container, worldName)
	local world = container:FindFirstChild(worldName)
	if not world then
		return nil
	end

	local interactables = world:FindFirstChild("Interactables")
	if not interactables then
		return nil
	end

	return interactables:FindFirstChild("NPC")
end

local function npcExists(container, worldName, npcName)
	if not container then
		return false
	end

	local npcFolder = findNPCFolder(container, worldName)
	if not npcFolder then
		return false
	end

	return npcFolder:FindFirstChild(npcName) ~= nil
end

local function isRequiredNPC(worldName, npcName, npcInfo)
	if not npcInfo.CountForBadge or not npcInfo.Dialogue then
		return false
	end

	local workspaceMaps = workspace:FindFirstChild("Maps")
	local replicatedWorlds = ReplicatedStorage:FindFirstChild("Worlds")

	return npcExists(workspaceMaps, worldName, npcName)
		or npcExists(replicatedWorlds, worldName, npcName)
end

-- Only NPCs present in an active or replicated world count toward the conversation badge.
local function prepareRequiredNPCs()
	table.clear(requiredNPCs)

	for worldName, worldData in pairs(NPCList.List) do
		for npcName, npcInfo in pairs(worldData) do
			if isRequiredNPC(worldName, npcName, npcInfo) then
				table.insert(requiredNPCs, npcName)
			end
		end
	end
end

local function initializePlayer(player)
	reconcileData(player)

	task.spawn(function()
		local replica = waitForReplica(player)
		if not replica then
			return
		end

		BadgesService:BadgeCheckup(player, "Hatched")
		BadgesService:BadgeCheckup(player, "Origami")
	end)
end

function BadgesService:KnitStart()
	DataService = Knit.GetService("DataService")
	RewardsService = Knit.GetService("RewardsService")

	prepareBadges()
	prepareRequiredNPCs()

	self.Client.SpokenToNPC:Connect(speakToNPC)
	self.Client.ClaimReward:Connect(rewardBadge)

	for _, player in ipairs(Players:GetPlayers()) do
		initializePlayer(player)
	end

	Players.PlayerAdded:Connect(initializePlayer)
end

return BadgesService
