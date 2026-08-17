require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ui/framework/CUI_Framework"
require "MSR_UpgradeData"
require "MSR_PlayerMessage"
require "MSR_InventoryHooks"
require "MSR_UpgradeItemCache"

---@class MSR_UpgradeWindow : ISPanel
---@field player IsoPlayer
---@field playerNum integer
---@field padding number
---@field headerHeight number
---@field stripHeight number
---@field selectedUpgrade any
---@field selectedLevel any
---@field upgradeCards MSR_CardList
---@field upgradeDetails any
---@field requiredItems any
---@field customizationPanel MSR_CustomizationPanel
---@field echoPanel MSR_EchoPanel
---@field echoTabButton ISButton
---@field upgradesTabButton ISButton
---@field customizationTabButton ISButton
---@field activeTab string
---@field tabHeight number
---@field closeButton ISButton
---@field resizeWidget ISResizeWidget
---@field _lastRefreshTime number
---@field _refreshThrottleMs number
---@field _inventoryChangeHandler function
---@field _relic any
---@field _closeDistance number
---@field _pendingUpgrade boolean
---@field _pendingUpgradeOperationId string|nil
---@field _pendingUpgradeTransactionId string|nil
---@field _pendingUpgradeStartedAt number|nil
MSR_UpgradeWindow = ISPanel:derive("MSR_UpgradeWindow")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local Config = require "ui/framework/CUI_Config"
local Theme = require "ui/MSR_Theme"
local Widgets = require "ui/MSR_Widgets"
local RELIC_UI_TEXTURE = getTexture("media/ui/SacredCore_128x160.png") --[[@as Texture]]
local UPGRADE_RESPONSE_TIMEOUT_SECONDS = 15

MSR_UpgradeWindow.WINDOW_WIDTH = math.floor(FONT_HGT_SMALL * 55)
MSR_UpgradeWindow.WINDOW_HEIGHT = math.floor(FONT_HGT_SMALL * 39)
MSR_UpgradeWindow.MIN_WIDTH = math.floor(FONT_HGT_SMALL * 45)
MSR_UpgradeWindow.MIN_HEIGHT = math.floor(FONT_HGT_SMALL * 32)
-- Two panes: the card list answers "what is there and can I afford it",
-- the details pane answers "what exactly do I get and what does it cost".
MSR_UpgradeWindow.CARDS_WIDTH_RATIO = 0.36
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
    MSR.UpgradeItemCache.setPlayer(player)
    o.padding = Config.padding
    o.headerHeight = Config.headerHeight
    o.selectedUpgrade = nil
    o.selectedLevel = nil
    o.upgradeCards = nil
    o.upgradeDetails = nil
    o.requiredItems = nil
    o.customizationPanel = nil
    o.echoPanel = nil
    o.activeTab = "echo"
    o.tabHeight = math.floor(FONT_HGT_MEDIUM * 1.8)
    -- Echo balance lives in a strip under the title bar: it is the currency for
    -- upgrades and buildables too, so it must be readable from every tab.
    o.stripHeight = math.floor(FONT_HGT_MEDIUM * 2.4)
    o.moveWithMouse = true
    o.resizable = true
    o.drawFrame = false
    
    o._lastRefreshTime = 0
    o._refreshThrottleMs = 100
    o._inventoryChangeHandler = nil
    o._pendingUpgrade = false  -- Guard against fast double-clicks
    o._pendingUpgradeOperationId = nil
    o._pendingUpgradeTransactionId = nil
    o._pendingUpgradeStartedAt = nil
    
    -- Store relic object for proximity check (same pattern as ISBaseEntityWindow)
    o._relic = relic
    o._closeDistance = 3  -- tiles
    
    return o
end

function MSR_UpgradeWindow:initialise()
    ISPanel.initialise(self)
    self:setWantKeyEvents(true)
end

function MSR_UpgradeWindow:tabTop()
    return self.headerHeight + self.stripHeight + self.padding
end

function MSR_UpgradeWindow:contentTop()
    return self:tabTop() + self.tabHeight + self.padding
end

