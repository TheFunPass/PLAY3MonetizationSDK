--[[
	PLAY3 MarketplaceService Wrapper

	Drop-in replacement for MarketplaceService that:
	- Lets developers use promptId names ("skip", "double_speed") instead of productIds
	- Automatically injects PromptId into receiptInfo for ProcessReceipt
	- Handles tier resolution internally

	USAGE:
	local MarketplaceService = require(game.ServerScriptService.PLAY3SDK).MarketplaceService

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		if receiptInfo.PromptId == "skip" then
			-- handle skip
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
]]

local RealMarketplaceService = game:GetService("MarketplaceService")

local MarketplaceWrapper = {}
MarketplaceWrapper.__index = MarketplaceWrapper

--============================================================
-- CONSTRUCTOR
--============================================================

function MarketplaceWrapper.new(config, getDecisionFunc)
	local self = setmetatable({}, MarketplaceWrapper)

	self._config = config
	self._getDecision = getDecisionFunc -- Function to get AI/cached tier decision
	self._developerProcessReceipt = nil -- Developer's callback
	self._isSetup = false

	-- Build lookup tables from catalog
	self._productIdToPromptId = {} -- productId (any tier) → promptId
	self._promptIdToProduct = {}   -- promptId → product config (with tiers)
	self._productIdToBaseId = {}   -- productId (any tier) → base productId (aliasOf)

	self:_buildLookupTables()

	return self
end

--============================================================
-- LOOKUP TABLE BUILDER
--============================================================

