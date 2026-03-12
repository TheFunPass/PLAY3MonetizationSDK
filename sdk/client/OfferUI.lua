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
local POPUP_WIDTH = IS_MOBILE and 0.85 or 0.3  -- 85% on mobile, 30% on desktop
local POPUP_MAX_WIDTH = 400
local POPUP_HEIGHT = IS_MOBILE and 0.35 or 0.3  -- Slightly taller on mobile
local PADDING = IS_MOBILE and 16 or 20
local TITLE_SIZE = IS_MOBILE and 18 or 20
local PRODUCT_SIZE = IS_MOBILE and 22 or 26
local MESSAGE_SIZE = IS_MOBILE and 14 or 16
local PRICE_SIZE = IS_MOBILE and 20 or 24
local BUTTON_TEXT_SIZE = IS_MOBILE and 16 or 18
local BUTTON_HEIGHT = IS_MOBILE and 44 or 40

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

-- Main popup frame - centered with scale sizing
local popup = Instance.new("Frame")
popup.Name = "Popup"
popup.AnchorPoint = Vector2.new(0.5, 0.5)
popup.Position = UDim2.new(0.5, 0, 0.5, 0)
popup.Size = UDim2.new(POPUP_WIDTH, 0, POPUP_HEIGHT, 0)
popup.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
popup.BorderSizePixel = 0
popup.Visible = false
popup.ZIndex = 101
popup.Parent = screenGui

-- Constrain max width
local sizeConstraint = Instance.new("UISizeConstraint")
sizeConstraint.MaxSize = Vector2.new(POPUP_MAX_WIDTH, 300)
sizeConstraint.Parent = popup

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 16)
corner.Parent = popup

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(80, 120, 255)
stroke.Thickness = 2
stroke.Parent = popup

-- Add padding
local uiPadding = Instance.new("UIPadding")
uiPadding.PaddingTop = UDim.new(0, PADDING)
uiPadding.PaddingBottom = UDim.new(0, PADDING)
uiPadding.PaddingLeft = UDim.new(0, PADDING)
uiPadding.PaddingRight = UDim.new(0, PADDING)
uiPadding.Parent = popup

-- Layout for content
local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)
layout.Parent = popup

-- Title - "Limited Time Offer"
local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, 0, 0, TITLE_SIZE + 4)
title.BackgroundTransparency = 1
title.Text = "Limited Time Offer"
title.TextColor3 = Color3.fromRGB(80, 180, 255)
title.TextSize = TITLE_SIZE
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Center
title.LayoutOrder = 1
title.Parent = popup

-- Product name
local productName = Instance.new("TextLabel")
productName.Name = "ProductName"
productName.Size = UDim2.new(1, 0, 0, PRODUCT_SIZE + 8)
productName.BackgroundTransparency = 1
productName.Text = "Product Name"
productName.TextColor3 = Color3.new(1, 1, 1)
productName.TextSize = PRODUCT_SIZE
productName.Font = Enum.Font.GothamBold
productName.TextXAlignment = Enum.TextXAlignment.Center
productName.TextTruncate = Enum.TextTruncate.AtEnd
productName.LayoutOrder = 2
productName.Parent = popup

-- Message
local message = Instance.new("TextLabel")
message.Name = "Message"
message.Size = UDim2.new(1, 0, 0, MESSAGE_SIZE * 2 + 8)
message.BackgroundTransparency = 1
message.Text = "Limited time offer just for you!"
message.TextColor3 = Color3.fromRGB(180, 180, 180)
message.TextSize = MESSAGE_SIZE
message.Font = Enum.Font.Gotham
message.TextXAlignment = Enum.TextXAlignment.Center
message.TextWrapped = true
message.LayoutOrder = 3
message.Parent = popup

-- Price
local price = Instance.new("TextLabel")
price.Name = "Price"
price.Size = UDim2.new(1, 0, 0, PRICE_SIZE + 8)
price.BackgroundTransparency = 1
price.Text = "R$ 99"
price.TextColor3 = Color3.fromRGB(0, 220, 100)
price.TextSize = PRICE_SIZE
price.Font = Enum.Font.GothamBold
price.TextXAlignment = Enum.TextXAlignment.Center
price.LayoutOrder = 4
price.Parent = popup

