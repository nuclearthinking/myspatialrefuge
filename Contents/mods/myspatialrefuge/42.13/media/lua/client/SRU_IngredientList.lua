-- SRU_IngredientList.lua
-- Right panel showing available ingredients for a selected requirement
-- Shows all possible items (primary + substitutes) that the player has
-- Uses manual rendering instead of ISScrollingListBox for reliability

require "ISUI/ISPanel"

SRU_IngredientList = ISPanel:derive("SRU_IngredientList")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

local Config = require "ui/framework/CUI_Config"

-----------------------------------------------------------
-- Constructor
-----------------------------------------------------------

function SRU_IngredientList:new(x, y, width, height, parentWindow)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.parentWindow = parentWindow
    o.player = parentWindow.player
    
    -- Layout
    o.padding = Config.paddingSmall
    o.headerHeight = math.floor(FONT_HGT_MEDIUM * 1.5)
    o.itemHeight = math.floor(FONT_HGT_SMALL * 2.5)
    
    -- Data
    o.requirement = nil
    o.allRequirements = {}
    o.availableItems = {}
    
    -- Scrolling
    o.scrollOffset = 0
    o.maxScroll = 0

    -- Scrollbar interaction (click+drag)
    o._sbDragging = false
    o._sbDragOffsetY = 0
    o._sbThumbY = 0
    o._sbThumbH = 0
    o._sbTrackY = 0
    o._sbTrackH = 0
    o._sbX = 0
    o._sbW = 0
    o._sbTickFn = nil
    
    return o
end

function SRU_IngredientList:initialise()
    ISPanel.initialise(self)
end

function SRU_IngredientList:createChildren()
    -- No children needed - we render everything manually
end

-----------------------------------------------------------
-- Requirements
-----------------------------------------------------------

function SRU_IngredientList:setRequirement(requirement)
    self.requirement = requirement
    self:refreshAvailableItems()
end

function SRU_IngredientList:setRequirements(requirements)
    self.allRequirements = requirements or {}
    self.requirement = nil
    self:refreshAllAvailableItems()
end

function SRU_IngredientList:refreshAvailableItems()
    self.availableItems = {}
    self.scrollOffset = 0
    
    if not self.requirement then
        return
    end
    
    -- Get all possible item types for this requirement
    local itemTypes = {self.requirement.type}
    if self.requirement.substitutes then
        for _, sub in ipairs(self.requirement.substitutes) do
            table.insert(itemTypes, sub)
        end
    end
    
    -- Find available items from player inventory
    self:findAvailableItems(itemTypes)
    
    -- Sort by count (most available first)
    table.sort(self.availableItems, function(a, b)
        return a.count > b.count
    end)
    
    self:updateMaxScroll()
end

function SRU_IngredientList:refreshAllAvailableItems()
    self.availableItems = {}
    self.scrollOffset = 0
    
    if not self.allRequirements or #self.allRequirements == 0 then
        return
    end
    
    -- Collect all unique item types from all requirements
    local allItemTypes = {}
    local seenTypes = {}
    
    for _, req in ipairs(self.allRequirements) do
        if req.type and not seenTypes[req.type] then
            table.insert(allItemTypes, req.type)
            seenTypes[req.type] = true
        end
        if req.substitutes then
            for _, sub in ipairs(req.substitutes) do
                if not seenTypes[sub] then
                    table.insert(allItemTypes, sub)
                    seenTypes[sub] = true
                end
            end
        end
    end
    
    -- Find available items
    self:findAvailableItems(allItemTypes)
    
    -- Sort by count
    table.sort(self.availableItems, function(a, b)
        return a.count > b.count
    end)
    
    self:updateMaxScroll()
end

function SRU_IngredientList:findAvailableItems(itemTypes)
    if not self.player then return end
    
    -- Get item sources (inventory + relic storage)
    local sources = MSR.UpgradeLogic.getItemSources(self.player)
    
    for _, itemType in ipairs(itemTypes) do
        local count = 0
        local sampleItem = nil
        
        -- Count items from all sources
        for _, container in ipairs(sources) do
            if container then
                local items = container:getItems()
                if items then
                    for i = 0, items:size() - 1 do
                        local item = items:get(i)
                        if item and item:getFullType() == itemType then
                            count = count + 1
                            if not sampleItem then
                                sampleItem = item
                            end
                        end
                    end
                end
            end
        end
        
        -- Always show items (even with 0 count) so player knows what they need
        local script = ScriptManager.instance:getItem(itemType)
        local displayName = itemType
        local texture = nil
        
        if script then
            displayName = script:getDisplayName()
            texture = script:getNormalTexture()
        elseif sampleItem then
            displayName = sampleItem:getDisplayName()
            texture = sampleItem:getTexture()
        end
        
        table.insert(self.availableItems, {
            itemType = itemType,
            displayName = displayName,
            count = count,
            texture = texture,
            script = script
        })
    end
