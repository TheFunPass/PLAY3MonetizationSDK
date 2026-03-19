--[[
	PLAY3 SDK - Auto State Client

	Tracks client-side state and sends to server:
	- idleMinutes: Time since last user input
	- timeOfDay: Player's local time bucket (morning/afternoon/evening/night)
	- isWeekend: Whether it's Saturday or Sunday in player's timezone
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Don't run in edit mode
if not RunService:IsRunning() then
	return
end

local player = Players.LocalPlayer

-- Wait for remotes
local function getRemote()
	local remotesFolder = ReplicatedStorage:WaitForChild("PLAY3Remotes", 30)
	if not remotesFolder then
		warn("[PLAY3] AutoStateClient: Could not find PLAY3Remotes folder")
		return nil
	end

	local autoStateRemote = remotesFolder:WaitForChild("AutoState", 10)
	if not autoStateRemote then
		warn("[PLAY3] AutoStateClient: Could not find AutoState remote")
		return nil
	end

	return autoStateRemote
end

local autoStateRemote = getRemote()
if not autoStateRemote then
	return
end

-- Track last input time
local lastInputTime = tick()

-- Update on any input
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	lastInputTime = tick()
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	lastInputTime = tick()
end)

-- Get time of day bucket from hour
local function getTimeOfDay(hour)
	if hour >= 5 and hour < 12 then
		return "morning"
	elseif hour >= 12 and hour < 17 then
		return "afternoon"
	elseif hour >= 17 and hour < 21 then
		return "evening"
	else
		return "night"
	end
end

-- Get local time data
local function getLocalTimeData()
	local dateTable = os.date("*t")
	local hour = dateTable.hour
	local wday = dateTable.wday -- 1 = Sunday, 7 = Saturday

	return {
		timeOfDay = getTimeOfDay(hour),
		isWeekend = (wday == 1 or wday == 7),
	}
end

-- Calculate idle minutes
local function getIdleMinutes()
	return math.floor((tick() - lastInputTime) / 60)
end

-- Send state to server
local function sendAutoState()
	local timeData = getLocalTimeData()

	autoStateRemote:FireServer({
		idleMinutes = getIdleMinutes(),
		timeOfDay = timeData.timeOfDay,
		isWeekend = timeData.isWeekend,
	})
end

-- Send immediately on load
task.defer(function()
	task.wait(1) -- Small delay to ensure server is ready
	sendAutoState()
end)

-- Send periodically (every 30 seconds)
task.spawn(function()
	while true do
		task.wait(30)
		if player and player.Parent then
			sendAutoState()
		else
			break
		end
	end
end)

print("[PLAY3] AutoStateClient ready")
