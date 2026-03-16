-- SRU_UpgradeGrid.lua
-- Left panel showing a grid of upgrade icons
-- Uses virtual scrolling for efficient rendering

require "ISUI/ISPanel"
require "MSR_UpgradeData"

SRU_UpgradeGrid = ISPanel:derive("SRU_UpgradeGrid")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

local Config = require "ui/framework/CUI_Config"

-----------------------------------------------------------
-- Constructor
-----------------------------------------------------------

function SRU_UpgradeGrid:new(x, y, width, height, parentWindow)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.parentWindow = parentWindow
    o.player = parentWindow.player
    
    -- Layout
    o.padding = Config.paddingSmall
    o.slotSpacing = 6
    o.targetColumns = 4  -- Target 4 icons per row for larger, clearer icons
    o.minSlotSize = 48   -- Minimum slot size in pixels
    o.slotSize = o.minSlotSize  -- Will be recalculated in calculateGridMetrics
    
    -- Data
    o.upgrades = {}
    o.slots = {}
    o.selectedSlotIndex = nil
    
    -- Scroll state
    o.scrollOffset = 0
    o.maxScrollOffset = 0
    o.smoothScrollY = nil
    o.smoothScrollTargetY = nil
    
    return o
end

function SRU_UpgradeGrid:initialise()
    ISPanel.initialise(self)
end

-----------------------------------------------------------
-- Slot Creation
-----------------------------------------------------------

function SRU_UpgradeGrid:createChildren()
    -- Calculate grid dimensions
    self:calculateGridMetrics()
    
    -- Create slot pool
    self:createSlotPool()
    
    -- Load upgrades
    self:refreshUpgrades()
end

function SRU_UpgradeGrid:calculateGridMetrics()
    local availableWidth = self.width - self.padding * 2
    
    -- Use target columns (default 6), but allow fewer if panel is too narrow
    self.columnsPerRow = self.targetColumns or 6
    
    -- Calculate slot size to fit target columns
    local totalSpacing = (self.columnsPerRow - 1) * self.slotSpacing
    self.slotSize = math.floor((availableWidth - totalSpacing) / self.columnsPerRow)
    
    -- Ensure minimum slot size
    if self.slotSize < self.minSlotSize then
        self.slotSize = self.minSlotSize
        -- Recalculate columns based on minimum size
        self.columnsPerRow = math.max(1, math.floor(availableWidth / (self.slotSize + self.slotSpacing)))
    end
end

function SRU_UpgradeGrid:createSlotPool()
    -- Clear existing slots
    for _, slot in ipairs(self.slots) do
        self:removeChild(slot)
    end
    self.slots = {}
    
    -- Calculate how many slots we need visible
    local visibleRows = math.ceil(self.height / (self.slotSize + self.slotSpacing)) + 2
    local poolSize = visibleRows * self.columnsPerRow
    
    -- Create slot pool
    for i = 1, poolSize do
        local slot = SRU_UpgradeSlot:new(0, 0, self.slotSize, self.slotSize, self, i)
        slot:initialise()
        slot:setVisible(false)
        self:addChild(slot)
        table.insert(self.slots, slot)
    end
end

-----------------------------------------------------------
-- Upgrade Data
-----------------------------------------------------------

function SRU_UpgradeGrid:refreshUpgrades()
    -- Get all upgrades
    self.upgrades = {}
    local ids = MSR.UpgradeData.getAllUpgradeIds()
    
    for _, id in ipairs(ids) do
        local upgrade = MSR.UpgradeData.getUpgrade(id)
        if upgrade then
            table.insert(self.upgrades, upgrade)
        end
    end
    
    -- Calculate scroll metrics
    self:updateScrollMetrics()
    
    -- Refresh visible slots
    self:refreshSlots()
end

