--[[
	PLAY3 SDK - API Client
	Handles all HTTP communication with PLAY3 backend
	Uses batching for outcomes and session_end to reduce HTTP overhead
]]

local HttpService = game:GetService("HttpService")

local HashLib = require(script.Parent.Parent.Analytics.HashLib.init)

local APIClient = {}
APIClient.__index = APIClient

-- API endpoints
local ENDPOINTS = {
	ACTIONS = "/actions",
	ROBLOX_EVENTS = "/roblox-events",
	ROBLOX_EVENTS_BATCH = "/roblox-events/batch",
}

-- Batching configuration
local BATCH_INTERVAL = 5 -- Flush every 5 seconds
local BATCH_MAX_SIZE = 20 -- Flush when queue reaches this size

--[[
	Hash player ID using SHA256 for consistent obfuscation
]]
local function hashPlayerId(playerId)
	return HashLib.sha256(tostring(playerId))
end

--[[
	Get ISO 8601 timestamp
]]
local function getISOTimestamp()
	return os.date("!%Y-%m-%dT%H:%M:%S") .. ".000Z"
end

function APIClient.new(config)
	local self = setmetatable({}, APIClient)
	self.config = config
	self.baseUrl = config.API_URL or "https://play3-ai-assistant-605640375727.us-central1.run.app"
	self.apiKey = config.API_KEY
	self.debug = config.debug or false
	self.gameId = tostring(game.GameId)

	-- Batching queues
	self.outcomeQueue = {}
	self.sessionEndQueue = {}
	self.isProcessing = false

	-- Start batch processor
	self:_startBatchProcessor()

	return self
end

--[[
	Start background batch processor
]]
function APIClient:_startBatchProcessor()
	task.spawn(function()
		while true do
			task.wait(BATCH_INTERVAL)
			self:_flushQueues()
		end
	end)
end

--[[
	Flush all queues
]]
function APIClient:_flushQueues()
	-- Flush outcomes
	if #self.outcomeQueue > 0 then
		local batch = self.outcomeQueue
		self.outcomeQueue = {}
		self:_sendOutcomeBatch(batch)
	end

	-- Flush session ends
	if #self.sessionEndQueue > 0 then
		local batch = self.sessionEndQueue
		self.sessionEndQueue = {}
		self:_sendSessionEndBatch(batch)
	end
end

--[[
	Send batch of outcomes
]]
function APIClient:_sendOutcomeBatch(batch)
	local url = self.baseUrl .. ENDPOINTS.ROBLOX_EVENTS_BATCH

	-- Transform batch to new format: each item needs {timestamp, data}
	local events = {}
	for _, item in ipairs(batch) do
		table.insert(events, {
			timestamp = item.timestamp,
			data = item.data,
		})
	end

	local body = HttpService:JSONEncode({
		eventType = "outcome",
		gameId = self.gameId,
		events = events,
	})

	task.spawn(function()
		local success, response = pcall(function()
			return HttpService:RequestAsync({
				Url = url,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-api-key"] = self.apiKey or "",
				},
				Body = body,
			})
		end)

		if success and response.StatusCode == 201 then
			if self.debug then
				print("[PLAY3 API] Sent outcome batch:", #batch, "items")
			end
		elseif success and response.StatusCode == 404 then
			-- Batch endpoint not available, fall back to individual sends
			if self.debug then
				print("[PLAY3 API] Batch endpoint not available, sending individually")
			end
			self:_sendOutcomesIndividually(batch)
		else
			if self.debug then
				warn("[PLAY3 API] Outcome batch failed:", response and response.StatusCode or "error")
			end
			-- On failure, try individual sends
			self:_sendOutcomesIndividually(batch)
		end
	end)
end

--[[
	Fallback: send outcomes individually
]]
function APIClient:_sendOutcomesIndividually(batch)
	local url = self.baseUrl .. ENDPOINTS.ROBLOX_EVENTS

	for _, item in ipairs(batch) do
		task.spawn(function()
			local body = HttpService:JSONEncode({
				eventType = "outcome",
				gameId = self.gameId,
				timestamp = item.timestamp,
				data = item.data,
			})

			pcall(function()
				HttpService:RequestAsync({
					Url = url,
					Method = "POST",
					Headers = {
						["Content-Type"] = "application/json",
						["x-api-key"] = self.apiKey or "",
					},
					Body = body,
				})
			end)
		end)
		task.wait(0.1) -- Small delay between individual sends
	end
end