-- Button container
local buttonContainer = Instance.new("Frame")
buttonContainer.Name = "Buttons"
buttonContainer.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT)
buttonContainer.BackgroundTransparency = 1
buttonContainer.LayoutOrder = 5
buttonContainer.Parent = popup

local buttonLayout = Instance.new("UIListLayout")
buttonLayout.FillDirection = Enum.FillDirection.Horizontal
buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
buttonLayout.Padding = UDim.new(0, 12)
buttonLayout.Parent = buttonContainer

-- Buy button
local buyBtn = Instance.new("TextButton")
buyBtn.Name = "BuyButton"
buyBtn.Size = UDim2.new(0.45, 0, 1, 0)
buyBtn.BackgroundColor3 = Color3.fromRGB(0, 180, 80)
buyBtn.Text = "Buy Now"
buyBtn.TextColor3 = Color3.new(1, 1, 1)
buyBtn.TextSize = BUTTON_TEXT_SIZE
buyBtn.Font = Enum.Font.GothamBold
buyBtn.AutoButtonColor = true
buyBtn.Parent = buttonContainer

local buyCorner = Instance.new("UICorner")
buyCorner.CornerRadius = UDim.new(0, 8)
buyCorner.Parent = buyBtn

-- Dismiss button
local dismissBtn = Instance.new("TextButton")
dismissBtn.Name = "DismissButton"
dismissBtn.Size = UDim2.new(0.45, 0, 1, 0)
dismissBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
dismissBtn.Text = "No Thanks"
dismissBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
dismissBtn.TextSize = BUTTON_TEXT_SIZE
dismissBtn.Font = Enum.Font.GothamBold
dismissBtn.AutoButtonColor = true
dismissBtn.Parent = buttonContainer

local dismissCorner = Instance.new("UICorner")
dismissCorner.CornerRadius = UDim.new(0, 8)
dismissCorner.Parent = dismissBtn

-- Current offer tracking
local currentOffer = nil
local fullSize = popup.Size

-- Show popup
local function showPopup(offer)
	currentOffer = offer

	productName.Text = offer.name or "Special Item"
	message.Text = offer.message or "Limited time offer just for you!"
	price.Text = "R$ " .. (offer.price or "??")

	overlay.BackgroundTransparency = 1
	popup.Visible = true
	popup.Size = UDim2.new(fullSize.X.Scale, fullSize.X.Offset, 0, 0)

	-- Animate in
	local overlayTween = TweenService:Create(overlay, TweenInfo.new(0.3), {BackgroundTransparency = 0.6})
	local popupTween = TweenService:Create(popup, TweenInfo.new(0.3, Enum.EasingStyle.Back), {Size = fullSize})

	overlayTween:Play()
	popupTween:Play()
end

-- Hide popup (optionally send result to server)
local function hidePopup(sendResult)
	if not currentOffer then return end

	local offer = currentOffer
	currentOffer = nil

	-- Animate out
	local overlayTween = TweenService:Create(overlay, TweenInfo.new(0.2), {BackgroundTransparency = 1})
	local popupTween = TweenService:Create(popup, TweenInfo.new(0.2), {Size = UDim2.new(fullSize.X.Scale, fullSize.X.Offset, 0, 0)})

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
		-- Prompt the real Roblox purchase dialog
		MarketplaceService:PromptProductPurchase(player, currentOffer.productId)
	end
	-- Hide popup without sending result (ProcessReceipt handles purchase tracking)
	hidePopup(false)
end)

-- Dismiss button: tell server player dismissed
dismissBtn.MouseButton1Click:Connect(function()
	hidePopup(true)  -- Send "dismissed" to server
end)

-- Tapping overlay dismisses
overlay.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		hidePopup(true)  -- Send "dismissed" to server
	end
end)

-- Listen for offers from server
showOfferEvent.OnClientEvent:Connect(function(offer)
	showPopup(offer)
end)

print("[PLAY3] Offer UI ready (mobile:", IS_MOBILE, ")")
