local replicatedStorage = game:GetService("ReplicatedStorage") -- Shared replicated storage
local players = game:GetService("Players") -- Players service
local robloxBadgeService = game:GetService("BadgeService") -- Roblox badge service
local runService = game:GetService("RunService") -- RunService for Studio checks
local packages = replicatedStorage:WaitForChild("Packages") -- Packages folder
local knit = require(packages:WaitForChild("Knit")) -- Knit framework
local badgesList = require(knit.Shared.List.Badges) -- Badge config module
local npcList = require(knit.Shared.List.NPC) -- NPC config module
local badgesService = knit.CreateService{ -- Creates Knit service
	Name = "BadgesService", -- Service name
	Client = { -- Client signals
		SpokenToNPC = knit.CreateSignal(), -- Fired when player speaks to NPC
		ClaimReward = knit.CreateSignal() -- Fired when player claims reward
	}
}
local dataService -- DataService reference
local rewardsService -- RewardsService reference
local easyBadgeCheckup = {} -- Cached badge requirements
local requiredNPCs = {} -- Required NPCs for NPC badge
local function rewardBadge(player, badgeName) -- Gives badge reward
	local replica = dataService:GetProfile(player)._Replica -- Player profile replica
	if table.find(replica.Data.AwardedBadges, badgeName) and not table.find(replica.Data.ClaimedBadges, badgeName) then -- Checks if reward can be claimed
		replica:ArrayInsert("ClaimedBadges", badgeName) -- Marks reward as claimed
		rewardsService:RewardPlayer(player, { -- Gives configured reward
			["RewardType"] = (badgesList.GetBadgeInfo(badgeName)).RewardType, -- Reward type
			["RewardName"] = (badgesList.GetBadgeInfo(badgeName)).RewardName, -- Reward name
			["RewardValue"] = (badgesList.GetBadgeInfo(badgeName)).RewardValue, -- Reward value
			["PetCraft"] = (badgesList.GetBadgeInfo(badgeName)).PetCraft -- Pet craft reward
		})
	end
end
local function prepareBadges() -- Prepares badge cache
	for categoryName, badges in pairs(badgesList.BadgesInfo) do -- Loops badge categories
		if not easyBadgeCheckup[categoryName] then -- Checks if category cache exists
			easyBadgeCheckup[categoryName] = {} -- Creates category cache
		end
		for badgeName, badgeData in pairs(badges) do -- Loops badges in category
			if badgeData["Category"] and badgeData["AwardAt"] then -- Checks if badge has requirements
				local success, result = pcall(function() -- Safely runs Roblox API call
					return robloxBadgeService:GetBadgeInfoAsync(badgeData.Id) -- Gets badge info
				end)
				if success and result then -- Checks if badge info loaded
					table.insert(easyBadgeCheckup[categoryName], { -- Saves badge requirement to cache
						BadgeAwardAt = badgeData["AwardAt"], -- Required amount
						BadgeName = result["Name"] -- Badge name
					})
				else
					warn("Failed to get badge info for BadgeId: " .. badgeData.Id)
				end
			end
		end
	end
end
local function checkAndPrintMissingNPCs(player) -- Checks missing NPCs
	local profile = dataService:GetProfile(player)._Replica -- Player profile
	local missingNPCs = {} -- Missing NPC list
	for _, requiredNPC in pairs(requiredNPCs) do -- Loops required NPCs
		if not table.find(profile.Data.SpokenNPCs, requiredNPC) then -- Checks if NPC was not spoken to
			table.insert(missingNPCs, requiredNPC) -- Adds NPC to missing list
		end
	end
	if #missingNPCs == 0 then -- Checks if no NPCs are missing
		badgesService:AwardBadge(player, "People's Person") -- Awards NPC badge
	end