function MSR_UpgradeWindow:createChildren()
    local tabY = self:tabTop()
    local tabWidth = math.floor((self.width - self.padding * 4) / 3)
    self.echoTabButton = ISButton:new(
        self.padding, tabY, tabWidth, self.tabHeight,
        getText("UI_RefugeTab_Echo"), self, self.onEchoTabClick
    )
    self.echoTabButton:initialise()
    self:addChild(self.echoTabButton)

    self.upgradesTabButton = ISButton:new(
        self.padding * 2 + tabWidth, tabY, tabWidth, self.tabHeight,
        getText("UI_RefugeTab_Upgrades"), self, self.onUpgradesTabClick
    )
    self.upgradesTabButton:initialise()
    self:addChild(self.upgradesTabButton)

    self.customizationTabButton = ISButton:new(
        self.padding * 3 + tabWidth * 2, tabY, tabWidth, self.tabHeight,
        getText("UI_RefugeTab_Customization"), self, self.onCustomizationTabClick
    )
    self.customizationTabButton:initialise()
    self:addChild(self.customizationTabButton)

    for _, tabButton in ipairs({ self.echoTabButton, self.upgradesTabButton,
                                 self.customizationTabButton }) do
        Theme.styleButton(tabButton)
        tabButton:setFont(UIFont.Medium)
    end

    local contentY = self:contentTop()
    local contentHeight = self.height - contentY - self.padding
    local cardsWidth = math.floor((self.width - self.padding * 3) * self.CARDS_WIDTH_RATIO)
    local detailsWidth = self.width - cardsWidth - self.padding * 3

    local MSR_EchoPanel = require "MSR_EchoPanel"
    self.echoPanel = MSR_EchoPanel:new(
        self.padding,
        contentY,
        self.width - self.padding * 2,
        contentHeight,
        self
    )
    self.echoPanel:initialise()
    self:addChild(self.echoPanel)

    local MSR_CardList = require "ui/MSR_CardList"
    self.upgradeCards = MSR_CardList:new(
        self.padding,
        contentY,
        cardsWidth,
        contentHeight,
        self,
        function(window, id) window:selectUpgrade(id) end
    )
    self.upgradeCards:initialise()
    self:addChild(self.upgradeCards)

    local SRU_UpgradeDetails = require "SRU_UpgradeDetails"
    self.upgradeDetails = SRU_UpgradeDetails:new(
        self.padding * 2 + cardsWidth,
        contentY,
        detailsWidth,
        contentHeight,
        self
    )
    self.upgradeDetails:initialise()
    self:addChild(self.upgradeDetails)

    local MSR_CustomizationPanel = require "MSR_CustomizationPanel"
    self.customizationPanel = MSR_CustomizationPanel:new(
        self.padding,
        contentY,
        self.width - self.padding * 2,
        contentHeight,
        self
    )
    self.customizationPanel:initialise()
    self:addChild(self.customizationPanel)
    
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
    self:showTab("echo")
    self:registerInventoryListener()
end

function MSR_UpgradeWindow:showTab(tabName)
    self.activeTab = tabName == "customization" and "customization"
        or (tabName == "upgrades" and "upgrades" or "echo")
    local showUpgrades = self.activeTab == "upgrades"
    local showEcho = self.activeTab == "echo"

    if self.upgradeCards then self.upgradeCards:setVisible(showUpgrades) end
    if self.upgradeDetails then self.upgradeDetails:setVisible(showUpgrades) end
    if self.customizationPanel then
        self.customizationPanel:setVisible(self.activeTab == "customization")
        if self.activeTab == "customization" then self.customizationPanel:refresh() end
    end
    if self.echoPanel then
        self.echoPanel:setVisible(showEcho)
        if showEcho then self.echoPanel:refresh() end
    end

    -- The active tab takes the content panel's fill so it reads as attached to
    -- the page; prerender then draws the accent line along its top edge.
    local function paintTab(button, isActive)
        if not button then return end
        local fill = isActive and Theme.color.panel or Theme.color.rowMuted
        local border = isActive and Theme.color.border or Theme.color.divider
        button.backgroundColor = { r = fill.r, g = fill.g, b = fill.b, a = fill.a }
        button.borderColor = { r = border.r, g = border.g, b = border.b, a = border.a }
    end
    paintTab(self.echoTabButton, showEcho)
    paintTab(self.upgradesTabButton, showUpgrades)
    paintTab(self.customizationTabButton, self.activeTab == "customization")
end

function MSR_UpgradeWindow:onEchoTabClick()
    self:showTab("echo")
end

