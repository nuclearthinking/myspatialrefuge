--[[
    CUI_SearchBox.lua - Search Input with Clear Button
    
    A styled search input box with:
    - Optional search mode button
    - Clear button that appears when text exists
    - Custom styled background
    
    Usage:
        local searchBox = CUI_SearchBox:new(x, y, width, height, target)
        searchBox:setOnSearchChanged(function(text) ... end)
]]

require "ISUI/ISPanel"
require "ISUI/ISTextEntryBox"

CUI_SearchBox = ISPanel:derive("CUI_SearchBox")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)

--==============================================================================
-- CONSTRUCTOR
--==============================================================================

function CUI_SearchBox:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o:noBackground()
    o.searchText = ""
    o.placeholder = "Search..."
    
    -- Sizing
    o.padding = math.floor(FONT_HGT_SMALL * 0.3)
    o.clearButtonSize = math.floor(height * 0.6)
    o.searchIconSize = math.floor(height * 0.5)
    
    -- Colors
    o.bgColor = {r=0.12, g=0.12, b=0.15, a=0.95}
    o.borderColor = {r=0.3, g=0.28, b=0.35, a=0.6}
    o.textColor = {r=0.9, g=0.9, b=0.9, a=1}
    o.placeholderColor = {r=0.5, g=0.48, b=0.52, a=0.7}
    
    -- Icons
    o.searchIcon = getTexture("media/ui/search.png")  -- Will fallback if not found
    o.clearIcon = nil  -- Will draw X manually
    
    -- Callbacks
    o.onSearchChanged = nil
    o.onSearchCleared = nil
    
    return o
end

function CUI_SearchBox:initialise()
    ISPanel.initialise(self)
end

--==============================================================================
-- CREATE CHILDREN
--==============================================================================

function CUI_SearchBox:createChildren()
    ISPanel.createChildren(self)
    
    -- Text entry box
    local entryX = self.padding + self.searchIconSize + self.padding
    local entryWidth = self.width - entryX - self.clearButtonSize - self.padding
    local entryY = (self.height - FONT_HGT_SMALL) / 2
    
    self.textEntry = ISTextEntryBox:new(
        "", 
        entryX, 
        0, 
        entryWidth, 
        self.height
    )
    self.textEntry:initialise()
    self.textEntry:instantiate()
    self.textEntry.font = UIFont.Small
    self.textEntry.backgroundColor = {r=0, g=0, b=0, a=0}
    self.textEntry.borderColor = {r=0, g=0, b=0, a=0}
    
    -- Capture text changes
    local self_ref = self
    self.textEntry.onTextChange = function()
        self_ref:onTextChanged()
    end
    
    self:addChild(self.textEntry)
    
    -- Clear button (invisible ISButton for click handling)
    local clearX = self.width - self.clearButtonSize - self.padding
    local clearY = (self.height - self.clearButtonSize) / 2
    
    self.clearButton = ISButton:new(
        clearX,
        clearY,
        self.clearButtonSize,
        self.clearButtonSize,
        "",
        self,
        self.onClearClick
    )
    self.clearButton:initialise()
    self.clearButton:instantiate()
    self.clearButton.borderColor = {r=0, g=0, b=0, a=0}
    self.clearButton.backgroundColor = {r=0, g=0, b=0, a=0}
    self.clearButton.backgroundColorMouseOver = {r=0.3, g=0.28, b=0.35, a=0.5}
    self.clearButton:setVisible(false)
    self:addChild(self.clearButton)
end

--==============================================================================
-- CONFIGURATION
--==============================================================================

function CUI_SearchBox:setPlaceholder(text)
    self.placeholder = text
end

function CUI_SearchBox:setOnSearchChanged(callback)
    self.onSearchChanged = callback
end

function CUI_SearchBox:setOnSearchCleared(callback)
    self.onSearchCleared = callback
end

function CUI_SearchBox:setBgColor(r, g, b, a)
    self.bgColor = {r=r, g=g, b=b, a=a or 0.95}
