-- Spatial Refuge Upgrade Window
-- Main container for the upgrade system UI
-- Features three-panel layout: grid selector, details panel, ingredients list

require "ISUI/ISPanel"
require "ui/framework/CUI_Framework"
require "shared/SpatialRefugeUpgradeData"

SpatialRefugeUpgradeWindow = ISPanel:derive("SpatialRefugeUpgradeWindow")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

local Config = require "ui/framework/CUI_Config"

SpatialRefugeUpgradeWindow.WINDOW_WIDTH = math.floor(FONT_HGT_SMALL * 55)
SpatialRefugeUpgradeWindow.WINDOW_HEIGHT = math.floor(FONT_HGT_SMALL * 35)
SpatialRefugeUpgradeWindow.MIN_WIDTH = math.floor(FONT_HGT_SMALL * 45)
SpatialRefugeUpgradeWindow.MIN_HEIGHT = math.floor(FONT_HGT_SMALL * 28)

-- Layout proportions
SpatialRefugeUpgradeWindow.GRID_WIDTH_RATIO = 0.35
SpatialRefugeUpgradeWindow.DETAILS_WIDTH_RATIO = 0.40
SpatialRefugeUpgradeWindow.INGREDIENTS_WIDTH_RATIO = 0.25

-----------------------------------------------------------
-- Static Instance Management
-----------------------------------------------------------

SpatialRefugeUpgradeWindow.instance = nil

function SpatialRefugeUpgradeWindow.Open(player)
    if SpatialRefugeUpgradeWindow.instance and SpatialRefugeUpgradeWindow.instance:isVisible() then
        SpatialRefugeUpgradeWindow.instance:close()
        return
    end
    
    local playerObj = player
    if type(player) == "number" then
        playerObj = getSpecificPlayer(player)
    end
    
    if not playerObj then return end
    
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local w = SpatialRefugeUpgradeWindow.WINDOW_WIDTH
    local h = SpatialRefugeUpgradeWindow.WINDOW_HEIGHT
    local x = (screenW - w) / 2
    local y = (screenH - h) / 2
    
    local window = SpatialRefugeUpgradeWindow:new(x, y, w, h, playerObj)
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    
    SpatialRefugeUpgradeWindow.instance = window
    
    return window
end

function SpatialRefugeUpgradeWindow.Close()
    if SpatialRefugeUpgradeWindow.instance then
        SpatialRefugeUpgradeWindow.instance:close()
    end
end

-----------------------------------------------------------
-- Constructor
-----------------------------------------------------------

function SpatialRefugeUpgradeWindow:new(x, y, width, height, player)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.player = player
    o.playerNum = player:getPlayerNum()
    
    -- Layout
    o.padding = Config.padding
    o.headerHeight = Config.headerHeight
    
    -- State
    o.selectedUpgrade = nil
    o.selectedLevel = nil
    
    -- Panels (created in createChildren)
    o.upgradeGrid = nil
    o.upgradeDetails = nil
    o.requiredItems = nil
    o.ingredientList = nil
    
    -- Window features
    o.moveWithMouse = true
    o.resizable = true
    o.drawFrame = false
    
    return o
end

function SpatialRefugeUpgradeWindow:initialise()
    ISPanel.initialise(self)
    self:setWantKeyEvents(true)
end

-----------------------------------------------------------
-- Child Panel Creation
-----------------------------------------------------------

