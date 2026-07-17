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

-- Retrieves the Replica attached to the player's loaded profile.
-- Returning nil keeps every caller safe when DataService has not finished loading or the player leaves early.
local function getReplica(player)
	local profile = DataService:GetProfile(player)
	if not profile then
		return nil
	end

	return profile._Replica
end

-- Profile loading is asynchronous, so this helper repeatedly checks for the Replica after the Player exists.
-- The player.Parent condition stops the loop when the player leaves, preventing an abandoned task from waiting forever.
local function waitForReplica(player)
	local replica = getReplica(player)

	while not replica and player.Parent do
		task.wait(0.5)
		replica = getReplica(player)
	end

	return replica
end

-- Centralizes membership checks for profile arrays so badge, reward, and NPC logic use the same comparison behavior.
-- table.find returns an index or nil, which is converted into a clear boolean result for callers.
local function contains(array, value)
	return table.find(array, value) ~= nil
end

-- Adds a missing array field to older player data without overwriting values that already exist.
-- Replica:SetValue is used instead of direct assignment so the replicated profile stays synchronized with clients.
local function ensureArray(replica, key)
	if replica.Data[key] then
		return
	end

	replica:SetValue(key, {})
end

-- Migrates older profiles by guaranteeing that every collection used by this service exists before access.
-- Keeping migration in one place prevents nil indexing throughout the rest of the badge system.
local function ensureBadgeData(replica)
	ensureArray(replica, "AwardedBadges")
	ensureArray(replica, "ClaimedBadges")
	ensureArray(replica, "SpokenNPCs")
end

-- Checks the persistent awarded-badge list rather than querying Roblox for routine gameplay decisions.
-- This avoids unnecessary web requests and makes repeated award checks inexpensive.
local function hasAwardedBadge(replica, badgeName)
	return contains(replica.Data.AwardedBadges, badgeName)
end

-- Determines whether a badge reward was already collected, which makes reward claims idempotent.
-- The persistent check prevents duplicate rewards after reconnects or repeated client requests.
local function hasClaimedBadge(replica, badgeName)
	return contains(replica.Data.ClaimedBadges, badgeName)
end

-- Records local badge ownership only when it is not already present.
-- The duplicate guard keeps profile arrays clean and prevents repeated replication updates.
local function addAwardedBadge(replica, badgeName)
	if hasAwardedBadge(replica, badgeName) then
		return
	end

	replica:ArrayInsert("AwardedBadges", badgeName)
end

-- Persists a successful reward claim exactly once.
-- This helper is called only after reward delivery succeeds so failed rewards remain claimable.
local function addClaimedBadge(replica, badgeName)
	if hasClaimedBadge(replica, badgeName) then
		return
	end

	replica:ArrayInsert("ClaimedBadges", badgeName)
end

-- Loads Roblox badge metadata needed to map configured badge IDs to their official names.
-- The API call is protected because network or platform failures should not stop the service from starting.
local function getRobloxBadgeInfo(badgeId)
	local success, result = pcall(BadgeService.GetBadgeInfoAsync, BadgeService, badgeId)
	if success then
		return result
	end

	warn(string.format("Failed to load badge info for BadgeId %s: %s", tostring(badgeId), tostring(result)))
	return nil
end

-- Checks platform-side badge ownership during reconciliation.
-- A nil result represents an API failure and is kept distinct from false, which means the player genuinely lacks the badge.
local function userHasRobloxBadge(player, badgeId)
	local success, result = pcall(BadgeService.UserHasBadgeAsync, BadgeService, player.UserId, badgeId)
	if success then
		return result
	end

	warn(string.format("Failed to check badge ownership for BadgeId %s: %s", tostring(badgeId), tostring(result)))
	return nil
end

-- Attempts to grant the live Roblox badge and isolates any platform error from the rest of the game loop.
-- Callers use the returned value to decide whether local ownership may safely be persisted.
local function awardRobloxBadge(player, badgeId)
	local success, result = pcall(BadgeService.AwardBadge, BadgeService, player.UserId, badgeId)
	if success then
		return result
	end

	warn(string.format("Failed to award BadgeId %s: %s", tostring(badgeId), tostring(result)))
	return nil
end

-- Registers every configured badge by name for direct awards and indexes stat-based badges by their tracked statistic.
-- Badges without Category or AwardAt remain available for manual awards but are excluded from automatic stat checks.
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

-- Rebuilds all runtime badge indexes from configuration when the service starts.
-- Clearing first avoids stale or duplicate entries if initialization is ever repeated during development.
local function prepareBadges()
	table.clear(badgeRequirementsByStat)
	table.clear(badgeDataByName)

	for _, badges in pairs(BadgesList.BadgesInfo) do
		for badgeName, badgeData in pairs(badges) do
			registerBadge(badgeName, badgeData)
		end
	end
end

-- Converts badge configuration into the standardized payload expected by RewardsService.
-- Returning nil for an unknown badge prevents an incomplete or malformed reward request.
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

-- Validates a client reward claim against server-owned profile data before granting anything.
-- The badge must be awarded, unclaimed, and correctly configured; the claim is saved only after RewardsService succeeds.
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