function MarketplaceWrapper:_buildLookupTables()
	local catalog = self._config.CATALOG
	if not catalog then return end

	for _, product in ipairs(catalog) do
		local promptId = product.promptId
		if not promptId then continue end

		-- Store full product config
		self._promptIdToProduct[promptId] = product

		-- Get base productId (aliasOf or first tier's productId)
		local baseProductId = product.aliasOf
		if not baseProductId and product.tiers and product.tiers[1] then
			-- If no aliasOf, use first tier as base
			baseProductId = product.tiers[1].productId
		end

		-- Map all tier productIds to this promptId
		if product.tiers then
			for _, tier in ipairs(product.tiers) do
				if tier.productId then
					self._productIdToPromptId[tier.productId] = promptId
					self._productIdToBaseId[tier.productId] = baseProductId
				end
			end
		end

		-- Also handle single productId (non-tiered products)
		if product.productId then
			self._productIdToPromptId[product.productId] = promptId
			self._productIdToBaseId[product.productId] = product.productId
		end
	end
end

--============================================================
-- RESOLVE HELPERS
--============================================================

-- Convert productId → promptId
function MarketplaceWrapper:GetPromptId(productId)
	return self._productIdToPromptId[productId]
end

-- Convert promptId → base productId (using aliasOf)
function MarketplaceWrapper:GetBaseProductId(promptId)
	local product = self._promptIdToProduct[promptId]
	if not product then return nil end
	return product.aliasOf or (product.tiers and product.tiers[1] and product.tiers[1].productId) or product.productId
end

-- Convert promptId → specific tier productId (based on AI decision)
function MarketplaceWrapper:GetTieredProductId(player, promptId)
	local product = self._promptIdToProduct[promptId]
	if not product then return nil end

	-- If no tiers, return single productId
	if not product.tiers then
		return product.productId
	end

	-- Try to get AI decision for tier
	local tier = nil
	if self._getDecision then
		local decision = self._getDecision(player, promptId)
		if decision and decision.tier then
			tier = decision.tier
		end
	end

	-- Default to base product (aliasOf) tier if no AI decision
	if not tier then
		local baseId = product.aliasOf
		if baseId then
			-- Find which tier has the base productId
			for _, t in ipairs(product.tiers) do
				if t.productId == baseId then
					return baseId
				end
			end
		end
		-- Fallback: use first tier
		return product.tiers[1] and product.tiers[1].productId
	end

	-- Find tier's productId
	for _, t in ipairs(product.tiers) do
		if t.tier == tier then
			return t.productId
		end
	end

	-- Tier not found, use base
	return product.aliasOf or product.tiers[1].productId
end

--============================================================
-- PROCESSRECEIPT INTERCEPTION
--============================================================

function MarketplaceWrapper:_setupProcessReceipt()
	if self._isSetup then return end
	self._isSetup = true

	local wrapper = self

	RealMarketplaceService.ProcessReceipt = function(receiptInfo)
		-- Inject PromptId into receiptInfo
		local promptId = wrapper:GetPromptId(receiptInfo.ProductId)
		if promptId then
			receiptInfo.PromptId = promptId
		end

		-- Inject BaseProductId (resolved from any tier)
		local baseId = wrapper._productIdToBaseId[receiptInfo.ProductId]
		if baseId then
			receiptInfo.BaseProductId = baseId
		end

		-- Call developer's callback
		if wrapper._developerProcessReceipt then
			return wrapper._developerProcessReceipt(receiptInfo)
		end

		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

--============================================================
-- MARKETPLACESERVICE API (WRAPPED)
--============================================================

-- PromptProductPurchase: Accept promptId (string) or productId (number)
function MarketplaceWrapper:PromptProductPurchase(player, promptIdOrProductId, ...)
	local productId

	if type(promptIdOrProductId) == "string" then
		-- It's a promptId, resolve to productId with tier
		productId = self:GetTieredProductId(player, promptIdOrProductId)
		if not productId then
			warn("[PLAY3] Unknown promptId:", promptIdOrProductId)
			return
		end
	else
		-- It's already a productId, pass through
		productId = promptIdOrProductId
	end

	return RealMarketplaceService:PromptProductPurchase(player, productId, ...)
end

-- GetProductInfo: Accept promptId (string) or productId (number)
function MarketplaceWrapper:GetProductInfo(promptIdOrProductId, infoType)
	local productId

	if type(promptIdOrProductId) == "string" then
		productId = self:GetBaseProductId(promptIdOrProductId)
		if not productId then
			warn("[PLAY3] Unknown promptId:", promptIdOrProductId)
			return nil
		end
	else
		productId = promptIdOrProductId
	end

	return RealMarketplaceService:GetProductInfo(productId, infoType or Enum.InfoType.Product)
end

--============================================================
-- PASSTHROUGH METHODS
--============================================================

function MarketplaceWrapper:GetDeveloperProductsAsync()
	return RealMarketplaceService:GetDeveloperProductsAsync()
end

function MarketplaceWrapper:PlayerOwnsAsset(player, assetId)
	return RealMarketplaceService:PlayerOwnsAsset(player, assetId)
end

function MarketplaceWrapper:UserOwnsGamePassAsync(userId, gamePassId)
	return RealMarketplaceService:UserOwnsGamePassAsync(userId, gamePassId)
end

function MarketplaceWrapper:PromptGamePassPurchase(player, gamePassId)
	return RealMarketplaceService:PromptGamePassPurchase(player, gamePassId)
end

function MarketplaceWrapper:PromptPurchase(player, assetId)
	return RealMarketplaceService:PromptPurchase(player, assetId)
end

function MarketplaceWrapper:PromptBundlePurchase(player, bundleId)
	return RealMarketplaceService:PromptBundlePurchase(player, bundleId)
end

function MarketplaceWrapper:PromptSubscriptionPurchase(player, subscriptionId)
	return RealMarketplaceService:PromptSubscriptionPurchase(player, subscriptionId)
end

function MarketplaceWrapper:GetSubscriptionStatusAsync(player, subscriptionId)
	return RealMarketplaceService:GetSubscriptionStatusAsync(player, subscriptionId)
end

--============================================================
-- PROPERTY-LIKE ACCESS (for ProcessReceipt assignment)
--============================================================

-- Allow: wrapper.ProcessReceipt = function(...) end
function MarketplaceWrapper:__newindex(key, value)
	if key == "ProcessReceipt" then
		self._developerProcessReceipt = value
		self:_setupProcessReceipt()
	else
		rawset(self, key, value)
	end
end

-- Allow reading ProcessReceipt
function MarketplaceWrapper:__index(key)
	if key == "ProcessReceipt" then
		return self._developerProcessReceipt
	end
	return MarketplaceWrapper[key]
end

--============================================================
-- EVENTS PASSTHROUGH
--============================================================

-- Forward events from real MarketplaceService
function MarketplaceWrapper:_getEvent(eventName)
	return RealMarketplaceService[eventName]
end

-- Common events
MarketplaceWrapper.PromptProductPurchaseFinished = RealMarketplaceService.PromptProductPurchaseFinished
MarketplaceWrapper.PromptPurchaseFinished = RealMarketplaceService.PromptPurchaseFinished
MarketplaceWrapper.PromptGamePassPurchaseFinished = RealMarketplaceService.PromptGamePassPurchaseFinished
MarketplaceWrapper.PromptSubscriptionPurchaseFinished = RealMarketplaceService.PromptSubscriptionPurchaseFinished

return MarketplaceWrapper