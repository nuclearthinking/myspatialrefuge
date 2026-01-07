-- SRU_RequiredItems.lua
-- Panel showing required items for an upgrade
-- Displays item slots with icons, names, and have/need counts

require "ISUI/ISPanel"

SRU_RequiredItems = ISPanel:derive("SRU_RequiredItems")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

local Config = require "ui/framework/CUI_Config"

-----------------------------------------------------------
-- Constructor
-----------------------------------------------------------

function SRU_RequiredItems:new(x, y, width, height, parentPanel)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.parentPanel = parentPanel
    o.player = parentPanel.player
    
    -- Layout
    o.padding = Config.paddingSmall
    o.slotWidth = math.floor(FONT_HGT_MEDIUM * 4)
    o.slotHeight = math.floor(FONT_HGT_MEDIUM * 3.5)
    o.slotSpacing = Config.paddingSmall
    
    -- Data
    o.requirements = {}
    o.slots = {}
    
    -- Callbacks
    o.onSlotClick = nil
    
    return o
end

function SRU_RequiredItems:initialise()
    ISPanel.initialise(self)
end

-----------------------------------------------------------
-- Slot Creation
-----------------------------------------------------------

function SRU_RequiredItems:createChildren()
    -- Slots are created dynamically when requirements are set
end

function SRU_RequiredItems:createSlots()
    -- Clear existing slots
    for _, slot in ipairs(self.slots) do
        self:removeChild(slot)
    end
    self.slots = {}
    
    if #self.requirements == 0 then return end
    
    -- Calculate layout
    local slotsPerRow = math.max(1, math.floor((self.width - self.padding * 2) / (self.slotWidth + self.slotSpacing)))
    local numRows = math.ceil(#self.requirements / slotsPerRow)
    
    for i, req in ipairs(self.requirements) do
        local row = math.floor((i - 1) / slotsPerRow)
        local col = (i - 1) % slotsPerRow
        
        local x = self.padding + col * (self.slotWidth + self.slotSpacing)
        local y = self.padding + FONT_HGT_SMALL + self.padding + row * (self.slotHeight + self.slotSpacing)
        
        local slot = SRU_ItemSlot:new(x, y, self.slotWidth, self.slotHeight, self, i)
        slot:initialise()
        slot:setRequirement(req)
        self:addChild(slot)
        table.insert(self.slots, slot)
    end
    
    -- Calculate required height to fit all rows
    local headerHeight = self.padding + FONT_HGT_SMALL + self.padding
    local slotsHeight = numRows * (self.slotHeight + self.slotSpacing)
    local requiredHeight = headerHeight + slotsHeight + self.padding
    
    -- Update panel height if needed
    if requiredHeight ~= self.height then
        self:setHeight(requiredHeight)
    end
end

-----------------------------------------------------------
-- Requirements
-----------------------------------------------------------

function SRU_RequiredItems:setRequirements(requirements)
    self.requirements = requirements or {}
    self:createSlots()
    self:refreshSlots()
end

function SRU_RequiredItems:refreshSlots()
    for i, slot in ipairs(self.slots) do
        if i <= #self.requirements then
            slot:setRequirement(self.requirements[i])
            slot:updateItemCount()
        end
    end
end

function SRU_RequiredItems:getSelectedRequirement()
    for _, slot in ipairs(self.slots) do
        if slot.isSelected then
            return slot.requirement
        end
    end
    return nil
end

-----------------------------------------------------------
-- Slot Selection
-----------------------------------------------------------

function SRU_RequiredItems:selectSlot(slotIndex)
    -- Deselect all
    for i, slot in ipairs(self.slots) do
        slot:setSelected(i == slotIndex)
    end
    
    -- Notify parent window to update ingredient list
    if self.parentPanel and self.parentPanel.parentWindow then
        local req = self.requirements[slotIndex]
        if req and self.parentPanel.parentWindow.ingredientList then
            self.parentPanel.parentWindow.ingredientList:setRequirement(req)
        end
    end
end

-----------------------------------------------------------
-- Rendering
-----------------------------------------------------------

function SRU_RequiredItems:prerender()
    -- Background
    self:drawRect(0, 0, self.width, self.height, 0.7, 0.06, 0.05, 0.08)
    
    -- Border
    self:drawRectBorder(0, 0, self.width, self.height, 0.5, 0.20, 0.18, 0.25)
    
    -- Header
    local header = getText("UI_RefugeUpgrade_RequiredItems") or "Required Items"
    self:drawText(header, self.padding, self.padding, 0.7, 0.68, 0.72, 1, UIFont.Small)
end

function SRU_RequiredItems:render()
    if #self.requirements == 0 then
        local text = getText("UI_RefugeUpgrade_NoRequirements") or "No items required"
        local textW = getTextManager():MeasureStringX(UIFont.Small, text)
        local textX = (self.width - textW) / 2
        local textY = self.height / 2
        self:drawText(text, textX, textY, 0.5, 0.5, 0.5, 0.6, UIFont.Small)
    end
end

-----------------------------------------------------------
-- Item Slot Component
-----------------------------------------------------------

SRU_ItemSlot = ISPanel:derive("SRU_ItemSlot")

function SRU_ItemSlot:new(x, y, width, height, parent, index)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.parentPanel = parent
    o.player = parent.player
    o.index = index
    
    o.requirement = nil
    o.haveCount = 0
    o.needCount = 0
    o.hasEnough = false
    
    o.isSelected = false
    o.isHovered = false
    
    return o
end

function SRU_ItemSlot:initialise()
    ISPanel.initialise(self)
end

function SRU_ItemSlot:setRequirement(req)
    self.requirement = req
    if req then
        self.needCount = req.count or 1
        self:updateItemCount()
    else
        self.needCount = 0
        self.haveCount = 0
        self.hasEnough = false
    end
end

function SRU_ItemSlot:updateItemCount()
    if not self.requirement or not self.player then
        self.haveCount = 0
        self.hasEnough = false
        return
    end
    
    -- Get available count using upgrade logic
    self.haveCount = MSR.UpgradeLogic.getAvailableItemCount(self.player, self.requirement)
    self.hasEnough = self.haveCount >= self.needCount
end

function SRU_ItemSlot:setSelected(selected)
    self.isSelected = selected
end

function SRU_ItemSlot:onMouseDown(x, y)
    if self.requirement then
        self.parentPanel:selectSlot(self.index)
    end
    return true
end

function SRU_ItemSlot:onMouseMove(dx, dy)
    self.isHovered = true
end

function SRU_ItemSlot:onMouseMoveOutside(dx, dy)
    self.isHovered = false
end

function SRU_ItemSlot:prerender()
    if not self.requirement then return end
    
    -- Background
    local bgR, bgG, bgB, bgA = 0.10, 0.08, 0.12, 0.9
    if self.isSelected then
        bgR, bgG, bgB = 0.20, 0.18, 0.28
    elseif self.isHovered then
        bgR, bgG, bgB = 0.15, 0.13, 0.20
    end
    self:drawRect(0, 0, self.width, self.height, bgA, bgR, bgG, bgB)
    
    -- Border - red if missing items, green if has enough
    local borderR, borderG, borderB = 0.25, 0.22, 0.30
    if self.hasEnough then
        borderR, borderG, borderB = 0.3, 0.6, 0.3
    else
        borderR, borderG, borderB = 0.7, 0.3, 0.3
    end
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, borderR, borderG, borderB)
end

