-- SRU_UpgradeDetails.lua
-- Middle panel showing upgrade details: icon, name, level, description
-- Also contains the required items panel and upgrade button

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "shared/MSR_UpgradeData"
require "shared/MSR_UpgradeLogic"

SRU_UpgradeDetails = ISPanel:derive("SRU_UpgradeDetails")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

local Config = require "ui/framework/CUI_Config"

-----------------------------------------------------------
-- Constructor
-----------------------------------------------------------

function SRU_UpgradeDetails:new(x, y, width, height, parentWindow)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.parentWindow = parentWindow
    o.player = parentWindow.player
    
    -- Layout
    o.padding = Config.padding
    o.iconSize = math.floor(FONT_HGT_MEDIUM * 4)
    
    -- State
    o.upgrade = nil
    o.level = nil
    o.levelData = nil
    
    -- Child panels
    o.requiredItems = nil
    o.upgradeButton = nil
    
    return o
end

function SRU_UpgradeDetails:initialise()
    ISPanel.initialise(self)
end

-----------------------------------------------------------
-- Child Creation
-----------------------------------------------------------

function SRU_UpgradeDetails:createChildren()
    -- Required items panel
    local SRU_RequiredItems = require "SRU_RequiredItems"
    
    local itemsY = self.iconSize + self.padding * 3 + FONT_HGT_MEDIUM + FONT_HGT_SMALL * 4
    local itemsHeight = math.floor(FONT_HGT_MEDIUM * 6)
    
    self.requiredItems = SRU_RequiredItems:new(
        self.padding,
        itemsY,
        self.width - self.padding * 2,
        itemsHeight,
        self
    )
    self.requiredItems:initialise()
    self:addChild(self.requiredItems)
    
    -- Upgrade button
    local buttonWidth = math.floor(self.width * 0.6)
    local buttonHeight = math.floor(FONT_HGT_MEDIUM * 1.8)
    local buttonX = (self.width - buttonWidth) / 2
    local buttonY = self.height - buttonHeight - self.padding * 2
    
    self.upgradeButton = ISButton:new(
        buttonX,
        buttonY,
        buttonWidth,
        buttonHeight,
        getText("UI_RefugeUpgrade_Upgrade") or "UPGRADE",
        self,
        self.onUpgradeClick
    )
    self.upgradeButton:initialise()
    self.upgradeButton.backgroundColor = {r=0.2, g=0.5, b=0.2, a=0.9}
    self.upgradeButton.backgroundColorMouseOver = {r=0.3, g=0.6, b=0.3, a=0.95}
    self.upgradeButton.borderColor = {r=0.4, g=0.7, b=0.4, a=1}
    self.upgradeButton.textColor = {r=1, g=1, b=1, a=1}
    self.upgradeButton:setFont(UIFont.Medium)
    self.upgradeButton:setVisible(false)
    self:addChild(self.upgradeButton)
end

-----------------------------------------------------------
-- Upgrade Data
-----------------------------------------------------------

function SRU_UpgradeDetails:setUpgrade(upgrade, level)
    self.upgrade = upgrade
    self.level = level
    
    if upgrade and level then
        self.levelData = MSR.UpgradeData.getLevelData(upgrade.id, level)
        -- Check if upgrade is locked (dependencies not met)
        self.isLocked = not MSR.UpgradeData.isUpgradeUnlocked(self.player, upgrade.id)
        -- Get missing dependencies
        self.missingDependencies = self:getMissingDependencies()
    else
        self.levelData = nil
        self.isLocked = false
        self.missingDependencies = {}
    end
    
    -- Update required items (uses difficulty-scaled costs)
    if self.requiredItems then
        local requirements = MSR.UpgradeData.getNextLevelRequirements(self.player, upgrade.id)
        if requirements then
            self.requiredItems:setRequirements(requirements)
        else
            self.requiredItems:setRequirements({})
        end
    end
    
    -- Update button visibility and state
    self:updateUpgradeButton()
end

function SRU_UpgradeDetails:getMissingDependencies()
    local missing = {}
    if not self.upgrade or not self.upgrade.dependencies then
        return missing
    end
    
    for _, depId in ipairs(self.upgrade.dependencies) do
        local depUpgrade = MSR.UpgradeData.getUpgrade(depId)
        if depUpgrade then
            local depLevel = MSR.UpgradeData.getPlayerUpgradeLevel(self.player, depId)
            local depMaxLevel = depUpgrade.maxLevel or 1
            -- Dependencies must be at MAX level (matching isUpgradeUnlocked logic)
            if depLevel < depMaxLevel then
                local depName = getText(depUpgrade.name) or depUpgrade.name or depId
                -- Include current/max level info for clarity
                local depText = string.format("%s (Level %d/%d)", depName, depLevel, depMaxLevel)
                table.insert(missing, depText)
            end
        end
    end
    
    return missing
