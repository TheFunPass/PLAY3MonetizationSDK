--[[
	PLAY3 SDK - Offer UI (Client)
	Responsive popup UI that scales for mobile and desktop
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Don't run in edit mode (Studio without game running)
if not RunService:IsRunning() then
	return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local MarketplaceService = game:GetService("MarketplaceService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Detect mobile
local function isMobile()
	local success, result = pcall(function()
		return GuiService:IsTenFootInterface() == false and
			(game:GetService("UserInputService").TouchEnabled and
			 not game:GetService("UserInputService").KeyboardEnabled)
	end)
	return success and result
end

local IS_MOBILE = isMobile()

-- Wait for remotes with retry
local function getRemotes()
	local remotesFolder = ReplicatedStorage:WaitForChild("PLAY3Remotes", 30)
	if not remotesFolder then
		remotesFolder = ReplicatedStorage:FindFirstChild("PLAY3Remotes")
		if not remotesFolder then
			warn("[PLAY3] Could not find PLAY3Remotes folder after 30s - server may not be initialized")
			return nil, nil
		end
	end

	local showOffer = remotesFolder:WaitForChild("ShowOffer", 30)
	if not showOffer then
		warn("[PLAY3] Could not find ShowOffer remote")
		return nil, nil
	end

	local offerResult = remotesFolder:FindFirstChild("OfferResult")
	if not offerResult then
		offerResult = remotesFolder:WaitForChild("OfferResult", 5)
	end

	return showOffer, offerResult
end

local showOfferEvent, offerResultEvent = getRemotes()
if not showOfferEvent then
	return
end

-- Sizing based on device
local POPUP_WIDTH = IS_MOBILE and 320 or 360
local PADDING = IS_MOBILE and 20 or 24
local TITLE_SIZE = IS_MOBILE and 16 or 18
local PRODUCT_SIZE = IS_MOBILE and 22 or 26
local DESC_SIZE = IS_MOBILE and 14 or 15
local PRICE_SIZE = IS_MOBILE and 20 or 22
local BUTTON_TEXT_SIZE = IS_MOBILE and 16 or 18
local BUTTON_HEIGHT = IS_MOBILE and 48 or 44

-- Create the UI
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PLAY3OfferUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

-- Background overlay
local overlay = Instance.new("Frame")
overlay.Name = "Overlay"
overlay.Size = UDim2.new(1, 0, 1, 0)
overlay.BackgroundColor3 = Color3.new(0, 0, 0)
overlay.BackgroundTransparency = 1
overlay.ZIndex = 100
overlay.Parent = screenGui

-- Main popup frame - centered with auto height
local popup = Instance.new("Frame")
popup.Name = "Popup"
popup.AnchorPoint = Vector2.new(0.5, 0.5)
popup.Position = UDim2.new(0.5, 0, 0.5, 0)
popup.Size = UDim2.new(0, POPUP_WIDTH, 0, 0) -- Height set by AutomaticSize
popup.AutomaticSize = Enum.AutomaticSize.Y
popup.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
popup.BorderSizePixel = 0
popup.Visible = false
popup.ZIndex = 101
popup.ClipsDescendants = true
popup.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 16)
corner.Parent = popup

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(80, 120, 255)
stroke.Thickness = 2
stroke.Parent = popup

-- Content container with padding
local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, 0, 0, 0)
content.AutomaticSize = Enum.AutomaticSize.Y
content.BackgroundTransparency = 1
content.Parent = popup

local contentPadding = Instance.new("UIPadding")
contentPadding.PaddingTop = UDim.new(0, PADDING)
contentPadding.PaddingBottom = UDim.new(0, PADDING)
contentPadding.PaddingLeft = UDim.new(0, PADDING)
contentPadding.PaddingRight = UDim.new(0, PADDING)
contentPadding.Parent = content

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 12)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = content

-- Title - "Limited Time Offer"
local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, 0, 0, TITLE_SIZE + 4)
title.BackgroundTransparency = 1
title.Text = "LIMITED TIME OFFER"
title.TextColor3 = Color3.fromRGB(100, 180, 255)
title.TextSize = TITLE_SIZE
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Center
title.LayoutOrder = 1
title.Parent = content

-- Product name
local productName = Instance.new("TextLabel")
productName.Name = "ProductName"
productName.Size = UDim2.new(1, 0, 0, PRODUCT_SIZE + 6)
productName.BackgroundTransparency = 1
productName.Text = "Product Name"
productName.TextColor3 = Color3.new(1, 1, 1)
productName.TextSize = PRODUCT_SIZE
productName.Font = Enum.Font.GothamBold
productName.TextXAlignment = Enum.TextXAlignment.Center
productName.TextTruncate = Enum.TextTruncate.AtEnd
productName.LayoutOrder = 2
productName.Parent = content

-- Description
local description = Instance.new("TextLabel")
description.Name = "Description"
description.Size = UDim2.new(1, 0, 0, 0)
description.AutomaticSize = Enum.AutomaticSize.Y
description.BackgroundTransparency = 1
description.Text = "Get ahead with this special offer!"
description.TextColor3 = Color3.fromRGB(180, 180, 190)
description.TextSize = DESC_SIZE
description.Font = Enum.Font.Gotham
description.TextXAlignment = Enum.TextXAlignment.Center
description.TextWrapped = true
description.LayoutOrder = 3
description.Parent = content

