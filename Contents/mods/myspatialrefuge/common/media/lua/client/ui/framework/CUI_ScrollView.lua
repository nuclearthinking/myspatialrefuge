--[[
    CUI_ScrollView.lua - Smooth Scrolling Container
    
    A scrollable container with:
    - Smooth inertial scrolling
    - Auto-hide scrollbars
    - Stencil clipping for child elements
    - Horizontal or vertical scrolling
]]

require "ISUI/ISUIElement"
require "ui/framework/CUI_ScrollBar"

CUI_ScrollView = ISUIElement:derive("CUI_ScrollView")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

--==============================================================================
-- INITIALIZATION
--==============================================================================

function CUI_ScrollView:new(x, y, w, h)
    local o = ISUIElement:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self

    o.x = x
    o.y = y
    o.width = w
    o.height = h
    o.keepOnScreen = false

    o.scrollChildren = {}
    o.lastX = 0
    o.lastY = 0

    o.scrollSensitivity = 32
    o.scrollDirection = "vertical"
    o.showScrollBars = true

    -- Smooth scrolling state
    o.smoothScrollX = nil
    o.smoothScrollY = nil
    o.smoothScrollTargetX = nil
    o.smoothScrollTargetY = nil

    -- Auto-hide scrollbar
    o.autoHideScrollbar = false
    o.scrollbarAlpha = 1.0     
    o.scrollbarLastActiveTime = 0
    o.hideDelay = 1500  -- ms before hiding

    return o
end

function CUI_ScrollView:createChildren()
    self:addCustomScrollBars()
end

function CUI_ScrollView:addCustomScrollBars()
    if self.scrollDirection == "vertical" then
        self.vscroll = CUI_ScrollBar:new(self, true)
        self.vscroll:initialise()
        self:addChild(self.vscroll)
    elseif self.scrollDirection == "horizontal" then
        self.hscroll = CUI_ScrollBar:new(self, false)
        self.hscroll:initialise()
        self:addChild(self.hscroll)
    end
end

--==============================================================================
-- CHILD MANAGEMENT
--==============================================================================

--- Add a child element that will scroll with the container
--- @param child ISUIElement The child element to add
function CUI_ScrollView:addScrollChild(child)
    self:addChild(child)
    table.insert(self.scrollChildren, child)

    local x = self:getXScroll()
    local y = self:getYScroll()
    child:setX(child:getX() + x)
    child:setY(child:getY() + y)

    self:sendScrollbarsToFront()
end

--- Remove a scrolling child element
--- @param child ISUIElement The child element to remove
function CUI_ScrollView:removeScrollChild(child)
    self:removeChild(child)
    for i, v in ipairs(self.scrollChildren) do
        if v == child then
            table.remove(self.scrollChildren, i)
            return
        end
    end
end

--- Clear all scrolling children
function CUI_ScrollView:clearScrollChildren()
    for _, child in ipairs(self.scrollChildren) do
        self:removeChild(child)
    end
    self.scrollChildren = {}
end

function CUI_ScrollView:sendScrollbarsToFront()
    if self.hscroll then
        self.hscroll:bringToTop()
    end
    if self.vscroll then
        self.vscroll:bringToTop()
    end
end

--==============================================================================
-- SCROLL DIMENSIONS
--==============================================================================

--- Get the total scrollable width (content width)
function CUI_ScrollView:getScrollWidth()
    if self.scrollwidth then
        return self.scrollwidth
    end
    
    local width = 0
    for _, child in pairs(self.scrollChildren) do
        width = math.max(width, child:getX() - self:getXScroll() + child:getWidth())
    end
    return width
end

--- Get the total scrollable height (content height)
function CUI_ScrollView:getScrollHeight()
    if self.scrollheight then
        return self.scrollheight
    end
    
    local height = 0
    for _, child in pairs(self.scrollChildren) do
        height = math.max(height, child:getY() - self:getYScroll() + child:getHeight())
    end
    return height
end

--- Manually set scroll width
function CUI_ScrollView:setScrollWidth(width)
    self.scrollwidth = width
end

--- Manually set scroll height
function CUI_ScrollView:setScrollHeight(height)
    self.scrollheight = height
end

--==============================================================================
-- SMOOTH SCROLLING
--==============================================================================

