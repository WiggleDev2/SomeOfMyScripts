-- Discord: wiggledev | Roblox: WiggleDev

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Game = ReplicatedStorage:WaitForChild("Game")
local Shared = Game:WaitForChild("Shared")
local Lists = Shared:WaitForChild("List")
local Utility = Shared:WaitForChild("Utility")
local StockPetsFolder = Workspace:WaitForChild("StockPets")

local Knit = require(Packages:WaitForChild("Knit"))
local MarketUtil = require(Knit.Shared.Utility.MarketUtil)
local TweenUtil = require(Utility:WaitForChild("TweenUtil"))
local StockPetList = require(Lists:WaitForChild("StockPets")).StockList

local StockPetsController = Knit.CreateController({
	Name = "StockPetsController",
})

local InteractableController
local StockPetsService

-- Stores all runtime state per stock ID so one interaction cannot
-- overwrite animation or input state belonging to another stock.
local stockStates = {}
local petAnimationStates = {}
local renderConnection
local inputBeganConnection
local inputEndedConnection

local function getCharacterRootPart()
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart")
		or character.PrimaryPart
end

local function isWithinDistance(position, maximumDistance)
	if not position then
		return false
	end

	local rootPart = getCharacterRootPart()
	if not rootPart then
		return false
	end

	return (rootPart.Position - position).Magnitude <= maximumDistance
end

local function getStockConfiguration(stockId)
	if type(stockId) ~= "string" then
		return nil
	end

	return StockPetList[stockId]
end

local function getStockModel(stockId)
	return StockPetsFolder:FindFirstChild(stockId)
end

local function getStandContainer(stockModel)
	if not stockModel then
		return nil
	end

	local stand = stockModel:FindFirstChild("Stand")
	if not stand then
		return nil
	end

	return stand:FindFirstChild("Stock")
end

local function getInteractablePart(stockModel)
	local stockContainer = getStandContainer(stockModel)
	if not stockContainer then
		return nil
	end

	local stand = stockContainer:FindFirstChild("Stand")
	if not stand then
		return nil
	end

	return stand:FindFirstChild("Main")
end

local function getBillboardGui(stockModel)
	local stockContainer = getStandContainer(stockModel)
	if not stockContainer then
		return nil
	end

	local stockDisplay = stockContainer:FindFirstChild("Stock")
	if not stockDisplay then
		return nil
	end

	return stockDisplay:FindFirstChildOfClass("BillboardGui")
end

local function getExpirationLabel(stockModel)
	local billboardGui = getBillboardGui(stockModel)
	if not billboardGui then
		return nil
	end

	return billboardGui:FindFirstChild("Expiration")
end

local function getInteractionVisuals(interaction)
	if not interaction then
		return nil, nil
	end

	local click = interaction:FindFirstChild("Click")
	if not click then
		return nil, nil
	end

	local back = click:FindFirstChild("Back")
	if not back then
		return click, nil
	end

	return click, back:FindFirstChild("Label")
end

local function getInteractionSize(sizeMultiplier)
	return UDim2.new(
		0.935 * sizeMultiplier,
		0,
		0.653 * sizeMultiplier,
		0
	)
end

-- Updates both the interaction container and text so the prompt
-- never remains visible while its BillboardGui is disabled.
local function tweenInteraction(enabled, interaction, sizeMultiplier)
	if not interaction then
		return
	end

	local click, label = getInteractionVisuals(interaction)
	local targetSize = UDim2.fromScale(0, 0)
	local targetTransparency = 1

	if enabled then
		targetSize = getInteractionSize(
			sizeMultiplier or 1
		)
		targetTransparency = 0
		interaction.Enabled = true
	end

	if click then
		TweenUtil.Play(
			click,
			TweenInfo.new(
				0.2,
				Enum.EasingStyle.Cubic
			),
			{
				Size = targetSize,
			}
		)
	end

	if label then
		TweenUtil.Play(
			label,
			TweenInfo.new(
				0.1,
				Enum.EasingStyle.Cubic
			),
			{
				TextTransparency = targetTransparency,
				TextStrokeTransparency = targetTransparency,
			}
		)
	end

	if enabled then
		return
	end

	task.delay(0.2, function()
		if interaction.Parent then
			interaction.Enabled = false
		end
	end)
