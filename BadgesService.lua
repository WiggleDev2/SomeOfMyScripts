-- // Services \\ --
local replicatedStorage = game:GetService("ReplicatedStorage")
local players = game:GetService("Players")
local robloxBadgeService = game:GetService("BadgeService")
local runService = game:GetService("RunService")
-- // Object Variables \\ --
local packages = replicatedStorage:WaitForChild("Packages")

-- // Loaded Modules \\ --
local knit = require(packages:WaitForChild("Knit"))
local badgesList = require(knit.Shared.List.Badges)
local npcList = require(knit.Shared.List.NPC)

-- // Knit Setup \\ --
local badgesService = knit.CreateService{
	Name = "BadgesService",
	Client = {
		SpokenToNPC = knit.CreateSignal(),
		ClaimReward = knit.CreateSignal()
	}
}

local dataService
local rewardsService
-- // Private Variables \\ --
local easyBadgeCheckup = {}
local requiredNPCs = {}

-- // Private Functions \\ --

local function rewardBadge(player, badgeName)
	local replica = dataService:GetProfile(player)._Replica
	if table.find(replica.Data.AwardedBadges, badgeName) and not table.find(replica.Data.ClaimedBadges, badgeName) then
		
		replica:ArrayInsert("ClaimedBadges", badgeName)
		
		rewardsService:RewardPlayer(player, {
			["RewardType"] = (badgesList.GetBadgeInfo(badgeName)).RewardType,
			["RewardName"] = (badgesList.GetBadgeInfo(badgeName)).RewardName,
			["RewardValue"] = (badgesList.GetBadgeInfo(badgeName)).RewardValue,
			["PetCraft"] = (badgesList.GetBadgeInfo(badgeName)).PetCraft
		})
	end
end

local function prepareBadges()
	for categoryName, badges in pairs(badgesList.BadgesInfo) do
		if not easyBadgeCheckup[categoryName] then
			easyBadgeCheckup[categoryName] = {}
		end

		for badgeName, badgeData in pairs(badges) do
			if badgeData["Category"] and badgeData["AwardAt"] then
				local success, result = pcall(function()
					return robloxBadgeService:GetBadgeInfoAsync(badgeData.Id)
				end)

				if success and result then
					table.insert(easyBadgeCheckup[categoryName], {
						BadgeAwardAt = badgeData["AwardAt"],
						BadgeName = result["Name"]
					})
				else
					warn("Failed to get badge info for BadgeId: " .. badgeData.Id)
				end
			end
		end
	end
end


local function checkAndPrintMissingNPCs(player)
	local profile = dataService:GetProfile(player)._Replica
	local missingNPCs = {}

	for _, requiredNPC in pairs(requiredNPCs) do
		if not table.find(profile.Data.SpokenNPCs, requiredNPC) then
			table.insert(missingNPCs, requiredNPC)
		end
	end

	if #missingNPCs == 0 then
		badgesService:AwardBadge(player, "People's Person")
	end
end


local function reconcileData(player)
	task.spawn(function()
		repeat
			task.wait(0.5)
		until dataService:GetProfile(player)

		local profile = dataService:GetProfile(player)._Replica

		if not profile.Data.AwardedBadges then
			profile:SetValue("AwardedBadges", {})
		end

		if not profile.Data.ClaimedBadges then
			profile:SetValue("ClaimedBadges", {})
		end

		if not profile.Data.SpokenNPCs then
			profile:SetValue("SpokenNPCs", {})
		end

		--checkAndPrintMissingNPCs(player)
		
		for categoryName, badges in pairs(badgesList.BadgesInfo) do
			for badgeName, badgeData in pairs(badges) do
				local success, hasBadge = pcall(function()
					return robloxBadgeService:UserHasBadgeAsync(player.UserId, badgeData.Id)
				end)

				if success then
					local success2, result = pcall(function()
						return robloxBadgeService:GetBadgeInfoAsync(badgeData.Id)
					end)

					if success2 and result then
						if hasBadge then
							if not table.find(profile.Data.AwardedBadges, result.Name) then
								profile:ArrayInsert("AwardedBadges", result.Name)
							end
						else
							if table.find(profile.Data.AwardedBadges, result.Name) then
								robloxBadgeService:AwardBadge(player.UserId, badgeData.Id)
							end
						end
					end
				end
			end
		end
		
		warn(profile.Data.AwardedBadges, profile.Data.ClaimedBadges)
	end)
end

local function getBadgeIdByRequirement(requirement, stat)
	for _, badges in pairs(badgesList.BadgesInfo) do
		for badgeName, data in pairs(badges) do
			
			--[[local Category = data.Category
			
			if data.Category == "Origami" then
				Category = "Total Origami"
			end]]
			
			if data.Category == stat and data.AwardAt == requirement then
				return data.Id
			end
		end
	end
	return nil
