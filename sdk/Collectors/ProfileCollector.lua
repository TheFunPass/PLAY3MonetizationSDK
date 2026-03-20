--[[
	PLAY3 SDK - Profile Collector
	Collects player profile data (Roblox data, avatar, social)
]]

local Players = game:GetService("Players")
local GroupService = game:GetService("GroupService")
local MarketplaceService = game:GetService("MarketplaceService")
local LocalizationService = game:GetService("LocalizationService")
local PolicyService = game:GetService("PolicyService")
local UserInputService = game:GetService("UserInputService")

local ProfileCollector = {}
ProfileCollector.__index = ProfileCollector

local playerProfiles = {}
local playerProfileReady = {} -- Track when profile loading is complete

-- Global asset value cache (shared across all players)
local assetValueCache = {}
local CACHE_DURATION = 3600 -- 1 hour cache for asset values
local lastApiCall = 0
local API_COOLDOWN = 1 -- Minimum 1 second between API calls

function ProfileCollector.new(config)
	local self = setmetatable({}, ProfileCollector)
	self.config = config
	return self
end

function ProfileCollector:init()
	-- Profile data is collected on player join
end

function ProfileCollector:loadProfile(player)
	task.spawn(function()
		-- Get age bracket (wrapped in pcall as property may not exist)
		local ageBracket = "unknown"
		pcall(function()
			if player.AgeBracket == Enum.AgeBracket.AgeUnder13 then
				ageBracket = "Under13"
			elseif player.AgeBracket == Enum.AgeBracket.Age13OrOver then
				ageBracket = "13+"
			end
		end)

		-- Get country code (Amendment PA-2026-001)
		local country = "unknown"
		pcall(function()
			country = LocalizationService:GetCountryRegionForPlayerAsync(player)
		end)

		-- Get policy signals (Amendment PA-2026-001)
		local policySignals = {}
		pcall(function()
			local policyInfo = PolicyService:GetPolicyInfoForPlayerAsync(player)
			policySignals = {
				ArePaidRandomItemsRestricted = policyInfo.ArePaidRandomItemsRestricted or false,
				IsPaidItemTradingAllowed = policyInfo.IsPaidItemTradingAllowed or false,
				IsSubjectToChinaPolicies = policyInfo.IsSubjectToChinaPolicies or false,
			}
		end)

		-- Get network ping (Amendment PA-2026-001)
		local pingMs = 0
		pcall(function()
			pingMs = math.floor(player:GetNetworkPing() * 1000) -- Convert to ms
		end)

		-- Check if VIP server (Amendment PA-2026-001)
		local isVIPServer = game.PrivateServerId ~= "" and game.PrivateServerId ~= nil

		-- Device type detection
		local deviceType = "Desktop"
		pcall(function()
			if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
				deviceType = "Mobile"
			elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
				deviceType = "Console"
			else
				deviceType = "Desktop"
			end
		end)

		local profile = {
			isPremium = player.MembershipType == Enum.MembershipType.Premium,
			accountAgeDays = player.AccountAge,
			locale = player.LocaleId or "en-us",
			ageBracket = ageBracket,
			deviceType = deviceType,
			-- Amendment PA-2026-001 fields
			country = country,
			hasVerifiedBadge = player.HasVerifiedBadge or false,
			pingMs = pingMs,
			isVIPServer = isVIPServer,
			policySignals = policySignals,
		}

		-- Get groups
		local groups = self:getGroups(player)
		profile.groupCount = #groups
		profile.highRankGroupCount = 0
		for _, group in ipairs(groups) do
			if group.Rank and group.Rank > 200 then
				profile.highRankGroupCount += 1
			end
		end

		-- Get friends count
		profile.friendsCount = self:getFriendsCount(player)

		-- Get avatar data (with real values from API)
		local avatar = self:getAvatarData(player)
		profile.avatarTotalValue = avatar.totalValue
		profile.avatarLimitedCount = avatar.limitedCount
		profile.avatarHighestItem = avatar.highestValue
		profile.avatarAccessoryCount = avatar.accessoryCount

		-- Party detection (basic - checks for friends in same server)
		local partyInfo = self:detectParty(player)
		profile.isInParty = partyInfo.isInParty
		profile.partySize = partyInfo.partySize

		playerProfiles[player.UserId] = profile
		playerProfileReady[player.UserId] = true
	end)
end

--[[
	Check if profile is fully loaded (all async fetches complete)
]]
function ProfileCollector:isReady(player)
	return playerProfileReady[player.UserId] == true
end

--[[
	Wait for profile to be ready (with timeout)
]]
function ProfileCollector:waitForReady(player, timeoutSec)
	timeoutSec = timeoutSec or 10
	local startTime = tick()

	while not playerProfileReady[player.UserId] do
		if tick() - startTime > timeoutSec then
			return false
		end
		task.wait(0.1)
	end

	return true
end

function ProfileCollector:getGroups(player)
	local success, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)

	if success then
		return groups
	end
	return {}
end

function ProfileCollector:getFriendsCount(player)
	local success, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)

	if not success then return 0 end

	local count = 0
	local maxPages = 5 -- Limit to avoid timeout
	local pageNum = 0

	while pageNum < maxPages do
		local items = pages:GetCurrentPage()
		count += #items

		if pages.IsFinished then break end

		local nextSuccess = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)

		if not nextSuccess then break end
		pageNum += 1
	end

	return count
