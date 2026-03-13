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

-- Core modules
local Config = require(script.Parent.Config)
local APIClient = require(script.Parent.Core.APIClient)
local DecisionCache = require(script.Parent.Core.DecisionCache)
local SignalBuilder = require(script.Parent.Core.SignalBuilder)
local StateCollector = require(script.Parent.Collectors.StateCollector)
local SessionCollector = require(script.Parent.Collectors.SessionCollector)
local DeviceCollector = require(script.Parent.Collectors.DeviceCollector)
local ProfileCollector = require(script.Parent.Collectors.ProfileCollector)

--============================================================
-- PLAY3 SDK
--============================================================

local PLAY3 = {}
PLAY3.__index = PLAY3
PLAY3.VERSION = "4.2.0"

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

	debugEnabled = options.debugEnabled or Config.debugEnabled or false
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

	-- Hook ProcessReceipt BEFORE game's handler
	self:_hookProcessReceipt()

	-- Core components
	self.apiClient = APIClient.new(Config)
	self.decisionCache = DecisionCache.new(Config)
	self.signalBuilder = SignalBuilder.new(Config, collectors)

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
-- CACHE-FIRST EVALUATION
--============================================================

function PLAY3:_evaluateState(player)
	local state = collectors.state:collect(player)
	local playerId = player.UserId

	local shouldCall, reason = self.decisionCache:shouldCallAI(state, playerId)

	if shouldCall then
		self.decisionCache:recordCheck(playerId)
		local payload = self.signalBuilder:build(player)

		if debugEnabled then
			print("[PLAY3] Calling AI - reason:", reason)
		end

		local success, result = pcall(function()
			return self.apiClient:request(payload)
		end)

		if success and result then
			-- Handle both response formats: {decision:{...}} or {success:true, data:{decision:{...}}}
			local decision = result.decision or (result.data and result.data.decision) or result.data or result

			if decision and type(decision) == 'table' then
				self.decisionCache:store(state, decision)

				if decision.show then
					self.decisionCache:recordAttempt(state)
					self:_showOffer(player, decision, state, payload)

					if debugEnabled then
						print('[PLAY3] AI decision: show', decision.promptId, 'tier', decision.tier)
					end
				elseif debugEnabled then
					print('[PLAY3] AI decision: suppress -', decision.suppressReason or 'no reason')
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
		local decision, shouldShow, cacheReason = self.decisionCache:getDecision(state)

		if shouldShow and decision then
			if debugEnabled then
				print("[PLAY3] Using cache - reason:", cacheReason)
			end
			self.decisionCache:recordAttempt(state)
			self:_showOffer(player, decision, state, nil)
		elseif debugEnabled then
			print("[PLAY3] Suppressed - reason:", reason or cacheReason)
		end
	end
end

--============================================================
-- SHOW OFFER
--============================================================

function PLAY3:_showOffer(player, decision, state, payload)
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

	pendingOffers[player.UserId] = {
		promptId = promptId,
		productId = tierData.productId,
		price = tierData.price,
		tier = tier,
		offerTimestamp = os.time(),
		stateAtOffer = state,
		sessionAtOffer = sessionAtOffer,
		segmentAtOffer = segmentAtOffer,
	}

	collectors.session:recordOfferShown(player, promptId)

	if self.showOfferRemote then
		self.showOfferRemote:FireClient(player, {
			promptId = promptId,
			productId = tierData.productId,
			price = tierData.price,
			tier = tier,
			name = product.name,
			description = product.description,
		})
	end

	PLAY3.OnShowOffer:Fire(player, {
		promptId = promptId,
		productId = tierData.productId,
		price = tierData.price,
		tier = tier,
		product = product,
	})
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
			price = offerData.price,
			timeToDecisionSec = timeToDecision,
			group = playerGroup,
			stateAtOffer = offerData.stateAtOffer,
			sessionAtOffer = offerData.sessionAtOffer,
			segmentAtOffer = offerData.segmentAtOffer,
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
			collectors.session:recordOfferDismissed(player)
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
			})

			collectors.session:recordPurchase(player, 0) -- Natural purchase, price unknown
		end
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

	offerResultRemote.OnServerEvent:Connect(function(player, promptId, result)
		-- Client sends "dismissed" when player closes offer without buying
		-- "purchased" is tracked via PromptProductPurchaseFinished, not here
		if result == "dismissed" then
			self:RecordResult(player, promptId, RESULT_DISMISSED)
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
