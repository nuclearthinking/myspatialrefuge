--[[
    CUI_ScrollBar.lua - Custom Styled Scrollbar
    
    A stylized scrollbar with:
    - Smooth thumb rendering
    - Auto-hide support
    - Click-to-jump functionality
    - Horizontal and vertical modes
]]

require "ISUI/ISScrollBar"

CUI_ScrollBar = ISScrollBar:derive("CUI_ScrollBar")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

-- Default colors
local COLOR_THUMB = {r=0.5, g=0.45, b=0.6, a=0.8}
local COLOR_THUMB_HOVER = {r=0.65, g=0.55, b=0.75, a=0.9}
local COLOR_TRACK = {r=0.1, g=0.1, b=0.12, a=0.3}

--==============================================================================
-- INITIALIZATION
--==============================================================================

function CUI_ScrollBar:instantiate()
    self.javaObject = UIElement.new(self)
    
    if self.vertical then
        self.anchorTop = false
        self.anchorLeft = false
        self.anchorRight = true
        self.anchorBottom = true
    else
        self.anchorTop = false
        self.anchorLeft = false
        self.anchorRight = true
        self.anchorBottom = true
    end

    self.javaObject:setHeight(self.height)
    self.javaObject:setWidth(self.width)
    self.javaObject:setAnchorLeft(self.anchorLeft or false)
    self.javaObject:setAnchorRight(self.anchorRight or false)
    self.javaObject:setAnchorTop(self.anchorTop or false)
    self.javaObject:setAnchorBottom(self.anchorBottom or false)
    self.javaObject:setScrollWithParent(false)
end

function CUI_ScrollBar:new(parent, vertical)
    local o = ISScrollBar:new(parent, vertical)
    setmetatable(o, self)
    self.__index = self
    
    o.alpha = 1.0
    o.thumbColor = COLOR_THUMB
    o.thumbHoverColor = COLOR_THUMB_HOVER
    o.trackColor = COLOR_TRACK
    o.cornerRadius = 3
    
    if vertical then
        o.width = math.floor(FONT_HGT_SMALL * 0.5)
    else
        o.height = math.floor(FONT_HGT_SMALL * 0.5)
    end
    
    return o
end

--==============================================================================
-- CONFIGURATION
--==============================================================================

--- Set thumb color
--- @param r number Red (0-1)
--- @param g number Green (0-1)
--- @param b number Blue (0-1)
--- @param a number Alpha (0-1)
function CUI_ScrollBar:setThumbColor(r, g, b, a)
    self.thumbColor = {r=r, g=g, b=b, a=a or 0.8}
end

--- Set thumb hover color
--- @param r number Red (0-1)
--- @param g number Green (0-1)
--- @param b number Blue (0-1)
--- @param a number Alpha (0-1)
function CUI_ScrollBar:setThumbHoverColor(r, g, b, a)
    self.thumbHoverColor = {r=r, g=g, b=b, a=a or 0.9}
end

--- Set track color
--- @param r number Red (0-1)
--- @param g number Green (0-1)
--- @param b number Blue (0-1)
--- @param a number Alpha (0-1)
function CUI_ScrollBar:setTrackColor(r, g, b, a)
    self.trackColor = {r=r, g=g, b=b, a=a or 0.3}
end

--==============================================================================
-- RENDERING
--==============================================================================

function CUI_ScrollBar:render()
    local mx = self:getMouseX()
    local my = self:getMouseY()
    local mouseOver = self.scrolling or (self:isMouseOver() and self:isPointOverThumb(mx, my))
    
    -- Select color based on state
    local color = mouseOver and self.thumbHoverColor or self.thumbColor
    
    if self.vertical then
        self:renderVertical(color)
    else
        self:renderHorizontal(color)
    end
end

