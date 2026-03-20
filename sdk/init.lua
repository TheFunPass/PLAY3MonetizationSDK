--[[
	PLAY3 SDK v4.2 - AI-Powered Monetization

	Usage:
		local PLAY3 = require(game.ServerScriptService.PLAY3SDK).Start("your-api-key")

		-- Set player state (AI learns from patterns)
		PLAY3:SetState(player, "coins", 50)
		PLAY3:SetState(player, "level", 5)
		PLAY3:SetState(player, "deaths", 3)

	Tiered Pricing:
		Products with aliasOf will automatically route to the original product.
		Create tier dev products at different prices, SDK handles the rest.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

-- Core modules
local Config = require(script.Parent.Config)
local APIClient = require(script.Parent.Core.APIClient)
local DecisionCache = require(script.Parent.Core.DecisionCache)
local SignalBuilder = require(script.Parent.Core.SignalBuilder)
local MarketplaceWrapper = require(script.Parent.Core.MarketplaceWrapper)
local StateCollector = require(script.Parent.Collectors.StateCollector)
local SessionCollector = require(script.Parent.Collectors.SessionCollector)
local DeviceCollector = require(script.Parent.Collectors.DeviceCollector)
local ProfileCollector = require(script.Parent.Collectors.ProfileCollector)

--============================================================
-- PLAY3 SDK
--============================================================

local PLAY3 = {}
PLAY3.__index = PLAY3
PLAY3.VERSION = "5.4.0"

-- Simple Signal implementation
local function createSignal()
	local connections = {}
	return {
		Connect = function(_, fn)
			table.insert(connections, fn)
			return { Disconnect = function() end }
		end,
		Fire = function(_, ...)
			for _, fn in ipairs(connections) do
				task.spawn(fn, ...)
			end
		end,
	}
end

-- Public signals
PLAY3.OnShowOffer = createSignal()
PLAY3.OnOfferResult = createSignal()
PLAY3.OnOfferQueued = createSignal()  -- Fires when offer is queued (player not ready)

-- Internal state
local initialized = false
local debugEnabled = false
local collectors = {}
local pendingOffers = {}
local playerGroups = {}
local pendingEvaluations = {}
local playerPurchases = {}

-- Product alias mapping: tierProductId -> aliasOf (original product)
local productAliasMap = {}

-- Offer history per player (for AI context)
local playerOfferHistory = {}

-- Offer gating: queue offers until player is "ready" (e.g., respawning, idle)
local playerOfferReady = {}      -- playerId → boolean (nil/true = ready, false = not ready)
local playerQueuedOffer = {}     -- playerId → {decision, state, payload, queuedAt}
local QUEUED_OFFER_EXPIRY = 60   -- Discard queued offers older than 60 seconds

-- Product price cache: productId -> price (fetched from MarketplaceService)
local productPriceCache = {}

-- Configuration constants
local EVAL_DEBOUNCE_TIME = 0.5
local PENDING_OFFER_TIMEOUT = 300

-- Result type constants
local RESULT_PURCHASED = "purchased"
local RESULT_DISMISSED = "dismissed"
local RESULT_NATURAL = "natural_purchase"

-- A/B group constants
local GROUP_TEST = "test"
local GROUP_CONTROL = "control"

--============================================================
-- START
--============================================================

function PLAY3.Start(apiKey, options)
	if initialized then
		warn("[PLAY3] Already initialized")
		return PLAY3
	end

	options = options or {}

	if apiKey then
		Config.API_KEY = apiKey
	end

	debugEnabled = options.debugEnabled or Config.debug or false
	PLAY3.testGroupPercent = options.testGroupPercent or Config.testGroupPercent or 100

	PLAY3:_init()
	return PLAY3
end

--============================================================
-- INITIALIZATION
--============================================================

function PLAY3:_init()
	if debugEnabled then
		print("[PLAY3] Initializing SDK v" .. self.VERSION)
	end

	-- Build product alias map from catalog FIRST
	self:_buildProductAliasMap()

	-- Prefetch product prices from MarketplaceService
	self:_prefetchProductPrices()

	-- ProcessReceipt hook disabled - use PLAY3:ResolveProduct() in your handler instead
	-- self:_hookProcessReceipt()

	-- Core components
	self.apiClient = APIClient.new(Config)
	self.decisionCache = DecisionCache.new(Config)
	self.signalBuilder = SignalBuilder.new(Config, collectors, productPriceCache)

	-- MarketplaceService wrapper (drop-in replacement)
	-- Pass a function that can retrieve cached tier decisions
	self.marketplaceWrapper = MarketplaceWrapper.new(Config, function(player, promptId)
		-- Try to get cached decision for this player's current state
		local state = collectors.state and collectors.state:collect(player)
		if state then
			local decision = self.decisionCache:getDecision(state, player.UserId)
			if decision and decision.promptId == promptId then
				return decision
			end
		end
		return nil -- No cached decision, wrapper will use aliasOf (base tier)
	end)

	-- Export as PLAY3.MarketplaceService for drop-in replacement usage
	PLAY3.MarketplaceService = self.marketplaceWrapper

	-- Collectors
	collectors.state = StateCollector.new(Config)
	collectors.session = SessionCollector.new(Config)
	collectors.device = DeviceCollector.new(Config)
	collectors.profile = ProfileCollector.new(Config)

	collectors.device:init()
	collectors.session:init()

	self.collectors = collectors

	-- Setup
	self:_setupPurchaseTracking()
	self:_setupUIRemotes()

	-- Player handlers
	Players.PlayerAdded:Connect(function(player)
		self:_onPlayerJoin(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerLeave(player)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:_onPlayerJoin(player)
		end)
	end

initialized = true

	-- Start periodic pattern stats reporting (every 5 minutes)
	task.spawn(function()
		while true do
			task.wait(300) -- 5 minutes
			local patterns = self.decisionCache:getPatternStats()
			self.apiClient:reportPatternStats(patterns)
		end
	end)

	if debugEnabled then
		print("[PLAY3] SDK ready")
		print("[PLAY3] Product aliases registered:", self:_countAliases())
	end
end

--============================================================
-- PRODUCT ALIAS SYSTEM
--============================================================

--[[
	Build lookup table: tierProductId -> originalProductId
	From catalog entries with aliasOf field
]]
function PLAY3:_buildProductAliasMap()
	local catalog = Config.CATALOG or {}

	for _, product in ipairs(catalog) do
		if product.aliasOf and product.tiers then
			for _, tierData in pairs(product.tiers) do
				if tierData.productId then
					productAliasMap[tierData.productId] = product.aliasOf

					if debugEnabled then
						print(string.format("[PLAY3] Alias: %d -> %d (%s)",
							tierData.productId, product.aliasOf, product.promptId or "unknown"))
					end
				end
			end
		end
	end
end

function PLAY3:_countAliases()
	local count = 0
	for _ in pairs(productAliasMap) do
		count += 1
	end
	return count
end

--============================================================
-- PRODUCT PRICE FETCHING
--============================================================

--[[
	Fetch product price from MarketplaceService and cache it
	Returns price in Robux, or nil if fetch fails
]]
function PLAY3:_fetchProductPrice(productId)
	if productPriceCache[productId] then
		return productPriceCache[productId]
	end

	local success, productInfo = pcall(function()
		return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
	end)

	if success and productInfo and productInfo.PriceInRobux then
		productPriceCache[productId] = productInfo.PriceInRobux
		if debugEnabled then
			print("[PLAY3] Fetched price for", productId, "=", productInfo.PriceInRobux)
		end
		return productInfo.PriceInRobux
	else
		if debugEnabled then
			warn("[PLAY3] Failed to fetch price for", productId)
		end
		return nil
	end
end

--[[
	Get product price (from cache or fetch)
	Falls back to config price if fetch fails
]]
function PLAY3:_getProductPrice(productId, fallbackPrice)
	local cachedPrice = productPriceCache[productId]
	if cachedPrice then
		return cachedPrice
	end

	local fetchedPrice = self:_fetchProductPrice(productId)
	return fetchedPrice or fallbackPrice or 0
end

--[[
	Prefetch all product prices from catalog on init
]]
function PLAY3:_prefetchProductPrices()
	local catalog = Config.CATALOG or {}

	task.spawn(function()
		for _, product in ipairs(catalog) do
			if product.tiers then
				for _, tierData in pairs(product.tiers) do
					if tierData.productId then
						self:_fetchProductPrice(tierData.productId)
						task.wait(0.1) -- Small delay to avoid throttling
					end
				end
			end
		end

		-- Refresh SignalBuilder catalog with fetched prices
		if self.signalBuilder then
			self.signalBuilder:refreshCatalog()
		end

		if debugEnabled then
			local count = 0
			for _ in pairs(productPriceCache) do count += 1 end
			print("[PLAY3] Prefetched", count, "product prices")
		end
	end)
end

--[[
	Hook into ProcessReceipt to swap tier product IDs to their aliasOf product
	This runs BEFORE the game's handler sees the purchase
]]
function PLAY3:_hookProcessReceipt()
	-- Wait a frame to let the game set up their ProcessReceipt first
	task.defer(function()
		local originalHandler = MarketplaceService.ProcessReceipt

		MarketplaceService.ProcessReceipt = function(receiptInfo)
			-- Check if this product has an alias
			local aliasProductId = productAliasMap[receiptInfo.ProductId]

			if aliasProductId then
				if debugEnabled then
					print(string.format("[PLAY3] Alias redirect: %d -> %d",
						receiptInfo.ProductId, aliasProductId))
				end

				-- Swap to the aliased product ID
				receiptInfo.ProductId = aliasProductId
			end

			-- Call the game's original handler (or return NotProcessedYet if none)
			if originalHandler then
				return originalHandler(receiptInfo)
			else
				warn("[PLAY3] No original ProcessReceipt handler found")
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
		end

		if debugEnabled then
			print("[PLAY3] ProcessReceipt hook installed")
		end
	end)
end

--[[
	Resolve a product ID to its alias (if any)
	Can be called manually if needed
]]
function PLAY3:ResolveProduct(productId)
	return productAliasMap[productId] or productId
end

--============================================================
-- PLAYER LIFECYCLE
--============================================================

function PLAY3:_onPlayerJoin(player)
	collectors.session:startSession(player)
	collectors.state:initPlayer(player)
	collectors.profile:loadProfile(player)

	playerPurchases[player.UserId] = {}
	playerOfferHistory[player.UserId] = {}

	local groupRoll = player.UserId % 100
	if groupRoll < self.testGroupPercent then
		playerGroups[player.UserId] = GROUP_TEST
	else
		playerGroups[player.UserId] = GROUP_CONTROL
	end

	if debugEnabled then
		print("[PLAY3] Player joined:", player.Name, "group:", playerGroups[player.UserId])
	end
end

function PLAY3:_onPlayerLeave(player)
	local sessionData = collectors.session:collect(player)
	local stateData = collectors.state:collect(player)
	local purchases = playerPurchases[player.UserId] or {}

	local totalSpent = 0
	local productIds = {}
	for _, purchase in ipairs(purchases) do
		totalSpent = totalSpent + (purchase.price or 0)
		table.insert(productIds, purchase.productId)
	end

	self.apiClient:reportSessionEnd({
		playerId = player.UserId,
		sessionId = sessionData.sessionId,
		sessionNumber = sessionData.sessionNumber or 1,
		isFirstSession = sessionData.isFirstSession or false,
		daysSinceLastSession = sessionData.daysSinceLastSession,
		group = playerGroups[player.UserId] or GROUP_TEST,
		duration = {
			totalSec = sessionData.sessionDurationSec or 0,
			activePlaySec = sessionData.sessionDurationSec or 0,
		},
		offers = {
			shown = sessionData.offersShown or 0,
			dismissed = sessionData.offersDismissed or 0,
			purchased = sessionData.purchasesMade or 0,
		},
		spend = {
			totalRobux = totalSpent,
			productsPurchased = productIds,
		},
		finalState = stateData,
		segment = {
			spendTier = self:_getSpendTier(totalSpent),
			engagementLevel = self:_getEngagementLevel(sessionData.sessionDurationSec or 0),
		},
	})

	collectors.session:clearPlayer(player)
	collectors.state:clearPlayer(player)
	collectors.profile:clearPlayer(player)
	self.decisionCache:clearPlayer(player.UserId)
	pendingOffers[player.UserId] = nil
	playerGroups[player.UserId] = nil
	pendingEvaluations[player.UserId] = nil
	playerPurchases[player.UserId] = nil
	playerOfferHistory[player.UserId] = nil
	playerOfferReady[player.UserId] = nil
	playerQueuedOffer[player.UserId] = nil
end

function PLAY3:_getSpendTier(totalSpent)
	if totalSpent >= 1000 then return "whale"
	elseif totalSpent >= 100 then return "dolphin"
	elseif totalSpent > 0 then return "minnow"
	else return "free" end
end

function PLAY3:_getEngagementLevel(durationSec)
	if durationSec >= 1800 then return "high"
	elseif durationSec >= 600 then return "medium"
	else return "low" end
end

--============================================================
-- PUBLIC API: SetState
--============================================================

function PLAY3:SetState(player, key, value)
	if not initialized then return end

	collectors.state:setState(player, key, value)

	if debugEnabled then
		print("[PLAY3] SetState:", player.Name, key, "=", value)
	end

	local playerId = player.UserId

	if not pendingEvaluations[playerId] then
		pendingEvaluations[playerId] = true

		task.delay(EVAL_DEBOUNCE_TIME, function()
			pendingEvaluations[playerId] = nil
			if not player.Parent then return end
			self:_evaluateState(player)
		end)
	end
end

--============================================================
-- PUBLIC API: Offer Gating
--============================================================

--[[
	SetOfferReady: Tell SDK if player is ready to receive offers

	Usage:
		PLAY3:SetOfferReady(player, false)  -- Player is busy (mid-jump, combat)
		PLAY3:SetOfferReady(player, true)   -- Player is ready (respawning, idle)

	When set to true, any queued offer will be shown immediately.
	Default is true (backwards compatible).
]]
function PLAY3:SetOfferReady(player, ready)
	local playerId = player.UserId
	playerOfferReady[playerId] = ready

	if debugEnabled then
		print("[PLAY3] SetOfferReady:", player.Name, ready)
	end

	if ready and playerQueuedOffer[playerId] then
		local queued = playerQueuedOffer[playerId]
		local age = os.time() - queued.queuedAt

		if age <= QUEUED_OFFER_EXPIRY then
			playerQueuedOffer[playerId] = nil
			self:_showOffer(player, queued.decision, queued.state, queued.payload, queued.mlContext)

			if debugEnabled then
				print("[PLAY3] Showing queued offer (age:", age, "s)")
			end
		else
			playerQueuedOffer[playerId] = nil
			if debugEnabled then
				print("[PLAY3] Discarded expired queued offer (age:", age, "s)")
			end
		end
	end
end

--[[
	IsOfferReady: Check if player is currently ready for offers
	Returns true by default (nil is treated as ready)
]]
function PLAY3:IsOfferReady(player)
	return playerOfferReady[player.UserId] ~= false
end

--[[
	ClearQueuedOffer: Manually clear any queued offer for a player
	Use when context has changed and the queued offer is no longer relevant
]]
function PLAY3:ClearQueuedOffer(player)
	playerQueuedOffer[player.UserId] = nil
	if debugEnabled then
		print("[PLAY3] Cleared queued offer for:", player.Name)
	end
end

--[[
	HasQueuedOffer: Check if player has a pending queued offer
]]
function PLAY3:HasQueuedOffer(player)
	return playerQueuedOffer[player.UserId] ~= nil
end

--[[
	ShowQueuedOffer: Main API for developers to show queued offers at opportune moments

	Usage:
		PLAY3:ShowQueuedOffer(player)        -- Instant check: show if queued, else nothing
		PLAY3:ShowQueuedOffer(player, 3)     -- With 3 second window for in-flight AI responses

	Without windowDuration:
		- Shows queued offer immediately if one exists
		- Does nothing if no offer queued

	With windowDuration:
		- Shows queued offer immediately if one exists
		- Also keeps "ready=true" for X seconds to catch in-flight AI responses
		- Useful when state change (death) happens right before opportune moment (respawn)

	Returns: true if offer was shown or window opened, false if nothing to do
]]
function PLAY3:ShowQueuedOffer(player, windowDuration)
	local playerId = player.UserId
	local queued = playerQueuedOffer[playerId]

	if debugEnabled then
		print("[PLAY3] ShowQueuedOffer called:", player.Name, "windowDuration:", windowDuration or "nil")
	end

	-- If there's a queued offer, show it immediately
	if queued then
		local age = os.time() - queued.queuedAt

		if age <= QUEUED_OFFER_EXPIRY then
			local queueMetadata = {
				wasQueued = true,
				queueDurationSec = age,
				windowDurationSec = windowDuration,
				stateAtDecision = queued.state,
			}

			playerQueuedOffer[playerId] = nil
			self:_showOfferFromQueue(player, queued.decision, queued.state, queued.payload, queueMetadata, queued.mlContext)

			if debugEnabled then
				print("[PLAY3] Showed queued offer (queueDuration:", age, "s)")
			end
			return true
		else
			-- Expired
			playerQueuedOffer[playerId] = nil
			if debugEnabled then
				print("[PLAY3] Discarded expired queued offer (age:", age, "s)")
			end
		end
	end

	-- If windowDuration specified, open a window for in-flight AI responses
	if windowDuration and windowDuration > 0 then
		playerOfferReady[playerId] = true

		-- Store window duration for any offers that arrive during window
		-- We'll track this in _showOffer
		if not playerQueuedOffer[playerId] then
			playerQueuedOffer[playerId] = {
				windowOnly = true,  -- Flag: no offer yet, just window open
				windowDurationSec = windowDuration,
				windowOpenedAt = os.time(),
			}
		end

		if debugEnabled then
			print("[PLAY3] Window opened for", windowDuration, "seconds")
		end

		-- Auto-close window after duration
		task.delay(windowDuration, function()
			if player and player.Parent then
				-- Only close if still in window mode
				local current = playerQueuedOffer[playerId]
				if current and current.windowOnly then
					playerQueuedOffer[playerId] = nil
				end
				playerOfferReady[playerId] = false

				if debugEnabled then
					print("[PLAY3] Window closed for:", player.Name)
				end
			end
		end)

		return true
	end

	return false
end

--============================================================
-- CACHE-FIRST EVALUATION
--============================================================

function PLAY3:_evaluateState(player)
	-- Skip AI calls entirely for control group (saves API costs)
	local playerGroup = playerGroups[player.UserId] or GROUP_TEST
	if playerGroup == GROUP_CONTROL then
		if debugEnabled then
			print("[PLAY3] Control group - skipping evaluation")
		end
		return
	end

	-- Wait for profile to be ready before evaluating (max 10 sec)
	if not collectors.profile:isReady(player) then
		local ready = collectors.profile:waitForReady(player, 10)
		if not ready then
			return
		end
	end
	local state = collectors.state:collect(player)
	local playerId = player.UserId

	local shouldCall, reason = self.decisionCache:shouldCallAI(state, playerId)

	if shouldCall then
		self.decisionCache:recordCheck(playerId)
		local offerHistory = playerOfferHistory[playerId] or {}
		local payload = self.signalBuilder:build(player, offerHistory)

		if debugEnabled then
			print("[PLAY3] Calling AI - reason:", reason)
		end

		local success, result = pcall(function()
			return self.apiClient:request(payload)
		end)

		if success and result then
			if debugEnabled then
				print("[PLAY3] ========== AI RESPONSE ==========")
				print(HttpService:JSONEncode(result))
				print("[PLAY3] ====================================")
			end

			local decision = result.decision or (result.data and result.data.decision) or result.data or result

			if decision and type(decision) == 'table' then
				if decision.show then
					if self.decisionCache:isProductSuppressed(playerId, decision.promptId) then
						if debugEnabled then
							print('[PLAY3] AI decision: show, but player dismissed too many times -', decision.promptId)
						end
					else
						self.decisionCache:store(state, decision)
						self.decisionCache:recordAttempt(state)
						self.decisionCache:recordOfferShown(playerId, decision.promptId)

						local decisionId = HttpService:GenerateGUID(false)
						local patternId = self.decisionCache:generateFingerprint(state)
						local profileData = collectors.profile:collect(player)
						local sessionData = collectors.session:collect(player)

						self.apiClient:reportDecision({
							playerId = playerId,
							decisionId = decisionId,
							patternId = patternId,
							source = "llm",
							decision = decision,
							gameState = state,
							sessionContext = {
								sessionId = sessionData.sessionId,
								sessionNumber = sessionData.sessionNumber,
								sessionDurationSec = sessionData.sessionDurationSec,
								isFirstSession = sessionData.isFirstSession,
							},
							segment = payload.segment,
							playerProfile = profileData,
						})

						self:_showOffer(player, decision, state, payload, {
							decisionId = decisionId,
							patternId = patternId,
							source = "llm",
							playerProfile = profileData,
						})

						if debugEnabled then
							print('[PLAY3] AI decision: show', decision.promptId, 'tier', decision.tier)
						end
					end
				elseif debugEnabled then
					print('[PLAY3] AI decision: suppress -', decision.suppressReason or 'no reason', '(not cached)')
				end
			elseif debugEnabled then
				warn('[PLAY3] Invalid decision format:', tostring(decision))
			end
		elseif not success then
			warn('[PLAY3] AI call error:', result)
		elseif debugEnabled then
			warn('[PLAY3] AI call failed:', result and result.error or 'unknown')
		end
	else
		local decision, shouldShow, cacheReason = self.decisionCache:getDecision(state, playerId)

		if shouldShow and decision then
			if debugEnabled then
				print("[PLAY3] Using cache - reason:", cacheReason)
			end
			self.decisionCache:recordAttempt(state)
			self.decisionCache:recordOfferShown(playerId, decision.promptId)

			local decisionId = HttpService:GenerateGUID(false)
			local patternId = self.decisionCache:generateFingerprint(state)
			local profileData = collectors.profile:collect(player)
			local sessionData = collectors.session:collect(player)
			local offerHistory = playerOfferHistory[playerId] or {}
			local payload = self.signalBuilder:build(player, offerHistory)

			self.apiClient:reportDecision({
				playerId = playerId,
				decisionId = decisionId,
				patternId = patternId,
				source = "cache",
				decision = decision,
				gameState = state,
				sessionContext = {
					sessionId = sessionData.sessionId,
					sessionNumber = sessionData.sessionNumber,
					sessionDurationSec = sessionData.sessionDurationSec,
					isFirstSession = sessionData.isFirstSession,
				},
				segment = payload.segment,
				playerProfile = profileData,
			})

			self:_showOffer(player, decision, state, payload, {
				decisionId = decisionId,
				patternId = patternId,
				source = "cache",
				playerProfile = profileData,
			})
		elseif debugEnabled then
			print("[PLAY3] Suppressed - reason:", reason or cacheReason)
		end
	end
end

--============================================================
-- SHOW OFFER
--============================================================

--[[
	Internal: Show offer from queue with metadata tracking
]]
function PLAY3:_showOfferFromQueue(player, decision, state, payload, queueMetadata, mlContext)
	self:_showOfferInternal(player, decision, state, payload, queueMetadata, mlContext)
end

--[[
	Internal: Main offer display logic with optional queue metadata and ML context
]]
function PLAY3:_showOfferInternal(player, decision, state, payload, queueMetadata, mlContext)
	local playerGroup = playerGroups[player.UserId] or GROUP_TEST
	local playerId = player.UserId

	local existingOffer = pendingOffers[playerId]
	if existingOffer and existingOffer.offerTimestamp then
		local age = os.time() - existingOffer.offerTimestamp
		if age > PENDING_OFFER_TIMEOUT then
			pendingOffers[playerId] = nil
			existingOffer = nil
		end
	end

	if existingOffer then
		if debugEnabled then
			print("[PLAY3] Offer already pending for:", player.Name)
		end
		return
	end

	if playerGroup == GROUP_CONTROL then
		if debugEnabled then
			print("[PLAY3] Control group - suppressing")
		end
		return
	end

	local promptId = decision.promptId
	local tier = decision.tier or 1
	local product = self:_findProduct(promptId)

	if not product then
		warn("[PLAY3] Product not found in catalog:", promptId)
		return
	end

	local tierData = product.tiers and product.tiers[tier]
	if not tierData then
		tierData = product.tiers and product.tiers[1]
		tier = 1
	end

	if not tierData then
		warn("[PLAY3] No tier data for product:", promptId)
		return
	end

	-- Get actual price from MarketplaceService (falls back to config price)
	local actualPrice = self:_getProductPrice(tierData.productId, tierData.price)

	local sessionData = collectors.session:collect(player)

	local sessionAtOffer = {
		sessionId = sessionData.sessionId,
		sessionNumber = sessionData.sessionNumber or 1,
		sessionDurationSec = sessionData.sessionDurationSec or 0,
		isFirstSession = sessionData.isFirstSession or false,
		daysSinceLastSession = sessionData.daysSinceLastSession,
		offersShown = sessionData.offersShown or 0,
		offersDismissed = sessionData.offersDismissed or 0,
		purchasesMade = sessionData.purchasesMade or 0,
		failures = sessionData.failures or 0,
		successes = sessionData.successes or 0,
	}

	local purchases = playerPurchases[playerId] or {}
	local totalSpent = 0
	for _, p in ipairs(purchases) do
		totalSpent = totalSpent + (p.price or 0)
	end

	local segmentAtOffer = {
		spendTier = self:_getSpendTier(totalSpent),
		engagementLevel = self:_getEngagementLevel(sessionData.sessionDurationSec or 0),
	}

	local currentState = collectors.state:collect(player)
	mlContext = mlContext or {}

	pendingOffers[player.UserId] = {
		promptId = promptId,
		productId = tierData.productId,
		price = actualPrice,
		tier = tier,
		offerTimestamp = os.time(),
		stateAtOffer = state,
		stateAtShow = currentState,
		sessionAtOffer = sessionAtOffer,
		segmentAtOffer = segmentAtOffer,
		wasQueued = queueMetadata and queueMetadata.wasQueued or false,
		queueDurationSec = queueMetadata and queueMetadata.queueDurationSec or 0,
		windowDurationSec = queueMetadata and queueMetadata.windowDurationSec or nil,
		decisionId = mlContext.decisionId,
		patternId = mlContext.patternId,
		source = mlContext.source,
		playerProfile = mlContext.playerProfile,
	}

	collectors.session:recordOfferShown(player, promptId)

	if self.showOfferRemote then
		self.showOfferRemote:FireClient(player, {
			promptId = promptId,
			productId = tierData.productId,
			price = actualPrice,
			tier = tier,
			name = product.name,
			description = product.description,
		})
	end

	PLAY3.OnShowOffer:Fire(player, {
		promptId = promptId,
		productId = tierData.productId,
		price = actualPrice,
		tier = tier,
		product = product,
	})
end

--[[
	Public-facing _showOffer that handles queueing logic
	Called by _evaluateState when AI decides to show an offer
	mlContext contains: decisionId, patternId, source, playerProfile
]]
function PLAY3:_showOffer(player, decision, state, payload, mlContext)
	local playerId = player.UserId

	if not self:IsOfferReady(player) then
		local existing = playerQueuedOffer[playerId]
		if not existing or existing.windowOnly then
			playerQueuedOffer[playerId] = {
				decision = decision,
				state = state,
				payload = payload,
				mlContext = mlContext,
				queuedAt = os.time(),
			}

			PLAY3.OnOfferQueued:Fire(player, {
				promptId = decision.promptId,
				tier = decision.tier or 1,
			})

			if debugEnabled then
				print("[PLAY3] Offer queued - player not ready:", player.Name, decision.promptId)
			end
		elseif debugEnabled then
			print("[PLAY3] Offer dropped - already have queued offer:", player.Name)
		end
		return
	end

	local windowInfo = playerQueuedOffer[playerId]
	local queueMetadata = nil

	if windowInfo and windowInfo.windowOnly then
		queueMetadata = {
			wasQueued = false,
			queueDurationSec = 0,
			windowDurationSec = windowInfo.windowDurationSec,
		}
		playerQueuedOffer[playerId] = nil

		if debugEnabled then
			print("[PLAY3] Offer arrived during window:", player.Name, decision.promptId)
		end
	end

	self:_showOfferInternal(player, decision, state, payload, queueMetadata, mlContext)
end

function PLAY3:_findProduct(promptId)
	local catalog = Config.CATALOG or {}
	for _, product in ipairs(catalog) do
		if product.promptId == promptId then
			return product
		end
	end
	return nil
end

--============================================================
-- RECORD RESULT
--============================================================

function PLAY3:RecordResult(player, promptId, result)
	if not initialized then return end

	local offerData = pendingOffers[player.UserId]
	local playerGroup = playerGroups[player.UserId] or GROUP_TEST

	if debugEnabled then
		print("[PLAY3] Result:", player.Name, promptId, result)
	end

	if offerData then
		local timeToDecision = os.time() - (offerData.offerTimestamp or os.time())

		-- Record to offer history for AI context
		local history = playerOfferHistory[player.UserId] or {}
		table.insert(history, {
			promptId = offerData.promptId,
			tier = offerData.tier,
			price = offerData.price,
			result = result,
			timestamp = offerData.offerTimestamp,
		})
		playerOfferHistory[player.UserId] = history

		if result == RESULT_PURCHASED then
			local purchases = playerPurchases[player.UserId] or {}
			table.insert(purchases, {
				productId = offerData.productId,
				price = offerData.price,
			})
			playerPurchases[player.UserId] = purchases
		end

		self.apiClient:reportOutcome({
			playerId = player.UserId,
			result = result,
			productId = offerData.productId,
			promptId = offerData.promptId,
			decisionId = offerData.decisionId,
			patternId = offerData.patternId,
			source = offerData.source,
			price = offerData.price,
			timeToDecisionSec = timeToDecision,
			group = playerGroup,
			stateAtOffer = offerData.stateAtOffer,
			stateAtShow = offerData.stateAtShow,
			sessionAtOffer = offerData.sessionAtOffer,
			segmentAtOffer = offerData.segmentAtOffer,
			playerProfile = offerData.playerProfile,
			wasQueued = offerData.wasQueued or false,
			queueDurationSec = offerData.queueDurationSec or 0,
			windowDurationSec = offerData.windowDurationSec,
		})

		if result == RESULT_PURCHASED then
			self.decisionCache:recordConversion(offerData.stateAtOffer)
			collectors.session:recordPurchase(player, offerData.price)

			if debugEnabled then
				local stats = self.decisionCache:getStats()
				print("[PLAY3] Conversion! Cache:", stats.entries, "entries,",
					string.format("%.1f%%", stats.overallRate * 100), "rate")
			end
		else
			-- Record dismissal for per-player fatigue tracking (use promptId since that's what cache stores)
			self.decisionCache:recordDismissal(player.UserId, offerData.promptId)
			collectors.session:recordOfferDismissed(player)

			if debugEnabled then
				print("[PLAY3] Offer dismissed - product cooldown started:", offerData.promptId)
			end
		end

		pendingOffers[player.UserId] = nil
	end

	PLAY3.OnOfferResult:Fire(player, promptId, result)
end

--============================================================
-- PURCHASE TRACKING
--============================================================

function PLAY3:_setupPurchaseTracking()
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
		local player = Players:GetPlayerByUserId(userId)
		if not player then return end

		local offer = pendingOffers[userId]

		-- Check both the tier product AND the aliased product
		local resolvedProductId = self:ResolveProduct(productId)
		local offerProductId = offer and self:ResolveProduct(offer.productId)

		if offer and (offer.productId == productId or offerProductId == resolvedProductId) then
			if isPurchased then
				self:RecordResult(player, offer.promptId, RESULT_PURCHASED)
			else
				self:RecordResult(player, offer.promptId, RESULT_DISMISSED)
			end
		elseif isPurchased then
			if debugEnabled then
				print("[PLAY3] Natural purchase:", player.Name, productId)
			end

			local sessionData = collectors.session:collect(player)
			local stateData = collectors.state:collect(player)

			local purchases = playerPurchases[userId] or {}
			table.insert(purchases, { productId = productId, price = 0 })
			playerPurchases[userId] = purchases

			local totalSpent = 0
			for _, p in ipairs(purchases) do
				totalSpent = totalSpent + (p.price or 0)
			end

			local sessionAtOffer = {
				sessionId = sessionData.sessionId,
				sessionNumber = sessionData.sessionNumber or 1,
				sessionDurationSec = sessionData.sessionDurationSec or 0,
				isFirstSession = sessionData.isFirstSession or false,
				daysSinceLastSession = sessionData.daysSinceLastSession,
				offersShown = sessionData.offersShown or 0,
				offersDismissed = sessionData.offersDismissed or 0,
				purchasesMade = sessionData.purchasesMade or 0,
				failures = sessionData.failures or 0,
				successes = sessionData.successes or 0,
			}

			local profileData = collectors.profile:collect(player)

			self.apiClient:reportOutcome({
				playerId = userId,
				result = RESULT_NATURAL,
				productId = productId,
				price = 0,
				timeToDecisionSec = 0,
				group = playerGroups[userId] or GROUP_TEST,
				stateAtOffer = stateData,
				sessionAtOffer = sessionAtOffer,
				segmentAtOffer = {
					spendTier = self:_getSpendTier(totalSpent),
					engagementLevel = self:_getEngagementLevel(sessionData.sessionDurationSec or 0),
				},
				playerProfile = profileData,
			})

			collectors.session:recordPurchase(player, 0) -- Natural purchase, price unknown
		end
	end)

	-- Gamepass purchase tracking
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if not wasPurchased then return end
		if not player then return end

		local userId = player.UserId

		if debugEnabled then
			print("[PLAY3] Natural gamepass purchase:", player.Name, gamePassId)
		end

		-- Fetch gamepass price
		local price = 0
		pcall(function()
			local info = MarketplaceService:GetProductInfo(gamePassId, Enum.InfoType.GamePass)
			price = info.PriceInRobux or 0
		end)

		local sessionData = collectors.session:collect(player)
		local stateData = collectors.state:collect(player)
		local profileData = collectors.profile:collect(player)

		local purchases = playerPurchases[userId] or {}
		table.insert(purchases, { productId = gamePassId, price = price, productType = "gamepass" })
		playerPurchases[userId] = purchases

		local totalSpent = 0
		for _, p in ipairs(purchases) do
			totalSpent = totalSpent + (p.price or 0)
		end

		self.apiClient:reportOutcome({
			playerId = userId,
			result = "natural_gamepass",
			productId = gamePassId,
			productType = "gamepass",
			price = price,
			timeToDecisionSec = 0,
			group = playerGroups[userId] or GROUP_TEST,
			stateAtOffer = stateData,
			sessionAtOffer = {
				sessionId = sessionData.sessionId,
				sessionNumber = sessionData.sessionNumber or 1,
				sessionDurationSec = sessionData.sessionDurationSec or 0,
				isFirstSession = sessionData.isFirstSession or false,
				daysSinceLastSession = sessionData.daysSinceLastSession,
				offersShown = sessionData.offersShown or 0,
				offersDismissed = sessionData.offersDismissed or 0,
				purchasesMade = sessionData.purchasesMade or 0,
			},
			segmentAtOffer = {
				spendTier = self:_getSpendTier(totalSpent),
				engagementLevel = self:_getEngagementLevel(sessionData.sessionDurationSec or 0),
			},
			playerProfile = profileData,
		})

		collectors.session:recordPurchase(player, price)
	end)
end

--============================================================
-- UI REMOTES
--============================================================

function PLAY3:_setupUIRemotes()
	local remotesFolder = ReplicatedStorage:FindFirstChild("PLAY3Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "PLAY3Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local showOfferRemote = remotesFolder:FindFirstChild("ShowOffer")
	if not showOfferRemote then
		showOfferRemote = Instance.new("RemoteEvent")
		showOfferRemote.Name = "ShowOffer"
		showOfferRemote.Parent = remotesFolder
	end

	local offerResultRemote = remotesFolder:FindFirstChild("OfferResult")
	if not offerResultRemote then
		offerResultRemote = Instance.new("RemoteEvent")
		offerResultRemote.Name = "OfferResult"
		offerResultRemote.Parent = remotesFolder
	end

	-- AutoState remote for client-sent data (idle time, local timezone)
	local autoStateRemote = remotesFolder:FindFirstChild("AutoState")
	if not autoStateRemote then
		autoStateRemote = Instance.new("RemoteEvent")
		autoStateRemote.Name = "AutoState"
		autoStateRemote.Parent = remotesFolder
	end

	offerResultRemote.OnServerEvent:Connect(function(player, promptId, result)
		-- Client sends "dismissed" when player closes offer without buying
		-- "purchased" is tracked via PromptProductPurchaseFinished, not here
		if result == "dismissed" then
			self:RecordResult(player, promptId, RESULT_DISMISSED)
		end
	end)

	-- Handle auto-state updates from client
	autoStateRemote.OnServerEvent:Connect(function(player, data)
		if data and type(data) == "table" then
			collectors.state:updateClientData(player, data)
		end
	end)

	self.showOfferRemote = showOfferRemote
end

--============================================================
-- TESTING & DEBUG
--============================================================

--[[
	Force-show an offer for testing (only works with debug = true)
	Usage: PLAY3:TestOffer(player, "coin_pack", 1)
]]
function PLAY3:TestOffer(player, promptId, tier)
	if not debugEnabled then
		warn("[PLAY3] TestOffer only works with debug = true in Config")
		return false
	end

	local product = self:_findProduct(promptId)
	if not product then
		warn("[PLAY3] TestOffer: Product not found:", promptId)
		return false
	end

	tier = tier or 1
	local tierData = product.tiers and product.tiers[tier]
	if not tierData then
		warn("[PLAY3] TestOffer: Tier not found:", tier)
		return false
	end

	print("[PLAY3] TestOffer: Showing", promptId, "tier", tier, "to", player.Name)

	self:_showOffer(player, {
		promptId = promptId,
		tier = tier,
		show = true,
	}, {}, nil)

	return true
end

-- Reset PLAY3 learning data (useful during development)
function PLAY3:Reset()
	self.decisionCache:clear()
	if debugEnabled then
		print("[PLAY3] Reset complete - learning data cleared")
	end
end

-- Legacy aliases
PLAY3.GetCacheStats = function(self) return self.decisionCache:getStats() end
PLAY3.ClearCache = function(self) self:Reset() end

return PLAY3