function SRU_UpgradeGrid:updateScrollMetrics()
    local rowCount = math.ceil(#self.upgrades / self.columnsPerRow)
    local contentHeight = rowCount * (self.slotSize + self.slotSpacing) + self.padding * 2
    
    self.maxScrollOffset = math.max(0, contentHeight - self.height)
    self.scrollOffset = math.max(0, math.min(self.scrollOffset, self.maxScrollOffset))
end

-----------------------------------------------------------
-- Slot Refresh (Virtual Scrolling)
-----------------------------------------------------------

function SRU_UpgradeGrid:refreshSlots()
    -- Hide all slots first
    for _, slot in ipairs(self.slots) do
        slot:setVisible(false)
    end
    
    if #self.upgrades == 0 then return end
    
    -- Calculate visible range
    local startY = self.scrollOffset
    local endY = self.scrollOffset + self.height
    
    local rowHeight = self.slotSize + self.slotSpacing
    local startRow = math.max(0, math.floor(startY / rowHeight))
    local endRow = math.ceil(endY / rowHeight)
    
    -- Assign upgrades to visible slots
    local slotIndex = 1
    for row = startRow, endRow do
        for col = 0, self.columnsPerRow - 1 do
            if slotIndex > #self.slots then break end
            
            local upgradeIndex = row * self.columnsPerRow + col + 1
            if upgradeIndex <= #self.upgrades then
                local slot = self.slots[slotIndex]
                local upgrade = self.upgrades[upgradeIndex]
                
                -- Position slot
                local x = self.padding + col * (self.slotSize + self.slotSpacing)
                local y = self.padding + row * rowHeight - self.scrollOffset
                
                slot:setX(x)
                slot:setY(y)
                slot:setUpgrade(upgrade, upgradeIndex)
                slot:setSelected(self.selectedSlotIndex == upgradeIndex)
                slot:setVisible(true)
                
                slotIndex = slotIndex + 1
            end
        end
    end
end

-----------------------------------------------------------
-- Selection
-----------------------------------------------------------

function SRU_UpgradeGrid:selectUpgrade(upgradeIndex)
    if upgradeIndex < 1 or upgradeIndex > #self.upgrades then return end
    
    self.selectedSlotIndex = upgradeIndex
    
    -- Notify parent window
    local upgrade = self.upgrades[upgradeIndex]
    if upgrade and self.parentWindow then
        self.parentWindow:selectUpgrade(upgrade.id)
    end
    
    -- Refresh slots to update selection state
    self:refreshSlots()
end

-----------------------------------------------------------
-- Scrolling
-----------------------------------------------------------

function SRU_UpgradeGrid:onMouseWheel(del)
    if self.maxScrollOffset <= 0 then return false end
    
    local scrollAmount = self.slotSize + self.slotSpacing
    local currentScroll = self.smoothScrollTargetY or self.scrollOffset
    local targetScroll = currentScroll - (del * scrollAmount)
    
    targetScroll = math.max(0, math.min(targetScroll, self.maxScrollOffset))
    
    self.smoothScrollTargetY = targetScroll
    if not self.smoothScrollY then
        self.smoothScrollY = self.scrollOffset
    end
    
    return true
end

function SRU_UpgradeGrid:updateSmoothScrolling()
    if not self.smoothScrollTargetY then return end
    
    if not self.smoothScrollY then
        self.smoothScrollY = self.scrollOffset
    end
    
    local dy = self.smoothScrollTargetY - self.smoothScrollY
    local frameRateFrac = UIManager.getMillisSinceLastRender() / 33.3
    local moveAmount = dy * math.min(0.5, 0.25 * frameRateFrac)
    
    if frameRateFrac > 1 then
        moveAmount = dy * math.min(1.0, math.min(0.5, 0.25 * frameRateFrac) * frameRateFrac)
    end
    
    local newOffset = self.smoothScrollY + moveAmount
    
    if math.abs(newOffset - self.smoothScrollY) > 0.1 then
        self.scrollOffset = newOffset
        self.smoothScrollY = newOffset
        self:refreshSlots()
    else
        self.scrollOffset = self.smoothScrollTargetY
        self.smoothScrollTargetY = nil
        self.smoothScrollY = nil
        self:refreshSlots()
    end
end

-----------------------------------------------------------
-- Resize
-----------------------------------------------------------

function SRU_UpgradeGrid:onResize()
    self:calculateGridMetrics()
    self:createSlotPool()
    self:updateScrollMetrics()
    self:refreshSlots()
end

-----------------------------------------------------------
-- Rendering
-----------------------------------------------------------

function SRU_UpgradeGrid:prerender()
    -- Panel background
    self:drawRect(0, 0, self.width, self.height, 0.8, 0.08, 0.07, 0.10)
    
    -- Border
    self:drawRectBorder(0, 0, self.width, self.height, 0.6, 0.25, 0.22, 0.30)
    
    -- Stencil for scrolling content
    self:setStencilRect(0, 0, self.width, self.height)
    
    -- Update smooth scrolling
    self:updateSmoothScrolling()
end

function SRU_UpgradeGrid:render()
    self:clearStencilRect()
    
    -- Draw scroll indicator if needed
    if self.maxScrollOffset > 0 then
        local scrollbarWidth = 4
        local scrollbarHeight = math.max(20, (self.height / (self.height + self.maxScrollOffset)) * self.height)
        local scrollbarY = (self.scrollOffset / self.maxScrollOffset) * (self.height - scrollbarHeight)
        
        self:drawRect(
            self.width - scrollbarWidth - 2,
            scrollbarY,
            scrollbarWidth,
            scrollbarHeight,
            0.6, 0.5, 0.5, 0.6
        )
    end
end

-----------------------------------------------------------
-- Upgrade Slot Component
-----------------------------------------------------------

SRU_UpgradeSlot = ISPanel:derive("SRU_UpgradeSlot")

function SRU_UpgradeSlot:new(x, y, width, height, grid, index)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.grid = grid
    o.index = index
    o.upgrade = nil
    o.upgradeIndex = nil
    o.isSelected = false
    o.isHovered = false
    o.isLocked = false
    
    return o
end

function SRU_UpgradeSlot:initialise()
    ISPanel.initialise(self)
end

function SRU_UpgradeSlot:setUpgrade(upgrade, upgradeIndex)
    self.upgrade = upgrade
    self.upgradeIndex = upgradeIndex
    
    -- Check if locked (dependencies not met)
    if upgrade and self.grid.player then
        self.isLocked = not MSR.UpgradeData.isUpgradeUnlocked(self.grid.player, upgrade.id)
        self.playerLevel = MSR.UpgradeData.getPlayerUpgradeLevel(self.grid.player, upgrade.id)
    else
        self.isLocked = false
        self.playerLevel = 0
    end
end

function SRU_UpgradeSlot:setSelected(selected)
    self.isSelected = selected
end

function SRU_UpgradeSlot:onMouseDown(x, y)
    -- Allow clicking locked upgrades so users can see their requirements
    if self.upgrade then
        self.grid:selectUpgrade(self.upgradeIndex)
    end
    return true
end

function SRU_UpgradeSlot:onMouseMove(dx, dy)
    self.isHovered = true
end

function SRU_UpgradeSlot:onMouseMoveOutside(dx, dy)
    self.isHovered = false
end

function SRU_UpgradeSlot:prerender()
    if not self.upgrade then return end
    
    -- Background color based on state
    local bgR, bgG, bgB, bgA = 0.12, 0.10, 0.15, 0.9
    
    if self.isSelected then
        -- Selected always shows selection color (even if locked)
        bgR, bgG, bgB, bgA = 0.35, 0.28, 0.45, 0.95
    elseif self.isHovered then
        -- Hover state (works for locked too now)
        bgR, bgG, bgB, bgA = 0.25, 0.22, 0.30, 0.95
    elseif self.isLocked then
        bgR, bgG, bgB, bgA = 0.10, 0.08, 0.10, 0.9
    end
    
    self:drawRect(0, 0, self.width, self.height, bgA, bgR, bgG, bgB)
    
    -- Border
    local borderR, borderG, borderB = 0.30, 0.25, 0.38
    if self.isSelected then
        borderR, borderG, borderB = 0.65, 0.45, 0.85
    elseif self.isLocked then
        borderR, borderG, borderB = 0.35, 0.20, 0.20
    elseif self.playerLevel and self.playerLevel > 0 then
        borderR, borderG, borderB = 0.4, 0.7, 0.4
    end
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, borderR, borderG, borderB)
end