function MSR_UpgradeWindow:onUpgradesTabClick()
    self:showTab("upgrades")
end

function MSR_UpgradeWindow:onCustomizationTabClick()
    self:showTab("customization")
end

function MSR_UpgradeWindow:registerInventoryListener()
    if self._inventoryChangeHandler then return end
    
    local window = self
    self._inventoryChangeHandler = function(_actionType, _items, _state)
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
    MSR.UpgradeItemCache.invalidate(self.player)
    self:refreshUpgradeList()          -- card states track the inventory
    self:refreshCurrentUpgrade()
    if self.customizationPanel then self.customizationPanel:refresh() end
    if self.echoPanel and not self.echoPanel.pending then self.echoPanel:refresh() end
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
    
    local contentY = self:contentTop()
    local contentHeight = newHeight - contentY - self.padding
    local cardsWidth = math.floor((newWidth - self.padding * 3) * self.CARDS_WIDTH_RATIO)
    local detailsWidth = newWidth - cardsWidth - self.padding * 3
    local tabWidth = math.floor((newWidth - self.padding * 4) / 3)
    if self.echoTabButton then
        self.echoTabButton:setX(self.padding)
        self.echoTabButton:setWidth(tabWidth)
    end
    if self.upgradesTabButton then
        self.upgradesTabButton:setX(self.padding * 2 + tabWidth)
        self.upgradesTabButton:setWidth(tabWidth)
    end
    if self.customizationTabButton then
        self.customizationTabButton:setX(self.padding * 3 + tabWidth * 2)
        self.customizationTabButton:setWidth(tabWidth)
    end
    if self.echoPanel then
        self.echoPanel:setX(self.padding)
        self.echoPanel:setY(contentY)
        self.echoPanel:setWidth(newWidth - self.padding * 2)
        self.echoPanel:setHeight(contentHeight)
        self.echoPanel:onResize()
    end
    if self.upgradeCards then
        self.upgradeCards:setX(self.padding)
        self.upgradeCards:setY(contentY)
        self.upgradeCards:setWidth(cardsWidth)
        self.upgradeCards:setHeight(contentHeight)
        self.upgradeCards:onResize()
    end

    if self.upgradeDetails then
        self.upgradeDetails:setX(self.padding * 2 + cardsWidth)
        self.upgradeDetails:setY(contentY)
        self.upgradeDetails:setWidth(detailsWidth)
        self.upgradeDetails:setHeight(contentHeight)
        if self.upgradeDetails.onResize then
            self.upgradeDetails:onResize()
        end
    end

    if self.customizationPanel then
        self.customizationPanel:setX(self.padding)
        self.customizationPanel:setY(contentY)
        self.customizationPanel:setWidth(newWidth - self.padding * 2)
        self.customizationPanel:setHeight(contentHeight)
        self.customizationPanel:onResize()
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
    if self.upgradeCards then
        self.upgradeCards:setSelected(upgradeId)
    end
end

--- One card per upgrade, grouped by category. State is precomputed here so the
--- list itself stays a dumb renderer.
function MSR_UpgradeWindow:buildUpgradeCards()
    local cards = {}
    local refugeData = MSR.Data.GetRefugeData(self.player)
    MSR.UpgradeItemCache.setPlayer(self.player)

    for _, category in ipairs(MSR.UpgradeData.getCategories()) do
        local group = getText("UI_RefugeUpgrade_Category_" .. category) or category
        for _, upgrade in ipairs(MSR.UpgradeData.getUpgradesByCategory(category)) do
            local currentLevel = MSR.UpgradeData.getPlayerUpgradeLevel(self.player, upgrade.id)
            local maxLevel = upgrade.maxLevel or 1
            local state, note
            if currentLevel >= maxLevel then
                state, note = "max", nil
            elseif not MSR.UpgradeData.isUpgradeUnlocked(self.player, upgrade.id) then
                state, note = "locked", getText("UI_Refuge_CardLocked")
            else
                local echoCost = MSR.UpgradeData.getNextLevelEchoCost(self.player, upgrade.id) or 0
                local hasEcho = MSR.Echo.CanSpend(refugeData, echoCost)
                local hasItems = true
                for _, req in ipairs(MSR.UpgradeData.getNextLevelRequirements(self.player, upgrade.id) or {}) do
                    if MSR.UpgradeItemCache.getCountForRequirement(req) < (req.count or 1) then
                        hasItems = false
                        break
                    end
                end
                state = (hasEcho and hasItems) and "ready" or "poor"
                note = getText("UI_Refuge_CostEcho", Theme.formatNumber(echoCost))
            end
            cards[#cards + 1] = {
                id = upgrade.id,
                group = group,
                icon = getTexture(upgrade.icon),
                title = getText(upgrade.name) or upgrade.name or upgrade.id,
                note = note,
                state = state,
                pips = { currentLevel, maxLevel },
            }
        end
    end
    return cards