function SpatialRefugeUpgradeWindow:createChildren()
    -- Calculate panel dimensions
    local contentY = self.headerHeight
    local contentHeight = self.height - self.headerHeight - self.padding
    
    local gridWidth = math.floor((self.width - self.padding * 4) * self.GRID_WIDTH_RATIO)
    local detailsWidth = math.floor((self.width - self.padding * 4) * self.DETAILS_WIDTH_RATIO)
    local ingredientsWidth = self.width - gridWidth - detailsWidth - self.padding * 4
    
    -- Create upgrade grid (left panel)
    local SRU_UpgradeGrid = require "refuge/SRU_UpgradeGrid"
    self.upgradeGrid = SRU_UpgradeGrid:new(
        self.padding,
        contentY,
        gridWidth,
        contentHeight,
        self
    )
    self.upgradeGrid:initialise()
    self:addChild(self.upgradeGrid)
    
    -- Create details panel (middle)
    local SRU_UpgradeDetails = require "refuge/SRU_UpgradeDetails"
    self.upgradeDetails = SRU_UpgradeDetails:new(
        self.padding * 2 + gridWidth,
        contentY,
        detailsWidth,
        contentHeight,
        self
    )
    self.upgradeDetails:initialise()
    self:addChild(self.upgradeDetails)
    
    -- Create ingredient list (right panel)
    local SRU_IngredientList = require "refuge/SRU_IngredientList"
    self.ingredientList = SRU_IngredientList:new(
        self.padding * 3 + gridWidth + detailsWidth,
        contentY,
        ingredientsWidth,
        contentHeight,
        self
    )
    self.ingredientList:initialise()
    self:addChild(self.ingredientList)
    
    -- Create close button
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
    
    -- Create resize widget
    self:createResizeWidget()
    
    -- Load upgrades
    self:refreshUpgradeList()
end

function SpatialRefugeUpgradeWindow:createResizeWidget()
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

-----------------------------------------------------------
-- Resize Handling
-----------------------------------------------------------

function SpatialRefugeUpgradeWindow:onResize(newWidth, newHeight)
    -- Enforce minimum size
    newWidth = math.max(self.MIN_WIDTH, newWidth)
    newHeight = math.max(self.MIN_HEIGHT, newHeight)
    
    self:setWidth(newWidth)
    self:setHeight(newHeight)
    
    -- Recalculate panel dimensions
    local contentY = self.headerHeight
    local contentHeight = newHeight - self.headerHeight - self.padding
    
    local gridWidth = math.floor((newWidth - self.padding * 4) * self.GRID_WIDTH_RATIO)
    local detailsWidth = math.floor((newWidth - self.padding * 4) * self.DETAILS_WIDTH_RATIO)
    local ingredientsWidth = newWidth - gridWidth - detailsWidth - self.padding * 4
    
    -- Update panel positions and sizes
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
    
    -- Update close button position
    if self.closeButton then
        local closeSize = self.closeButton:getWidth()
        self.closeButton:setX(newWidth - closeSize - self.padding)
    end
    
    -- Update resize widget position
    if self.resizeWidget then
        local resizeSize = self.resizeWidget:getWidth()
        self.resizeWidget:setX(newWidth - resizeSize - 2)
        self.resizeWidget:setY(newHeight - resizeSize - 2)
    end
end

-----------------------------------------------------------
-- Upgrade Selection
-----------------------------------------------------------

function SpatialRefugeUpgradeWindow:selectUpgrade(upgradeId)
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    if not upgrade then return end
    
    self.selectedUpgrade = upgrade
    self.selectedLevel = SpatialRefugeUpgradeData.getPlayerUpgradeLevel(self.player, upgradeId) + 1
    
    -- Clamp to max level
    if self.selectedLevel > upgrade.maxLevel then
        self.selectedLevel = upgrade.maxLevel
    end
    
    -- Update panels
    if self.upgradeDetails then
        self.upgradeDetails:setUpgrade(upgrade, self.selectedLevel)
    end
    
    if self.ingredientList then
        local requirements = SpatialRefugeUpgradeData.getLevelData(upgradeId, self.selectedLevel)
        if requirements then
            self.ingredientList:setRequirements(requirements.requirements or {})
        else
            self.ingredientList:setRequirements({})
        end
    end
end

function SpatialRefugeUpgradeWindow:refreshUpgradeList()
    if self.upgradeGrid then
        self.upgradeGrid:refreshUpgrades()
    end
end

