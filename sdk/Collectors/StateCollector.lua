--[[
	PLAY3 SDK - State Collector

	Collects game state from two sources:
	1. Developer-set state via SetState(player, key, value)
	2. Auto-collected state (sessionMinutes, idleMinutes, timeOfDay, isWeekend, leaderstats)
]]

local Players = game:GetService("Players")

local StateCollector = {}
StateCollector.__index = StateCollector

local playerStates = {}      -- Developer-set states
local playerJoinTimes = {}   -- For sessionMinutes
local playerClientData = {}  -- Client-sent data (idle, time)

function StateCollector.new(config)
	local self = setmetatable({}, StateCollector)
	self.config = config
	return self
end

function StateCollector:init()
	-- States are set by developer code and auto-collected
end

function StateCollector:initPlayer(player)
	-- Don't overwrite if state already exists (handles race conditions)
	if not playerStates[player.UserId] then
		playerStates[player.UserId] = {}
	end

	-- Track join time for sessionMinutes
	playerJoinTimes[player.UserId] = tick()

	-- Initialize client data storage
	playerClientData[player.UserId] = {
		idleMinutes = 0,
		timeOfDay = "unknown",
		isWeekend = false,
	}
end

-- Set any state value (called by developer)
function StateCollector:setState(player, key, value)
	local state = playerStates[player.UserId]
	if not state then
		-- Auto-initialize if not already done (handles race conditions)
		state = {}
		playerStates[player.UserId] = state
	end
	state[key] = value
end

-- Get a state value
function StateCollector:getState(player, key)
	local state = playerStates[player.UserId]
	return state and state[key]
end

-- Update client-sent data (called from RemoteEvent handler)
function StateCollector:updateClientData(player, data)
	local clientData = playerClientData[player.UserId]
	if not clientData then
		clientData = {}
		playerClientData[player.UserId] = clientData
	end

	if data.idleMinutes ~= nil then
		clientData.idleMinutes = data.idleMinutes
	end
	if data.timeOfDay ~= nil then
		clientData.timeOfDay = data.timeOfDay
	end
	if data.isWeekend ~= nil then
		clientData.isWeekend = data.isWeekend
	end
end

-- Get auto-collected leaderstats
function StateCollector:_getLeaderstats(player)
	local result = {}
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then return result end

	for _, stat in ipairs(leaderstats:GetChildren()) do
		if stat:IsA("ValueBase") then
			result[stat.Name] = stat.Value
		end
	end

	return result
end

-- Calculate sessionMinutes
function StateCollector:_getSessionMinutes(player)
	local joinTime = playerJoinTimes[player.UserId]
	if not joinTime then return 0 end
	return math.floor((tick() - joinTime) / 60)
end

-- Collect all state for API payload (merges developer-set + auto-collected)
function StateCollector:collect(player)
	local result = {}
	local autoStates = self.config.autoStates or {}

	-- 1. Add developer-set states
	local devState = playerStates[player.UserId]
	if devState then
		for k, v in pairs(devState) do
			result[k] = v
		end
	end

	-- 2. Add auto-collected states (if enabled)

	-- sessionMinutes
	if autoStates.sessionMinutes ~= false then
		result.sessionMinutes = self:_getSessionMinutes(player)
	end

	-- Client-sent data (idleMinutes, timeOfDay, isWeekend)
	local clientData = playerClientData[player.UserId]
	if clientData then
		if autoStates.idleMinutes ~= false then
			result.idleMinutes = clientData.idleMinutes
		end
		if autoStates.timeOfDay ~= false then
			result.timeOfDay = clientData.timeOfDay
		end
		if autoStates.isWeekend ~= false then
			result.isWeekend = clientData.isWeekend
		end
	end

	-- Leaderstats
	if autoStates.leaderstats ~= false then
		local leaderstats = self:_getLeaderstats(player)
		for k, v in pairs(leaderstats) do
			-- Don't overwrite developer-set states
			if result[k] == nil then
				result[k] = v
			end
		end
	end

	return result
end

function StateCollector:clearPlayer(player)
	playerStates[player.UserId] = nil
	playerJoinTimes[player.UserId] = nil
	playerClientData[player.UserId] = nil
end

return StateCollector