function CUI_ScrollBar:renderVertical(color)
    local sh = self.parent:getScrollHeight()
    
    -- Draw track background
    self:drawRect(0, 0, self.width, self.height, 
        self.trackColor.a * self.alpha, self.trackColor.r, self.trackColor.g, self.trackColor.b)
    
    if sh > self:getHeight() then
        local del = self:getHeight() / sh
        local boxheight = del * self:getHeight()
        boxheight = math.ceil(boxheight)
        boxheight = math.max(boxheight, 20)
        
        local dif = (self:getHeight() - boxheight) * self.pos
        dif = math.ceil(dif)
        
        -- Store bar dimensions for hit testing
        local padding = 2
        self.barwidth = self.width - padding * 2
        self.barheight = boxheight
        self.barx = padding
        self.bary = dif
        
        -- Draw thumb
        self:drawRect(self.barx, self.bary, self.barwidth, self.barheight, 
            color.a * self.alpha, color.r, color.g, color.b)
    else
        self.barx = 0
        self.bary = 0
        self.barwidth = 0
        self.barheight = 0
    end
end

function CUI_ScrollBar:renderHorizontal(color)
    local sw = self.parent:getScrollWidth()
    
    -- Draw track background
    self:drawRect(0, 0, self.width, self.height, 
        self.trackColor.a * self.alpha, self.trackColor.r, self.trackColor.g, self.trackColor.b)
    
    if sw > self:getWidth() then
        local del = self:getWidth() / sw
        local boxwidth = del * self:getWidth()
        boxwidth = math.ceil(boxwidth)
        boxwidth = math.max(boxwidth, 20)
        
        local dif = (self:getWidth() - boxwidth) * self.pos
        dif = math.ceil(dif)
        
        -- Store bar dimensions for hit testing
        local padding = 2
        self.barwidth = boxwidth
        self.barheight = self.height - padding * 2
        self.barx = dif
        self.bary = padding
        
        -- Draw thumb
        self:drawRect(self.barx, self.bary, self.barwidth, self.barheight, 
            color.a * self.alpha, color.r, color.g, color.b)
    else
        self.barx = 0
        self.bary = 0
        self.barwidth = 0
        self.barheight = 0
    end
end

--==============================================================================
-- CLICK-TO-JUMP HANDLING
--==============================================================================

function CUI_ScrollBar:hitTest(x, y)
    if not self:isPointOver(self:getAbsoluteX() + x, self:getAbsoluteY() + y) then
        return nil
    end

    if self:isPointOverThumb(x, y) then
        return "thumb"
    end

    if not self.barx or (self.barwidth == 0) then
        return nil
    end

    if self.vertical then
        if y < self.bary then
            return "trackUp"
        end
        return "trackDown"
    else
        if x < self.barx then
            return "trackLeft"
        end
        return "trackRight"
    end
end

function CUI_ScrollBar:onClickTrackUp(y)
    self:jumpToClickPosition(nil, y)
end

function CUI_ScrollBar:onClickTrackDown(y)
    self:jumpToClickPosition(nil, y)
end

function CUI_ScrollBar:onClickTrackLeft(x)
    self:jumpToClickPosition(x, nil)
end

function CUI_ScrollBar:onClickTrackRight(x)
    self:jumpToClickPosition(x, nil)
end

--- Jump scroll position to where user clicked on track
function CUI_ScrollBar:jumpToClickPosition(x, y)
    if self.vertical and y then
        local scrollHeight = self.parent:getScrollHeight()
        local parentHeight = self.parent:getHeight()
        if scrollHeight <= parentHeight then return end
        
        local relativePos = math.max(0, math.min(1, y / self:getHeight()))
        self.pos = relativePos
        self.parent:setYScroll(-relativePos * (scrollHeight - parentHeight))
        
    elseif not self.vertical and x then
        local scrollWidth = self.parent:getScrollWidth()
        local parentWidth = self.parent:getWidth()
        if scrollWidth <= parentWidth then return end
        
        local relativePos = math.max(0, math.min(1, x / self:getWidth()))
        self.pos = relativePos
        self.parent:setXScroll(-relativePos * (scrollWidth - parentWidth))
    end
end

print("[CUI_ScrollBar] Custom ScrollBar loaded")

return CUI_ScrollBar