end

local function speakToNpc(player, npcName)
	if npcList.Get(npcName) then
		local profile = dataService:GetProfile(player)._Replica
		if not table.find(profile.Data.SpokenNPCs, npcName) then
			profile:ArrayInsert("SpokenNPCs", npcName)
		
			local allNPCsSpokenTo = true
			local missingNPCs = {}

			for _, requiredNPC in pairs(requiredNPCs) do
				if not table.find(profile.Data.SpokenNPCs, requiredNPC) then
					allNPCsSpokenTo = false
					table.insert(missingNPCs, requiredNPC)
					break
				end
			end

			if allNPCsSpokenTo then
				badgesService:AwardBadge(player, "People's Person")
			end
		end
	end
end


-- // Public Functions \\ --

function badgesService:BadgeCheckup(player, changedStat)
	local profile = dataService:GetProfile(player)._Replica
	local stat = profile.Data[changedStat]

	if easyBadgeCheckup[changedStat] then
		for _, requirement in pairs(easyBadgeCheckup[changedStat]) do
			if stat >= requirement.BadgeAwardAt and not table.find(profile.Data.AwardedBadges, requirement.BadgeName) then
				local badgeId = getBadgeIdByRequirement(requirement.BadgeAwardAt, changedStat)

				if badgeId then
					if runService:IsStudio() then
						profile:ArrayInsert("AwardedBadges", requirement.BadgeName)
					else
						local awardSuccess, result = pcall(function()
							return robloxBadgeService:AwardBadge(player.UserId, badgeId)
						end)

						if awardSuccess and result then
							profile:ArrayInsert("AwardedBadges", result["Name"])
						else
							warn("Failed to award badge for BadgeId: " .. badgeId)
						end
					end
				else
					warn("Badge ID not found for requirement: " .. requirement.BadgeAwardAt)
				end
			end
		end
	end
end

function badgesService:AwardBadge(player, badgeName)
	local profile = dataService:GetProfile(player)._Replica

	if not table.find(profile.Data.AwardedBadges, badgeName) then
		local data = nil

		for _, badges in pairs(badgesList.BadgesInfo) do
			data = badges[badgeName]
			if data then
				break
			end
		end

		if data and data.Id then
			local badgeId = data.Id

			if runService:IsStudio() then
				profile:ArrayInsert("AwardedBadges", badgeName)
			else
				local awardSuccess, result = pcall(function()
					return robloxBadgeService:AwardBadge(player.UserId, badgeId)
				end)

				if awardSuccess then
					profile:ArrayInsert("AwardedBadges", badgeName)
				end
			end
		end
	end
end

function badgesService:KnitStart()
	task.wait(0.5)

	dataService = knit.GetService("DataService")
	rewardsService = knit.GetService("RewardsService")
	
	prepareBadges()
	
	badgesService.Client.SpokenToNPC:Connect(speakToNpc)

	self.Client.ClaimReward:Connect(function(player: Player, badgeName)
		rewardBadge(player, badgeName)
	end)

	for worldName, worldData in pairs(npcList.List) do
		for npcName, npcInfo in pairs(worldData) do
			if npcInfo.CountForBadge and npcInfo.Dialogue then
				local workspaceMap = game.Workspace:FindFirstChild("Maps")
				local replicatedMap = game.ReplicatedStorage:FindFirstChild("Worlds")

				local npcExistsInWorkspace = workspaceMap 
					and workspaceMap:FindFirstChild(worldName) 
					and workspaceMap[worldName]:FindFirstChild("Interactables") 
					and workspaceMap[worldName].Interactables:FindFirstChild("NPC") 
					and workspaceMap[worldName].Interactables.NPC:FindFirstChild(npcName)

				local npcExistsInReplicated = replicatedMap 
					and replicatedMap:FindFirstChild(worldName) 
					and replicatedMap[worldName]:FindFirstChild("Interactables") 
					and replicatedMap[worldName].Interactables:FindFirstChild("NPC") 
					and replicatedMap[worldName].Interactables.NPC:FindFirstChild(npcName)

				if npcExistsInWorkspace or npcExistsInReplicated then
					table.insert(requiredNPCs, npcName)
				end
			end
		end
	end

	for _, player in pairs(players:GetPlayers()) do
		reconcileData(player)
		
		badgesService:BadgeCheckup(player, "Hatched")
		badgesService:BadgeCheckup(player, "Origami")
	end

	players.PlayerAdded:Connect(reconcileData)
	
end

-- // Initialize \\ --
return badgesService
