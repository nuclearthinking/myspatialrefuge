-- SRU_UpgradeDetails.lua
-- Middle panel showing upgrade details: icon, name, level, description
-- Also contains the required items panel and upgrade button

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "MSR_UpgradeData"
require "MSR_UpgradeLogic"
require "MSR_UpgradeItemCache"
require "MSR_Echo"

---@class SRU_UpgradeDetails : ISPanel
---@field parentWindow any
---@field player IsoPlayer
---@field padding number
---@field iconSize number
---@field upgrade table?
---@field level number?
---@field levelData table?
---@field requiredItems SRU_RequiredItems?
---@field upgradeButton ISButton?
---@field _requirements table[]?
---@field _echoCost number
---@field isLocked boolean
---@field missingDependencies string[]
SRU_UpgradeDetails = ISPanel:derive("SRU_UpgradeDetails")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local ABSTRACT_EFFECTS = {
    refugeWoundRecoveryMultiplier = true,
    refugeSleepFatigueMultiplier = true,
    refugeMentalRecoveryMultiplier = true,
    refugeStiffnessRecoveryMultiplier = true,
}

local function getTextFormatted(key, ...)
    ---@type fun(textKey: string, ...): string
    local formatter = _G.getText
    return formatter(key, ...)
end

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

local Config = require "ui/framework/CUI_Config"
local Theme = require "ui/MSR_Theme"
local Widgets = require "ui/MSR_Widgets"

-----------------------------------------------------------
-- Constructor
-----------------------------------------------------------

---@return SRU_UpgradeDetails
function SRU_UpgradeDetails:new(x, y, width, height, parentWindow)
    ---@type SRU_UpgradeDetails
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
    o._echoCost = 0
    
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
    Theme.styleButton(self.upgradeButton, "primary")
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
    self._requirements = nil
    
    if upgrade and level then
        self.levelData = MSR.UpgradeData.getLevelData(upgrade.id, level)
        -- Check if upgrade is locked (dependencies not met)
        self.isLocked = not MSR.UpgradeData.isUpgradeUnlocked(self.player, upgrade.id)
        -- Get missing dependencies
        self.missingDependencies = self:getMissingDependencies()
        self._requirements = MSR.UpgradeData.getNextLevelRequirements(self.player, upgrade.id)
        self._echoCost = MSR.UpgradeData.getNextLevelEchoCost(self.player, upgrade.id) or 0
    else
        self.levelData = nil
        self.isLocked = false
        self.missingDependencies = {}
        self._echoCost = 0
    end
    
    -- Update required items (uses difficulty-scaled costs)
    if self.requiredItems then
        if self._requirements then
            self.requiredItems:setRequirements(self._requirements)
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
                local depText = getTextFormatted("UI_RefugeUpgrade_DependencyLevel", depName, depLevel, depMaxLevel)
                    or string.format("%s (Level %d/%d)", depName, depLevel, depMaxLevel)
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
    local canUpgrade = MSR.UpgradeData.canUpgrade(self.player, self.upgrade.id)
    
    -- Check if has required items
    local hasItems = self:checkHasRequiredItems()
    local refugeData = MSR.Data.GetRefugeData(self.player)
    local hasEcho = MSR.Echo.CanSpend(refugeData, self._echoCost or 0)
    
    self.upgradeButton:setVisible(true)
    self.upgradeButton:setEnable(canUpgrade and hasItems and hasEcho)

    -- A disabled button must say why; render() draws this line above it.
    self._blockReason = nil
    if self.isLocked then
        self._blockReason = getText("UI_RefugeUpgrade_RequiresUpgrades")
    elseif not hasEcho then
        local refuge = MSR.Data.GetRefugeData(self.player)
        local balance = MSR.Echo.GetBalance(refuge)
        self._blockReason = getText("UI_Refuge_MissingEcho",
            Theme.formatNumber((self._echoCost or 0) - balance))
    elseif not hasItems then
        self._blockReason = getText("UI_Refuge_MissingItems")
    end

    if canUpgrade and hasItems and hasEcho then
        Theme.styleButton(self.upgradeButton, "primary")
    else
        Theme.styleButton(self.upgradeButton)
    end