end

--[[
	Get avatar data with real values from Roblox Catalog API
	Uses batching and caching to minimize API calls
]]
function ProfileCollector:getAvatarData(player)
	local debugEnabled = self.config and self.config.debug

	local result = {
		totalValue = 0,
		limitedCount = 0,
		highestValue = 0,
		accessoryCount = 0,
	}

	-- Get HumanoidDescription
	local success, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(player.UserId)
	end)

	if not success or not description then
		return result
	end

	-- Collect all asset IDs from avatar
	local assetIds = {}
	local accessoryDescriptions = description:GetAccessories(false)
	for _, acc in ipairs(accessoryDescriptions) do
		if acc.AssetId and acc.AssetId > 0 then
			table.insert(assetIds, acc.AssetId)
		end
	end

	result.accessoryCount = #assetIds

	if #assetIds == 0 then
		return result
	end

	-- Check which assets need lookup (not in cache or expired)
	local uncachedIds = {}
	local now = tick()

	for _, assetId in ipairs(assetIds) do
		local cached = assetValueCache[assetId]
		if not cached or (now - cached.timestamp) > CACHE_DURATION then
			table.insert(uncachedIds, assetId)
		end
	end

	-- Fetch uncached assets from API (batched)
	if #uncachedIds > 0 then
		self:fetchAssetValues(uncachedIds)
	end

	-- Calculate totals from cache
	for _, assetId in ipairs(assetIds) do
		local cached = assetValueCache[assetId]
		if cached then
			local value = cached.price or 0
			result.totalValue += value

			if cached.isLimited then
				result.limitedCount += 1
				-- For limiteds, use resale price if available
				if cached.lowestResalePrice and cached.lowestResalePrice > value then
					result.totalValue += (cached.lowestResalePrice - value)
					value = cached.lowestResalePrice
				end
			end

			if value > result.highestValue then
				result.highestValue = value
			end
		end
	end

	return result
end

--[[
	Fetch asset values using MarketplaceService:GetProductInfo
	(HttpService cannot access Roblox APIs directly)
]]
function ProfileCollector:fetchAssetValues(assetIds)
	for _, assetId in ipairs(assetIds) do
		-- Rate limit between calls
		local now = tick()
		if (now - lastApiCall) < API_COOLDOWN then
			task.wait(API_COOLDOWN - (now - lastApiCall))
		end
		lastApiCall = tick()

		local success, assetInfo = pcall(function()
			return MarketplaceService:GetProductInfo(assetId, Enum.InfoType.Asset)
		end)

		if success and assetInfo then
			local price = assetInfo.PriceInRobux or 0
			local isLimited = assetInfo.IsLimited or assetInfo.IsLimitedUnique or false

			assetValueCache[assetId] = {
				price = price,
				isLimited = isLimited,
				lowestResalePrice = nil,
				timestamp = tick(),
			}
		else
			-- Asset lookup failed - cache zero
			assetValueCache[assetId] = {
				price = 0,
				isLimited = false,
				timestamp = tick(),
			}
		end
	end
end

--[[
	Detect if player is in a party (friends in same server)
]]
function ProfileCollector:detectParty(player)
	local result = {
		isInParty = false,
		partySize = 0,
	}

	-- Get player's friends
	local friendIds = {}
	local success, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)

	if not success then return result end

	-- Collect friend IDs (first page only for speed)
	local items = pages:GetCurrentPage()
	for _, friend in ipairs(items) do
		friendIds[friend.Id] = true
	end

	-- Check if any friends are in the same server
	local friendsInServer = 0
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player and friendIds[otherPlayer.UserId] then
			friendsInServer += 1
		end
	end

	if friendsInServer > 0 then
		result.isInParty = true
		result.partySize = friendsInServer + 1 -- Include the player
	end

	return result
end

function ProfileCollector:collect(player)
	local profile = playerProfiles[player.UserId]

	if profile then
		return profile
	else
		-- Get age bracket (wrapped in pcall as property may not exist)
		local ageBracket = "unknown"
		pcall(function()
			if player.AgeBracket == Enum.AgeBracket.AgeUnder13 then
				ageBracket = "Under13"
			elseif player.AgeBracket == Enum.AgeBracket.Age13OrOver then
				ageBracket = "13+"
			end
		end)

		-- Device type detection for fallback
		local deviceType = "Desktop"
		pcall(function()
			if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
				deviceType = "Mobile"
			elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
				deviceType = "Console"
			end
		end)

		return {
			isPremium = player.MembershipType == Enum.MembershipType.Premium,
			accountAgeDays = player.AccountAge,
			locale = player.LocaleId or "en-us",
			ageBracket = ageBracket,
			deviceType = deviceType,
			country = "unknown",
			hasVerifiedBadge = player.HasVerifiedBadge or false,
			pingMs = 0,
			isVIPServer = game.PrivateServerId ~= "" and game.PrivateServerId ~= nil,
			policySignals = {},
			groupCount = 0,
			highRankGroupCount = 0,
			friendsCount = 0,
			avatarTotalValue = 0,
			avatarLimitedCount = 0,
			avatarHighestItem = 0,
			avatarAccessoryCount = 0,
			isInParty = false,
			partySize = 0,
		}
	end
end

function ProfileCollector:clearPlayer(player)
	playerProfiles[player.UserId] = nil
	playerProfileReady[player.UserId] = nil
end

return ProfileCollector