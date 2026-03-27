--[[
	PLAY3 SDK - Signal Builder
	Builds API request payload from player state
]]

local HashLib = require(script.Parent.Parent.Analytics.HashLib.init)

local SignalBuilder = {}
SignalBuilder.__index = SignalBuilder

local function hashPlayerId(userId)
	return HashLib.sha256(tostring(userId))
end

function SignalBuilder.new(config, collectors, priceCache)
	local self = setmetatable({}, SignalBuilder)
	self.config = config
	self.collectors = collectors
	self.priceCache = priceCache or {} -- Reference to product price cache
	self._cachedCatalog = nil -- Cache catalog on first build
	return self
end

--[[
	Calculate spendPropensity using multiple signals
	Returns: "whale", "dolphin", "minnow", or "free"
]]
function SignalBuilder:calculateSpendPropensity(profile, session, device)
	local score = 0

	-- Premium subscriber (already pays for Roblox)
	if profile.isPremium then
		score = score + 3
	end

	-- Avatar value indicates spending history
	local avatarValue = profile.avatarTotalValue or 0
	if avatarValue >= 10000 then
		score = score + 3 -- Whale-tier avatar
	elseif avatarValue >= 2000 then
		score = score + 2
	elseif avatarValue >= 500 then
		score = score + 1
	end

	-- Owns limited items (collector behavior)
	local limitedCount = profile.avatarLimitedCount or 0
	if limitedCount >= 5 then
		score = score + 3
	elseif limitedCount > 0 then
		score = score + 2
	end

	-- Account maturity
	local accountAge = profile.accountAgeDays or 0
	if accountAge > 365 then
		score = score + 1
	end

	-- Returning player loyalty
	local sessionNumber = session.sessionNumber or 1
	if sessionNumber > 10 then
		score = score + 2
	elseif sessionNumber > 5 then
		score = score + 1
	end

	-- Social context (playing with friends = social spending pressure)
	if profile.isInParty then
		score = score + 1
	end

	-- High-end device suggests affluence
	local screenRes = device.screenResX or 0
	if screenRes >= 1920 then
		score = score + 1
	end

	-- VIP server owner (already paid for private server)
	if profile.isVIPServer then
		score = score + 2
	end

	-- Verified badge (creator/influencer, likely has Robux)
	if profile.hasVerifiedBadge then
		score = score + 2
	end

	-- Negative signals
	if profile.ageBracket == "Under13" then
		score = score - 1 -- Limited spending power
	end

	if device.isMobile and screenRes < 1280 then
		score = score - 1 -- Budget device
	end

	if session.isFirstSession then
		score = score - 2 -- New player, unknown behavior
	end

	-- Map score to category
	if score >= 7 then
		return "whale"
	elseif score >= 4 then
		return "dolphin"
	elseif score >= 1 then
		return "minnow"
	else
		return "free"
	end
end

--[[
	Calculate churnRisk using multiple signals
	Returns: "high", "medium", or "low"
]]
function SignalBuilder:calculateChurnRisk(profile, session, device)
	local sessionDurationSec = session.sessionDurationSec or 0
	local sessionNumber = session.sessionNumber or 1
	local isFirstSession = session.isFirstSession or false
	local daysSinceLastSession = session.daysSinceLastSession or 0
	local dismissRate = session.dismissRateThisSession or 0
	local purchasesMade = session.purchasesMade or 0

	-- High risk indicators
	local highRiskSignals = 0

	-- Very short session (about to leave)
	if sessionDurationSec < 60 then
		highRiskSignals = highRiskSignals + 2
	end

	-- New player bouncing quickly
	if isFirstSession and sessionDurationSec < 120 then
		highRiskSignals = highRiskSignals + 2
	end

	-- Returning after long absence (might leave again)
	if daysSinceLastSession > 14 then
		highRiskSignals = highRiskSignals + 1
	end

	-- Frustrated with offers
	if dismissRate > 0.5 then
		highRiskSignals = highRiskSignals + 1
	end

	-- Low risk indicators
	local lowRiskSignals = 0

	-- Engaged session
	if sessionDurationSec > 600 then
		lowRiskSignals = lowRiskSignals + 2
	elseif sessionDurationSec > 300 then
		lowRiskSignals = lowRiskSignals + 1
	end

	-- Playing with friends (social anchor)
	if profile.isInParty then
		lowRiskSignals = lowRiskSignals + 2
	end

	-- Loyal returning player
	if sessionNumber > 10 then
		lowRiskSignals = lowRiskSignals + 2
	elseif sessionNumber > 5 then
		lowRiskSignals = lowRiskSignals + 1
	end

	-- Already purchased this session (invested)
	if purchasesMade > 0 then
		lowRiskSignals = lowRiskSignals + 2
	end

	-- Premium subscriber (committed to platform)
	if profile.isPremium then
		lowRiskSignals = lowRiskSignals + 1
	end

	-- Calculate net risk
	local netRisk = highRiskSignals - lowRiskSignals

	if netRisk >= 2 then
		return "high"
	elseif netRisk >= 0 then
		return "medium"
	else
		return "low"
	end
