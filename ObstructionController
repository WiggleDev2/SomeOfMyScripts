local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local Shake = require(ReplicatedStorage.Packages.Shake)
local DistanceFade = require(ReplicatedStorage.Game.Shared.Utility.DistanceFade)

local Players = game:GetService("Players")
local Camera = workspace.Camera
local priority = Enum.RenderPriority.Last.Value

local ObstructionController = Knit.CreateController {
	Name = "ObstructionController",
}

function ObstructionController:KnitStart()
	local ObstructionService = Knit.GetService("ObstructionService")
	local EggHatchController = Knit.GetController("EggHatchController")
	
	local function applyDistanceFade(map)
		if map then
			local obstruction = map:FindFirstChild("Obstruction")
			if obstruction then
				for _, v in pairs(obstruction:GetChildren()) do
					if v.Name == "Part" or v.Name == "Obstruction" then
						local distanceFadeObj = DistanceFade.new()

						for _, face in pairs({Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Bottom, Enum.NormalId.Top, Enum.NormalId.Left, Enum.NormalId.Right}) do
							distanceFadeObj:AddFace(v, face)
						end

						game:GetService("RunService").Heartbeat:Connect(function()
							distanceFadeObj:Step()
						end)
					end
				end
			end
		else
			warn(map .. " not found in Workspace or ReplicatedStorage.Worlds")
		end
	end

	local function getMapNames()
		local maps = {}
		local workspaceMaps = game:GetService("Workspace"):FindFirstChild("Maps")
		local replicatedStorageWorlds = game:GetService("ReplicatedStorage"):FindFirstChild("Worlds")

		if workspaceMaps then
			for _, map in pairs(workspaceMaps:GetChildren()) do
				if map:IsA("Folder") then
					table.insert(maps, map)
				end
			end
		end

		if replicatedStorageWorlds then
			for _, world in pairs(replicatedStorageWorlds:GetChildren()) do
				if world:IsA("Folder") then
					table.insert(maps, world)
				end
			end
		end

		return maps
	end

	local mapModels = getMapNames()

	for _, map in pairs(mapModels) do
		applyDistanceFade(map)
	end
	
	ObstructionService.RejectPlayer:Connect(function(player: Player)
		if (player.Character) then
			if (EggHatchController:IsHatching() == false) then
				local shake = Shake.new()
				shake.FadeInTime = 0
				shake.Frequency = 0.1
				shake.Amplitude = 1
				shake.RotationInfluence = Vector3.new(0.1, 0.1, 0.1)
				shake:Start()
				shake:BindToRenderStep(Shake.NextRenderName(), priority, function(pos, rot, isDone)
					Camera.CFrame *= CFrame.new(pos) * CFrame.Angles(rot.X, rot.Y, rot.Z)
				end)
			end
			
			local assemblyMass = player.Character:FindFirstChild("HumanoidRootPart").AssemblyMass
			local direction = player.Character:FindFirstChild("HumanoidRootPart").CFrame.LookVector * Vector3.new(1, 1.1, 1)
			player.Character:FindFirstChild("HumanoidRootPart"):ApplyImpulse(-direction * assemblyMass * 90)
		end
	end)
end


function ObstructionController:KnitInit()

end


return ObstructionController