function SRU_ItemSlot:render()
    if not self.requirement then return end
    
    local padding = 4
    local iconSize = self.height - FONT_HGT_SMALL - padding * 3
    
    -- Get item info
    local itemType = self.requirement.type
    local item = ScriptManager.instance:getItem(itemType)
    
    -- Draw icon
    local texture = nil
    if item then
        texture = item:getNormalTexture()
    end
    
    local iconX = (self.width - iconSize) / 2
    local iconY = padding
    
    if texture then
        self:drawTextureScaledAspect(texture, iconX, iconY, iconSize, iconSize, 1, 1, 1, 1)
    else
        -- Placeholder
        self:drawRect(iconX, iconY, iconSize, iconSize, 0.5, 0.3, 0.3, 0.4)
        self:drawText("?", iconX + iconSize/2 - 4, iconY + iconSize/2 - 8, 0.8, 0.8, 0.8, 1, UIFont.Medium)
    end
    
    -- Draw substitution indicator if has substitutes
    if self.requirement.substitutes and #self.requirement.substitutes > 0 then
        local indSize = 12
        self:drawRect(self.width - indSize - 2, 2, indSize, indSize, 0.8, 0.4, 0.4, 0.6)
        self:drawText("?", self.width - indSize + 1, 1, 1, 1, 1, 1, UIFont.Small)
    end
    
    -- Draw count
    local countText = string.format("%d/%d", self.haveCount, self.needCount)
    local countColor = self.hasEnough and {r=0.5, g=0.8, b=0.5} or {r=0.8, g=0.4, b=0.4}
    local countW = getTextManager():MeasureStringX(UIFont.Small, countText)
    local countX = (self.width - countW) / 2
    local countY = self.height - FONT_HGT_SMALL - padding
    
    self:drawText(countText, countX, countY, countColor.r, countColor.g, countColor.b, 1, UIFont.Small)
    
    -- Draw item name (truncated)
    local itemName = ""
    if item then
        itemName = item:getDisplayName()
    else
        -- Extract short name from type
        itemName = itemType:match("%.(.+)$") or itemType
    end
    
    -- Truncate if needed
    local maxWidth = self.width - padding * 2
    local nameWidth = getTextManager():MeasureStringX(UIFont.Small, itemName)
    if nameWidth > maxWidth then
        while nameWidth > maxWidth - 10 and #itemName > 3 do
            itemName = itemName:sub(1, -2)
            nameWidth = getTextManager():MeasureStringX(UIFont.Small, itemName .. "...")
        end
        itemName = itemName .. "..."
    end
    
    -- Draw name below icon (centered)
    nameWidth = getTextManager():MeasureStringX(UIFont.Small, itemName)
    local nameX = (self.width - nameWidth) / 2
    -- Name is drawn as part of tooltip on hover, not here to avoid clutter
end

return SRU_RequiredItems