end

function MSR_UpgradeWindow:refreshUpgradeList()
    if not self.upgradeCards then return end
    self.upgradeCards:setCards(self:buildUpgradeCards())
    if self.selectedUpgrade then
        self.upgradeCards:setSelected(self.selectedUpgrade.id)
    else
        -- Open with something on screen instead of an empty details pane.
        local firstId = self.upgradeCards:firstSelectableId()
        if firstId then self:selectUpgrade(firstId) end
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

function MSR_UpgradeWindow:setUpgradePending(pending, operationId, transactionId)
    self._pendingUpgrade = pending == true
    if self._pendingUpgrade then
        self._pendingUpgradeOperationId = operationId or self._pendingUpgradeOperationId
        self._pendingUpgradeTransactionId = transactionId or self._pendingUpgradeTransactionId
        self._pendingUpgradeStartedAt = self._pendingUpgradeStartedAt or K.time()
    else
        self._pendingUpgradeOperationId = nil
        self._pendingUpgradeTransactionId = nil
        self._pendingUpgradeStartedAt = nil
    end
    if self.upgradeDetails and self.upgradeDetails.upgradeButton then
        self.upgradeDetails.upgradeButton:setEnable(not self._pendingUpgrade and self:canCurrentlyUpgrade())
    end
end

function MSR_UpgradeWindow:isUpgradeResponseCurrent(operationId)
    if not MSR.Env.isMultiplayerClient() or not self._pendingUpgrade then return true end
    return type(operationId) == "string" and operationId == self._pendingUpgradeOperationId
end

function MSR_UpgradeWindow:onUpgradeTransactionTimeout(transactionId)
    if not self._pendingUpgrade or transactionId ~= self._pendingUpgradeTransactionId then return end
    self:setUpgradePending(false)
    self:refreshUpgradeList()
    self:refreshCurrentUpgrade()
end

function MSR_UpgradeWindow:onUpgradeClick()
    if not self.selectedUpgrade then return end
    if self._pendingUpgrade then return end  -- Guard against double-click
    
    self:setUpgradePending(true)
    
    local success, err, operationId, transactionId = MSR.UpgradeLogic.purchaseUpgrade(
        self.player,
        self.selectedUpgrade.id,
        self.selectedLevel
    )
    
    if not success then
        self:setUpgradePending(false)
        if self.player then
            local PM = MSR.PlayerMessage
            if err == PM.BASEMENT_STAIRS_BLOCKED then
                MSR.UpgradeLogic.showBasementStairsBlockedAlert()
            elseif err then
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
    elseif not operationId then
        self:setUpgradePending(false)
        MSR.PlayerMessage.Say(self.player, MSR.PlayerMessage.UPGRADE_FAILED)
    else
        self:setUpgradePending(true, operationId, transactionId)
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
    MSR._basementStairsAlertShown = nil
    MSR.UpgradeItemCache.invalidate(self.player)
end

---@diagnostic disable-next-line: unused -- ISPanel override required by PZ.
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

function MSR_UpgradeWindow:currentEchoBalance()
    local refugeData = MSR.Data and MSR.Data.GetRefugeData and MSR.Data.GetRefugeData(self.player)
    if not refugeData or not MSR.Echo then return 0, 1 end
    return MSR.Echo.GetBalance(refugeData), MSR.Echo.GetCapacity()
end

function MSR_UpgradeWindow:drawTitleBar()
    Theme.box(self, 0, 0, self.width, self.headerHeight, Theme.color.titleBg, Theme.color.border)

    local iconSize = math.floor(self.headerHeight * 0.7)
    local iconY = math.floor((self.headerHeight - iconSize) / 2)
    self:drawTextureScaledAspect(
        RELIC_UI_TEXTURE, self.padding, iconY, iconSize, iconSize, 1, 1, 1, 1)

    local title = getText("UI_RefugeManagement_Title") or "Manage Spatial Refuge"
    Theme.text(self, title, self.padding * 2 + iconSize,
        math.floor((self.headerHeight - FONT_HGT_LARGE) / 2), Theme.color.text, UIFont.Large)