-- Verifies completion of the conversation objective by comparing the player's history with the prepared NPC requirement list.
-- The function exits on the first missing NPC to avoid unnecessary work once failure is known.
local function hasSpokenToAllRequiredNPCs(replica)
	for _, npcName in ipairs(requiredNPCs) do
		if not contains(replica.Data.SpokenNPCs, npcName) then
			return false
		end
	end

	return true
end

-- Awards the NPC conversation badge only after every eligible NPC has been recorded.
-- The normal AwardBadge path supplies duplicate protection and handles Studio versus live-server behavior.
local function checkNPCBadge(player, replica)
	if not hasSpokenToAllRequiredNPCs(replica) then
		return
	end

	BadgesService:AwardBadge(player, "People's Person")
end

-- Handles the client signal for an NPC conversation while treating all client input as untrusted.
-- It validates the NPC, requires loaded data, ignores duplicate conversations, then rechecks the completion badge.
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

-- Mirrors a badge already owned on Roblox into the local profile.
-- Using the shared insert helper preserves duplicate protection during repeated reconciliation passes.
local function syncOwnedBadge(replica, badgeName)
	addAwardedBadge(replica, badgeName)
end

-- Repairs the opposite mismatch: the profile says the badge was earned, but Roblox does not show ownership.
-- Local data is touched only after the Roblox award succeeds, preserving consistency when the API fails.
local function restoreMissingRobloxBadge(player, replica, badgeId, badgeName)
	local result = awardRobloxBadge(player, badgeId)
	if not result then
		return
	end

	addAwardedBadge(replica, badgeName)
end

-- Compares Roblox ownership with saved profile ownership and repairs whichever side is missing.
-- API failures stop only the current badge check, preventing an uncertain result from overwriting valid data.
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

-- Applies ownership reconciliation to every badge in configuration when a player's profile becomes available.
-- Iterating the source configuration ensures manually awarded and stat-based badges are both included.
local function reconcileAllBadges(player, replica)
	for _, badges in pairs(BadgesList.BadgesInfo) do
		for badgeName, badgeData in pairs(badges) do
			reconcileBadge(player, replica, badgeData)
		end
	end
end

-- Runs profile migration and badge reconciliation in a separate task so player initialization never blocks KnitStart.
-- The task exits safely if the player leaves before their profile finishes loading.
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

-- Simulates a successful badge award in Studio by updating only profile data.
-- Roblox badge endpoints are unreliable in local testing, so this keeps development tests deterministic.
local function awardBadgeLocally(replica, badgeName)
	addAwardedBadge(replica, badgeName)
end

-- Grants a badge through Roblox in live servers, then saves local ownership only after platform confirmation.
-- Returning a boolean lets higher-level award logic report whether the complete operation succeeded.
local function awardBadgeNormally(player, replica, badgeId, badgeName)
	local result = awardRobloxBadge(player, badgeId)
	if not result then
		return false
	end

	addAwardedBadge(replica, badgeName)
	return true
end

-- Chooses the correct award strategy for the current environment.
-- Studio receives a local simulation, while published servers require a successful Roblox badge award.
local function awardConfiguredBadge(player, replica, badgeId, badgeName)
	if RunService:IsStudio() then
		awardBadgeLocally(replica, badgeName)
		return true
	end

	return awardBadgeNormally(player, replica, badgeId, badgeName)
end

-- Evaluates both conditions for a stat badge: the threshold must be reached and the badge must still be unowned.
-- Separating this predicate keeps the main check loop easy to read and prevents duplicate award requests.
local function shouldAwardRequirement(replica, statValue, requirement)
	if statValue < requirement.AwardAt then
		return false
	end

	return not hasAwardedBadge(replica, requirement.BadgeName)
end

-- Checks only badges associated with the statistic that changed instead of scanning the complete badge catalogue.
-- The server reads the authoritative profile value and ignores missing or nonnumeric statistics before evaluating thresholds.
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

-- Provides the service-level entry point for awarding a named badge from other server systems.
-- It treats an already-owned badge as success, validates configuration, and delegates environment-specific awarding.
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

-- Resolves the expected World/Interactables/NPC hierarchy without assuming every map is fully populated.
-- Returning nil at each missing level lets discovery code support both active and replicated worlds safely.
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

-- Checks whether an NPC model exists inside a particular world container.
-- This wrapper handles absent containers and folders so configuration can be evaluated without indexing errors.
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

-- Decides whether an NPC should count toward the conversation badge.
-- An NPC must opt in, provide dialogue, and physically exist in either the active map or replicated world assets.
local function isRequiredNPC(worldName, npcName, npcInfo)
	if not npcInfo.CountForBadge or not npcInfo.Dialogue then
		return false
	end

	local workspaceMaps = workspace:FindFirstChild("Maps")
	local replicatedWorlds = ReplicatedStorage:FindFirstChild("Worlds")

	return npcExists(workspaceMaps, worldName, npcName)
		or npcExists(replicatedWorlds, worldName, npcName)
end

-- Builds the runtime list of NPCs that genuinely count toward the all-conversations badge.
-- Deriving the list from configuration and available world assets prevents removed or incomplete NPCs from blocking progress.
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

-- Starts asynchronous reconciliation and then checks existing progression stats after the profile becomes available.
-- Rechecking Hatched and Origami allows eligible players to receive badges even when they joined with progress already saved.
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

-- Connects dependencies, prepares runtime indexes, binds client signals, and initializes every current and future player.
-- Existing players are processed first because Knit services may start after players have already entered the server.
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
