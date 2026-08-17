require "ISUI/ISPanel"
require "ISUI/ISButton"
require "MSR_SpatialWell"
require "MSR_Echo"
require "MSR_SpatialWellCursor"
require "MSR_UpgradeItemCache"
require "MSR_PlayerMessage"

--[[
    Structures ("Обустройство") tab.

    Card list on the left, details on the right - the same shape as the upgrades
    tab, rendered by the same ui/ components. The tab itself is data-driven: it
    walks the BUILDABLES registry below, so adding a structure to the refuge is
    a new registry entry, not a new screen.

    A registry entry:

        id          unique string
        icon        texture path for the card and the details header
        nameKey     translation key of the display name
        descriptionKeys  ordered translation keys, one paragraph each
        getStatus(panel) -> { built, textKey, color }    current world state
        getProperties(panel) -> { {labelKey, value, color?}, ... }
        getCosts(panel) -> { {texture, label, have, need}, ... }  echo row first
        getAction(panel) -> { labelKey, enabled, reason }  the footer button
        onAction(panel)  perform/start the build
]]

---@class MSR_CustomizationPanel : ISPanel
---@field parentWindow MSR_UpgradeWindow
---@field player IsoPlayer
---@field padding number
MSR_CustomizationPanel = ISPanel:derive("MSR_CustomizationPanel")

local Theme = require "ui/MSR_Theme"
local Widgets = require "ui/MSR_Widgets"
local MSR_CardList = require "ui/MSR_CardList"
local M = Theme.metrics
local C = Theme.color

local FONT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_LARGE = getTextManager():getFontHeight(UIFont.Large)

local CARDS_WIDTH_RATIO = 0.36
local WELL_ITEM_ORDER = {
    "Base.MetalPipe",
    "Base.ConcretePowder",
    "Base.BucketEmpty",
}

local function wellItemDisplay(itemType)
    local displayName, texture = MSR.UpgradeItemCache.getItemMeta(itemType)
    if itemType == MSR.Config.SPATIAL_WELL.EMPTY_BUCKET_TYPE then
        displayName = getText("UI_SpatialWell_EmptyBucket")
    end
    return tostring(displayName or itemType), texture
end

--==============================================================================
-- BUILDABLE REGISTRY
--==============================================================================

