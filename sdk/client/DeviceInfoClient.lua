--[[
	PLAY3 SDK - Device Info Client

	Detects client device info and sends to server:
	- platform: pc/mobile/console/vr
	- deviceSubType: phone/tablet/xbox/playstation/unknown
	- inputType: keyboard/touch/gamepad
	- screenResX/screenResY: viewport dimensions
	- isMobile/isConsole/isVR: boolean flags
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local VRService = game:GetService("VRService")
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
		warn("[PLAY3] DeviceInfoClient: Could not find PLAY3Remotes folder")
		return nil
	end

	local deviceRemote = remotesFolder:WaitForChild("DeviceInfo", 10)
	if not deviceRemote then
		warn("[PLAY3] DeviceInfoClient: Could not find DeviceInfo remote")
		return nil
	end

	return deviceRemote
end

-- Determine device type
local function getDeviceType()
	if UserInputService.VREnabled or VRService.VREnabled then
		return "vr"
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "mobile"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "console"
	elseif UserInputService.KeyboardEnabled then
		return "pc"
	end
	return "unknown"
end

-- Determine device subtype
local function getDeviceSubType(deviceType)
	if deviceType == "mobile" then
		local camera = workspace.CurrentCamera
		if camera then
			local longestSide = math.max(camera.ViewportSize.X, camera.ViewportSize.Y)
			local shortestSide = math.min(camera.ViewportSize.X, camera.ViewportSize.Y)
			local aspectRatio = longestSide / shortestSide
			if aspectRatio > 1.8 then
				return "phone"
			elseif aspectRatio <= 1.7 then
				return "tablet"
			else
				return "phone" -- Default for edge cases
			end
		end
	elseif deviceType == "console" then
		local success, imageUrl = pcall(function()
			return UserInputService:GetImageForKeyCode(Enum.KeyCode.ButtonX)
		end)
		if success and imageUrl then
			if string.find(imageUrl, "Xbox") then
				return "xbox"
			elseif string.find(imageUrl, "PlayStation") then
				return "playstation"
			end
		end
		return "unknown"
	end
	return "unknown"
end

-- Determine current input type
local function getInputType()
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "gamepad"
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	else
		return "keyboard"
	end
end

-- Get screen resolution
local function getScreenResolution()
	local camera = workspace.CurrentCamera
	if camera then
		return camera.ViewportSize.X, camera.ViewportSize.Y
	end
	return 0, 0
end

-- Collect all device info
local function collectDeviceInfo()
	local deviceType = getDeviceType()
	local screenX, screenY = getScreenResolution()

	return {
		platform = deviceType,
		deviceSubType = getDeviceSubType(deviceType),
		inputType = getInputType(),
		screenResX = math.floor(screenX),
		screenResY = math.floor(screenY),
		isMobile = deviceType == "mobile",
		isConsole = deviceType == "console",
		isVR = deviceType == "vr",
	}
end

-- Main
local deviceRemote = getRemote()
if not deviceRemote then
	return
end

-- Send device info immediately on load
task.defer(function()
	task.wait(0.5) -- Small delay to ensure camera is ready
	local deviceInfo = collectDeviceInfo()
	deviceRemote:FireServer(deviceInfo)
end)

-- Track input type changes and resend if needed
local lastInputType = getInputType()

UserInputService.LastInputTypeChanged:Connect(function(lastType)
	local newInputType
	if lastType == Enum.UserInputType.Keyboard or lastType == Enum.UserInputType.MouseMovement then
		newInputType = "keyboard"
	elseif lastType == Enum.UserInputType.Touch then
		newInputType = "touch"
	elseif string.match(tostring(lastType), "Gamepad") then
		newInputType = "gamepad"
	end

	if newInputType and newInputType ~= lastInputType then
		lastInputType = newInputType
		local deviceInfo = collectDeviceInfo()
		deviceRemote:FireServer(deviceInfo)
	end
end)

print("[PLAY3] DeviceInfoClient ready")