end

function SRU_UpgradeDetails:updateUpgradeButton()
    if not self.upgradeButton then return end
    
    if not self.upgrade or not self.level then
        self.upgradeButton:setVisible(false)
        return
    end
    
    -- Check if already at max level
    local currentLevel = MSR.UpgradeData.getPlayerUpgradeLevel(self.player, self.upgrade.id)
    if currentLevel >= self.upgrade.maxLevel then
        self.upgradeButton:setVisible(false)
        return
    end
    
    -- Check if can upgrade
    local canUpgrade, err = MSR.UpgradeData.canUpgrade(self.player, self.upgrade.id)
    
    -- Check if has required items
    local hasItems = self:checkHasRequiredItems()
    
    self.upgradeButton:setVisible(true)
    self.upgradeButton:setEnable(canUpgrade and hasItems)
    
    -- Update button appearance based on state
    if canUpgrade and hasItems then
        self.upgradeButton.backgroundColor = {r=0.2, g=0.5, b=0.2, a=0.9}
        self.upgradeButton.backgroundColorMouseOver = {r=0.3, g=0.6, b=0.3, a=0.95}
        self.upgradeButton.borderColor = {r=0.4, g=0.7, b=0.4, a=1}
    else
        self.upgradeButton.backgroundColor = {r=0.3, g=0.3, b=0.3, a=0.7}
        self.upgradeButton.backgroundColorMouseOver = {r=0.35, g=0.35, b=0.35, a=0.8}
        self.upgradeButton.borderColor = {r=0.4, g=0.4, b=0.4, a=0.8}
    end
end

function SRU_UpgradeDetails:checkHasRequiredItems()
    if not self.upgrade then
        return true
    end
    
    -- Use difficulty-scaled requirements
    local requirements = MSR.UpgradeData.getNextLevelRequirements(self.player, self.upgrade.id)
    if not requirements then
        return true
    end
    
    -- Use upgrade logic to check items
    return MSR.UpgradeLogic.hasRequiredItems(self.player, requirements)
end

-----------------------------------------------------------
-- Button Handler
-----------------------------------------------------------

function SRU_UpgradeDetails:onUpgradeClick()
    if self.parentWindow then
        self.parentWindow:onUpgradeClick()
    end
end

-----------------------------------------------------------
-- Resize
-----------------------------------------------------------

function SRU_UpgradeDetails:onResize()
    -- Update required items panel
    if self.requiredItems then
        self.requiredItems:setWidth(self.width - self.padding * 2)
    end
    
    -- Update button position
    if self.upgradeButton then
        local buttonWidth = math.floor(self.width * 0.6)
        local buttonX = (self.width - buttonWidth) / 2
        local buttonY = self.height - self.upgradeButton:getHeight() - self.padding * 2
        self.upgradeButton:setX(buttonX)
        self.upgradeButton:setY(buttonY)
        self.upgradeButton:setWidth(buttonWidth)
    end
end

-----------------------------------------------------------
-- Rendering
-----------------------------------------------------------

function SRU_UpgradeDetails:prerender()
    -- Panel background
    self:drawRect(0, 0, self.width, self.height, 0.85, 0.08, 0.07, 0.10)
    
    -- Border
    self:drawRectBorder(0, 0, self.width, self.height, 0.6, 0.25, 0.22, 0.30)
end

