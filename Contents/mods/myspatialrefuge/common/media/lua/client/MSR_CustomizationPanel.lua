require "ISUI/ISPanel"
require "ISUI/ISButton"
require "MSR_SpatialWell"
require "MSR_SpatialWellCursor"
require "MSR_UpgradeItemCache"
require "MSR_PlayerMessage"

---@class MSR_CustomizationPanel : ISPanel
---@field parentWindow MSR_UpgradeWindow
---@field player IsoPlayer
---@field padding number
---@field requirements table<string, number>
---@field haveCounts table<string, number>
---@field hasEnough boolean
---@field isBuilt boolean
---@field buildButton ISButton
MSR_CustomizationPanel = ISPanel:derive("MSR_CustomizationPanel")

local FONT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local ITEM_ORDER = {
    "Base.MagicalCore",
    "Base.MetalPipe",
    "Base.ConcretePowder",
    "Base.BucketEmpty",
}

function MSR_CustomizationPanel:new(x, y, width, height, parentWindow)
    local o = ISPanel:new(x, y, width, height) --[[@as MSR_CustomizationPanel]]
    setmetatable(o, self)
    self.__index = self
    o.parentWindow = parentWindow
    o.player = parentWindow.player
    o.padding = 12
    o.requirements = MSR.SpatialWell.GetRequirements()
    o.haveCounts = {}
    o.hasEnough = false
    o.isBuilt = false
    o.drawFrame = false
    return o
end

function MSR_CustomizationPanel:initialise()
    ISPanel.initialise(self)
end

function MSR_CustomizationPanel:createChildren()
    local buttonWidth = math.floor(FONT_MEDIUM * 11)
    local buttonHeight = math.floor(FONT_MEDIUM * 2.1)
    self.buildButton = ISButton:new(
        self.width - self.padding - buttonWidth,
        self.height - self.padding - buttonHeight,
        buttonWidth,
        buttonHeight,
        getText("UI_SpatialWell_Build"),
        self,
        self.onBuildClick
    )
    self.buildButton:initialise()
    self.buildButton.anchorRight = true
    self.buildButton.anchorBottom = true
    self:addChild(self.buildButton)
    self:refresh()
end

function MSR_CustomizationPanel:refresh()
    MSR.UpgradeItemCache.setPlayer(self.player)
    local refugeData = MSR.Data.GetRefugeData(self.player)
    self.isBuilt = MSR.SpatialWell.IsBuilt(refugeData)
    self.hasEnough = true

    for itemType, requiredCount in pairs(self.requirements) do
        local count
        if itemType == MSR.Config.SPATIAL_WELL.EMPTY_BUCKET_TYPE then
            count = MSR.SpatialWell.CountEmptyBuckets(self.player)
        else
            count = MSR.UpgradeItemCache.getCount(itemType)
        end
        self.haveCounts[itemType] = count
        if count < requiredCount then self.hasEnough = false end
    end

    if self.buildButton then
        self.buildButton:setTitle(getText(self.isBuilt and "UI_SpatialWell_Built" or "UI_SpatialWell_Build"))
        self.buildButton:setEnable(not self.isBuilt and self.hasEnough)
    end
end

function MSR_CustomizationPanel:onBuildClick()
    if self.isBuilt then return end
    if not self.hasEnough then
        MSR.PlayerMessage.Say(self.player, MSR.PlayerMessage.SPATIAL_WELL_MISSING_RESOURCES)
        return
    end

    if self.parentWindow then self.parentWindow:close() end
    if not MSR_SpatialWellCursor.Start(self.player) then
        MSR.PlayerMessage.Say(self.player, MSR.PlayerMessage.SPATIAL_WELL_BUILD_FAILED)
    end
end

local function getItemDisplay(itemType)
    local displayName, texture = MSR.UpgradeItemCache.getItemMeta(itemType)
    if itemType == MSR.Config.SPATIAL_WELL.EMPTY_BUCKET_TYPE then
        displayName = getText("UI_SpatialWell_EmptyBucket")
    end
    return tostring(displayName or itemType), texture
end

function MSR_CustomizationPanel:drawRequirementRow(x, y, width, height, itemType, requiredCount, index)
    if index % 2 == 0 then
        self:drawRect(x, y, width, height, 0.18, 0.12, 0.09, 0.16)
    end

    local iconSize = height - 8
    local displayName, texture = getItemDisplay(itemType)
    if texture then
        self:drawTextureScaledAspect(texture, x + 6, y + 4, iconSize, iconSize, 1, 1, 1, 1)
    end

    self:drawText(displayName, x + iconSize + 14, y + (height - FONT_SMALL) / 2,
        0.88, 0.86, 0.84, 1, UIFont.Small)

    local have = self.haveCounts[itemType] or 0
    local countText = string.format("%d / %d", have, requiredCount)
    local countWidth = getTextManager():MeasureStringX(UIFont.Small, countText)
    local color = have >= requiredCount and { 0.45, 0.82, 0.48 } or { 0.86, 0.38, 0.38 }
    self:drawText(countText, x + width - countWidth - 8, y + (height - FONT_SMALL) / 2,
        color[1], color[2], color[3], 1, UIFont.Small)