end

function SRU_UpgradeDetails:checkHasRequiredItems()
    if not self.upgrade then
        return true
    end
    
    -- Use difficulty-scaled requirements
    local requirements = self._requirements
    if not requirements then
        return true
    end
    
    -- Use shared UI cache to avoid repeated scans
    MSR.UpgradeItemCache.setPlayer(self.player)
    for _, req in ipairs(requirements) do
        local haveCount = MSR.UpgradeItemCache.getCountForRequirement(req)
        if haveCount < (req.count or 1) then
            return false
        end
    end
    return true
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
    Theme.box(self, 0, 0, self.width, self.height, Theme.color.inset, Theme.color.border)
    Theme.fill(self, 1, 1, self.width - 2, 2, Theme.color.brass)
end

function SRU_UpgradeDetails:render()
    local C = Theme.color
    if not self.upgrade then
        local text = getText("UI_RefugeUpgrade_SelectUpgrade") or "Select an upgrade"
        Theme.textCentre(self, text, math.floor(self.width / 2),
            math.floor(self.height / 2 - FONT_HGT_MEDIUM / 2), C.textMuted, UIFont.Medium)
        return
    end

    local p = self.padding
    local contentW = self.width - p * 2
    local y = p + 2

    -- Header: icon slot, name, pips, category
    Widgets.iconSlot(self, getTexture(self.upgrade.icon), p, y, self.iconSize, self.isLocked)

    local textX = p + self.iconSize + p
    local name = getText(self.upgrade.name) or self.upgrade.name or self.upgrade.id
    Theme.text(self, name, textX, y, C.text, UIFont.Large)

    local currentLevel = MSR.UpgradeData.getPlayerUpgradeLevel(self.player, self.upgrade.id)
    local maxLevel = self.upgrade.maxLevel or 1
    local pipY = y + FONT_HGT_LARGE + 4
    local pipSize = math.max(6, math.floor(FONT_HGT_SMALL * 0.6))
    local pipEnd = Widgets.levelPips(self, textX, pipY + 2, currentLevel, maxLevel, pipSize)
    local levelText
    if currentLevel >= maxLevel then
        levelText = getTextFormatted("UI_RefugeUpgrade_LevelMax", currentLevel, maxLevel)
    else
        levelText = getTextFormatted("UI_RefugeUpgrade_LevelNext",
            currentLevel, maxLevel, self.level or currentLevel + 1)
    end
    Theme.text(self, levelText, pipEnd + p, pipY, C.accentHi, UIFont.Small)

    local category = self.upgrade.category or "general"
    Theme.text(self, getText("UI_RefugeUpgrade_Category_" .. category) or category,
        textX, pipY + FONT_HGT_SMALL + 4, C.textMuted, UIFont.Small)

    y = y + math.max(self.iconSize, FONT_HGT_LARGE + FONT_HGT_SMALL * 2 + 10) + p

    -- Locked: the gate is the most important fact, show it first
    if self.isLocked and self.missingDependencies and #self.missingDependencies > 0 then
        y = Widgets.sectionHeader(self, p, y, contentW,
            getText("UI_RefugeUpgrade_RequiresUpgrades"))
        for _, depName in ipairs(self.missingDependencies) do
            y = Widgets.keyValueRow(self, p, y, contentW, depName, "", C.bad)
        end
        y = y + p
    end

    -- What changes: current value -> value at the offered level
    if self.levelData and self.levelData.effects then
        local prevEffects = currentLevel > 0
            and MSR.UpgradeData.getLevelEffects(self.upgrade.id, currentLevel) or nil
        local drewHeader = false
        for effectName, effectValue in pairs(self.levelData.effects) do
            if not drewHeader then
                y = Widgets.sectionHeader(self, p, y, contentW,
                    getText("UI_RefugeUpgrade_Effects"))
                drewHeader = true
            end
            local label, after = self:formatEffectParts(effectName, effectValue)
            local before = nil
            if prevEffects and prevEffects[effectName] ~= nil then
                local _, prevValue = self:formatEffectParts(effectName, prevEffects[effectName])
                before = prevValue
            end
            y = Widgets.deltaRow(self, p, y, contentW, label, before, after)
        end
        if drewHeader then y = y + p end
    end

    -- Description
    if self.levelData and self.levelData.description then
        local desc = getText(self.levelData.description) or self.levelData.description
        local lines = Widgets.wrapText(desc, contentW, UIFont.Small)
        for i, line in ipairs(lines) do
            Theme.text(self, line, p, y, C.textDim, UIFont.Small)
            y = y + FONT_HGT_SMALL
            if i >= 4 then break end
        end
        y = y + p
    end

    -- Cost: echo first, item rows follow in the child panel
    y = Widgets.sectionHeader(self, p, y, contentW, getText("UI_SpatialWell_RequiredResources"))
    local echoBalance = MSR.Echo.GetBalance(MSR.Data.GetRefugeData(self.player))
    local echoName, echoTexture = MSR.UpgradeItemCache.getItemMeta(MSR.Config.ECHO.DISPLAY_ITEM, self.player)
    y = Widgets.costRow(self, p, y, contentW,
        echoTexture, tostring(echoName or getText("UI_RefugeUpgrade_EchoCost")),
        echoBalance, self._echoCost or 0)
    if self.requiredItems then
        self.requiredItems:setY(y)
    end

    -- Footer: the reason the button is grey, right above the button
    if self._blockReason and self.upgradeButton and self.upgradeButton:isVisible() then
        Theme.text(self, self._blockReason, p,
            self.upgradeButton:getY() - FONT_HGT_SMALL - 4, C.bad, UIFont.Small)
    end