-- Price container
local priceContainer = Instance.new("Frame")
priceContainer.Name = "PriceContainer"
priceContainer.Size = UDim2.new(1, 0, 0, PRICE_SIZE + 16)
priceContainer.BackgroundTransparency = 1
priceContainer.LayoutOrder = 4
priceContainer.Parent = content

local price = Instance.new("TextLabel")
price.Name = "Price"
price.Size = UDim2.new(1, 0, 1, 0)
price.BackgroundTransparency = 1
price.Text = "R$ 99"
price.TextColor3 = Color3.fromRGB(50, 220, 120)
price.TextSize = PRICE_SIZE
price.Font = Enum.Font.GothamBold
price.TextXAlignment = Enum.TextXAlignment.Center
price.TextYAlignment = Enum.TextYAlignment.Center
price.Parent = priceContainer

-- Button container
local buttonContainer = Instance.new("Frame")
buttonContainer.Name = "Buttons"
buttonContainer.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT)
buttonContainer.BackgroundTransparency = 1
buttonContainer.LayoutOrder = 5
buttonContainer.Parent = content

local buttonLayout = Instance.new("UIListLayout")
buttonLayout.FillDirection = Enum.FillDirection.Horizontal
buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
buttonLayout.Padding = UDim.new(0, 12)
buttonLayout.Parent = buttonContainer

-- Calculate button width (fit within container with gap)
local buttonWidth = (POPUP_WIDTH - PADDING * 2 - 12) / 2

-- Buy button
local buyBtn = Instance.new("TextButton")
buyBtn.Name = "BuyButton"
buyBtn.Size = UDim2.new(0, buttonWidth, 0, BUTTON_HEIGHT)
buyBtn.BackgroundColor3 = Color3.fromRGB(40, 180, 90)
buyBtn.Text = "Buy Now"
buyBtn.TextColor3 = Color3.new(1, 1, 1)
buyBtn.TextSize = BUTTON_TEXT_SIZE
buyBtn.Font = Enum.Font.GothamBold
buyBtn.AutoButtonColor = true
buyBtn.LayoutOrder = 1
buyBtn.Parent = buttonContainer

local buyCorner = Instance.new("UICorner")
buyCorner.CornerRadius = UDim.new(0, 10)
buyCorner.Parent = buyBtn

-- Dismiss button
local dismissBtn = Instance.new("TextButton")
dismissBtn.Name = "DismissButton"
dismissBtn.Size = UDim2.new(0, buttonWidth, 0, BUTTON_HEIGHT)
dismissBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
dismissBtn.Text = "No Thanks"
dismissBtn.TextColor3 = Color3.fromRGB(180, 180, 190)
dismissBtn.TextSize = BUTTON_TEXT_SIZE
dismissBtn.Font = Enum.Font.GothamBold
dismissBtn.AutoButtonColor = true
dismissBtn.LayoutOrder = 2
dismissBtn.Parent = buttonContainer

local dismissCorner = Instance.new("UICorner")
dismissCorner.CornerRadius = UDim.new(0, 10)
dismissCorner.Parent = dismissBtn

-- Current offer tracking
local currentOffer = nil

-- Show popup with animation
local function showPopup(offer)
	currentOffer = offer

	productName.Text = offer.name or "Special Item"
	description.Text = offer.description or "Get ahead with this special offer!"
	price.Text = "R$ " .. tostring(offer.price or "??")

	-- Reset for animation
	overlay.BackgroundTransparency = 1
	popup.Visible = true
	popup.Position = UDim2.new(0.5, 0, 0.5, 50)

	-- Animate in
	local overlayTween = TweenService:Create(overlay, TweenInfo.new(0.25), {BackgroundTransparency = 0.5})
	local popupPosTween = TweenService:Create(popup, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0.5, 0)
	})

	overlayTween:Play()
	popupPosTween:Play()
end

-- Hide popup
local function hidePopup(sendResult)
	if not currentOffer then return end

	local offer = currentOffer
	currentOffer = nil

	-- Animate out
	local overlayTween = TweenService:Create(overlay, TweenInfo.new(0.2), {BackgroundTransparency = 1})
	local popupTween = TweenService:Create(popup, TweenInfo.new(0.15), {
		Position = UDim2.new(0.5, 0, 0.5, 30)
	})

	overlayTween:Play()
	popupTween:Play()

	popupTween.Completed:Connect(function()
		popup.Visible = false
	end)

	-- Only send "dismissed" to server - "purchased" is handled by ProcessReceipt
	if sendResult and offerResultEvent then
		offerResultEvent:FireServer(offer.promptId, "dismissed")
	end
end

-- Buy button: prompt actual Roblox purchase
buyBtn.MouseButton1Click:Connect(function()
	if currentOffer and currentOffer.productId then
		MarketplaceService:PromptProductPurchase(player, currentOffer.productId)
	end
	hidePopup(false)
end)

-- Dismiss button: tell server player dismissed
dismissBtn.MouseButton1Click:Connect(function()
	hidePopup(true)
end)

-- Tapping overlay dismisses
overlay.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		hidePopup(true)
	end
end)

-- Listen for offers from server
showOfferEvent.OnClientEvent:Connect(function(offer)
	showPopup(offer)
end)

print("[PLAY3] Offer UI ready (mobile:", IS_MOBILE, ")")