end
local function reconcileData(player) -- Syncs badge data
	task.spawn(function() -- Runs in separate task
		repeat
			task.wait(0.5) -- Waits before retrying
		until dataService:GetProfile(player) -- Waits for player profile
		local profile = dataService:GetProfile(player)._Replica -- Player profile
		if not profile.Data.AwardedBadges then -- Checks AwardedBadges data
			profile:SetValue("AwardedBadges", {}) -- Creates AwardedBadges data
		end
		if not profile.Data.ClaimedBadges then -- Checks ClaimedBadges data
			profile:SetValue("ClaimedBadges", {}) -- Creates ClaimedBadges data
		end
		if not profile.Data.SpokenNPCs then -- Checks SpokenNPCs data
			profile:SetValue("SpokenNPCs", {}) -- Creates SpokenNPCs data
		end
		for categoryName, badges in pairs(badgesList.BadgesInfo) do -- Loops badge categories
			for badgeName, badgeData in pairs(badges) do -- Loops badges
				local success, hasBadge = pcall(function() -- Safely checks badge ownership
					return robloxBadgeService:UserHasBadgeAsync(player.UserId, badgeData.Id) -- Checks Roblox badge ownership
				end)
				if success then -- Checks if ownership check worked
					local success2, result = pcall(function() -- Safely gets badge info
						return robloxBadgeService:GetBadgeInfoAsync(badgeData.Id) -- Gets Roblox badge info
					end)
					if success2 and result then -- Checks if badge info loaded
						if hasBadge then -- Checks if player owns badge
							if not table.find(profile.Data.AwardedBadges, result.Name) then -- Checks if badge missing locally
								profile:ArrayInsert("AwardedBadges", result.Name) -- Adds badge locally
							end
						else
							if table.find(profile.Data.AwardedBadges, result.Name) then -- Checks if local data says player owns badge
								robloxBadgeService:AwardBadge(player.UserId, badgeData.Id) -- Re-awards badge on Roblox
							end
						end
					end
				end
			end
		end
		warn(profile.Data.AwardedBadges, profile.Data.ClaimedBadges)
	end)
end
local function getBadgeIdByRequirement(requirement, stat) -- Finds badge ID by requirement
	for _, badges in pairs(badgesList.BadgesInfo) do -- Loops badge categories
		for badgeName, data in pairs(badges) do -- Loops badges
			if data.Category == stat and data.AwardAt == requirement then -- Checks matching stat and requirement
				return data.Id -- Returns badge ID
			end
		end
	end
	return nil -- Returns nothing if badge was not found
end
local function speakToNpc(player, npcName) -- Handles NPC speaking
	if npcList.Get(npcName) then -- Checks if NPC exists
		local profile = dataService:GetProfile(player)._Replica -- Player profile
		if not table.find(profile.Data.SpokenNPCs, npcName) then -- Checks if NPC was not already spoken to
			profile:ArrayInsert("SpokenNPCs", npcName) -- Saves NPC as spoken to
			local allNPCsSpokenTo = true -- Tracks if all NPCs were spoken to
			local missingNPCs = {} -- Missing NPC list
			for _, requiredNPC in pairs(requiredNPCs) do -- Loops required NPCs
				if not table.find(profile.Data.SpokenNPCs, requiredNPC) then -- Checks if required NPC missing
					allNPCsSpokenTo = false -- Marks badge requirement incomplete
					table.insert(missingNPCs, requiredNPC) -- Adds missing NPC
					break
				end
			end
			if allNPCsSpokenTo then -- Checks if all NPCs were spoken to
				badgesService:AwardBadge(player, "People's Person") -- Awards NPC badge
			end
		end
	end