end

-----------------------------------------------------------
-- Helpers
-----------------------------------------------------------

---@diagnostic disable-next-line: unused -- Kept as an overridable panel helper.
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

--- Split an effect into (label, value text) so callers can render deltas.
function SRU_UpgradeDetails:formatEffectParts(name, value)
    local displayName = getText("UI_Effect_" .. name) or name

    if self:isAbstractEffect(name) then
        local level = self.level or 1
        return displayName, getTextFormatted("UI_Effect_LevelFormat", level)
            or string.format("level %d", level)
    end

    -- Boolean/unlock effects (name ends with "Enabled") - show as unlocked ability
    if string.sub(name, -7) == "Enabled" then
        return displayName, getText("UI_Effect_Unlocked") or "Unlocked"
    end

    if type(value) == "number" then
        if name == "corePickupRadius" then
            local formattedValue
            if value % 1 == 0 then
                formattedValue = string.format("%d", value)
            else
                formattedValue = string.format("%.1f", value)
            end
            local formatKey = value == 1 and "UI_Effect_TileFormat" or "UI_Effect_TilesFormat"
            return displayName, getTextFormatted(formatKey, formattedValue)
                or string.format(value == 1 and "%s tile" or "%s tiles", formattedValue)
        end

        -- Time multipliers (lower = faster) - apply difficulty scaling
        if name == "readingSpeedMultiplier" or name == "refugeCastTimeMultiplier" or
           name == "refugeCropGrowthTimeMultiplier" then
            local scaledValue = D.positiveEffect(value)
            local speedBonus = math.floor((1 - scaledValue) * 100 + 0.5)
            local sign = speedBonus > 0 and "+" or ""
            return displayName, string.format("%s%d%%", sign, speedBonus)
        elseif value < 1 and value > 0 then
            return displayName, string.format("+%d%%", math.floor(value * 100))
        else
            return displayName, string.format("+%d", value)
        end
    end
    return displayName, tostring(value)
end

function SRU_UpgradeDetails:formatEffect(name, value)
    local label, valueText = self:formatEffectParts(name, value)
    return string.format("%s: %s", label, valueText)
end

---@diagnostic disable-next-line: unused -- Kept as an overridable panel helper.
function SRU_UpgradeDetails:isAbstractEffect(name)
    return ABSTRACT_EFFECTS[name] == true
end

return SRU_UpgradeDetails

