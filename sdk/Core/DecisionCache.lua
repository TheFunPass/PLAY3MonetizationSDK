--[[
	PLAY3 SDK - Decision Cache
	Cache-first decision system
	- Stores AI decisions with outcome tracking
	- Uses state fingerprints for pattern matching
	- Only calls AI for new/unknown patterns
]]

local DecisionCache = {}
DecisionCache.__index = DecisionCache

-- Configuration
local DEFAULT_TTL = 600 -- 10 minutes
local MAX_CACHE_SIZE = 200
local SIMILARITY_THRESHOLD = 0.7 -- 70% key match for fuzzy matching
local MIN_ATTEMPTS_FOR_RATE = 3 -- Need 3+ attempts before trusting success rate
local MIN_SUCCESS_RATE = 0.03 -- 3% minimum to keep showing
local MIN_CHECK_INTERVAL = 30 -- Minimum seconds between evaluations per player
local MAX_DISMISSALS_PER_PRODUCT = 2 -- Stop showing product after N dismissals in a session

function DecisionCache.new(config)
	local self = setmetatable({}, DecisionCache)
	self.config = config
	self.cache = {} -- fingerprint -> entry
	self.playerLastCheck = {} -- playerId -> timestamp
	self.playerDismissals = {} -- playerId -> { productId -> { count, lastDismissal } }
	self.playerLastOffer = {} -- playerId -> { productId, timestamp }
	self.debug = config.debug or false
	return self
end

--[[
	Generate fingerprint from player state (SetState values)
	Uses logarithmic bucketing for numbers - scales to any value range
]]
function DecisionCache:generateFingerprint(state)
	local parts = {}

	-- Sort keys for consistent fingerprint
	local keys = {}
	for k in pairs(state) do
		table.insert(keys, k)
	end
	table.sort(keys)

	for _, key in ipairs(keys) do
		local value = state[key]
		local bucketedValue

		if type(value) == "number" then
			-- Logarithmic bucketing: scales dynamically to any value range
			-- 0, 1-9, 10-99, 100-999, 1k-9.9k, 10k-99k, 100k-999k, 1M+, etc.
			if value == 0 then
				bucketedValue = "0"
			elseif value < 0 then
				-- Handle negative numbers with same log scale
				local absVal = math.abs(value)
				local magnitude = math.floor(math.log10(absVal))
				local bucket = math.pow(10, magnitude)
				bucketedValue = "-" .. self:_formatBucket(bucket)
			else
				-- Positive numbers: bucket by order of magnitude
				local magnitude = math.floor(math.log10(value))
				local bucket = math.pow(10, magnitude)
				bucketedValue = self:_formatBucket(bucket)
			end
		elseif type(value) == "boolean" then
			bucketedValue = value and "true" or "false"
		elseif type(value) == "string" then
			bucketedValue = value
		else
			bucketedValue = tostring(value)
		end

		table.insert(parts, key .. ":" .. bucketedValue)
	end

	return table.concat(parts, "|")
end

--[[
	Format bucket value with human-readable suffixes
]]
function DecisionCache:_formatBucket(bucket)
	if bucket >= 1000000000 then
		return string.format("%dB", bucket / 1000000000)
	elseif bucket >= 1000000 then
		return string.format("%dM", bucket / 1000000)
	elseif bucket >= 1000 then
		return string.format("%dk", bucket / 1000)
	else
		return tostring(math.floor(bucket))
	end
end

--[[
	Parse fingerprint back to key-value pairs
]]
function DecisionCache:parseFingerprint(fingerprint)
	local parts = {}
	for part in fingerprint:gmatch("[^|]+") do
		local k, v = part:match("([^:]+):(.+)")
		if k then parts[k] = v end
	end
	return parts
end

