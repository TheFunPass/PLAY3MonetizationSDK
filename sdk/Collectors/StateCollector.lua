--[[
	PLAY3 SDK - State Collector
	Simple key/value store for game state
	Developer sets any values via SetState(player, key, value)
]]

local StateCollector = {}
StateCollector.__index = StateCollector

local playerStates = {}

function StateCollector.new(config)
	local self = setmetatable({}, StateCollector)
	self.config = config
	return self
end

function StateCollector:init()
	-- States are set by developer code
end

function StateCollector:initPlayer(player)
	playerStates[player.UserId] = {}
end

-- Set any state value
function StateCollector:setState(player, key, value)
	local state = playerStates[player.UserId]
	if state then
		state[key] = value
	end
end

-- Get a state value
function StateCollector:getState(player, key)
	local state = playerStates[player.UserId]
	return state and state[key]
end

-- Collect all state for API payload (flat key/value)
function StateCollector:collect(player)
	local state = playerStates[player.UserId]
	if state then
		-- Return a copy of the state table
		local result = {}
		for k, v in pairs(state) do
			result[k] = v
		end
		return result
	else
		return {}
	end
end

function StateCollector:clearPlayer(player)
	playerStates[player.UserId] = nil
end

return StateCollector