function CUI_ScrollView:onMouseWheel(del)
    self:resetScrollbarActivity()
    
    if self.scrollDirection == "horizontal" then
        local currentScroll = self.smoothScrollTargetX or self:getXScroll()
        local targetScroll = currentScroll - (del * self.scrollSensitivity)

        local scrollWidth = self:getScrollWidth()
        local maxScroll = math.min(0, self.width - scrollWidth)
        targetScroll = math.max(maxScroll, math.min(0, targetScroll))
        
        self.smoothScrollTargetX = targetScroll
        if not self.smoothScrollX then
            self.smoothScrollX = self:getXScroll()
        end
    else
        local currentScroll = self.smoothScrollTargetY or self:getYScroll()
        local targetScroll = currentScroll - (del * self.scrollSensitivity)

        local scrollHeight = self:getScrollHeight()
        local maxScroll = math.min(0, self.height - scrollHeight)
        targetScroll = math.max(maxScroll, math.min(0, targetScroll))
        
        self.smoothScrollTargetY = targetScroll
        if not self.smoothScrollY then
            self.smoothScrollY = self:getYScroll()
        end
    end
    return true
end

function CUI_ScrollView:updateSmoothScrolling()
    local frameRateFrac = UIManager.getMillisSinceLastRender() / 33.3
    
    -- Vertical smooth scrolling
    if self.smoothScrollTargetY then
        if not self.smoothScrollY then 
            self.smoothScrollY = self:getYScroll()
        end
        
        local dy = self.smoothScrollTargetY - self.smoothScrollY
        local moveAmount = dy * math.min(0.5, 0.25 * frameRateFrac)
        
        if frameRateFrac > 1 then
            moveAmount = dy * math.min(1.0, math.min(0.5, 0.25 * frameRateFrac) * frameRateFrac)
        end
        
        local targetY = self.smoothScrollY + moveAmount
        
        if math.abs(targetY - self.smoothScrollY) > 0.1 then
            self:setYScroll(targetY)
            self.smoothScrollY = targetY
        else
            self:setYScroll(self.smoothScrollTargetY)
            self.smoothScrollTargetY = nil
            self.smoothScrollY = nil
        end
    end
    
    -- Horizontal smooth scrolling
    if self.smoothScrollTargetX then
        if not self.smoothScrollX then 
            self.smoothScrollX = self:getXScroll()
        end
        
        local dx = self.smoothScrollTargetX - self.smoothScrollX
        local moveAmount = dx * math.min(0.5, 0.25 * frameRateFrac)
        
        if frameRateFrac > 1 then
            moveAmount = dx * math.min(1.0, math.min(0.5, 0.25 * frameRateFrac) * frameRateFrac)
        end
        
        local targetX = self.smoothScrollX + moveAmount
        
        if math.abs(targetX - self.smoothScrollX) > 0.1 then
            self:setXScroll(targetX)
            self.smoothScrollX = targetX
        else
            self:setXScroll(self.smoothScrollTargetX)
            self.smoothScrollTargetX = nil
            self.smoothScrollX = nil
        end
    end
end

--==============================================================================
-- CONFIGURATION
--==============================================================================

--- Set scroll sensitivity (pixels per scroll wheel tick)
function CUI_ScrollView:setScrollSensitivity(sensitivity)
    if sensitivity and sensitivity > 0 then
        self.scrollSensitivity = sensitivity
    end
end

--- Reset scroll position to top/left
function CUI_ScrollView:resetScroll()
    self.smoothScrollX = nil
    self.smoothScrollY = nil
    self.smoothScrollTargetX = nil
    self.smoothScrollTargetY = nil

    self:setXScroll(0)
    self:setYScroll(0)
    self:updateScroll()
end

--- Show or hide scrollbars
function CUI_ScrollView:setShowScrollBars(show)
    self.showScrollBars = show
    if self.vscroll then
        self.vscroll:setVisible(show and self.vscroll:getIsVisible())
    end
    if self.hscroll then
        self.hscroll:setVisible(show and self.hscroll:getIsVisible())
    end
end

--- Set scroll direction ("horizontal" or "vertical")
function CUI_ScrollView:setScrollDirection(direction)
    if direction == "horizontal" or direction == "vertical" then
        local oldDirection = self.scrollDirection
        self.scrollDirection = direction
        
        if oldDirection ~= direction and (self.vscroll or self.hscroll) then
            self:recreateScrollBars()
        end
    end
end

function CUI_ScrollView:recreateScrollBars()
    if self.vscroll then
        self:removeChild(self.vscroll)
        self.vscroll = nil
    end
    if self.hscroll then
        self:removeChild(self.hscroll)
        self.hscroll = nil
    end

    self:addCustomScrollBars()
end

--==============================================================================
-- SCROLL UPDATE
--==============================================================================

