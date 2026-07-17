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

-- Cached lookup tables avoid scanning the full badge configuration during gameplay.
local badgeRequirementsByStat = {}
local badgeDataByName = {}
local requiredNPCs = {}

-- Returns the player's Replica once their profile is available.
local function getReplica(player)
	local profile = DataService:GetProfile(player)
	if not profile then
		return nil
	end

	return profile._Replica
end

-- Waits for profile loading, but stops if the player leaves.
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

-- Adds missing data fields for profiles created before these arrays existed.
local function ensureArray(replica, key)
	if replica.Data[key] then
		return
	end

	replica:SetValue(key, {})
end

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

-- Duplicate checks keep saved arrays clean and make repeated calls safe.
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

-- Roblox badge API calls are protected because platform requests may fail.
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

-- Registers badges by name and groups automatic badge requirements by stat.
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

-- Converts badge configuration into the format expected by RewardsService.
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

-- Claims are validated on the server and saved only after reward delivery succeeds.
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

-- Awards the conversation badge once every required NPC has been recorded.
local function checkNPCBadge(player, replica)
	if not hasSpokenToAllRequiredNPCs(replica) then
		return
	end

	BadgesService:AwardBadge(player, "People's Person")
end

-- Client input is checked against the NPC configuration before being saved.
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

-- Reconciliation keeps Roblox ownership and saved profile data consistent.
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
		for _, badgeData in pairs(badges) do
			reconcileBadge(player, replica, badgeData)
		end
	end
end

-- Profile migration and badge reconciliation run asynchronously during join.
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

-- Studio stores the badge locally because live badge awards are unreliable in testing.
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

-- Only requirements linked to the changed stat are evaluated.
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

-- Allows other server systems to award configured badges by name.
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

-- Only configured NPCs with dialogue and a matching world model count.
local function isRequiredNPC(worldName, npcName, npcInfo)
	if not npcInfo.CountForBadge or not npcInfo.Dialogue then
		return false
	end

	local workspaceMaps = workspace:FindFirstChild("Maps")
	local replicatedWorlds = ReplicatedStorage:FindFirstChild("Worlds")

	return npcExists(workspaceMaps, worldName, npcName)
		or npcExists(replicatedWorlds, worldName, npcName)
end

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

-- Existing progression is checked after the profile finishes loading.
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