--[[
	Send batch of session ends
]]
function APIClient:_sendSessionEndBatch(batch)
	local url = self.baseUrl .. ENDPOINTS.ROBLOX_EVENTS_BATCH

	-- Transform batch to new format: each item needs {timestamp, data}
	local events = {}
	for _, item in ipairs(batch) do
		table.insert(events, {
			timestamp = item.timestamp,
			data = item.data,
		})
	end

	local body = HttpService:JSONEncode({
		eventType = "session_end",
		gameId = self.gameId,
		events = events,
	})

	task.spawn(function()
		local success, response = pcall(function()
			return HttpService:RequestAsync({
				Url = url,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-api-key"] = self.apiKey or "",
				},
				Body = body,
			})
		end)

		if success and response.StatusCode == 201 then
			if self.debug then
				print("[PLAY3 API] Sent session_end batch:", #batch, "items")
			end
		elseif success and response.StatusCode == 404 then
			-- Batch endpoint not available, fall back to individual sends
			self:_sendSessionEndsIndividually(batch)
		else
			if self.debug then
				warn("[PLAY3 API] Session end batch failed:", response and response.StatusCode or "error")
			end
			self:_sendSessionEndsIndividually(batch)
		end
	end)
end

--[[
	Fallback: send session ends individually
]]
function APIClient:_sendSessionEndsIndividually(batch)
	local url = self.baseUrl .. ENDPOINTS.ROBLOX_EVENTS

	for _, item in ipairs(batch) do
		task.spawn(function()
			local body = HttpService:JSONEncode({
				eventType = "session_end",
				gameId = self.gameId,
				timestamp = item.timestamp,
				data = item.data,
			})

			pcall(function()
				HttpService:RequestAsync({
					Url = url,
					Method = "POST",
					Headers = {
						["Content-Type"] = "application/json",
						["x-api-key"] = self.apiKey or "",
					},
					Body = body,
				})
			end)
		end)
		task.wait(0.1)
	end
end

--[[
	Make API request for pricing decision
	Called when cache-first system determines we need AI input
]]
function APIClient:request(payload)
	local url = self.baseUrl .. ENDPOINTS.ACTIONS

	-- Format payload to match API expectations
	local body = HttpService:JSONEncode({
		action = "pricing",
		gameId = self.gameId,
		playerId = tostring(payload.playerId),
		context = payload,
	})

	local success, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["x-api-key"] = self.apiKey or "",
			},
			Body = body,
		})
	end)

	if not success then
		if self.debug then
			warn("[PLAY3 API] Request failed:", response)
		end
		return { success = false, error = response }
	end

	if response.StatusCode ~= 200 then
		if self.debug then
			warn("[PLAY3 API] HTTP error:", response.StatusCode, response.Body)
		end
		return { success = false, error = "HTTP " .. response.StatusCode }
	end

	local decoded = HttpService:JSONDecode(response.Body)

	-- Debug: Print API response
	if self.debug then
		local resp = decoded.response or decoded
		if resp.reasoning and resp.reasoning.summary then
			print("[PLAY3 API] Reasoning:", resp.reasoning.summary)
		end
		if resp.decision then
			print("[PLAY3 API] Decision:", HttpService:JSONEncode(resp.decision))
		end
	end

	-- Extract decision from response wrapper
	if decoded.response and decoded.response.decision then
		return decoded.response
	elseif decoded.decision then
		return decoded
	else
		return { success = true, data = decoded }
	end
end

--[[
	Report outcome (purchase, dismissed, natural_purchase)
	Queued for batch sending

	Expected data format from init.lua:
	{
		playerId = number,
		result = "purchased" | "dismissed" | "natural_purchase",
		productId = string,
		promptId = string,
		decisionId = string,
		patternId = string,
		source = "llm" | "cache",
		price = number,
		timeToDecisionSec = number,
		group = "test" | "control",
		stateAtOffer = { ... },
		sessionAtOffer = { ... },
		segmentAtOffer = { ... },
		playerProfile = { ... },
	}
]]
function APIClient:reportOutcome(data)
	local queueItem = {
		timestamp = getISOTimestamp(),
		data = {
			playerId = hashPlayerId(data.playerId),
			result = data.result,
			productId = tostring(data.productId),
			promptId = data.promptId,
			decisionId = data.decisionId,
			patternId = data.patternId,
			source = data.source,
			price = data.price or 0,
			timeToDecisionSec = data.timeToDecisionSec or 0,
			group = data.group or "test",
			stateAtOffer = data.stateAtOffer or {},
			sessionAtOffer = data.sessionAtOffer or {},
			segmentAtOffer = data.segmentAtOffer or {},
			playerProfile = data.playerProfile or {},
		},
	}

	table.insert(self.outcomeQueue, queueItem)

	-- Flush immediately if queue is full
	if #self.outcomeQueue >= BATCH_MAX_SIZE then
		local batch = self.outcomeQueue
		self.outcomeQueue = {}
		self:_sendOutcomeBatch(batch)
	end

	if self.debug then
		print("[PLAY3 API] Outcome queued, queue size:", #self.outcomeQueue)
	end
end

--[[
	Report decision (when LLM or cache makes a decision)
	Logs full context at decision time for ML training
]]
function APIClient:reportDecision(data)
	local url = self.baseUrl .. ENDPOINTS.ROBLOX_EVENTS

	local body = HttpService:JSONEncode({
		eventType = "decision",
		gameId = self.gameId,
		timestamp = getISOTimestamp(),
		data = {
			playerId = hashPlayerId(data.playerId),
			decisionId = data.decisionId,
			patternId = data.patternId,
			source = data.source,
			decision = {
				show = data.decision.show,
				promptId = data.decision.promptId,
				tier = data.decision.tier,
				confidence = data.decision.confidence,
			},
			context = {
				gameState = data.gameState or {},
				sessionContext = data.sessionContext or {},
				segment = data.segment or {},
				playerProfile = data.playerProfile or {},
			},
		},
	})

	task.spawn(function()
		pcall(function()
			HttpService:RequestAsync({
				Url = url,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-api-key"] = self.apiKey or "",
				},
				Body = body,
			})
		end)
	end)

	if self.debug then
		print("[PLAY3 API] Decision logged:", data.decision.promptId, "source:", data.source)
	end