function CUI_ScrollView:updateScroll()
    local xScroll = self:getXScroll()
    local yScroll = self:getYScroll()

    local scrollAreaWidth = self:getScrollWidth()
    local scrollAreaHeight = self:getScrollHeight()

    if self.scrollDirection == "horizontal" then
        if scrollAreaWidth > self.width then
            if xScroll > 0 then xScroll = 0 end
            if xScroll < -(scrollAreaWidth - self.width) then
                xScroll = -(scrollAreaWidth - self.width)
            end
            self:setXScroll(xScroll)
        else
            self:setXScroll(0)
        end
        self:setYScroll(0)
        
    else
        if scrollAreaHeight > self.height then
            if yScroll > 0 then yScroll = 0 end
            local maxNegativeScroll = -(scrollAreaHeight - self.height)
            if yScroll < maxNegativeScroll then
                yScroll = maxNegativeScroll
            end
            self:setYScroll(yScroll)
        else
            self:setYScroll(0)
        end
        self:setXScroll(0)
    end

    -- Update child positions
    local deltaX = self:getXScroll() - self.lastX
    local deltaY = self:getYScroll() - self.lastY
    for _, child in pairs(self.scrollChildren) do
        child:setX(child:getX() + deltaX)
        child:setY(child:getY() + deltaY)
    end

    self.lastX = self:getXScroll()
    self.lastY = self:getYScroll()

    -- Update scrollbar position
    if self.scrollDirection == "vertical" then
        if self.vscroll then
            if scrollAreaHeight <= self.height then
                self.vscroll.pos = 0
            else
                self.vscroll.pos = (-self:getYScroll()) / (scrollAreaHeight - self.height)
            end
        end
    elseif self.scrollDirection == "horizontal" then
        if self.hscroll then
            if scrollAreaWidth <= self.width then
                self.hscroll.pos = 0
            else
                self.hscroll.pos = (-self:getXScroll()) / (scrollAreaWidth - self.width)
            end
        end
    end
end

function CUI_ScrollView:updateScrollbars()
    local sw = self:getScrollWidth() or 1
    local sh = self:getScrollHeight() or 1

    local margin = FONT_HGT_SMALL * 0.2

    if self.scrollDirection == "vertical" then
        if self.vscroll then
            local needVScroll = sh > self.height
            self.vscroll:setHeight(self.height - margin * 2)
            self.vscroll:setX(self.width - self.vscroll.width)
            self.vscroll:setY(margin)
            self.vscroll:setVisible(self.showScrollBars and needVScroll)
        end
        
    elseif self.scrollDirection == "horizontal" then
        if self.hscroll then
            local needHScroll = sw > self.width
            self.hscroll:setWidth(self.width - margin * 2)
            self.hscroll:setX(margin)
            self.hscroll:setY(self.height - self.hscroll.height)
            self.hscroll:setVisible(needHScroll)
        end
    end
end

--==============================================================================
-- AUTO-HIDE SCROLLBAR
--==============================================================================

--- Enable or disable auto-hiding scrollbar
function CUI_ScrollView:setAutoHideScrollbar(enable)
    self.autoHideScrollbar = enable
    if not enable then
        self.scrollbarAlpha = 1.0
        if self.vscroll then self.vscroll.alpha = 1.0 end
        if self.hscroll then self.hscroll.alpha = 1.0 end
    end
end

function CUI_ScrollView:resetScrollbarActivity()
    if self.autoHideScrollbar then
        self.scrollbarLastActiveTime = getTimestampMs()
        self.scrollbarAlpha = 1.0
    end
end

function CUI_ScrollView:updateScrollbarAlpha()
    if not self.autoHideScrollbar then return end
    
    local currentTime = getTimestampMs()
    local mouseOver = false

    if self.vscroll and self.vscroll:isVisible() then
        mouseOver = mouseOver or self.vscroll:isMouseOver()
    end
    if self.hscroll and self.hscroll:isVisible() then
        mouseOver = mouseOver or self.hscroll:isMouseOver()
    end

    if mouseOver or self.smoothScrollTargetY or self.smoothScrollTargetX then
        self.scrollbarAlpha = 1.0
        self.scrollbarLastActiveTime = currentTime
    elseif currentTime - self.scrollbarLastActiveTime > self.hideDelay then
        self.scrollbarAlpha = math.max(0, self.scrollbarAlpha - 0.05)
    end

    if self.vscroll then self.vscroll.alpha = self.scrollbarAlpha end
    if self.hscroll then self.hscroll.alpha = self.scrollbarAlpha end
end

--==============================================================================
-- RENDERING
--==============================================================================

function CUI_ScrollView:prerender()
    self:updateSmoothScrolling()
    self:updateScrollbarAlpha()
    self:setStencilRect(0, 0, self.width, self.height)
    self:updateScrollbars()
    self:updateScroll()
end

function CUI_ScrollView:render()
    self:clearStencilRect()
end

print("[CUI_ScrollView] Smooth ScrollView loaded")

return CUI_ScrollView