end

--[[
	Calculate priceSensitivity using multiple signals
	Returns: "high" (show cheaper tiers), "medium", or "low" (can show premium)
]]
function SignalBuilder:calculatePriceSensitivity(profile, session, device)
	local score = 0 -- Higher score = more price sensitive

	-- Avatar value is strong indicator of spending comfort
	local avatarValue = profile.avatarTotalValue or 0
	if avatarValue < 200 then
		score = score + 3 -- Doesn't spend on cosmetics
	elseif avatarValue < 500 then
		score = score + 2
	elseif avatarValue < 2000 then
		score = score + 1
	elseif avatarValue >= 5000 then
		score = score - 2 -- Comfortable spending
	end

	-- Mobile + low resolution often indicates budget/younger
	local screenRes = device.screenResX or 0
	if device.isMobile and screenRes < 1280 then
		score = score + 2
	elseif device.isMobile then
		score = score + 1
	end

	-- Age bracket affects spending power
	if profile.ageBracket == "Under13" then
		score = score + 2 -- Limited funds, needs parent approval
	end

	-- High dismiss rate suggests price objections
	local dismissRate = session.dismissRateThisSession or 0
	if dismissRate > 0.5 then
		score = score + 2
	elseif dismissRate > 0.3 then
		score = score + 1
	end

	-- Non-premium without collectibles = budget player
	if not profile.isPremium and (profile.avatarLimitedCount or 0) == 0 then
		score = score + 1
	end

	-- Low sensitivity indicators (comfortable with higher prices)
	if profile.isPremium then
		score = score - 2
	end

	if (profile.avatarLimitedCount or 0) >= 3 then
		score = score - 2 -- Collector, comfortable with premium prices
	end

	if profile.hasVerifiedBadge then
		score = score - 2 -- Creator/influencer
	end

	if profile.isVIPServer then
		score = score - 1 -- Paid for private server
	end

	-- High-end display
	if screenRes >= 2560 then
		score = score - 1 -- 1440p+ likely affluent
	end

	-- Map score to category
	if score >= 3 then
		return "high" -- Show cheaper tiers
	elseif score >= 0 then
		return "medium"
	else
		return "low" -- Can show premium tiers
	end
end

