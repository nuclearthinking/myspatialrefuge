require "ISUI/ISPanel"
require "ui/framework/CUI_Framework"
require "shared/MSR_UpgradeData"
require "shared/MSR_PlayerMessage"
require "MSR_InventoryHooks"

---@class MSR_UpgradeWindow : ISPanel
---@field player IsoPlayer
---@field playerNum integer
---@field padding number
---@field headerHeight number
---@field selectedUpgrade any
---@field selectedLevel any
---@field upgradeGrid any
---@field upgradeDetails any
---@field requiredItems any
---@field ingredientList any
---@field closeButton ISButton
---@field resizeWidget ISResizeWidget
---@field _lastRefreshTime number
---@field _refreshThrottleMs number
---@field _inventoryChangeHandler function
---@field _relic any
---@field _closeDistance number
MSR_UpgradeWindow = ISPanel:derive("MSR_UpgradeWindow")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local Config = require "ui/framework/CUI_Config"

MSR_UpgradeWindow.WINDOW_WIDTH = math.floor(FONT_HGT_SMALL * 55)
MSR_UpgradeWindow.WINDOW_HEIGHT = math.floor(FONT_HGT_SMALL * 35)
MSR_UpgradeWindow.MIN_WIDTH = math.floor(FONT_HGT_SMALL * 45)
MSR_UpgradeWindow.MIN_HEIGHT = math.floor(FONT_HGT_SMALL * 28)
MSR_UpgradeWindow.GRID_WIDTH_RATIO = 0.35
MSR_UpgradeWindow.DETAILS_WIDTH_RATIO = 0.40
MSR_UpgradeWindow.INGREDIENTS_WIDTH_RATIO = 0.25
MSR_UpgradeWindow.instance = nil

function MSR_UpgradeWindow.Open(player, relic)
    if MSR_UpgradeWindow.instance and MSR_UpgradeWindow.instance:isVisible() then
        MSR_UpgradeWindow.instance:close()
        return
    end
    
    local playerObj = player
    if type(player) == "number" then
        playerObj = getSpecificPlayer(player)
    end
    
    if not playerObj then return end
    
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local w = MSR_UpgradeWindow.WINDOW_WIDTH
    local h = MSR_UpgradeWindow.WINDOW_HEIGHT
    local x = (screenW - w) / 2
    local y = (screenH - h) / 2
    
    local window = MSR_UpgradeWindow:new(x, y, w, h, playerObj, relic)
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    
    MSR_UpgradeWindow.instance = window
    
    return window
end

function MSR_UpgradeWindow.Close()
    if MSR_UpgradeWindow.instance then
        MSR_UpgradeWindow.instance:close()
    end
end

function MSR_UpgradeWindow:new(x, y, width, height, player, relic)
    local o = ISPanel:new(x, y, width, height) --[[@as MSR_UpgradeWindow]]
    setmetatable(o, self)
    self.__index = self
    
    o.player = player
    o.playerNum = player:getPlayerNum()
    o.padding = Config.padding
    o.headerHeight = Config.headerHeight
    o.selectedUpgrade = nil
    o.selectedLevel = nil
    o.upgradeGrid = nil
    o.upgradeDetails = nil
    o.requiredItems = nil
    o.ingredientList = nil
    o.moveWithMouse = true
    o.resizable = true
    o.drawFrame = false
    
    o._lastRefreshTime = 0
    o._refreshThrottleMs = 100
    o._inventoryChangeHandler = nil
    o._pendingUpgrade = false  -- Guard against fast double-clicks
    
    -- Store relic object for proximity check (same pattern as ISBaseEntityWindow)
    o._relic = relic
    o._closeDistance = 3  -- tiles
    
    return o
end

function MSR_UpgradeWindow:initialise()
    ISPanel.initialise(self)
    self:setWantKeyEvents(true)
end

function MSR_UpgradeWindow:createChildren()
    local contentY = self.headerHeight
    local contentHeight = self.height - self.headerHeight - self.padding
    local gridWidth = math.floor((self.width - self.padding * 4) * self.GRID_WIDTH_RATIO)
    local detailsWidth = math.floor((self.width - self.padding * 4) * self.DETAILS_WIDTH_RATIO)
    local ingredientsWidth = self.width - gridWidth - detailsWidth - self.padding * 4
    
    local SRU_UpgradeGrid = require "SRU_UpgradeGrid"
    self.upgradeGrid = SRU_UpgradeGrid:new(
        self.padding,
        contentY,
        gridWidth,
        contentHeight,
        self
    )
    self.upgradeGrid:initialise()
    self:addChild(self.upgradeGrid)
    
    local SRU_UpgradeDetails = require "SRU_UpgradeDetails"
    self.upgradeDetails = SRU_UpgradeDetails:new(
        self.padding * 2 + gridWidth,
        contentY,
        detailsWidth,
        contentHeight,
        self
    )
    self.upgradeDetails:initialise()
    self:addChild(self.upgradeDetails)
    
    local SRU_IngredientList = require "SRU_IngredientList"
    self.ingredientList = SRU_IngredientList:new(
        self.padding * 3 + gridWidth + detailsWidth,
        contentY,
        ingredientsWidth,
        contentHeight,
        self
    )
    self.ingredientList:initialise()
    self:addChild(self.ingredientList)
    
    local closeSize = math.floor(FONT_HGT_MEDIUM * 1.2)
    self.closeButton = ISButton:new(
        self.width - closeSize - self.padding,
        (self.headerHeight - closeSize) / 2,
        closeSize,
        closeSize,
        "X",
        self,
        self.onCloseClick
    )
    self.closeButton:initialise()
    self.closeButton.borderColor = {r=0, g=0, b=0, a=0}
    self.closeButton.backgroundColor = {r=0, g=0, b=0, a=0}
    self.closeButton.backgroundColorMouseOver = {r=0.8, g=0.2, b=0.2, a=0.8}
    self:addChild(self.closeButton)
    
    self:createResizeWidget()
    self:refreshUpgradeList()
    self:registerInventoryListener()
