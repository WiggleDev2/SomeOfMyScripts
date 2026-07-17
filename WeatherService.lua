-- Discord: wiggledev | Roblox: WiggleDev

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Knit = require(Packages:WaitForChild("Knit"))
local Promise = require(Packages:WaitForChild("Promise"))
local Weather = require(Knit.Shared.List.Weather)
local TweenUtil = require(Knit.Shared.Utility.TweenUtil)

local FOG_WEATHERS = {
	Foggy = true,
	["Foggy And Cloudy"] = true,
	["Foggy And Snowy"] = true,
}

local WeatherService = Knit.CreateService({
	Name = "WeatherService",
	Client = {
		CurrentWeather = Knit.CreateProperty(""),
		ClaimThunder = Knit.CreateSignal(),
	},
})

local ServerUpdates
local HoverboardService

local currentWeather = ""
local claimedThunderPlayers = {}

-- Each lightning simulation receives its own session ID so an old loop
-- cannot continue producing flashes after the weather changes.
local lightningSessionId = 0
local weatherLoopRunning = false

-- The atmosphere is moved between Lighting and ReplicatedFirst depending
-- on whether Roblox fog or Atmosphere should control visibility.
local function getAtmosphere()
	return Lighting:FindFirstChildOfClass("Atmosphere")
		or ReplicatedFirst:FindFirstChildOfClass("Atmosphere")
end

local function tweenAtmosphere(atmosphere, density, haze)
	if not atmosphere then
		return
	end

	local tweenInfo = TweenInfo.new(
		1,
		Enum.EasingStyle.Sine
	)

	TweenUtil.Play(atmosphere, tweenInfo, {
		Density = density,
	})

	TweenUtil.Play(atmosphere, tweenInfo, {
		Haze = haze,
	})
end

local function moveAtmosphere(parent)
	local atmosphere = getAtmosphere()
	if not atmosphere then
		return nil
	end

	atmosphere.Parent = parent
	return atmosphere
end

-- Live server definitions take priority, with the shared weather list
-- acting as a fallback if updated data is unavailable.
local function getWeatherDefinitions()
	if ServerUpdates then
		local success, result = pcall(function()
			return ServerUpdates:ReturnWeatherInformation()
		end)

		if success and type(result) == "table" then
			return result
		end

		if not success then
			warn(
				"[WeatherService] Failed to load server weather data:",
				result
			)
		end
	end

	return Weather.GetAll()
end

local function isValidWeatherEntry(weatherData)
	if type(weatherData) ~= "table" then
		return false
	end

	if weatherData.CanRoll ~= true then
		return false
	end

	if type(weatherData.Chance) ~= "number" then
		return false
	end

	return weatherData.Chance > 0
end

local function buildWeightedWeatherList(weatherDefinitions)
	local weightedEntries = {}
	local totalWeight = 0

	for weatherName, weatherData in pairs(weatherDefinitions) do
		if not isValidWeatherEntry(weatherData) then
			continue
		end

		totalWeight += weatherData.Chance

		table.insert(weightedEntries, {
			Name = weatherName,
			Data = weatherData,
			Weight = weatherData.Chance,
		})
	end

	return weightedEntries, totalWeight
end