--[[
	Calculate similarity between two fingerprints (0-1)
]]
function DecisionCache:calculateSimilarity(fp1, fp2)
	local parts1 = self:parseFingerprint(fp1)
	local parts2 = self:parseFingerprint(fp2)

	-- Count all unique keys
	local allKeys = {}
	for k in pairs(parts1) do allKeys[k] = true end
	for k in pairs(parts2) do allKeys[k] = true end

	local total = 0
	local matches = 0
	for k in pairs(allKeys) do
		total = total + 1
		if parts1[k] == parts2[k] then
			matches = matches + 1
		end
	end

	return total > 0 and (matches / total) or 0
end

--[[
	Find similar cached entry (fuzzy match)
	Returns: entry, fingerprint, similarity OR nil
]]
function DecisionCache:findSimilar(state)
	local targetFp = self:generateFingerprint(state)

	-- First try exact match
	if self.cache[targetFp] then
		local entry = self.cache[targetFp]
		if not self:isExpired(entry) then
			-- Update last access time (LRU tracking)
			entry.lastAccess = tick()
			return entry, targetFp, 1.0
		end
	end

	-- Fuzzy match - find best similar entry
	local bestEntry, bestFp, bestSim = nil, nil, 0

	for fp, entry in pairs(self.cache) do
		if not self:isExpired(entry) then
			local sim = self:calculateSimilarity(targetFp, fp)

			-- EARLY EXIT: 90%+ match is good enough, skip remaining iterations
			if sim >= 0.90 then
				entry.lastAccess = tick()
				if self.debug then
					print("[PLAY3 Cache] Early match:", fp:sub(1,50), "sim:", string.format("%.0f%%", sim * 100))
				end
				return entry, fp, sim
			end

			if sim >= SIMILARITY_THRESHOLD and sim > bestSim then
				-- Prefer entries with more data (more attempts)
				local hasEnoughData = entry.attempts >= MIN_ATTEMPTS_FOR_RATE
				if hasEnoughData or sim > 0.85 then
					bestEntry, bestFp, bestSim = entry, fp, sim
				end
			end
		end
	end

	if bestEntry then
		-- Update last access time (LRU tracking)
		bestEntry.lastAccess = tick()

		if self.debug then
			print("[PLAY3 Cache] Similar match:", bestFp:sub(1,50), "sim:", string.format("%.0f%%", bestSim * 100))
		end
		return bestEntry, bestFp, bestSim
	end

	return nil, nil, 0
end

--[[
	Check if entry is expired
]]
function DecisionCache:isExpired(entry)
	local ttl = self.config.cacheTTL or DEFAULT_TTL
	return (tick() - entry.timestamp) > ttl
end

--[[
	Should we call AI for this state?
	Returns true if:
	- No similar cached entry exists (new pattern)
	- Cached entry has poor success rate AND enough data (needs better decision)

	If we have a cached decision, USE IT to test if it converts.
	Only call AI again if we have proof the current decision isn't working.
]]
function DecisionCache:shouldCallAI(state, playerId)
	-- Rate limit per player
	local now = tick()
	local lastCheck = self.playerLastCheck[playerId] or 0
	if (now - lastCheck) < MIN_CHECK_INTERVAL then
		return false, "rate_limited"
	end

	local entry, fp, sim = self:findSimilar(state)

	if not entry then
		-- New pattern - call AI to get initial decision
		if self.debug then
			print("[PLAY3 Cache] New pattern, calling AI")
		end
		return true, "new_pattern"
	end

	-- We have a cached decision - use it to test if it converts
	-- Don't call AI again until we have enough data to judge

	if entry.attempts < MIN_ATTEMPTS_FOR_RATE then
		-- Not enough data yet - keep using cached decision to gather data
		if self.debug then
			print("[PLAY3 Cache] Testing cached decision (" .. entry.attempts .. " attempts so far)")
		end
		return false, "testing_decision"
	end

	-- We have enough data - check success rate
	local rate = self:getSuccessRate(entry)

	if rate >= MIN_SUCCESS_RATE then
		-- Pattern is converting well - keep using cached decision
		if self.debug then
			print("[PLAY3 Cache] Good rate (" .. string.format("%.1f%%", rate * 100) .. "), using cache")
		end
		return false, "good_rate"
	end

	-- Poor performance with enough data - try getting a new decision from AI
	if math.random() < 0.2 then -- 20% chance to get new decision
		if self.debug then
			print("[PLAY3 Cache] Poor rate (" .. string.format("%.1f%%", rate * 100) .. "), trying new decision")
		end
		return true, "poor_rate_retry"
	end

	return false, "poor_rate_suppress"