end

function MSR_UpgradeWindow:registerInventoryListener()
    if self._inventoryChangeHandler then return end
    
    local window = self
    self._inventoryChangeHandler = function(actionType, items, state)
        if not window:isVisible() then return end
        window:onInventoryChanged()
    end
    
    if Events.MSR_OnInventoryChange then
        Events.MSR_OnInventoryChange.Add(self._inventoryChangeHandler)
    end
end

function MSR_UpgradeWindow:unregisterInventoryListener()
    if self._inventoryChangeHandler then
        if Events.MSR_OnInventoryChange then
            Events.MSR_OnInventoryChange.Remove(self._inventoryChangeHandler)
        end
        self._inventoryChangeHandler = nil
    end
end

function MSR_UpgradeWindow:onInventoryChanged()
    local now = K.timeMs()
    if (now - self._lastRefreshTime) < self._refreshThrottleMs then return end
    self._lastRefreshTime = now
    self:refreshCurrentUpgrade()
end

function MSR_UpgradeWindow:createResizeWidget()
    local resizeSize = math.floor(FONT_HGT_SMALL * 0.8)
    self.resizeWidget = ISResizeWidget:new(
        self.width - resizeSize - 2,
        self.height - resizeSize - 2,
        resizeSize,
        resizeSize,
        self,
        false
    )
    self.resizeWidget.anchorRight = true
    self.resizeWidget.anchorBottom = true
    self.resizeWidget:initialise()
    self.resizeWidget:instantiate()
    self.resizeWidget.resizeFunction = function(target, newWidth, newHeight)
        target:onResize(newWidth, newHeight)
    end
    self:addChild(self.resizeWidget)
end

function MSR_UpgradeWindow:onResize(newWidth, newHeight)
    newWidth = math.max(self.MIN_WIDTH, newWidth)
    newHeight = math.max(self.MIN_HEIGHT, newHeight)
    
    self:setWidth(newWidth)
    self:setHeight(newHeight)
    
    local contentY = self.headerHeight
    local contentHeight = newHeight - self.headerHeight - self.padding
    local gridWidth = math.floor((newWidth - self.padding * 4) * self.GRID_WIDTH_RATIO)
    local detailsWidth = math.floor((newWidth - self.padding * 4) * self.DETAILS_WIDTH_RATIO)
    local ingredientsWidth = newWidth - gridWidth - detailsWidth - self.padding * 4
    if self.upgradeGrid then
        self.upgradeGrid:setX(self.padding)
        self.upgradeGrid:setY(contentY)
        self.upgradeGrid:setWidth(gridWidth)
        self.upgradeGrid:setHeight(contentHeight)
        if self.upgradeGrid.onResize then
            self.upgradeGrid:onResize()
        end
    end
    
    if self.upgradeDetails then
        self.upgradeDetails:setX(self.padding * 2 + gridWidth)
        self.upgradeDetails:setY(contentY)
        self.upgradeDetails:setWidth(detailsWidth)
        self.upgradeDetails:setHeight(contentHeight)
        if self.upgradeDetails.onResize then
            self.upgradeDetails:onResize()
        end
    end
    
    if self.ingredientList then
        self.ingredientList:setX(self.padding * 3 + gridWidth + detailsWidth)
        self.ingredientList:setY(contentY)
        self.ingredientList:setWidth(ingredientsWidth)
        self.ingredientList:setHeight(contentHeight)
        if self.ingredientList.onResize then
            self.ingredientList:onResize()
        end
    end
    
    if self.closeButton then
        self.closeButton:setX(newWidth - self.closeButton:getWidth() - self.padding)
    end
    
    if self.resizeWidget then
        local resizeSize = self.resizeWidget:getWidth()
        self.resizeWidget:setX(newWidth - resizeSize - 2)
        self.resizeWidget:setY(newHeight - resizeSize - 2)
    end
end

