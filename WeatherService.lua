local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Weather = require(Knit.Shared.List.Weather)
local TweenUtil = require(Knit.Shared.Utility.TweenUtil)
local ServerUpdates = nil
local hoverboardService
local Lighting = game:GetService("Lighting")
local weathersWithFog = {"Foggy", "Foggy And Cloudy", "Foggy And Snowy"}

local WeatherService = Knit.CreateService {
	Name = "WeatherService";
	Client = {
		CurrentWeather = Knit.CreateProperty(""),
		ClaimThunder = Knit.CreateSignal()
	};
}

local claimDebounces = {}
local CURRENTWEATHER = ""

function WeatherService:_simulateFog(toggled: boolean)
	if (toggled == true) then
		if Lighting:FindFirstChild("Atmosphere") then
			TweenUtil.Play(Lighting:FindFirstChild("Atmosphere"), TweenInfo.new(1, Enum.EasingStyle.Sine), { Density = 0 })	
			TweenUtil.Play(Lighting:FindFirstChild("Atmosphere"), TweenInfo.new(1, Enum.EasingStyle.Sine), { Haze = 0 })	
			task.wait(1.5)
			Lighting:FindFirstChild("Atmosphere").Parent = game.ReplicatedFirst	
			task.wait(0.5)
		end
		local rng = math.random(500, 700)
		TweenUtil.Play(Lighting, TweenInfo.new(1, Enum.EasingStyle.Sine), { FogEnd = rng })	
	else
		if game.ReplicatedFirst:FindFirstChild("Atmosphere") then
			local Atmosphere = game.ReplicatedFirst:FindFirstChild("Atmosphere")
			Atmosphere.Parent = game.Lighting
			task.wait(0.1)
			TweenUtil.Play(Atmosphere, TweenInfo.new(1, Enum.EasingStyle.Sine), { Density = 0.3 })	
			TweenUtil.Play(Atmosphere, TweenInfo.new(1, Enum.EasingStyle.Sine), { Haze = 1 })
		end
		task.wait(0.5)
		TweenUtil.Play(Lighting, TweenInfo.new(1, Enum.EasingStyle.Sine), { FogEnd = 10000 })
	end	
end

function WeatherService:_simulateLightning(toggled: boolean)
	if (toggled == true) then
		
	else
		
	end	
end

function WeatherService:_generateWeather()	
    local weightedSum = 0
    local NewStats = {}

    if ServerUpdates:ReturnWeatherInformation() ~= nil then
        NewStats = ServerUpdates:ReturnWeatherInformation() 
    else
        NewStats = Weather.GetAll()
    end
	
	 for key, value in pairs(NewStats) do
        if type(value) ~= "table" or not value.CanRoll then
            continue
        end
        weightedSum = weightedSum + value.Chance
    end
	
	local random = Random.new()
	local rng = random:NextNumber(0, weightedSum)
	
	for key, value in pairs(NewStats) do
		if type(value) ~= "table" then
			continue
		end
		local chance = value.CanRoll and value.Chance or 0
		if rng < chance then
			return key, value
		end
		rng = rng - chance
	end
end

function WeatherService:_loadWeather()
	local selectedWeather, weatherData = self:_generateWeather()
	local weatherDuration = math.random(weatherData.LastTimeMin, weatherData.LastTimeMax)
	--warn("Weather: " .. selectedWeather, "Duration: " .. weatherDuration)
	
	if (table.find(weathersWithFog, selectedWeather)) then
		self:_simulateFog(true)
	else
		self:_simulateFog(false)
	end
	
	if (selectedWeather) == "Stormy" then
		self:_simulateLightning(true)
	else
		self:_simulateLightning(false)
	end
	
	CURRENTWEATHER = selectedWeather
	self.Client.CurrentWeather:Set(selectedWeather)
	
	return Promise.delay(weatherDuration) --> weatherDuration
end


function WeatherService:KnitStart()
	ServerUpdates = Knit.GetService("ServerUpdates")
	hoverboardService = Knit.GetService("HoverboardService")
	
	WeatherService.Client.ClaimThunder:Connect(function(player)
		if not claimDebounces[player] and CURRENTWEATHER == "Stormy" then
			claimDebounces[player] = true
			
			hoverboardService:GrantHoverboard(player, "Stormy Hoverboard")
		end
	end)
	
	while (true) do
		self:_loadWeather():await()
	end
end


function WeatherService:KnitInit()
	
end


return WeatherService
