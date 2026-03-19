--[[
	PLAY3 SDK - Session Collector
	Tracks session-level data (time, offers, purchases)
]]

local HttpService = game:GetService("HttpService")

local SessionCollector = {}
SessionCollector.__index = SessionCollector

local playerSessions = {}

function SessionCollector.new(config)
	local self = setmetatable({}, SessionCollector)
	self.config = config
	return self
end

function SessionCollector:init()
	-- Sessions are started on player join
end

function SessionCollector:startSession(player, storedData)
	local sessionId = HttpService:GenerateGUID(false)

	local lastSession = storedData and storedData.lastSessionTime or 0
	local daysSince = 0
	if lastSession > 0 then
		daysSince = math.floor((os.time() - lastSession) / 86400)
	end

	playerSessions[player.UserId] = {
		sessionId = sessionId,
		sessionNumber = storedData and (storedData.totalSessions or 0) + 1 or 1,
		startTime = tick(),
		isFirstSession = not storedData or storedData.totalSessions == 0,
		daysSinceLastSession = daysSince,
		offersShown = 0,
		offersDismissed = 0,
		purchasesMade = 0,
		sessionSpendRobux = 0, -- Track total spend this session
		-- NEW: Track last offer timing and result
		lastOfferTime = nil,
		lastOfferResult = "none",
		lastOfferPromptId = nil,
	}
end

function SessionCollector:recordOfferShown(player, promptId)
	local session = playerSessions[player.UserId]
	if session then
		session.offersShown += 1
		session.lastOfferTime = tick()
		session.lastOfferResult = "pending" -- Will be updated when result comes in
		session.lastOfferPromptId = promptId
	end
end

function SessionCollector:recordOfferDismissed(player)
	local session = playerSessions[player.UserId]
	if session then
		session.offersDismissed += 1
		session.lastOfferResult = "dismissed"
	end
end

function SessionCollector:recordPurchase(player, priceRobux)
	local session = playerSessions[player.UserId]
	if session then
		session.purchasesMade += 1
		session.sessionSpendRobux += (priceRobux or 0)
		session.lastOfferResult = "purchased"
	end
end

-- NEW: Record when offer is ignored (shown but no response within timeout)
function SessionCollector:recordOfferIgnored(player)
	local session = playerSessions[player.UserId]
	if session then
		session.lastOfferResult = "ignored"
	end
end

function SessionCollector:collect(player)
	local session = playerSessions[player.UserId]

	if session then
		-- Calculate seconds since last offer
		local secondsSinceLastOffer = nil
		if session.lastOfferTime then
			secondsSinceLastOffer = math.floor(tick() - session.lastOfferTime)
		end

		-- Calculate dismiss rate this session
		local dismissRate = 0
		if session.offersShown > 0 then
			dismissRate = session.offersDismissed / session.offersShown
		end

		-- Calculate session duration
		local sessionDurationSec = math.floor(tick() - session.startTime)

		return {
			sessionId = session.sessionId,
			sessionNumber = session.sessionNumber,
			sessionDurationSec = sessionDurationSec,
			isFirstSession = session.isFirstSession,
			daysSinceLastSession = session.daysSinceLastSession,
			offersShown = session.offersShown,
			offersDismissed = session.offersDismissed,
			purchasesMade = session.purchasesMade,
			sessionSpendRobux = session.sessionSpendRobux or 0,
			-- Offer timing context for AI learning
			lastOfferResult = session.lastOfferResult,
			lastOfferPromptId = session.lastOfferPromptId,
			secondsSinceLastOffer = secondsSinceLastOffer,
			dismissRateThisSession = dismissRate,
		}
	else
		return {
			sessionId = "unknown",
			sessionNumber = 1,
			sessionDurationSec = 0,
			isFirstSession = true,
			daysSinceLastSession = 0,
			offersShown = 0,
			offersDismissed = 0,
			purchasesMade = 0,
			sessionSpendRobux = 0,
			lastOfferResult = "none",
			lastOfferPromptId = nil,
			secondsSinceLastOffer = nil,
			dismissRateThisSession = 0,
		}
	end
end

function SessionCollector:getSessionTime(player)
	local session = playerSessions[player.UserId]
	if session then
		return tick() - session.startTime
	end
	return 0
end

-- NEW: Get last offer info (for checking if offer is pending)
function SessionCollector:getLastOfferInfo(player)
	local session = playerSessions[player.UserId]
	if session and session.lastOfferTime then
		return {
			time = session.lastOfferTime,
			result = session.lastOfferResult,
			promptId = session.lastOfferPromptId,
			secondsAgo = math.floor(tick() - session.lastOfferTime),
		}
	end
	return nil
end

function SessionCollector:clearPlayer(player)
	playerSessions[player.UserId] = nil
end

return SessionCollector