end

function SRU_IngredientList:updateMaxScroll()
    local contentHeight = #self.availableItems * self.itemHeight
    local viewHeight = self.height - self.headerHeight - self.padding * 2
    self.maxScroll = math.max(0, contentHeight - viewHeight)
end

-----------------------------------------------------------
-- Mouse Handling
-----------------------------------------------------------

function SRU_IngredientList:onMouseWheel(del)
    local scrollAmount = self.itemHeight
    self.scrollOffset = self.scrollOffset - (del * scrollAmount)
    self.scrollOffset = math.max(0, math.min(self.scrollOffset, self.maxScroll))
    return true
end

-- Click+drag scrollbar support (not mouse wheel)
function SRU_IngredientList:onMouseDown(x, y)
    if not self.maxScroll or self.maxScroll <= 0 then
        return false
    end

    -- Only if click is inside scrollbar track
    if x >= self._sbX and x <= (self._sbX + self._sbW) and y >= self._sbTrackY and y <= (self._sbTrackY + self._sbTrackH) then
        -- Click on thumb -> start dragging
        if y >= self._sbThumbY and y <= (self._sbThumbY + self._sbThumbH) then
            self._sbDragging = true
            self._sbDragOffsetY = y - self._sbThumbY

            -- Capture-style dragging: keep updating even if mouse leaves this panel.
            -- We do this by polling global mouse position each tick while button is held.
            if Events and Events.OnTick and not self._sbTickFn then
                local panel = self
                panel._sbTickFn = function()
                    if not panel._sbDragging then
                        Events.OnTick.Remove(panel._sbTickFn)
                        panel._sbTickFn = nil
                        return
                    end

                    -- If mouse button released, stop dragging.
                    local isDown = (isMouseButtonDown and isMouseButtonDown(0)) or false
                    if not isDown then
                        panel._sbDragging = false
                        Events.OnTick.Remove(panel._sbTickFn)
                        panel._sbTickFn = nil
                        return
                    end

                    -- Use global mouse Y so dragging continues outside the element.
                    local gY = getMouseY and getMouseY() or nil
                    if not gY then
                        -- Can't read global mouse; fail-safe stop to avoid leaking OnTick
                        panel._sbDragging = false
                        Events.OnTick.Remove(panel._sbTickFn)
                        panel._sbTickFn = nil
                        return
                    end

                    local absY = panel.getAbsoluteY and panel:getAbsoluteY() or 0
                    local localY = gY - absY
                    panel:updateScrollFromThumbY(localY - panel._sbDragOffsetY)
                end
                Events.OnTick.Add(panel._sbTickFn)
            end

            return true
        end

        -- Click on track -> jump thumb toward click (page-ish)
        local targetThumbY = y - (self._sbThumbH / 2)
        local minThumbY = self._sbTrackY
        local maxThumbY = self._sbTrackY + (self._sbTrackH - self._sbThumbH)
        if targetThumbY < minThumbY then targetThumbY = minThumbY end
        if targetThumbY > maxThumbY then targetThumbY = maxThumbY end

        local denom = (self._sbTrackH - self._sbThumbH)
        local ratio = 0
        if denom > 0 then
            ratio = (targetThumbY - self._sbTrackY) / denom
        end
        self.scrollOffset = math.max(0, math.min(self.maxScroll * ratio, self.maxScroll))
        return true
    end

    return false
end

function SRU_IngredientList:onMouseUp(x, y)
    if self._sbDragging then
        self._sbDragging = false
        if Events and Events.OnTick and self._sbTickFn then
            Events.OnTick.Remove(self._sbTickFn)
            self._sbTickFn = nil
        end
        return true
    end
    return false
end

function SRU_IngredientList:onMouseUpOutside(x, y)
    if self._sbDragging then
        self._sbDragging = false
        if Events and Events.OnTick and self._sbTickFn then
            Events.OnTick.Remove(self._sbTickFn)
            self._sbTickFn = nil
        end
        return true
    end
    return false