end

--- Balance and capacity, plus - while the absorption tab is open - a ghost
--- segment showing what the current selection would add.
function MSR_UpgradeWindow:drawEchoStrip()
    local y = self.headerHeight
    Theme.box(self, 0, y, self.width, self.stripHeight, Theme.color.stripBg, Theme.color.border)

    local balance, capacity = self:currentEchoBalance()
    local preview = 0.0
    if self.activeTab == "echo" and self.echoPanel and self.echoPanel.selectedTotal then
        preview = self.echoPanel:selectedTotal()
    end

    local x = self.padding
    local iconSize = math.floor(self.stripHeight * 0.62)
    if self.echoPanel and self.echoPanel.echoTexture then
        self:drawTextureScaledAspect(self.echoPanel.echoTexture, x,
            y + math.floor((self.stripHeight - iconSize) / 2), iconSize, iconSize, 1, 1, 1, 1)
        x = x + iconSize + self.padding
    end

    local labelY = y + math.floor(self.stripHeight * 0.16)
    Theme.text(self, getText("UI_Echo_Title"), x, labelY, Theme.color.brassHi, UIFont.Small)

    local valueY = labelY + FONT_HGT_SMALL - 2
    local valueText = Theme.formatNumber(balance)
    Theme.text(self, valueText, x, valueY, Theme.color.accentHi, UIFont.Medium)

    local capText = "/ " .. Theme.formatNumber(capacity)
    local valueW = getTextManager():MeasureStringX(UIFont.Medium, valueText)
    Theme.text(self, capText, x + valueW + self.padding, valueY + 2,
        Theme.color.textMuted, UIFont.Small)

    local barX = x + valueW + self.padding
        + getTextManager():MeasureStringX(UIFont.Small, capText) + self.padding * 2
    local barW = self.width - barX - self.padding
    if barW > FONT_HGT_SMALL * 4 then
        local barH = math.max(10, math.floor(self.stripHeight * 0.32))
        Widgets.resourceBar(self, barX, y + math.floor((self.stripHeight - barH) / 2),
            barW, barH, balance, capacity, preview)
    end
end

function MSR_UpgradeWindow:prerender()
    Theme.box(self, 0, 0, self.width, self.height, Theme.color.windowBg)
    self:drawTitleBar()
    self:drawEchoStrip()

    local frameY = self:contentTop() - self.padding
    Theme.box(self, self.padding, frameY, self.width - self.padding * 2,
        self.height - frameY - self.padding, Theme.color.panel, Theme.color.border)

    local activeButton = self.echoTabButton
    if self.activeTab == "upgrades" then
        activeButton = self.upgradesTabButton
    elseif self.activeTab == "customization" then
        activeButton = self.customizationTabButton
    end
    if activeButton then
        Theme.fill(self, activeButton:getX(), activeButton:getY(),
            activeButton:getWidth(), 2, Theme.color.accent)
        Theme.fill(self, activeButton:getX() + 1, frameY,
            activeButton:getWidth() - 2, 1, Theme.color.panel)
    end

    Widgets.windowFrame(self, self.width, self.height)
end

---@diagnostic disable-next-line: unused -- ISPanel override required by PZ.
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

    if self._pendingUpgrade
        and self._pendingUpgradeStartedAt
        and K.time() - self._pendingUpgradeStartedAt > UPGRADE_RESPONSE_TIMEOUT_SECONDS
    then
        local transactionId = self._pendingUpgradeTransactionId
        if transactionId then
            MSR.Transaction.Rollback(self.player, transactionId)
            MSR.PlayerMessage.Say(self.player, MSR.PlayerMessage.ACTION_TIMEOUT_ITEMS_UNLOCKED)
        else
            MSR.PlayerMessage.Say(self.player, MSR.PlayerMessage.UPGRADE_FAILED)
        end
        self:setUpgradePending(false)
        MSR.Data.RequestModDataFromServer(true)
        self:refreshUpgradeList()
        self:refreshCurrentUpgrade()
    end
end

return MSR_UpgradeWindow

