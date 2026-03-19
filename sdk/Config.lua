--[[
	PLAY3 SDK Configuration

	SETUP:
	1. Add your API key (get one at https://play3.ai)
	2. Define your product catalog
	3. (Optional) Add game context for smarter AI decisions

	The SDK learns from player state patterns set via:
	PLAY3:SetState(player, "coins", 50)
	PLAY3:SetState(player, "level", 5)
	PLAY3:SetState(player, "deaths", 3)
]]

return {
	--==========================================================
	-- REQUIRED: Your PLAY3 API Key
	-- Get your API key at https://play3.ai
	--==========================================================
	API_KEY = "YOUR_API_KEY_HERE",

	--==========================================================
	-- REQUIRED: Product Catalog
	-- Define the products AI can recommend to players
	--
	-- TIERED PRICING with aliasOf:
	--   Create 3 dev products at different prices (e.g. T1=25R, T2=50R, T3=100R)
	--   Set aliasOf to the "base" product ID (usually T2) that your game handles
	--   AI picks the tier, SDK's ResolveProduct() maps all tiers to the base
	--   Your ProcessReceipt only needs to handle one productId per item!
	--
	--   In your MonetizationManager, add this line to your receipt handler:
	--     local productId = getPLAY3():ResolveProduct(receiptInfo.ProductId)
	--
	-- NOTE: Prices are automatically fetched from MarketplaceService.
	--       The 'price' field is optional and only used as a fallback.
	--==========================================================
	CATALOG = {
		-- Example product with tiered pricing
		{
			promptId = "coins_pack",           -- Unique identifier for this product
			name = "Coin Pack",                -- Display name
			category = "currency",             -- Category: currency, power_up, cosmetic, etc.
			description = "A pack of coins",   -- What this product does
			aliasOf = 123456002,               -- Base product ID (your game handles this one)
			tiers = {
				{ tier = 1, productId = 123456001 },  -- Budget tier (e.g. 25 Robux)
				{ tier = 2, productId = 123456002 },  -- Standard tier (e.g. 50 Robux)
				{ tier = 3, productId = 123456003 },  -- Premium tier (e.g. 100 Robux)
			},
		},
		-- Example single-tier product (no tiered pricing)
		{
			promptId = "speed_boost",
			name = "Speed Boost",
			category = "power_up",
			description = "2x speed for 5 minutes",
			aliasOf = 123456010,
			tiers = {
				{ tier = 1, productId = 123456010 },
				{ tier = 2, productId = 123456010 },
				{ tier = 3, productId = 123456010 },
			},
		},
		-- Add more products here...
	},

	--==========================================================
	-- OPTIONAL: Game Context
	-- Helps AI understand your game for smarter decisions
	--==========================================================
	GAME_CONTEXT = {
		name = "Your Game Name",
		genre = "obby",  -- obby, tycoon, simulator, rpg, shooter, etc.
		description = "Brief description of your game",

		-- Explain what each SetState key means to the AI.
		-- Leaderstats are auto-detected if enabled in autoStates.
		-- You can optionally add definitions here to help AI understand them better.
		stateDefinitions = {
			-- Examples:
			-- coins = "Player's current coin balance",
			-- level = "Player's current level (1-100)",
			-- deaths = "Deaths this session. High = struggling player",
		},

		-- Explain what each product solves
		products = {
			-- Examples:
			-- coins_pack = "Gives player coins - good when balance is low",
			-- speed_boost = "2x speed - good for impatient players",
		},
	},

	--==========================================================
	-- OPTIONAL: A/B Testing
	-- Percentage of players in the AI test group (0-100)
	-- Control group gets no AI offers for comparison
	--==========================================================
	testGroupPercent = 100,

	--==========================================================
	-- OPTIONAL: Cache Settings
	-- How long to cache AI decisions (seconds)
	--==========================================================
	cacheTTL = 600,

	--==========================================================
	-- AUTO-COLLECTED STATES
	-- These are tracked automatically without developer code.
	-- Set to false to disable any you don't want.
	--==========================================================
	autoStates = {
		sessionMinutes = true,   -- Minutes since player joined
		idleMinutes = true,      -- Minutes since last input (client-tracked)
		timeOfDay = true,        -- Player's local time: morning/afternoon/evening/night
		isWeekend = true,        -- True if player's local day is Saturday/Sunday
		leaderstats = true,      -- Auto-read any leaderstats values
	},

	--==========================================================
	-- DEBUG
	-- Set to true to see detailed logs in Studio output
	--==========================================================
	debug = false,

	--==========================================================
	-- API SETTINGS (don't change unless instructed)
	--==========================================================
	API_URL = "https://play3-ai-assistant-605640375727.us-central1.run.app",
}
