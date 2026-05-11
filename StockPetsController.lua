-- // Services \\ --

local replicatedStorage = game:GetService("ReplicatedStorage")
local players = game:GetService("Players")
local marketplaceService = game:GetService("MarketplaceService")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")

-- // Object Variables \\ --

local localPlayer = players.LocalPlayer

local packages = replicatedStorage:WaitForChild("Packages")
local listFolder = replicatedStorage:WaitForChild("Game"):WaitForChild("Shared"):WaitForChild("List")
local stockPetsFolder = workspace:WaitForChild("StockPets")

-- // Loaded Modules \\ --

local knit = require(packages:WaitForChild("Knit"))
local MarketUtil = require(knit.Shared.Utility.MarketUtil)
local tweenUtil = require(replicatedStorage:WaitForChild("Game"):WaitForChild("Shared"):WaitForChild("Utility"):WaitForChild("TweenUtil"))
local stockPetList = require(listFolder:WaitForChild("StockPets")).StockList

-- // Knit Setup \\ --

local stockPets = knit.CreateController{
	Name = "StockPetsController"
}

local interactableController
local stockPetsService

-- // Private Variables \\ --

local maxDistance = 30
local showInteraction = true
local setupStock = {}
local interactionSizeMultiplier = 1
local interactionSize = 1.5
local interactions = {}
local interactionConnections = {}

-- // Private Functions \\ --

local function checkDistance(npcPosition, maxDistance)
	-- Check the distance between the NPCs and the local player
	if not npcPosition then return false end

	local character = localPlayer.Character
	if not character or not character.PrimaryPart then return false end

	local magnitude = (character.PrimaryPart.Position - npcPosition).Magnitude
	return magnitude <= maxDistance
end

local function tweenInteractionFunction(toggled, interaction, sizeMultiplier)
	-- Function to tween interaction UI elements
	if not sizeMultiplier then
		sizeMultiplier = 1
	end

	local size = UDim2.new(0.935 * sizeMultiplier, 0, 0.653 * sizeMultiplier, 0)
	local transparency = 0

	if not toggled then
		size = UDim2.new(0, 0, 0, 0)
		transparency = 1
	end

	if interaction then
		local click = interaction:FindFirstChild("Click")
		local label = click and click:FindFirstChild("Back"):FindFirstChild("Label")
		if click and label then
			tweenUtil.YieldPlay(click, TweenInfo.new(0.2, Enum.EasingStyle.Cubic), {Size = size})
			tweenUtil.YieldPlay(label, TweenInfo.new(0.1, Enum.EasingStyle.Cubic), {TextTransparency = transparency, TextStrokeTransparency = transparency})
		end
		interaction.Enabled = toggled
	end
end

local function renderStepped(interaction, interactablePart)
	local distanceCheck = checkDistance(interactablePart.Position, maxDistance) and showInteraction
	tweenInteractionFunction(distanceCheck, interaction, interactionSizeMultiplier)
end

local function interact(id)
	local product = stockPetList[id]
	if product then
		MarketUtil.PromptProduct(localPlayer, "", tonumber(product.ProductId))
	end
end

local function runPetAnimation(pet)
	local originalPosition = pet.PrimaryPart.CFrame

	runService.RenderStepped:Connect(function()
		local step = tick() / 1.5
		local goal = CFrame.new(0, 2, 0) * CFrame.Angles(math.rad(math.cos(step * 4)) * 8, 0, 0) + Vector3.new(0, math.sin(step * 4) * 0.5, 0)
		pet.PrimaryPart.CFrame = originalPosition * goal
	end)
end

local function setupInteraction(interactablePart, id)
	return interactableController:AttachInteraction(interactablePart, "Stock", 60, function()
		interact(id)
	end, "Buy Stock", nil, interactionSize)
end

local function removeInteraction(id)
	if interactionConnections[id] then
		for _, connection in pairs(interactionConnections[id]) do
			if connection then
				connection:Disconnect()
			end
		end
		interactionConnections[id] = nil
	end

	local interaction = interactions[id]
	if interaction then
		tweenInteractionFunction(false, interaction, 0)
		tweenUtil.Play(stockPetsFolder:WaitForChild(id):WaitForChild("Stand"):WaitForChild("Stock"):WaitForChild("Stock").BillboardGui.Expiration, TweenInfo.new(0.5), {TextTransparency = 1})
		task.delay(0.5, function()
			if interaction then
				table.remove(setupStock, table.find(setupStock, stockPetList[id].PetName))
				interaction:Destroy()
			end
			interactions[id] = nil
		end)
	else
		interactions[id] = nil
	end
end

local function prepareStock(id)
	local stockPet = stockPetsFolder:FindFirstChild(id)
	if not stockPet then return end
	if table.find(setupStock, stockPetList[id].PetName) then return end
	local interactablePart = stockPet:FindFirstChild("Stand"):FindFirstChild("Stock"):FindFirstChild("Stand"):FindFirstChild("Main")
	local billboardGui = stockPet:FindFirstChild("Stand"):FindFirstChild("Stock"):FindFirstChild("Stock").BillboardGui
	if not interactablePart or not billboardGui then return end

	table.insert(setupStock, stockPetList[id].PetName)

	tweenUtil.Play(billboardGui.Expiration, TweenInfo.new(0.5), {TextTransparency = 0})

	-- If the interaction already exists, remove and recreate it
	if interactions[id] then
		removeInteraction(id)
	end

	interactions[id] = setupInteraction(interactablePart, id)

	interactionConnections[id] = {}
	interactionConnections[id][1] = runService.RenderStepped:Connect(function()
		renderStepped(interactions[id], interactablePart)
	end)

	interactionConnections[id][2] = userInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == Enum.KeyCode.E then
			local distanceCheck = checkDistance(interactablePart.Position, maxDistance) and showInteraction
			if distanceCheck then
				interactionSizeMultiplier = 0.8
			end
		end
	end)

	interactionConnections[id][3] = userInputService.InputEnded:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == Enum.KeyCode.E then
			local distanceCheck = checkDistance(interactablePart.Position, maxDistance) and showInteraction
			if distanceCheck then
				interactionSizeMultiplier = 1
				interact(id)
			end
		end
	end)
end

-- // Public Functions \\ --

function stockPets:KnitStart()
	task.wait(0.5)

	interactableController = knit.GetController("InteractableController")
	stockPetsService = knit.GetService("StockPetsService")

	stockPetsService:GetActiveStocks():andThen(function(data)
		for _, id in pairs(data) do
			prepareStock(id)
		end
	end)

	for id, _ in pairs(stockPetList) do
		local pet = stockPetsFolder:FindFirstChild(id):FindFirstChild("Pet"):FindFirstChild("Pet")
		if pet then
			runPetAnimation(pet)
		end
	end

	stockPetsService.PrepareStock:Connect(prepareStock)
	stockPetsService.RemoveStock:Connect(removeInteraction)
end

-- // Initialize \\ --

return stockPets
