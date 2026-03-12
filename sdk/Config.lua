--[[
	PLAY3 SDK Configuration

	SETUP:
	1. Add your API key
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
	--==========================================================
	API_KEY = "",

	--==========================================================
	-- REQUIRED: Product Catalog
	-- Define the products AI can recommend to players
	--==========================================================
	CATALOG = {
		-- Example:
		-- {
		--     promptId = "coin_pack",
		--     name = "Coin Pack",
		--     category = "currency",
		--     description = "Gives coins to buy items",
		--     tiers = {
		--         { tier = 1, price = 49, productId = 123456 },
		--         { tier = 2, price = 99, productId = 123457 },
		--         { tier = 3, price = 199, productId = 123458 },
		--     },
		-- },
	},

	--==========================================================
	-- OPTIONAL: Game Context
	-- Helps AI understand your game for smarter decisions
	--==========================================================

	-- GAME_CONTEXT = {
	--     name = "My Awesome Game",
	--     genre = "simulator",
	--     description = "Players collect items and upgrade their base",
	--
	--     -- Explain what each SetState key means to the AI
	--     -- This helps the AI understand your game and make smarter decisions
	--     stateDefinitions = {
	--         coins = "In-game currency. Low coins = good time for currency offers",
	--         level = "Player progression level. Higher = more invested player",
	--         inventoryFull = "True when inventory at max. Perfect for storage offers",
	--         hasBoost = "True if player has active boost. False = boost opportunity",
	--         deathCount = "Deaths this session. High count = frustrated player",
	--         hasEverPurchased = "True if ever bought. False = needs lower tier pricing",
	--     },
	--
	--     -- Explain what each product solves
	--     products = {
	--         coin_pack = "Currency for upgrades - good when player is stuck",
	--         speed_boost = "Temporary speed increase - good for impatient players",
	--         auto_collect = "Automates collection - good for busy players",
	--         storage = "More inventory space - when inventory is full",
	--     },
	-- },

	--==========================================================
	-- OPTIONAL: A/B Testing
	--==========================================================

	-- Percentage of players in test group (default 100)
	-- Set to 50 for 50% test, 50% control
	-- Control group is tracked but doesn't see SDK offers
	testGroupPercent = 100,

	--==========================================================
	-- OPTIONAL: Cache Settings
	--==========================================================

	-- How long cached decisions stay valid (seconds)
	cacheTTL = 600, -- 10 minutes

	--==========================================================
	-- DEBUG
	--==========================================================

	-- Enable debug logging
	debug = false,

	--==========================================================
	-- API SETTINGS (don't change unless instructed)
	--==========================================================
	API_URL = "https://play3-ai-assistant-605640375727.us-central1.run.app",
}