end

--[[
	Get success rate for an entry
]]
function DecisionCache:getSuccessRate(entry)
	if not entry or not entry.attempts or entry.attempts == 0 then
		return 0
	end
	return (entry.conversions or 0) / entry.attempts
end

--[[
	Store a new decision from AI
]]
function DecisionCache:store(state, decision)
	local fingerprint = self:generateFingerprint(state)

	self:evictIfNeeded()

	-- Preserve existing stats if updating
	local existing = self.cache[fingerprint]

	self.cache[fingerprint] = {
		decision = decision,
		timestamp = tick(),
		attempts = existing and existing.attempts or 0,
		conversions = existing and existing.conversions or 0,
	}

	if self.debug then
		print("[PLAY3 Cache] Stored:", fingerprint:sub(1, 60))
	end

	return fingerprint
end

--[[
	Record that we showed an offer (attempt)
]]
function DecisionCache:recordAttempt(state)
	local fingerprint = self:generateFingerprint(state)
	local entry = self.cache[fingerprint]

	if entry then
		entry.attempts = (entry.attempts or 0) + 1
		entry.lastAttempt = tick()

		if self.debug then
			print("[PLAY3 Cache] Attempt recorded:", entry.attempts, "total")
		end
	else
		-- Find similar and update that
		local similar, similarFp = self:findSimilar(state)
		if similar then
			similar.attempts = (similar.attempts or 0) + 1
			similar.lastAttempt = tick()
		end
	end
end

--[[
	Record successful conversion (purchase)
]]
function DecisionCache:recordConversion(state)
	local fingerprint = self:generateFingerprint(state)
	local entry = self.cache[fingerprint]

	if entry then
		entry.conversions = (entry.conversions or 0) + 1
		entry.lastConversion = tick()

		local rate = self:getSuccessRate(entry)
		if self.debug then
			print("[PLAY3 Cache] Conversion! Rate:", string.format("%.1f%%", rate * 100))
		end
	else
		-- Find similar and update that
		local similar, similarFp = self:findSimilar(state)
		if similar then
			similar.conversions = (similar.conversions or 0) + 1
			similar.lastConversion = tick()
		end
	end
end

--[[
	Record player check time (for rate limiting)
]]
function DecisionCache:recordCheck(playerId)
	self.playerLastCheck[playerId] = tick()
end

--[[
	Get cached decision if available and good
	Returns: decision, shouldShow, reason
]]
function DecisionCache:getDecision(state, playerId)
	local entry, fp, sim = self:findSimilar(state)

	if not entry then
		return nil, false, "no_cache"
	end

	-- Check if this product is suppressed for this player (dismissals)
	local promptId = entry.decision and entry.decision.promptId
	if promptId and playerId and self:isProductSuppressed(playerId, promptId) then
		return entry.decision, false, "player_dismissed"
	end

	-- Check success rate
	local rate = self:getSuccessRate(entry)
	if entry.attempts >= MIN_ATTEMPTS_FOR_RATE and rate < MIN_SUCCESS_RATE then
		return entry.decision, false, "poor_rate"
	end

	-- Good cached decision
	return entry.decision, entry.decision.show, "cache_hit"
end