end

function MSR_CustomizationPanel:prerender()
    self:drawRect(0, 0, self.width, self.height, 0.82, 0.06, 0.05, 0.08)
    self:drawRectBorder(0, 0, self.width, self.height, 0.6, 0.25, 0.22, 0.30)

    local p = self.padding
    local iconSize = math.floor(FONT_LARGE * 3.2)
    local icon = getTexture("media/ui/SpatialWell_64x64.png")
    if icon then
        self:drawTextureScaledAspect(icon, p, p, iconSize, iconSize, 1, 1, 1, 1)
    end

    local textX = p + iconSize + p
    self:drawText(getText("UI_SpatialWell_Name"), textX, p, 0.92, 0.78, 0.52, 1, UIFont.Large)
    self:drawText(getText("UI_SpatialWell_Description"), textX, p + FONT_LARGE + 5,
        0.78, 0.76, 0.80, 1, UIFont.Small)
    self:drawText(getText("UI_SpatialWell_Description2"), textX, p + FONT_LARGE + FONT_SMALL + 8,
        0.78, 0.76, 0.80, 1, UIFont.Small)

    local statusText = getText(self.isBuilt and "UI_SpatialWell_Status_Built" or "UI_SpatialWell_Status_NotBuilt")
    local statusColor = self.isBuilt and { 0.45, 0.82, 0.48 } or { 0.75, 0.70, 0.66 }
    self:drawText(getText("UI_SpatialWell_Status") .. ": " .. statusText,
        textX, p + FONT_LARGE + FONT_SMALL * 2 + 13,
        statusColor[1], statusColor[2], statusColor[3], 1, UIFont.Small)

    local infoY = p + iconSize + p
    local infoWidth = math.floor((self.width - p * 3) * 0.45)
    local materialsX = p + infoWidth + p
    local materialsWidth = self.width - materialsX - p
    local infoHeight = self.height - infoY - p

    self:drawRect(p, infoY, infoWidth, infoHeight, 0.62, 0.09, 0.07, 0.12)
    self:drawRectBorder(p, infoY, infoWidth, infoHeight, 0.5, 0.24, 0.20, 0.30)
    self:drawText(getText("UI_SpatialWell_Properties"), p * 2, infoY + p,
        0.84, 0.74, 0.58, 1, UIFont.Medium)
    self:drawText(getText("UI_SpatialWell_Capacity") .. ": " .. tostring(MSR.Config.SPATIAL_WELL.CAPACITY),
        p * 2, infoY + p + FONT_MEDIUM + 10, 0.82, 0.82, 0.84, 1, UIFont.Small)
    self:drawText(getText("UI_SpatialWell_RefillRate") .. ": " ..
        getText("UI_SpatialWell_RefillValue", MSR.Config.SPATIAL_WELL.REFILL_PER_HOUR),
        p * 2, infoY + p + FONT_MEDIUM + FONT_SMALL + 16, 0.82, 0.82, 0.84, 1, UIFont.Small)
    self:drawText(getText("UI_SpatialWell_NoSkillRequired"),
        p * 2, infoY + p + FONT_MEDIUM + FONT_SMALL * 2 + 22, 0.56, 0.78, 0.88, 1, UIFont.Small)
    self:drawText(getText("UI_SpatialWell_Immovable"),
        p * 2, infoY + p + FONT_MEDIUM + FONT_SMALL * 3 + 28, 0.72, 0.68, 0.74, 1, UIFont.Small)

    self:drawRect(materialsX, infoY, materialsWidth, infoHeight, 0.62, 0.09, 0.07, 0.12)
    self:drawRectBorder(materialsX, infoY, materialsWidth, infoHeight, 0.5, 0.24, 0.20, 0.30)
    self:drawText(getText("UI_SpatialWell_RequiredResources"), materialsX + p, infoY + p,
        0.84, 0.74, 0.58, 1, UIFont.Medium)

    local rowY = infoY + p + FONT_MEDIUM + 8
    local rowHeight = math.floor(FONT_SMALL * 2.2)
    for index, itemType in ipairs(ITEM_ORDER) do
        self:drawRequirementRow(materialsX + p, rowY, materialsWidth - p * 2,
            rowHeight, itemType, self.requirements[itemType] or 0, index)
        rowY = rowY + rowHeight
    end
end

function MSR_CustomizationPanel:onResize()
    if not self.buildButton then return end
    self.buildButton:setX(self.width - self.padding - self.buildButton:getWidth())
    self.buildButton:setY(self.height - self.padding - self.buildButton:getHeight())
end

return MSR_CustomizationPanel