-- Weather is selected using a cumulative weighted roll rather than
-- treating each configured weather type equally.
local function selectWeightedWeather()
	local weatherDefinitions = getWeatherDefinitions()
	local weightedEntries, totalWeight =
		buildWeightedWeatherList(weatherDefinitions)

	if totalWeight <= 0 then
		return nil, nil
	end

	local roll = Random.new():NextNumber(0, totalWeight)
	local cumulativeWeight = 0

	for _, entry in ipairs(weightedEntries) do
		cumulativeWeight += entry.Weight

		if roll <= cumulativeWeight then
			return entry.Name, entry.Data
		end
	end

	-- The final entry covers rare floating-point edge cases.
	local fallbackEntry = weightedEntries[#weightedEntries]
	if not fallbackEntry then
		return nil, nil
	end

	return fallbackEntry.Name, fallbackEntry.Data
end

-- Invalid duration ranges are repaired before selecting a random length.
local function getWeatherDuration(weatherData)
	if type(weatherData) ~= "table" then
		return 60
	end

	local minimumDuration = tonumber(weatherData.LastTimeMin) or 60
	local maximumDuration = tonumber(weatherData.LastTimeMax)
		or minimumDuration

	minimumDuration = math.max(minimumDuration, 1)
	maximumDuration = math.max(maximumDuration, minimumDuration)

	return math.random(minimumDuration, maximumDuration)
end

local function shouldUseFog(weatherName)
	return FOG_WEATHERS[weatherName] == true
end

-- Fog weather temporarily removes Atmosphere so it does not compete with
-- Lighting.FogEnd. Normal weather restores and fades the atmosphere back in.
local function setFogEnabled(enabled)
	if enabled then
		local atmosphere = getAtmosphere()

		if atmosphere and atmosphere.Parent == Lighting then
			tweenAtmosphere(atmosphere, 0, 0)
			task.wait(1.5)

			if atmosphere.Parent == Lighting then
				atmosphere.Parent = ReplicatedFirst
			end
		end

		task.wait(0.5)

		TweenUtil.Play(
			Lighting,
			TweenInfo.new(
				1,
				Enum.EasingStyle.Sine
			),
			{
				FogEnd = math.random(
					500,
					700
				),
			}
		)

		return
	end

	local atmosphere = getAtmosphere()

	if atmosphere and atmosphere.Parent == ReplicatedFirst then
		atmosphere.Parent = Lighting
		task.wait(0.1)

		tweenAtmosphere(
			atmosphere,
			0.3,
			1
		)
	end

	task.wait(0.5)

	TweenUtil.Play(
		Lighting,
		TweenInfo.new(
			1,
			Enum.EasingStyle.Sine
		),
		{
			FogEnd = 10000,
		}
	)
end

local function createLightningFlash(originalBrightness)
	Lighting.Brightness =
		originalBrightness * 2

	task.wait(0.08)

	Lighting.Brightness = originalBrightness
end

-- The captured session ID invalidates this loop as soon as another
-- lightning session starts or the current one is stopped.
local function startLightningSimulation()
	lightningSessionId += 1
	local sessionId = lightningSessionId

	task.spawn(function()
		while currentWeather == "Stormy"
			and sessionId == lightningSessionId
		do
			task.wait(
				math.random(
					3,
					8
				)
			)

			if currentWeather ~= "Stormy"
				or sessionId ~= lightningSessionId
			then
				break
			end

			local originalBrightness = Lighting.Brightness
			createLightningFlash(originalBrightness)
		end
	end)
end

local function stopLightningSimulation()
	lightningSessionId += 1
end

local function updateLightningState(weatherName)
	if weatherName == "Stormy" then
		startLightningSimulation()
		return
	end

	stopLightningSimulation()
end

-- Thunder rewards may be claimed once per player during each storm.
local function resetThunderClaims()
	table.clear(claimedThunderPlayers)
end

local function applyWeatherEffects(weatherName)
	setFogEnabled(shouldUseFog(weatherName))
	updateLightningState(weatherName)
end

-- The current weather is stored server-side and replicated to clients.
local function publishCurrentWeather(weatherName)
	currentWeather = weatherName
	WeatherService.Client.CurrentWeather:Set(weatherName)
end

-- Returns a Promise so the main weather loop can wait for the selected
-- weather duration before beginning the next cycle.
local function loadNextWeather()
	local selectedWeather, weatherData =
		selectWeightedWeather()

	if not selectedWeather or not weatherData then
		warn(
			"[WeatherService] No valid weather configuration found"
		)

		return Promise.delay(5)
	end

	local duration = getWeatherDuration(weatherData)

	resetThunderClaims()
	applyWeatherEffects(selectedWeather)
	publishCurrentWeather(selectedWeather)

	return Promise.delay(duration)
end

local function canClaimThunder(player)
	if currentWeather ~= "Stormy" then
		return false, "WrongWeather"
	end

	if claimedThunderPlayers[player] then
		return false, "AlreadyClaimed"
	end

	return true
end

-- The player is marked before granting the reward to block duplicate
-- requests. The claim is restored if the grant fails.
local function claimThunder(player)
	local canClaim = canClaimThunder(player)
	if not canClaim then
		return
	end

	claimedThunderPlayers[player] = true

	local success, result = pcall(function()
		return HoverboardService:GrantHoverboard(
			player,
			"Stormy Hoverboard"
		)
	end)

	if success and result ~= false then
		return
	end

	claimedThunderPlayers[player] = nil

	warn(
		"[WeatherService] Failed to grant thunder reward to",
		player.Name,
		result
	)
end

local function onPlayerRemoving(player)
	claimedThunderPlayers[player] = nil
end

-- Only one weather loop may run at a time. Failed cycles wait briefly
-- before retrying so repeated errors cannot create a tight loop.
local function runWeatherLoop()
	if weatherLoopRunning then
		return
	end

	weatherLoopRunning = true

	task.spawn(function()
		while weatherLoopRunning do
			local success, errorMessage =
				loadNextWeather():await()

			if success then
				continue
			end

			warn(
				"[WeatherService] Weather cycle failed:",
				errorMessage
			)

			task.wait(5)
		end
	end)
end

function WeatherService:GetCurrentWeather()
	return currentWeather
end

-- Forced weather uses the same effect and replication path as naturally
-- selected weather, but does not wait for or replace the active loop.
function WeatherService:ForceWeather(weatherName)
	local weatherDefinitions = getWeatherDefinitions()
	local weatherData = weatherDefinitions[weatherName]

	if type(weatherData) ~= "table" then
		return false, "InvalidWeather"
	end

	resetThunderClaims()
	applyWeatherEffects(weatherName)
	publishCurrentWeather(weatherName)

	return true
end

function WeatherService:KnitStart()
	ServerUpdates =
		Knit.GetService("ServerUpdates")

	HoverboardService =
		Knit.GetService("HoverboardService")

	self.Client.ClaimThunder:Connect(claimThunder)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	runWeatherLoop()
end

return WeatherService