end

function SRU_IngredientList:onMouseMove(dx, dy)
    if not self._sbDragging then
        return false
    end

    -- Keep old behavior when cursor is still over this element.
    local y = self:getMouseY()
    self:updateScrollFromThumbY(y - self._sbDragOffsetY)
    return true
end

-- Convert a desired thumb Y (in panel coords) into scrollOffset.
function SRU_IngredientList:updateScrollFromThumbY(targetThumbY)
    local minThumbY = self._sbTrackY
    local maxThumbY = self._sbTrackY + (self._sbTrackH - self._sbThumbH)
    if targetThumbY < minThumbY then targetThumbY = minThumbY end
    if targetThumbY > maxThumbY then targetThumbY = maxThumbY end

    local denom = (self._sbTrackH - self._sbThumbH)
    local ratio = 0
    if denom > 0 then
        ratio = (targetThumbY - self._sbTrackY) / denom
    end

    self.scrollOffset = math.max(0, math.min(self.maxScroll * ratio, self.maxScroll))
end

-----------------------------------------------------------
-- Rendering
-----------------------------------------------------------

function SRU_IngredientList:prerender()
    -- Panel background
    self:drawRect(0, 0, self.width, self.height, 0.85, 0.08, 0.07, 0.10)
    
    -- Border
    self:drawRectBorder(0, 0, self.width, self.height, 0.6, 0.25, 0.22, 0.30)
    
    -- Header background
    self:drawRect(0, 0, self.width, self.headerHeight, 0.9, 0.12, 0.10, 0.16)
    
    -- Header text
    local header = getText("UI_RefugeUpgrade_AvailableIngredients") or "Available Ingredients"
    local headerW = getTextManager():MeasureStringX(UIFont.Small, header)
    local headerX = (self.width - headerW) / 2
    local headerY = (self.headerHeight - FONT_HGT_SMALL) / 2
    self:drawText(header, headerX, headerY, 0.85, 0.75, 0.55, 1, UIFont.Small)
end

function SRU_IngredientList:render()
    local padding = self.padding
    local listTop = self.headerHeight + padding
    local listHeight = self.height - listTop - padding
    local listWidth = self.width - padding * 2

    -- Reserve space for scrollbar so it doesn't overlap the count column.
    local scrollbarW = self:getScrollbarWidth()
    local showScrollbar = self.maxScroll and self.maxScroll > 0
    if showScrollbar then
        listWidth = listWidth - (scrollbarW + 4)
    end
    
    -- Draw list background
    self:drawRect(padding, listTop, listWidth, listHeight, 0.8, 0.06, 0.05, 0.08)
    self:drawRectBorder(padding, listTop, listWidth, listHeight, 0.6, 0.20, 0.18, 0.25)
    
    if #self.availableItems == 0 then
        local text = getText("UI_RefugeUpgrade_NoIngredients") or "No items available"
        local textW = getTextManager():MeasureStringX(UIFont.Small, text)
        local textX = (self.width - textW) / 2
        local textY = listTop + listHeight / 2 - FONT_HGT_SMALL / 2
        self:drawText(text, textX, textY, 0.5, 0.5, 0.5, 0.6, UIFont.Small)
        return
    end
    
    -- Set clipping for list area
    self:setStencilRect(padding, listTop, listWidth, listHeight)
    
    -- Draw each item
    local itemY = listTop - self.scrollOffset
    local iconPadding = 4
    local iconSize = self.itemHeight - iconPadding * 2
    
    for i, itemInfo in ipairs(self.availableItems) do
        -- Only draw if visible
        if itemY + self.itemHeight > listTop and itemY < listTop + listHeight then
            self:drawIngredientItem(padding, itemY, listWidth, self.itemHeight, itemInfo, i)
        end
        itemY = itemY + self.itemHeight
    end
    
    -- Clear clipping
    self:clearStencilRect()
    
    -- Draw scrollbar if needed
    if showScrollbar then
        self:drawScrollbar(padding + listWidth + 4, listTop, listHeight)
    end
end

function SRU_IngredientList:getScrollbarWidth()
    return 10
end