end

function CUI_SearchBox:setBorderColor(r, g, b, a)
    self.borderColor = {r=r, g=g, b=b, a=a or 0.6}
end

function CUI_SearchBox:getText()
    return self.searchText
end

function CUI_SearchBox:setText(text)
    self.searchText = text or ""
    if self.textEntry then
        self.textEntry:setText(self.searchText)
    end
    self:updateClearButtonVisibility()
end

function CUI_SearchBox:clear()
    self:setText("")
    if self.onSearchCleared then
        self.onSearchCleared()
    end
    if self.onSearchChanged then
        self.onSearchChanged("")
    end
end

function CUI_SearchBox:focus()
    if self.textEntry then
        self.textEntry:focus()
    end
end

--==============================================================================
-- EVENT HANDLERS
--==============================================================================

function CUI_SearchBox:onTextChanged()
    self.searchText = self.textEntry:getInternalText() or ""
    self:updateClearButtonVisibility()
    
    if self.onSearchChanged then
        self.onSearchChanged(self.searchText)
    end
end

function CUI_SearchBox:onClearClick()
    self:clear()
    self:focus()
end

function CUI_SearchBox:updateClearButtonVisibility()
    if self.clearButton then
        local hasText = self.searchText and self.searchText ~= ""
        self.clearButton:setVisible(hasText)
    end
end

--==============================================================================
-- RENDERING
--==============================================================================

function CUI_SearchBox:prerender()
    local bg = self.bgColor
    local border = self.borderColor
    
    -- Background
    self:drawRect(0, 0, self.width, self.height, bg.a, bg.r, bg.g, bg.b)
    
    -- Border
    self:drawRectBorder(0, 0, self.width, self.height, border.a, border.r, border.g, border.b)
    
    -- Search icon (magnifying glass)
    local iconX = self.padding
    local iconY = (self.height - self.searchIconSize) / 2
    
    if self.searchIcon then
        self:drawTextureScaled(self.searchIcon, iconX, iconY, 
            self.searchIconSize, self.searchIconSize, 0.5, 0.7, 0.7, 0.7)
    else
        -- Draw a simple magnifying glass manually
        local cx = iconX + self.searchIconSize * 0.4
        local cy = iconY + self.searchIconSize * 0.4
        local radius = self.searchIconSize * 0.3
        -- Circle approximation with small rects
        self:drawRect(cx - radius, cy - 1, radius * 2, 2, 0.5, 0.6, 0.6, 0.6)
        self:drawRect(cx - 1, cy - radius, 2, radius * 2, 0.5, 0.6, 0.6, 0.6)
        -- Handle
        self:drawRect(cx + radius * 0.5, cy + radius * 0.5, radius, 2, 0.5, 0.6, 0.6, 0.6)
    end
    
    -- Placeholder text (only if no text entered)
    if (not self.searchText or self.searchText == "") and self.placeholder then
        local textX = self.padding + self.searchIconSize + self.padding
        local textY = (self.height - FONT_HGT_SMALL) / 2
        local pc = self.placeholderColor
        self:drawText(self.placeholder, textX, textY, pc.r, pc.g, pc.b, pc.a, UIFont.Small)
    end
end

function CUI_SearchBox:render()
    ISPanel.render(self)
    
    -- Draw clear button X if visible
    if self.clearButton and self.clearButton:isVisible() then
        local btn = self.clearButton
        local cx = btn:getX() + btn:getWidth() / 2
        local cy = btn:getY() + btn:getHeight() / 2
        local size = 4
        
        local alpha = btn:isMouseOver() and 0.9 or 0.6
        local color = btn:isMouseOver() and 1.0 or 0.7
        
        -- Draw X
        self:drawRect(cx - size, cy - 1, size * 2, 2, alpha, color, color, color)
        self:drawRect(cx - 1, cy - size, 2, size * 2, alpha, color, color, color)
    end
end

return CUI_SearchBox