local BUILDABLES = {
    {
        id = "spatial_well",
        icon = "media/ui/SpatialWell_128x128.png",
        nameKey = "UI_SpatialWell_Name",
        descriptionKeys = { "UI_SpatialWell_Description", "UI_SpatialWell_Description2" },

        getStatus = function(panel)
            local refugeData = MSR.Data.GetRefugeData(panel.player)
            local built = MSR.SpatialWell.IsBuilt(refugeData)
            return {
                built = built,
                textKey = built and "UI_SpatialWell_Status_Built" or "UI_SpatialWell_Status_NotBuilt",
                color = built and C.ok or C.warn,
            }
        end,

        getProperties = function(_panel)
            return {
                { labelKey = "UI_SpatialWell_Capacity",
                  value = tostring(MSR.Config.SPATIAL_WELL.CAPACITY) },
                { labelKey = "UI_SpatialWell_RefillRate",
                  value = getText("UI_SpatialWell_RefillValue",
                      MSR.Config.SPATIAL_WELL.REFILL_PER_HOUR) },
            }
        end,

        getCosts = function(panel)
            local refugeData = MSR.Data.GetRefugeData(panel.player)
            local echoName, echoTexture = MSR.UpgradeItemCache.getItemMeta(
                MSR.Config.ECHO.DISPLAY_ITEM, panel.player)
            local costs = {
                {
                    texture = echoTexture,
                    label = tostring(echoName or getText("UI_RefugeUpgrade_EchoCost")),
                    have = MSR.Echo.GetBalance(refugeData),
                    need = MSR.SpatialWell.GetEchoCost(),
                },
            }
            local requirements = MSR.SpatialWell.GetRequirements()
            for _, itemType in ipairs(WELL_ITEM_ORDER) do
                local need = requirements[itemType]
                if need then
                    local have
                    if itemType == MSR.Config.SPATIAL_WELL.EMPTY_BUCKET_TYPE then
                        have = MSR.SpatialWell.CountEmptyBuckets(panel.player)
                    else
                        have = MSR.UpgradeItemCache.getCount(itemType)
                    end
                    local label, texture = wellItemDisplay(itemType)
                    costs[#costs + 1] = { texture = texture, label = label,
                                          have = have, need = need }
                end
            end
            return costs
        end,

        getAction = function(panel, entry)
            local status = entry.getStatus(panel)
            if status.built then
                return { labelKey = "UI_SpatialWell_Built", enabled = false }
            end
            local missing = {}
            for _, cost in ipairs(entry.getCosts(panel)) do
                if cost.have < cost.need then missing[#missing + 1] = cost.label end
            end
            if #missing > 0 then
                return { labelKey = "UI_SpatialWell_Build", enabled = false,
                         reason = getText("UI_Refuge_MissingList",
                             table.concat(missing, ", ")) }
            end
            return { labelKey = "UI_SpatialWell_Build", enabled = true }
        end,

        onAction = function(panel)
            if panel.parentWindow then panel.parentWindow:close() end
            if not MSR_SpatialWellCursor.Start(panel.player) then
                MSR.PlayerMessage.Say(panel.player, MSR.PlayerMessage.SPATIAL_WELL_BUILD_FAILED)
            end
        end,
    },
}

--==============================================================================
-- PANEL
--==============================================================================

function MSR_CustomizationPanel:new(x, y, width, height, parentWindow)
    local o = ISPanel:new(x, y, width, height) --[[@as MSR_CustomizationPanel]]
    setmetatable(o, self)
    self.__index = self
    o.parentWindow = parentWindow
    o.player = parentWindow.player
    o.padding = M.pad
    o.selectedId = nil
    o.drawFrame = false
    return o
end

function MSR_CustomizationPanel:initialise()
    ISPanel.initialise(self)
end

function MSR_CustomizationPanel:cardsWidth()
    return math.floor(self.width * CARDS_WIDTH_RATIO)
end

function MSR_CustomizationPanel:createChildren()
    self.cardList = MSR_CardList:new(0, 0, self:cardsWidth(), self.height, self,
        function(panel, id) panel:selectBuildable(id) end)
    self.cardList:initialise()
    self:addChild(self.cardList)

    self.actionButton = ISButton:new(0, 0, math.floor(M.fontMedium * 11),
        math.floor(M.buttonHeight * 1.2), "", self, self.onActionClick)
    self.actionButton:initialise()
    Theme.styleButton(self.actionButton, "primary")
    self.actionButton:setFont(UIFont.Medium)
    self:addChild(self.actionButton)

    self:layoutControls()
    self:refresh()
end

function MSR_CustomizationPanel:layoutControls()
    if self.cardList then
        self.cardList:setWidth(self:cardsWidth())
        self.cardList:setHeight(self.height)
        self.cardList:onResize()
    end
    if self.actionButton then
        self.actionButton:setX(self.width - self.padding - self.actionButton:getWidth())
        self.actionButton:setY(self.height - self.padding - self.actionButton:getHeight())
    end
end

function MSR_CustomizationPanel:onResize()
    self:layoutControls()
end

--==============================================================================
-- DATA
--==============================================================================

function MSR_CustomizationPanel.getEntry(id)
    for _, entry in ipairs(BUILDABLES) do
        if entry.id == id then return entry end
    end
    return nil
end

function MSR_CustomizationPanel:refresh()
    MSR.UpgradeItemCache.setPlayer(self.player)

    local group = getText("UI_Refuge_BuildablesGroup")
    local cards = {}
    for _, entry in ipairs(BUILDABLES) do
        local status = entry.getStatus(self)
        local state, note
        if status.built then
            state = "max"
        else
            local action = entry.getAction(self, entry)
            state = action.enabled and "ready" or "poor"
            local costs = entry.getCosts(self)
            local echo = costs[1]
            note = echo and getText("UI_Refuge_CostEcho", Theme.formatNumber(echo.need)) or nil
        end
        cards[#cards + 1] = {
            id = entry.id,
            group = group,
            icon = getTexture(entry.icon),
            title = getText(entry.nameKey),
            note = note,
            state = state,
        }
    end
    if self.cardList then
        self.cardList:setCards(cards)
        if not self.selectedId then
            self.selectedId = self.cardList:firstSelectableId()
        end
        self.cardList:setSelected(self.selectedId)
    end
    self:updateActionButton()
end

function MSR_CustomizationPanel:selectBuildable(id)
    self.selectedId = id
    self:updateActionButton()
end

function MSR_CustomizationPanel:updateActionButton()
    local entry = self.getEntry(self.selectedId)
    if not self.actionButton then return end
    if not entry then
        self.actionButton:setVisible(false)
        return
    end
    local action = entry.getAction(self, entry)
    self.actionButton:setVisible(true)
    self.actionButton:setTitle(getText(action.labelKey))
    self.actionButton:setEnable(action.enabled == true)
    self._blockReason = action.reason
    if action.enabled then
        Theme.styleButton(self.actionButton, "primary")
    else
        Theme.styleButton(self.actionButton)
    end
end

function MSR_CustomizationPanel:onActionClick()
    local entry = self.getEntry(self.selectedId)
    if not entry then return end
    local action = entry.getAction(self, entry)
    if not action.enabled then
        if action.reason then MSR.PlayerMessage.SayRaw(self.player, action.reason) end
        return
    end
    entry.onAction(self)
end

--==============================================================================
-- RENDER
--==============================================================================

function MSR_CustomizationPanel:renderDetails(entry, x, w)
    local p = self.padding
    Theme.box(self, x, 0, w, self.height, C.inset, C.border)
    Theme.fill(self, x + 1, 1, w - 2, 2, C.brass)

    local contentX = x + p
    local contentW = w - p * 2
    local y = p + 2

    -- Header: framed art, name, status
    local artSize = math.floor(FONT_LARGE * 4.2)
    Widgets.iconSlot(self, getTexture(entry.icon), contentX, y, artSize)

    local textX = contentX + artSize + p
    Theme.text(self, getText(entry.nameKey), textX, y, C.brassHi, UIFont.Large)
    local status = entry.getStatus(self)
    Theme.text(self, getText("UI_SpatialWell_Status") .. ": " .. getText(status.textKey),
        textX, y + FONT_LARGE + M.padSmall, status.color, UIFont.Small)

    local descY = y + FONT_LARGE + FONT_SMALL + M.pad
    local descW = w - (textX - x) - p
    for _, key in ipairs(entry.descriptionKeys or {}) do
        for _, line in ipairs(Widgets.wrapText(getText(key), descW, UIFont.Small)) do
            Theme.text(self, line, textX, descY, C.textDim, UIFont.Small)
            descY = descY + FONT_SMALL
        end
    end
    y = math.max(y + artSize, descY) + p

    -- Two columns: properties on the left, costs on the right
    local colW = math.floor((contentW - p) / 2)
    local leftY = Widgets.sectionHeader(self, contentX, y, colW,
        getText("UI_SpatialWell_Properties"))
    for _, prop in ipairs(entry.getProperties(self)) do
        if prop.value == "" then
            leftY = Widgets.keyValueRow(self, contentX, leftY, colW,
                getText(prop.labelKey), "", prop.color)
        else
            leftY = Widgets.keyValueRow(self, contentX, leftY, colW,
                getText(prop.labelKey), prop.value, prop.color)
        end
    end

    local rightX = contentX + colW + p
    local rightY = Widgets.sectionHeader(self, rightX, y, colW,
        getText("UI_SpatialWell_RequiredResources"))
    for _, cost in ipairs(entry.getCosts(self)) do
        rightY = Widgets.costRow(self, rightX, rightY, colW,
            cost.texture, cost.label, cost.have, cost.need)
    end

    -- Footer: keep long missing-resource lists above the action button so they
    -- can use the full details width instead of disappearing behind the button.
    if self._blockReason and self.actionButton and self.actionButton:isVisible() then
        local reasonLines = Widgets.wrapText(self._blockReason, contentW, UIFont.Small)
        local reasonY = self.actionButton:getY() - M.padSmall - #reasonLines * FONT_SMALL
        for _, line in ipairs(reasonLines) do
            Theme.text(self, line, contentX, reasonY, C.bad, UIFont.Small)
            reasonY = reasonY + FONT_SMALL
        end
    end
end

function MSR_CustomizationPanel:prerender()
    Theme.box(self, 0, 0, self.width, self.height, C.panel)
    local entry = self.getEntry(self.selectedId)
    local x = self:cardsWidth() + self.padding
    if entry then
        self:renderDetails(entry, x, self.width - x)
    end
end

return MSR_CustomizationPanel