function SRU_UpgradeSlot:render()
    if not self.upgrade then return end
    
    local iconPadding = 2
    local iconSize = self.width - iconPadding * 2
    
    -- Draw icon (try to load texture, fallback to zombie core or placeholder)
    local texture = getTexture(self.upgrade.icon)
    if not texture then
        -- Try to use zombie core as fallback icon
        texture = getTexture("media/textures/sacred_core.png") or getTexture("Item_ZombieCore")
    end
    
    if texture then
        local alpha = self.isLocked and 0.4 or 1.0
        self:drawTextureScaledAspect(texture, iconPadding, iconPadding, iconSize, iconSize, alpha, 1, 1, 1)
    else
        -- Ultimate fallback - draw a colored placeholder with first letter
        local alpha = self.isLocked and 0.3 or 0.6
        self:drawRect(iconPadding, iconPadding, iconSize, iconSize, alpha, 0.4, 0.3, 0.5)
        
        -- Draw first letter of upgrade name
        if self.upgrade.name then
            local letter = self.upgrade.name:sub(1, 1):upper()
            local font = UIFont.Medium
            local letterW = getTextManager():MeasureStringX(font, letter)
            local letterH = getTextManager():getFontHeight(font)
            self:drawText(
                letter,
                iconPadding + (iconSize - letterW) / 2,
                iconPadding + (iconSize - letterH) / 2,
                1, 1, 1, alpha,
                font
            )
        end
    end
    
    -- Check if max level reached
    local maxLvl = self.upgrade.maxLevel or 1
    local isMaxLevel = self.playerLevel and self.playerLevel >= maxLvl
    
    -- Debug: uncomment to see values
    -- if self.playerLevel and self.playerLevel > 0 then
    --     print("[SRU_UpgradeSlot] " .. tostring(self.upgrade.id) .. " playerLevel=" .. tostring(self.playerLevel) .. " maxLevel=" .. tostring(maxLvl) .. " isMax=" .. tostring(isMaxLevel))
    -- end
    
    -- Draw level badge or max level indicator (scaled to slot size)
    if isMaxLevel then
        -- Green checkmark badge for max level
        local badgeSize = math.max(16, math.floor(self.width * 0.35))
        local badgeX = self.width - badgeSize - 1
        local badgeY = 1
        
        -- Badge background (bright green)
        self:drawRect(badgeX, badgeY, badgeSize, badgeSize, 0.95, 0.15, 0.55, 0.15)
        self:drawRectBorder(badgeX, badgeY, badgeSize, badgeSize, 0.9, 0.4, 0.9, 0.4)
        
        -- Draw checkmark icon
        local checkmarkTexture = getTexture("media/textures/checkmark_16x16.png")
        if checkmarkTexture then
            local iconPad = 2
            self:drawTextureScaledAspect(
                checkmarkTexture, 
                badgeX + iconPad, 
                badgeY + iconPad, 
                badgeSize - iconPad * 2, 
                badgeSize - iconPad * 2, 
                1, 1, 1, 1
            )
        else
            -- Fallback to "M" text if texture not found
            local checkText = "M"
            local font = UIFont.Small
            local textW = getTextManager():MeasureStringX(font, checkText)
            local textH = getTextManager():getFontHeight(font)
            self:drawText(
                checkText,
                badgeX + (badgeSize - textW) / 2,
                badgeY + (badgeSize - textH) / 2,
                1, 1, 1, 1,
                font
            )
        end
    elseif self.playerLevel and self.playerLevel > 0 then
        -- Regular level badge
        local badgeSize = math.max(10, math.floor(self.width * 0.35))
        local badgeX = self.width - badgeSize - 1
        local badgeY = 1
        
        -- Badge background
        self:drawRect(badgeX, badgeY, badgeSize, badgeSize, 0.9, 0.2, 0.6, 0.2)
        
        -- Level number
        local levelText = tostring(self.playerLevel)
        local font = UIFont.Small
        local textW = getTextManager():MeasureStringX(font, levelText)
        local textH = getTextManager():getFontHeight(font)
        self:drawText(
            levelText,
            badgeX + (badgeSize - textW) / 2,
            badgeY + (badgeSize - textH) / 2,
            1, 1, 1, 1,
            font
        )
    end
    
    -- Draw lock overlay if locked
    if self.isLocked then
        -- Semi-transparent dark overlay on entire slot (subtle, not alarming)
        self:drawRect(0, 0, self.width, self.height, 0.5, 0.0, 0.0, 0.0)
        
        -- Lock icon in corner (bottom-left)
        local lockBadgeSize = math.max(16, math.floor(self.width * 0.4))
        local lockX = 2
        local lockY = self.height - lockBadgeSize - 2
        
        -- Lock badge background (neutral dark gray)
        self:drawRect(lockX, lockY, lockBadgeSize, lockBadgeSize, 0.85, 0.18, 0.18, 0.20)
        self:drawRectBorder(lockX, lockY, lockBadgeSize, lockBadgeSize, 0.7, 0.35, 0.35, 0.38)
        
        -- Draw gray cross icon
        local crossTexture = getTexture("media/textures/lock_gray_16x16.png")
        if crossTexture then
            local iconPad = 2
            self:drawTextureScaledAspect(
                crossTexture,
                lockX + iconPad,
                lockY + iconPad,
                lockBadgeSize - iconPad * 2,
                lockBadgeSize - iconPad * 2,
                1, 1, 1, 1
            )
        else
            -- Fallback to "X" text if texture not found
            local lockText = "X"
            local font = UIFont.Small
            local textW = getTextManager():MeasureStringX(font, lockText)
            local textH = getTextManager():getFontHeight(font)
            self:drawText(
                lockText,
                lockX + (lockBadgeSize - textW) / 2,
                lockY + (lockBadgeSize - textH) / 2,
                0.6, 0.6, 0.6, 1,
                font
            )
        end
    end
end

return SRU_UpgradeGrid