end
function badgesService:BadgeCheckup(player, changedStat) -- Checks stat badges
	local profile = dataService:GetProfile(player)._Replica -- Player profile
	local stat = profile.Data[changedStat] -- Current stat value
	if easyBadgeCheckup[changedStat] then -- Checks if stat has badge cache
		for _, requirement in pairs(easyBadgeCheckup[changedStat]) do -- Loops requirements
			if stat >= requirement.BadgeAwardAt and not table.find(profile.Data.AwardedBadges, requirement.BadgeName) then -- Checks if badge should be awarded
				local badgeId = getBadgeIdByRequirement(requirement.BadgeAwardAt, changedStat) -- Gets badge ID
				if badgeId then -- Checks if badge ID exists
					if runService:IsStudio() then -- Checks if running in Studio
						profile:ArrayInsert("AwardedBadges", requirement.BadgeName) -- Adds badge locally in Studio
					else
						local awardSuccess, result = pcall(function() -- Safely awards badge
							return robloxBadgeService:AwardBadge(player.UserId, badgeId) -- Awards Roblox badge
						end)
						if awardSuccess and result then -- Checks if awarding succeeded
							profile:ArrayInsert("AwardedBadges", result["Name"]) -- Saves awarded badge locally
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
function badgesService:AwardBadge(player, badgeName) -- Awards specific badge by name
	local profile = dataService:GetProfile(player)._Replica -- Player profile
	if not table.find(profile.Data.AwardedBadges, badgeName) then -- Checks if badge not already awarded
		local data = nil -- Badge data holder
		for _, badges in pairs(badgesList.BadgesInfo) do -- Loops badge categories
			data = badges[badgeName] -- Tries to find badge by name
			if data then
				break
			end
		end
		if data and data.Id then -- Checks if badge data exists
			local badgeId = data.Id -- Badge ID
			if runService:IsStudio() then -- Checks if running in Studio
				profile:ArrayInsert("AwardedBadges", badgeName) -- Adds badge locally in Studio
			else
				local awardSuccess, result = pcall(function() -- Safely awards badge
					return robloxBadgeService:AwardBadge(player.UserId, badgeId) -- Awards Roblox badge
				end)
				if awardSuccess then -- Checks if award succeeded
					profile:ArrayInsert("AwardedBadges", badgeName) -- Saves badge locally
				end
			end
		end
	end
end
function badgesService:KnitStart() -- Starts service
	task.wait(0.5) -- Short startup delay
	dataService = knit.GetService("DataService") -- Gets DataService
	rewardsService = knit.GetService("RewardsService") -- Gets RewardsService
	prepareBadges() -- Builds badge cache
	badgesService.Client.SpokenToNPC:Connect(speakToNpc) -- Connects NPC signal
	self.Client.ClaimReward:Connect(function(player: Player, badgeName) -- Connects reward claim signal
		rewardBadge(player, badgeName) -- Rewards claimed badge
	end)
	for worldName, worldData in pairs(npcList.List) do -- Loops worlds
		for npcName, npcInfo in pairs(worldData) do -- Loops NPCs
			if npcInfo.CountForBadge and npcInfo.Dialogue then -- Checks if NPC counts for badge
				local workspaceMap = game.Workspace:FindFirstChild("Maps") -- Finds workspace maps folder
				local replicatedMap = game.ReplicatedStorage:FindFirstChild("Worlds") -- Finds replicated worlds folder
				local npcExistsInWorkspace = workspaceMap and workspaceMap:FindFirstChild(worldName) and workspaceMap[worldName]:FindFirstChild("Interactables") and workspaceMap[worldName].Interactables:FindFirstChild("NPC") and workspaceMap[worldName].Interactables.NPC:FindFirstChild(npcName) -- Checks NPC in workspace
				local npcExistsInReplicated = replicatedMap and replicatedMap:FindFirstChild(worldName) and replicatedMap[worldName]:FindFirstChild("Interactables") and replicatedMap[worldName].Interactables:FindFirstChild("NPC") and replicatedMap[worldName].Interactables.NPC:FindFirstChild(npcName) -- Checks NPC in replicated storage
				if npcExistsInWorkspace or npcExistsInReplicated then -- Checks if NPC exists anywhere
					table.insert(requiredNPCs, npcName) -- Adds NPC to required list
				end
			end
		end
	end
	for _, player in pairs(players:GetPlayers()) do -- Loops current players
		reconcileData(player) -- Syncs player badge data
		badgesService:BadgeCheckup(player, "Hatched") -- Checks Hatched badges
		badgesService:BadgeCheckup(player, "Origami") -- Checks Origami badges
	end
	players.PlayerAdded:Connect(reconcileData) -- Syncs new players
end
return badgesService -- Returns Knit service