function SignalBuilder:build(player, offerHistory)
	local c = self.collectors

	-- Collect from all collectors
	-- Note: Empty tables serialize as [] in JSON, so ensure gameState has a key
	local state = c.state and c.state:collect(player) or {}
	if next(state) == nil then
		state._empty = true -- Force object serialization
	end

	-- Offer history (purchases + dismissals this session)
	offerHistory = offerHistory or {}
	local session = c.session and c.session:collect(player) or {}
	local profile = c.profile and c.profile:collect(player) or {}
	local device = c.device and c.device:collect(player) or {}

	-- Map ageBracket to schema enum
	local ageGroup = "unknown"
	if profile.ageBracket == "Under13" then
		ageGroup = "under_13"
	elseif profile.ageBracket == "13+" then
		ageGroup = "13_plus"
	end

	-- Calculate smart segments using all available signals
	local spendPropensity = self:calculateSpendPropensity(profile, session, device)
	local churnRisk = self:calculateChurnRisk(profile, session, device)
	local priceSensitivity = self:calculatePriceSensitivity(profile, session, device)
	local sessionDurationSec = session.sessionDurationSec or 0

	-- Normalize lastOfferResult to valid enum values only
	local validOfferResults = { none = true, purchased = true, dismissed = true, ignored = true }
	local lastOfferResult = session.lastOfferResult or "none"
	if not validOfferResults[lastOfferResult] then
		lastOfferResult = "none" -- Fallback for invalid values like "pending"
	end

	-- Build payload
	local payload = {
		playerId = hashPlayerId(player.UserId),

		-- Game state from SetState
		gameState = state,

		-- Session info (includes offer timing for AI learning)
		sessionContext = {
			sessionId = session.sessionId,
			sessionNumber = session.sessionNumber,
			sessionDurationSec = sessionDurationSec,
			isFirstSession = session.isFirstSession,
			-- Offer counts
			offersShownThisSession = session.offersShown or 0,
			-- Offer timing context - lets AI learn when NOT to show
			lastOfferResult = lastOfferResult,
			lastOfferTimestamp = session.lastOfferTime and math.floor(session.lastOfferTime) or nil,
		},

		-- Player profile (schema-aligned)
		playerProfile = {
			accountAgeDays = profile.accountAgeDays or 0,
			ageGroup = ageGroup,
			dismissRate = session.dismissRateThisSession or 0,
			purchaseCount = session.purchasesMade or 0,
			totalSessions = session.sessionNumber or 1,
			-- Amendment PA-2026-001 fields
			country = profile.country,
			hasVerifiedBadge = profile.hasVerifiedBadge,
			pingMs = profile.pingMs,
			isVIPServer = profile.isVIPServer,
			policySignals = profile.policySignals,
			-- Additional profile data
			isPremium = profile.isPremium or false,
			locale = profile.locale or "en-us",
			groupCount = profile.groupCount or 0,
			highRankGroupCount = profile.highRankGroupCount or 0,
			friendsCount = profile.friendsCount or 0,
			-- Avatar wealth indicators
			avatarTotalValue = profile.avatarTotalValue or 0,
			avatarLimitedCount = profile.avatarLimitedCount or 0,
			avatarHighestItem = profile.avatarHighestItem or 0,
			avatarAccessoryCount = profile.avatarAccessoryCount or 0,
			-- Social context
			isInParty = profile.isInParty or false,
			partySize = profile.partySize or 0,
			-- Session retention
			daysSinceLastSession = session.daysSinceLastSession or 0,
			isFirstSession = session.isFirstSession or false,
		},

		-- Segment (SDK-calculated using multiple signals)
		segment = {
			spendPropensity = spendPropensity,
			churnRisk = churnRisk,
			priceSensitivity = priceSensitivity,
		},

		-- Device info (expanded)
		device = {
			platform = device.platform or "desktop",
			deviceSubType = device.deviceSubType or "unknown",
			inputType = device.inputType or "unknown",
			isMobile = device.isMobile or false,
			isConsole = device.isConsole or false,
			isVR = device.isVR or false,
			screenResX = device.screenResX or 0,
			screenResY = device.screenResY or 0,
		},

		-- Catalog for AI to choose from (cached)
		catalog = self:getCatalog(),

		-- Game context (optional, from Config)
		gameContext = self.config.GAME_CONTEXT or nil,

		-- Offer history this session (purchases + dismissals)
		offerHistory = #offerHistory > 0 and offerHistory or nil,
	}

	return payload
end

--[[
	Get catalog (cached after first build)
]]
function SignalBuilder:getCatalog()
	if not self._cachedCatalog then
		self._cachedCatalog = self:buildCatalog()
	end
	return self._cachedCatalog
end

--[[
	Build catalog from config (internal)
	Uses fetched prices from MarketplaceService when available
]]
function SignalBuilder:buildCatalog()
	local catalog = {}
	local configCatalog = self.config.CATALOG or {}

	for _, product in ipairs(configCatalog) do
		local entry = {
			promptId = product.promptId,
			name = product.name,
			category = product.category,
			description = product.description,
			tiers = {},
		}

		local tiers = product.tiers or {}
		for _, tier in ipairs(tiers) do
			-- Use fetched price from cache, fall back to config price
			local actualPrice = self.priceCache[tier.productId] or tier.price
			table.insert(entry.tiers, {
				tier = tier.tier,
				price = actualPrice,
				productId = tostring(tier.productId),
			})
		end

		table.insert(catalog, entry)
	end

	return catalog
end

--[[
	Force rebuild catalog (if config changes at runtime)
]]
function SignalBuilder:refreshCatalog()
	self._cachedCatalog = nil
end

return SignalBuilder