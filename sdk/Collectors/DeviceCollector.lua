--[[
	PLAY3 SDK - Device Collector
	Receives device info from client and stores it
]]

local RunService = game:GetService("RunService")

local DeviceCollector = {}
DeviceCollector.__index = DeviceCollector

local playerDeviceData = {}

function DeviceCollector.new(config)
	local self = setmetatable({}, DeviceCollector)
	self.config = config
	return self
end

function DeviceCollector:init()
	-- Skip remote setup in Studio edit mode
	if not RunService:IsRunning() then
		return
	end

	-- Create RemoteEvent for client to send device data
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local remotesFolder = ReplicatedStorage:FindFirstChild("PLAY3Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "PLAY3Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local deviceEvent = remotesFolder:FindFirstChild("DeviceInfo")
	if not deviceEvent then
		deviceEvent = Instance.new("RemoteEvent")
		deviceEvent.Name = "DeviceInfo"
		deviceEvent.Parent = remotesFolder
	end

	local success = pcall(function()
		deviceEvent.OnServerEvent:Connect(function(player, data)
			self:receiveDeviceData(player, data)
		end)
	end)

	if not success then
		warn("[PLAY3] DeviceCollector: Could not connect OnServerEvent (expected in edit mode)")
	end
end

function DeviceCollector:receiveDeviceData(player, data)
	if not data or type(data) ~= "table" then return end

	playerDeviceData[player.UserId] = {
		platform = data.platform or "unknown",
		deviceSubType = data.deviceSubType or "unknown",
		inputType = data.inputType or "unknown",
		screenResX = data.screenResX or 0,
		screenResY = data.screenResY or 0,
		isMobile = data.isMobile or false,
		isConsole = data.isConsole or false,
		isVR = data.isVR or false,
		receivedAt = tick(),
	}
end

function DeviceCollector:collect(player)
	local data = playerDeviceData[player.UserId]

	if data then
		return {
			platform = data.platform,
			deviceSubType = data.deviceSubType,
			inputType = data.inputType,
			screenResX = data.screenResX,
			screenResY = data.screenResY,
			isMobile = data.isMobile,
			isConsole = data.isConsole,
			isVR = data.isVR,
		}
	else
		return {
			platform = "unknown",
			deviceSubType = "unknown",
			inputType = "unknown",
			screenResX = 0,
			screenResY = 0,
			isMobile = false,
			isConsole = false,
			isVR = false,
		}
	end
end

function DeviceCollector:clearPlayer(player)
	playerDeviceData[player.UserId] = nil
end

return DeviceCollector