function SRU_UpgradeDetails:render()
    if not self.upgrade then
        -- Empty state
        local text = getText("UI_RefugeUpgrade_SelectUpgrade") or "Select an upgrade"
        local textW = getTextManager():MeasureStringX(UIFont.Medium, text)
        local textX = (self.width - textW) / 2
        local textY = self.height / 2 - FONT_HGT_MEDIUM / 2
        self:drawText(text, textX, textY, 0.5, 0.5, 0.5, 0.8, UIFont.Medium)
        return
    end
    
    local y = self.padding
    
    -- Icon and name row
    local iconX = self.padding
    local iconY = y
    
    -- Draw icon
    local texture = getTexture(self.upgrade.icon)
    if texture then
        self:drawTextureScaledAspect(texture, iconX, iconY, self.iconSize, self.iconSize, 1, 1, 1, 1)
    else
        -- Placeholder
        self:drawRect(iconX, iconY, self.iconSize, self.iconSize, 0.6, 0.4, 0.3, 0.5)
    end
    
    -- Name and level
    local textX = iconX + self.iconSize + self.padding
    local textY = iconY
    
    local name = getText(self.upgrade.name) or self.upgrade.name or self.upgrade.id
    self:drawText(name, textX, textY, 0.92, 0.90, 0.88, 1, UIFont.Large)
    textY = textY + FONT_HGT_LARGE + 4
    
    -- Level indicator
    local currentLevel = MSR.UpgradeData.getPlayerUpgradeLevel(self.player, self.upgrade.id)
    local maxLevel = self.upgrade.maxLevel or 1
    
    local levelText
    if currentLevel >= maxLevel then
        levelText = string.format("Level %d/%d (MAX)", currentLevel, maxLevel)
    else
        levelText = string.format("Level %d/%d -> %d", currentLevel, maxLevel, self.level or currentLevel + 1)
    end
    self:drawText(levelText, textX, textY, 0.65, 0.45, 0.85, 1, UIFont.Medium)
    textY = textY + FONT_HGT_MEDIUM + 4
    
    -- Category
    local category = self.upgrade.category or "general"
    local categoryText = getText("UI_RefugeUpgrade_Category_" .. category) or category
    self:drawText(categoryText, textX, textY, 0.55, 0.52, 0.58, 0.9, UIFont.Small)
    
    -- Locked warning with dependencies
    y = iconY + self.iconSize + self.padding * 2
    
    if self.isLocked and self.missingDependencies and #self.missingDependencies > 0 then
        -- Draw locked warning
        local lockWarning = getText("UI_RefugeUpgrade_RequiresUpgrades") or "Requires:"
        self:drawText(lockWarning, self.padding, y, 0.9, 0.4, 0.4, 1, UIFont.Small)
        y = y + FONT_HGT_SMALL
        
        for _, depName in ipairs(self.missingDependencies) do
            self:drawText("  - " .. depName, self.padding, y, 0.8, 0.5, 0.5, 1, UIFont.Small)
            y = y + FONT_HGT_SMALL
        end
        
        y = y + self.padding
    end
    
    if self.levelData and self.levelData.description then
        local desc = getText(self.levelData.description) or self.levelData.description
        local maxWidth = self.width - self.padding * 2
        
        -- Simple word wrap
        local lines = self:wrapText(desc, maxWidth, UIFont.Small)
        for i, line in ipairs(lines) do
            self:drawText(line, self.padding, y, 0.85, 0.83, 0.80, 1, UIFont.Small)
            y = y + FONT_HGT_SMALL
            if i >= 4 then break end -- Limit to 4 lines
        end
    end
    
    -- Effects section
    y = y + self.padding
    if self.levelData and self.levelData.effects then
        local hasEffects = false
        for _ in pairs(self.levelData.effects) do
            hasEffects = true
            break
        end
        
        if hasEffects then
            self:drawText(getText("UI_RefugeUpgrade_Effects") or "Effects:", self.padding, y, 0.7, 0.68, 0.72, 1, UIFont.Small)
            y = y + FONT_HGT_SMALL
            
            for effectName, effectValue in pairs(self.levelData.effects) do
                local effectText = self:formatEffect(effectName, effectValue)
                self:drawText("  + " .. effectText, self.padding, y, 0.5, 0.8, 0.5, 1, UIFont.Small)
                y = y + FONT_HGT_SMALL
            end
        end
    end
    
    -- Required Items header (panel draws below)
    y = y + self.padding
    if self.requiredItems then
        self.requiredItems:setY(y)
    end
end

-----------------------------------------------------------
-- Helpers
-----------------------------------------------------------

function SRU_UpgradeDetails:wrapText(text, maxWidth, font)
    local lines = {}
    local currentLine = ""
    
    for word in text:gmatch("%S+") do
        local testLine = currentLine == "" and word or (currentLine .. " " .. word)
        local testWidth = getTextManager():MeasureStringX(font, testLine)
        
        if testWidth <= maxWidth then
            currentLine = testLine
        else
            if currentLine ~= "" then
                table.insert(lines, currentLine)
            end
            currentLine = word
        end
    end
    
    if currentLine ~= "" then
        table.insert(lines, currentLine)
    end
    
    return lines
end

function SRU_UpgradeDetails:formatEffect(name, value)
    local displayName = getText("UI_Effect_" .. name) or name
    
    -- Boolean/unlock effects (name ends with "Enabled") - show as unlocked ability
    if string.sub(name, -7) == "Enabled" then
        local unlockText = getText("UI_Effect_Unlocked") or "Unlocked"
        return string.format("%s: %s", displayName, unlockText)
    end
    
    if type(value) == "number" then
        -- Time multipliers (lower = faster) - apply difficulty scaling
        if name == "readingSpeedMultiplier" or name == "refugeCastTimeMultiplier" then
            local scaledValue = D.positiveEffect(value)
            local speedBonus = math.floor((1 - scaledValue) * 100 + 0.5)
            local sign = speedBonus > 0 and "+" or ""
            return string.format("%s: %s%d%%", displayName, sign, speedBonus)
        elseif value < 1 and value > 0 then
            return string.format("%s: +%d%%", displayName, math.floor(value * 100))
        else
            return string.format("%s: +%d", displayName, value)
        end
    else
        return string.format("%s: %s", displayName, tostring(value))
    end
end

return SRU_UpgradeDetails

