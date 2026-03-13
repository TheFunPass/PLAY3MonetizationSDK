--[[
	PLAY3 SDK - Signal Builder
	Builds API request payload from player state
]]

local HashLib = require(script.Parent.Parent.Analytics.PLAY3_Analytics.HashLib)

local SignalBuilder = {}
SignalBuilder.__index = SignalBuilder

local function hashPlayerId(userId)
	return HashLib.sha256(tostring(userId))
end

function SignalBuilder.new(config, collectors)
	local self = setmetatable({}, SignalBuilder)
	self.config = config
	self.collectors = collectors
	self._cachedCatalog = nil -- Cache catalog on first build
	return self
end

function SignalBuilder:build(player)
	local c = self.collectors

	-- Collect from all collectors
	local state = c.state and c.state:collect(player) or {}
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

	-- Calculate spend tier from session spend
	local sessionSpend = session.sessionSpendRobux or 0
	local spendPropensity = "free"
	if sessionSpend >= 1000 then
		spendPropensity = "whale"
	elseif sessionSpend >= 100 then
		spendPropensity = "dolphin"
	elseif sessionSpend > 0 then
		spendPropensity = "minnow"
	end

	-- Calculate engagement level based on session duration
	local sessionDurationSec = session.sessionDurationSec or 0
	local churnRisk = "low"
	if sessionDurationSec < 60 then
		churnRisk = "high" -- Very short session
	elseif sessionDurationSec < 300 then
		churnRisk = "medium"
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
			lastOfferResult = session.lastOfferResult or "none",
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
			groupCount = profile.groupCount,
			friendsCount = profile.friendsCount,
			avatarTotalValue = profile.avatarTotalValue,
			avatarLimitedCount = profile.avatarLimitedCount,
		},

		-- Segment (SDK-calculated)
		segment = {
			spendPropensity = spendPropensity,
			churnRisk = churnRisk,
			priceSensitivity = sessionSpend == 0 and "high" or (sessionSpend < 100 and "medium" or "low"),
		},

		-- Device info
		device = {
			platform = device.platform or "desktop",
			isMobile = device.isMobile or false,
			isConsole = device.isConsole or false,
		},

		-- Catalog for AI to choose from (cached)
		catalog = self:getCatalog(),

		-- Game context (optional, from Config)
		gameContext = self.config.GAME_CONTEXT or nil,
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
			table.insert(entry.tiers, {
				tier = tier.tier,
				price = tier.price,
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