end

local function setExpirationVisible(stockModel, visible)
	local expirationLabel = getExpirationLabel(stockModel)
	if not expirationLabel then
		return
	end

	TweenUtil.Play(
		expirationLabel,
		TweenInfo.new(0.5),
		{
			TextTransparency = visible and 0 or 1,
		}
	)
end

local function promptPurchase(stockId)
	local product = getStockConfiguration(stockId)
	if not product then
		warn(
			"[StockPetsController] Unknown stock ID:",
			stockId
		)

		return
	end

	local productId = tonumber(product.ProductId)
	if not productId then
		warn(
			"[StockPetsController] Invalid ProductId for",
			stockId
		)

		return
	end

	MarketUtil.PromptProduct(LocalPlayer, "", productId)
end

local function createInteraction(interactablePart, stockId)
	return InteractableController:AttachInteraction(
		interactablePart,
		"Stock",
		60,
		function()
			promptPurchase(stockId)
		end,
		"Buy Stock",
		nil,
		1.5
	)
end

local function getStockState(stockId)
	return stockStates[stockId]
end

local function isStockInteractable(state)
	if not state then
		return false
	end

	if not state.InteractablePart then
		return false
	end

	if not state.InteractablePart.Parent then
		return false
	end

	return isWithinDistance(
		state.InteractablePart.Position,
		30
	)
end

local function updateInteractionState(state)
	if not state or not state.Interaction then
		return
	end

	local shouldShow = isStockInteractable(state)
	local sizeMultiplier = state.IsPressed
		and 0.8
		or 1

	if state.IsVisible == shouldShow
		and state.LastSizeMultiplier == sizeMultiplier
	then
		return
	end

	state.IsVisible = shouldShow
	state.LastSizeMultiplier = sizeMultiplier

	tweenInteraction(
		shouldShow,
		state.Interaction,
		sizeMultiplier
	)
end

-- A single RenderStepped connection updates every active prompt.
-- The original version created one permanent render connection per stock.
local function updateAllInteractions()
	for _, state in pairs(stockStates) do
		updateInteractionState(state)
	end
end

local function startInteractionUpdater()
	if renderConnection then
		return
	end

	renderConnection = RunService.RenderStepped:Connect(
		updateAllInteractions
	)
end

local function stopPetAnimation(stockId)
	petAnimationStates[stockId] = nil
end

local function registerPetAnimation(stockId, pet)
	if not pet or not pet:IsA("Model") then
		return
	end

	local primaryPart = pet.PrimaryPart
	if not primaryPart then
		return
	end

	petAnimationStates[stockId] = {
		Model = pet,
		OriginalCFrame = primaryPart.CFrame,
	}
end

-- Pet animations also share one RenderStepped connection through
-- the same controller update loop instead of one connection per pet.
local function updatePetAnimations()
	local timeStep = os.clock() / 1.5

	for stockId, animationState in pairs(petAnimationStates) do
		local pet = animationState.Model
		local primaryPart = pet and pet.PrimaryPart

		if not pet or not pet.Parent or not primaryPart then
			petAnimationStates[stockId] = nil
			continue
		end

		local wave = timeStep * 4
		local tilt = math.rad(math.cos(wave) * 8)
		local verticalMovement = math.sin(wave) * 0.5

		local offset = CFrame.new(
			0,
			2 + verticalMovement,
			0
		)

		primaryPart.CFrame =
			animationState.OriginalCFrame
			* offset
			* CFrame.Angles(tilt, 0, 0)
	end
end

local animationConnection

local function startPetAnimationUpdater()
	if animationConnection then
		return
	end

	animationConnection = RunService.RenderStepped:Connect(
		updatePetAnimations
	)
end

local function destroyInteraction(stockId)
	local state = getStockState(stockId)
	if not state then
		return
	end

	local interaction = state.Interaction
	state.Interaction = nil
	state.IsVisible = false
	state.IsPressed = false

	if not interaction then
		return
	end

	tweenInteraction(false, interaction, 0)

	task.delay(0.2, function()
		if interaction.Parent then
			interaction:Destroy()
		end
	end)