--[[
	Evict entries if cache is full
	Priority: expired first, then poor performers, then LRU
]]
function DecisionCache:evictIfNeeded()
	local count = 0
	local now = tick()

	-- First pass: remove expired entries
	local toRemove = {}
	for fp, entry in pairs(self.cache) do
		count = count + 1
		if self:isExpired(entry) then
			table.insert(toRemove, fp)
		end
	end

	for _, fp in ipairs(toRemove) do
		self.cache[fp] = nil
		count = count - 1
	end

	-- If still over limit, evict by score (poor rate + LRU)
	while count >= MAX_CACHE_SIZE do
		local worst = nil
		local worstScore = math.huge

		for fp, entry in pairs(self.cache) do
			-- Score combines: success rate, recency of access, and attempt count
			local rate = self:getSuccessRate(entry)
			local lastAccess = entry.lastAccess or entry.timestamp
			local age = now - lastAccess
			local attempts = entry.attempts or 0

			-- Higher score = keep, Lower score = evict
			-- Good rate + recent access + more data = keep
			local score = (rate * 100) + (attempts * 5) - (age / 60)

			if score < worstScore then
				worstScore = score
				worst = fp
			end
		end

		if worst then
			self.cache[worst] = nil
			count = count - 1
		else
			break
		end
	end
end

--[[
	Record that player dismissed an offer (closed without buying)
	Uses promptId since that's what the AI decision contains
]]
function DecisionCache:recordDismissal(playerId, promptId)
	if not playerId or not promptId then return end

	if not self.playerDismissals[playerId] then
		self.playerDismissals[playerId] = {}
	end

	local dismissals = self.playerDismissals[playerId]
	if not dismissals[promptId] then
		dismissals[promptId] = { count = 0, lastDismissal = 0 }
	end

	dismissals[promptId].count = dismissals[promptId].count + 1
	dismissals[promptId].lastDismissal = tick()

	if self.debug then
		print("[PLAY3 Cache] Dismissal recorded for", promptId, "- count:", dismissals[promptId].count)
	end
end

--[[
	Check if product should be suppressed for this player (too many dismissals)
	Uses promptId since that's what the AI decision contains
]]
function DecisionCache:isProductSuppressed(playerId, promptId)
	if not playerId or not promptId then return false end

	local dismissals = self.playerDismissals[playerId]
	if not dismissals or not dismissals[promptId] then
		return false
	end

	local data = dismissals[promptId]

	-- Check if max dismissals reached (suppress for rest of session)
	if data.count >= MAX_DISMISSALS_PER_PRODUCT then
		if self.debug then
			print("[PLAY3 Cache] Product", promptId, "suppressed - dismissed", data.count, "times")
		end
		return true
	end

	return false
end

--[[
	Record that an offer was shown to player (for tracking)
]]
function DecisionCache:recordOfferShown(playerId, productId)
	if not playerId or not productId then return end

	self.playerLastOffer[playerId] = {
		productId = productId,
		timestamp = tick()
	}
end

--[[
	Clear all cache
]]
function DecisionCache:clear()
	self.cache = {}
	self.playerLastCheck = {}
	if self.debug then
		print("[PLAY3 Cache] Cleared")
	end
end

--[[
	Clear player rate limit (on leave)
]]
function DecisionCache:clearPlayer(playerId)
	self.playerLastCheck[playerId] = nil
	self.playerDismissals[playerId] = nil
	self.playerLastOffer[playerId] = nil
end

--[[
	Get cache statistics
]]
function DecisionCache:getStats()
	local count = 0
	local totalAttempts = 0
	local totalConversions = 0

	for _, entry in pairs(self.cache) do
		count = count + 1
		totalAttempts = totalAttempts + (entry.attempts or 0)
		totalConversions = totalConversions + (entry.conversions or 0)
	end

	return {
		entries = count,
		totalAttempts = totalAttempts,
		totalConversions = totalConversions,
		overallRate = totalAttempts > 0 and (totalConversions / totalAttempts) or 0,
	}
end

--[[
	Get all pattern stats for reporting to backend
]]
function DecisionCache:getPatternStats()
	local patterns = {}
	for fingerprint, entry in pairs(self.cache) do
		table.insert(patterns, {
			fingerprint = fingerprint,
			decision = entry.decision,
			attempts = entry.attempts or 0,
			conversions = entry.conversions or 0,
			conversionRate = self:getSuccessRate(entry),
			lastAttempt = entry.lastAttempt,
			lastConversion = entry.lastConversion,
			timestamp = entry.timestamp,
		})
	end
	return patterns
end

return DecisionCache