function MSR_UpgradeWindow:selectUpgrade(upgradeId)
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return end
    
    self.selectedUpgrade = upgrade
    self.selectedLevel = MSR.UpgradeData.getPlayerUpgradeLevel(self.player, upgradeId) + 1
    if self.selectedLevel > upgrade.maxLevel then
        self.selectedLevel = upgrade.maxLevel
    end
    if self.upgradeDetails then
        self.upgradeDetails:setUpgrade(upgrade, self.selectedLevel)
    end
    
    if self.ingredientList then
        local requirements = MSR.UpgradeData.getNextLevelRequirements(self.player, upgradeId)
        self.ingredientList:setRequirements(requirements or {})
    end
end

function MSR_UpgradeWindow:refreshUpgradeList()
    if self.upgradeGrid then
        self.upgradeGrid:refreshUpgrades()
    end
end

function MSR_UpgradeWindow:refreshCurrentUpgrade()
    if self.selectedUpgrade then
        self:selectUpgrade(self.selectedUpgrade.id)
    end
end

function MSR_UpgradeWindow:canCurrentlyUpgrade()
    if not self.selectedUpgrade then return false end
    local canUpgrade, _ = MSR.UpgradeLogic.canPurchaseUpgrade(self.player, self.selectedUpgrade.id, self.selectedLevel)
    return canUpgrade
end

function MSR_UpgradeWindow:setUpgradePending(pending)
    self._pendingUpgrade = pending
    if self.upgradeDetails and self.upgradeDetails.upgradeButton then
        self.upgradeDetails.upgradeButton:setEnable(not pending and self:canCurrentlyUpgrade())
    end
end

function MSR_UpgradeWindow:onUpgradeClick()
    if not self.selectedUpgrade then return end
    if self._pendingUpgrade then return end  -- Guard against double-click
    
    self:setUpgradePending(true)
    
    local success, err = MSR.UpgradeLogic.purchaseUpgrade(self.player, self.selectedUpgrade.id, self.selectedLevel)
    
    if not success then
        self:setUpgradePending(false)
        if self.player then
            local PM = MSR.PlayerMessage
            if err then
                PM.SayRaw(self.player, err)
            else
                PM.Say(self.player, PM.UPGRADE_FAILED)
            end
        end
    elseif not MSR.Env.isMultiplayerClient() then
        -- SP/Host: upgrade ran synchronously, reset pending and refresh now
        self:setUpgradePending(false)
        self:refreshUpgradeList()
        self:refreshCurrentUpgrade()
    end
    -- MP client: wait for server response (onUpgradeComplete)
end

function MSR_UpgradeWindow:onCloseClick()
    self:close()
end

function MSR_UpgradeWindow:close()
    self:unregisterInventoryListener()
    self:setVisible(false)
    self:removeFromUIManager()
    MSR_UpgradeWindow.instance = nil
end

function MSR_UpgradeWindow:isKeyConsumed(key)
    return key == Keyboard.KEY_ESCAPE
end

function MSR_UpgradeWindow:onKeyRelease(key)
    if key == Keyboard.KEY_ESCAPE then
        self:close()
        return true
    end
    return false
end

function MSR_UpgradeWindow:prerender()
    self:drawRect(0, 0, self.width, self.height, 0.95, 0.06, 0.05, 0.08)
    self:drawRect(0, 0, self.width, self.headerHeight, 1, 0.10, 0.08, 0.14)
    self:drawRectBorder(0, 0, self.width, self.headerHeight, 0.8, 0.30, 0.25, 0.38)
    
    local iconSize = math.floor(self.headerHeight * 0.7)
    local iconY = (self.headerHeight - iconSize) / 2
    local headerIcon = getTexture("media/ui/UpgradeArrow_32x32.png")
    
    if headerIcon then
        self:drawTextureScaledAspect(headerIcon, self.padding, iconY, iconSize, iconSize, 1, 1, 1, 1)
    else
        self:drawRect(self.padding, iconY, iconSize, iconSize, 0.6, 0.4, 0.3, 0.5)
    end
    
    local titleX = self.padding * 2 + iconSize
    local titleY = (self.headerHeight - FONT_HGT_LARGE) / 2
    local title = getText("UI_RefugeUpgrade_Title") or "Upgrade Spatial Refuge"
    self:drawText(title, titleX, titleY, 0.92, 0.90, 0.88, 1, UIFont.Large)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.30, 0.25, 0.38)
end

function MSR_UpgradeWindow:render() end

function MSR_UpgradeWindow:update()
    ISPanel.update(self)
    if not self.player then
        self:close()
        return
    end
    if not pcall(function() return self.player:getUsername() end) then
        self:close()
        return
    end
    
    -- Proximity check: close if player walked away from relic
    if self._relic and self.player.DistToProper then
        local ok, dist = pcall(function() return self.player:DistToProper(self._relic) end)
        if not ok or dist > self._closeDistance then
            self:close()
            return
        end
    end
end

return MSR_UpgradeWindow