end

local function removeInteraction(stockId)
	local state = getStockState(stockId)
	if not state then
		return
	end

	setExpirationVisible(state.StockModel, false)
	destroyInteraction(stockId)

	task.delay(0.5, function()
		if stockStates[stockId] == state then
			stockStates[stockId] = nil
		end
	end)
end

local function prepareStock(stockId)
	local stockConfiguration = getStockConfiguration(stockId)
	if not stockConfiguration then
		return
	end

	local stockModel = getStockModel(stockId)
	if not stockModel then
		warn(
			"[StockPetsController] Stock model not found:",
			stockId
		)

		return
	end

	local interactablePart = getInteractablePart(stockModel)
	if not interactablePart then
		warn(
			"[StockPetsController] Interactable part missing:",
			stockId
		)

		return
	end

	local billboardGui = getBillboardGui(stockModel)
	if not billboardGui then
		warn(
			"[StockPetsController] BillboardGui missing:",
			stockId
		)

		return
	end

	removeInteraction(stockId)

	local interaction = createInteraction(
		interactablePart,
		stockId
	)

	stockStates[stockId] = {
		StockModel = stockModel,
		InteractablePart = interactablePart,
		Interaction = interaction,
		IsPressed = false,
		IsVisible = false,
		LastSizeMultiplier = nil,
	}

	setExpirationVisible(stockModel, true)
	updateInteractionState(stockStates[stockId])
end

local function setPressedStateForNearbyStocks(isPressed)
	for _, state in pairs(stockStates) do
		if isStockInteractable(state) then
			state.IsPressed = isPressed
			updateInteractionState(state)
		end
	end
end

local function purchaseNearestStock()
	local nearestStockId
	local nearestDistance = math.huge
	local rootPart = getCharacterRootPart()

	if not rootPart then
		return
	end

	for stockId, state in pairs(stockStates) do
		local interactablePart = state.InteractablePart
		if not interactablePart or not interactablePart.Parent then
			continue
		end

		local distance =
			(rootPart.Position - interactablePart.Position).Magnitude

		if distance <= 30
			and distance < nearestDistance
		then
			nearestStockId = stockId
			nearestDistance = distance
		end
	end

	if nearestStockId then
		promptPurchase(nearestStockId)
	end
end

local function onInputBegan(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode ~= Enum.KeyCode.E then
		return
	end

	setPressedStateForNearbyStocks(true)
end

local function onInputEnded(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode ~= Enum.KeyCode.E then
		return
	end

	purchaseNearestStock()
	setPressedStateForNearbyStocks(false)
end

local function connectInput()
	if not inputBeganConnection then
		inputBeganConnection =
			UserInputService.InputBegan:Connect(onInputBegan)
	end

	if not inputEndedConnection then
		inputEndedConnection =
			UserInputService.InputEnded:Connect(onInputEnded)
	end
end

local function setupPetAnimations()
	for stockId in pairs(StockPetList) do
		local stockModel = getStockModel(stockId)
		if not stockModel then
			continue
		end

		local petContainer = stockModel:FindFirstChild("Pet")
		local pet = petContainer
			and petContainer:FindFirstChild("Pet")

		if pet then
			registerPetAnimation(stockId, pet)
		end
	end

	startPetAnimationUpdater()
end

local function loadActiveStocks()
	StockPetsService:GetActiveStocks():andThen(function(activeStocks)
		if type(activeStocks) ~= "table" then
			return
		end

		for _, stockId in ipairs(activeStocks) do
			prepareStock(stockId)
		end
	end):catch(function(errorMessage)
		warn(
			"[StockPetsController] Failed to load active stocks:",
			errorMessage
		)
	end)
end

function StockPetsController:KnitStart()
	InteractableController =
		Knit.GetController("InteractableController")

	StockPetsService =
		Knit.GetService("StockPetsService")

	startInteractionUpdater()
	connectInput()
	setupPetAnimations()
	loadActiveStocks()

	StockPetsService.PrepareStock:Connect(prepareStock)
	StockPetsService.RemoveStock:Connect(removeInteraction)
end

return StockPetsController