end

--[[
	Report session end
	Queued for batch sending

	Expected data format from init.lua:
	{
		playerId = number,
		sessionId = string,
		sessionNumber = number,
		isFirstSession = boolean,
		daysSinceLastSession = number,
		group = "test" | "control",
		duration = { totalSec, activePlaySec },
		offers = { shown, dismissed, purchased },
		spend = { totalRobux, productsPurchased },
		finalState = { ... },
		segment = { ... },
	}
]]
function APIClient:reportSessionEnd(data)
	-- Format to match new API schema: {timestamp, data}
	local queueItem = {
		timestamp = getISOTimestamp(),
		data = {
			playerId = hashPlayerId(data.playerId),
			sessionId = data.sessionId or HttpService:GenerateGUID(false),
			sessionNumber = data.sessionNumber or 1,
			isFirstSession = data.isFirstSession or false,
			daysSinceLastSession = data.daysSinceLastSession,
			group = data.group or "test",
			duration = data.duration or {
				totalSec = data.sessionDurationSec or 0,
				activePlaySec = data.sessionDurationSec or 0,
			},
			offers = data.offers or {
				shown = data.offersShown or 0,
				dismissed = data.offersDismissed or 0,
				purchased = data.purchasesMade or 0,
			},
			spend = data.spend or {
				totalRobux = data.totalRobuxSpent or 0,
				productsPurchased = data.productsPurchased or {},
			},
			finalState = data.finalState or {},
			segment = data.segment or {},
		},
	}

	table.insert(self.sessionEndQueue, queueItem)

	-- Flush immediately if queue is full
	if #self.sessionEndQueue >= BATCH_MAX_SIZE then
		local batch = self.sessionEndQueue
		self.sessionEndQueue = {}
		self:_sendSessionEndBatch(batch)
	end

	if self.debug then
		print("[PLAY3 API] Session end queued, queue size:", #self.sessionEndQueue)
	end
end

--[[
	Report pattern stats from DecisionCache
	Sent periodically to track cache effectiveness
]]
function APIClient:reportPatternStats(patterns)
	if #patterns == 0 then
		if self.debug then
			print("[PLAY3 API] No patterns to report")
		end
		return
	end

	local url = self.baseUrl .. ENDPOINTS.ROBLOX_EVENTS_BATCH

	-- Wrap each pattern in {timestamp, data} format for batch endpoint
	local events = {}
	local now = getISOTimestamp()
	for _, pattern in ipairs(patterns) do
		table.insert(events, {
			timestamp = now,
			data = pattern,
		})
	end

	local body = HttpService:JSONEncode({
		eventType = "pattern_stats",
		gameId = self.gameId,
		events = events,
	})

	print("[PLAY3] ========== SENDING PATTERN STATS ==========")
	print("[PLAY3] Patterns:", #patterns)
	for i, p in ipairs(patterns) do
		if i <= 5 then -- Show first 5
			print(string.format("  %s: %d attempts, %d conversions (%.1f%%)",
				p.decision and p.decision.promptId or "unknown",
				p.attempts,
				p.conversions,
				p.conversionRate * 100))
		end
	end
	if #patterns > 5 then
		print("  ... and", #patterns - 5, "more patterns")
	end
	print("[PLAY3] ================================================")

	task.spawn(function()
		local success, response = pcall(function()
			return HttpService:RequestAsync({
				Url = url,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-api-key"] = self.apiKey or "",
				},
				Body = body,
			})
		end)

		if success and (response.StatusCode == 200 or response.StatusCode == 201) then
			print("[PLAY3] Pattern stats sent successfully!")
		else
			warn("[PLAY3] Pattern stats failed:", response and response.StatusCode or "error")
		end
	end)
end
--[[
	Force flush all queues (call on game shutdown if needed)
]]
function APIClient:flush()
	self:_flushQueues()
end

return APIClient