function SpatialRefugeUpgradeWindow:refreshCurrentUpgrade()
    if self.selectedUpgrade then
        self:selectUpgrade(self.selectedUpgrade.id)
    end
end

-----------------------------------------------------------
-- Upgrade Purchase
-----------------------------------------------------------

function SpatialRefugeUpgradeWindow:onUpgradeClick()
    if not self.selectedUpgrade then return end
    
    local upgradeId = self.selectedUpgrade.id
    local targetLevel = self.selectedLevel
    
    -- Attempt upgrade via logic module
    local SpatialRefugeUpgradeLogic = require "refuge/SpatialRefugeUpgradeLogic"
    local success, err = SpatialRefugeUpgradeLogic.purchaseUpgrade(self.player, upgradeId, targetLevel)
    
    if success then
        -- Refresh UI
        self:refreshUpgradeList()
        self:refreshCurrentUpgrade()
    else
        -- Show error (player say or UI feedback)
        if self.player and self.player.Say then
            self.player:Say(err or "Upgrade failed")
        end
    end
end

-----------------------------------------------------------
-- Input Handling
-----------------------------------------------------------

function SpatialRefugeUpgradeWindow:onCloseClick()
    self:close()
end

function SpatialRefugeUpgradeWindow:close()
    self:setVisible(false)
    self:removeFromUIManager()
    SpatialRefugeUpgradeWindow.instance = nil
end

function SpatialRefugeUpgradeWindow:isKeyConsumed(key)
    return key == Keyboard.KEY_ESCAPE
end

function SpatialRefugeUpgradeWindow:onKeyRelease(key)
    if key == Keyboard.KEY_ESCAPE then
        self:close()
        return true
    end
    return false
end

-----------------------------------------------------------
-- Rendering
-----------------------------------------------------------

function SpatialRefugeUpgradeWindow:prerender()
    -- Background
    self:drawRect(0, 0, self.width, self.height, 0.95, 0.06, 0.05, 0.08)
    
    -- Header background
    self:drawRect(0, 0, self.width, self.headerHeight, 1, 0.10, 0.08, 0.14)
    
    -- Header border
    self:drawRectBorder(0, 0, self.width, self.headerHeight, 0.8, 0.30, 0.25, 0.38)
    
    -- Header icon (upgrade icon)
    local iconSize = math.floor(self.headerHeight * 0.7)
    local iconY = (self.headerHeight - iconSize) / 2
    local headerIcon = getTexture("media/textures/upgrade_spatial_refuge_64x64.png")
    if not headerIcon then
        headerIcon = getTexture("media/textures/sacred_core.png") or getTexture("Item_ZombieCore")
    end
    if headerIcon then
        self:drawTextureScaledAspect(headerIcon, self.padding, iconY, iconSize, iconSize, 1, 1, 1, 1)
    else
        -- Fallback placeholder
        self:drawRect(self.padding, iconY, iconSize, iconSize, 0.6, 0.4, 0.3, 0.5)
    end
    
    -- Header title
    local titleX = self.padding * 2 + iconSize
    local titleY = (self.headerHeight - FONT_HGT_LARGE) / 2
    local title = getText("UI_RefugeUpgrade_Title") or "Upgrade Spatial Refuge"
    self:drawText(title, titleX, titleY, 0.92, 0.90, 0.88, 1, UIFont.Large)
    
    -- Main border
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.30, 0.25, 0.38)
end

function SpatialRefugeUpgradeWindow:render()
    -- Render is called after children
end

function SpatialRefugeUpgradeWindow:update()
    ISPanel.update(self)
    
    -- Check if player is still valid
    if not self.player then
        self:close()
        return
    end
    
    local ok = pcall(function() return self.player:getUsername() end)
    if not ok then
        self:close()
        return
    end
end

-----------------------------------------------------------
-- Module Export
-----------------------------------------------------------

print("[SpatialRefugeUpgradeWindow] Upgrade window loaded")

return SpatialRefugeUpgradeWindow