function SRU_IngredientList:drawIngredientItem(x, y, width, height, itemInfo, index)
    local padding = 6
    local iconSize = height - padding * 2
    
    -- Alternating row background
    if index % 2 == 0 then
        self:drawRect(x, y, width, height, 0.15, 0.08, 0.07, 0.12)
    end
    
    -- Icon
    local iconX = x + padding
    local iconY = y + padding
    if itemInfo.texture then
        self:drawTextureScaledAspect(itemInfo.texture, iconX, iconY, iconSize, iconSize, 1, 1, 1, 1)
    else
        -- Placeholder icon with "?" for unknown items
        self:drawRect(iconX, iconY, iconSize, iconSize, 0.5, 0.25, 0.25, 0.35)
        self:drawRectBorder(iconX, iconY, iconSize, iconSize, 0.6, 0.4, 0.4, 0.5)
        
        -- Draw "?" in center
        local qMark = "?"
        local qFont = UIFont.Small
        local qW = getTextManager():MeasureStringX(qFont, qMark)
        local qH = getTextManager():getFontHeight(qFont)
        self:drawText(qMark, iconX + (iconSize - qW) / 2, iconY + (iconSize - qH) / 2, 0.7, 0.7, 0.7, 0.8, qFont)
    end
    
    -- Name - check if it's a raw item type (like "Base.DirtBag") and format it
    local textX = iconX + iconSize + padding * 2
    local textY = y + (height - FONT_HGT_SMALL) / 2
    
    local displayName = tostring(itemInfo.displayName or "Unknown")
    
    -- If displayName still contains "Base." or similar, extract just the item name
    if displayName:match("^Base%.") or displayName:match("^%w+%.") then
        -- Extract the part after the last dot and make it readable
        local shortName = displayName:match("%.([^%.]+)$") or displayName
        -- Convert CamelCase to words with spaces (e.g., "DirtBag" -> "Dirt Bag")
        displayName = shortName:gsub("(%l)(%u)", "%1 %2")
    end
    
    -- Calculate max text width
    local countText = "x" .. tostring(itemInfo.count or 0)
    local countWidth = getTextManager():MeasureStringX(UIFont.Small, countText)
    local maxTextWidth = x + width - textX - countWidth - padding * 3
    
    -- Truncate if too long
    local nameWidth = getTextManager():MeasureStringX(UIFont.Small, displayName)
    if nameWidth > maxTextWidth and maxTextWidth > 30 then
        while nameWidth > maxTextWidth and #displayName > 3 do
            displayName = displayName:sub(1, -2)
            nameWidth = getTextManager():MeasureStringX(UIFont.Small, displayName .. "...")
        end
        displayName = displayName .. "..."
    end
    
    local textColor = (itemInfo.count or 0) > 0 and {r=0.9, g=0.9, b=0.9} or {r=0.5, g=0.5, b=0.5}
    self:drawText(displayName, textX, textY, textColor.r, textColor.g, textColor.b, 1, UIFont.Small)
    
    -- Count (right-aligned)
    local countX = x + width - countWidth - padding
    local countColor = (itemInfo.count or 0) > 0 and {r=0.5, g=0.8, b=0.5} or {r=0.5, g=0.5, b=0.5}
    self:drawText(countText, countX, textY, countColor.r, countColor.g, countColor.b, 1, UIFont.Small)
end

function SRU_IngredientList:drawScrollbar(scrollbarX, listTop, listHeight)
    local scrollbarWidth = self:getScrollbarWidth()
    
    -- Track
    self:drawRect(scrollbarX, listTop, scrollbarWidth, listHeight, 0.5, 0.1, 0.1, 0.15)
    
    -- Calculate thumb size and position
    local contentHeight = #self.availableItems * self.itemHeight
    local thumbRatio = listHeight / contentHeight
    local thumbHeight = math.max(20, listHeight * thumbRatio)
    local scrollRatio = self.scrollOffset / self.maxScroll
    local thumbY = listTop + (listHeight - thumbHeight) * scrollRatio
    
    -- Thumb
    self:drawRect(scrollbarX, thumbY, scrollbarWidth, thumbHeight, 0.8, 0.4, 0.35, 0.5)

    -- Save geometry for mouse interaction
    self._sbX = scrollbarX
    self._sbW = scrollbarWidth
    self._sbTrackY = listTop
    self._sbTrackH = listHeight
    self._sbThumbY = thumbY
    self._sbThumbH = thumbHeight
end

-----------------------------------------------------------
-- Resize
-----------------------------------------------------------

function SRU_IngredientList:onResize()
    self:updateMaxScroll()
end

return SRU_IngredientList
