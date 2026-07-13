-- Discord: wiggledev | Roblox: WiggleDev

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Game = ReplicatedStorage:WaitForChild("Game")
local Shared = Game:WaitForChild("Shared")
local Utility = Shared:WaitForChild("Utility")

local Knit = require(Packages:WaitForChild("Knit"))
local Shake = require(Packages:WaitForChild("Shake"))
local DistanceFade = require(Utility:WaitForChild("DistanceFade"))

local LOCAL_PLAYER = Players.LocalPlayer
local RENDER_PRIORITY = Enum.RenderPriority.Last.Value
local IMPULSE_STRENGTH = 90
local UPWARD_DIRECTION_MULTIPLIER = 1.1

local VALID_OBSTRUCTION_NAMES = {
	Part = true,
	Obstruction = true,
}

local ALL_FACES = {
	Enum.NormalId.Front,
	Enum.NormalId.Back,
	Enum.NormalId.Bottom,
	Enum.NormalId.Top,
	Enum.NormalId.Left,
	Enum.NormalId.Right,
}

local ObstructionController = Knit.CreateController({
	Name = "ObstructionController",
})

local ObstructionService
local EggHatchController

-- A single Heartbeat connection updates every DistanceFade object.
-- This avoids creating one permanent connection for each obstruction part.
local activeDistanceFades = {}
local registeredParts = {}
local heartbeatConnection

local function getCurrentCamera()
	return Workspace.CurrentCamera
end

local function getCharacterRootPart()
	local character = LOCAL_PLAYER.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart")
end

local function canApplyRejectionEffect()
	if not EggHatchController then
		return true
	end

	return not EggHatchController:IsHatching()
end

local function createDistanceFade(part)
	if registeredParts[part] then
		return
	end

	if not part:IsA("BasePart") then
		return
	end

	if not VALID_OBSTRUCTION_NAMES[part.Name] then
		return
	end

	local distanceFade = DistanceFade.new()

	for _, face in ipairs(ALL_FACES) do
		distanceFade:AddFace(part, face)
	end

	registeredParts[part] = distanceFade
	table.insert(activeDistanceFades, distanceFade)
end

local function registerObstructionFolder(obstructionFolder)
	for _, descendant in ipairs(obstructionFolder:GetDescendants()) do
		createDistanceFade(descendant)
	end

	obstructionFolder.DescendantAdded:Connect(createDistanceFade)
end

local function registerMap(map)
	local obstructionFolder = map:FindFirstChild("Obstruction")
	if not obstructionFolder then
		return
	end

	registerObstructionFolder(obstructionFolder)
end

local function registerMapsFrom(container)
	if not container then
		return
	end

	for _, map in ipairs(container:GetChildren()) do
		if map:IsA("Folder") or map:IsA("Model") then
			registerMap(map)
		end
	end

	container.ChildAdded:Connect(function(map)
		if not map:IsA("Folder") and not map:IsA("Model") then
			return
		end

		registerMap(map)
	end)
end

local function stepDistanceFades()
	for index = #activeDistanceFades, 1, -1 do
		local distanceFade = activeDistanceFades[index]

		local success, errorMessage = pcall(function()
			distanceFade:Step()
		end)

		if success then
			continue
		end

		warn(
			"[ObstructionController] DistanceFade update failed:",
			errorMessage
		)

		table.remove(activeDistanceFades, index)
	end
end

local function startDistanceFadeUpdater()
	if heartbeatConnection then
		return
	end

	heartbeatConnection = RunService.Heartbeat:Connect(stepDistanceFades)
end

-- The shake is applied to the current camera every rendered frame.
-- Shake.NextRenderName() prevents render-step binding name collisions.
local function playRejectionShake()
	local camera = getCurrentCamera()
	if not camera then
		return
	end

	local shake = Shake.new()
	shake.FadeInTime = 0
	shake.Frequency = 0.1
	shake.Amplitude = 1
	shake.RotationInfluence = Vector3.new(0.1, 0.1, 0.1)

	shake:Start()
	shake:BindToRenderStep(
		Shake.NextRenderName(),
		RENDER_PRIORITY,
		function(positionOffset, rotationOffset)
			local currentCamera = getCurrentCamera()
			if not currentCamera then
				return
			end

			local translation = CFrame.new(positionOffset)
			local rotation = CFrame.Angles(
				rotationOffset.X,
				rotationOffset.Y,
				rotationOffset.Z
			)

			currentCamera.CFrame *= translation * rotation
		end
	)
end

local function applyRejectionImpulse()
	local rootPart = getCharacterRootPart()
	if not rootPart then
		return
	end

	local forwardDirection = rootPart.CFrame.LookVector
	local adjustedDirection = Vector3.new(
		forwardDirection.X,
		forwardDirection.Y * UPWARD_DIRECTION_MULTIPLIER,
		forwardDirection.Z
	)

	if adjustedDirection.Magnitude == 0 then
		return
	end

	local impulseDirection = -adjustedDirection.Unit
	local impulse = impulseDirection * rootPart.AssemblyMass * IMPULSE_STRENGTH

	rootPart:ApplyImpulse(impulse)
end

-- Knit client signals do not automatically pass the receiving player.
-- The controller therefore operates on Players.LocalPlayer.
local function onPlayerRejected()
	if canApplyRejectionEffect() then
		playRejectionShake()
	end

	applyRejectionImpulse()
end

local function initializeMapObstructions()
	local workspaceMaps = Workspace:FindFirstChild("Maps")
	local replicatedWorlds = ReplicatedStorage:FindFirstChild("Worlds")

	registerMapsFrom(workspaceMaps)
	registerMapsFrom(replicatedWorlds)
	startDistanceFadeUpdater()
end

function ObstructionController:KnitStart()
	ObstructionService = Knit.GetService("ObstructionService")
	EggHatchController = Knit.GetController("EggHatchController")

	initializeMapObstructions()
	ObstructionService.RejectPlayer:Connect(onPlayerRejected)
end

return ObstructionController
