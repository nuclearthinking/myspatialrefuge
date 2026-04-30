--[[
    CUI_ProgressBar.lua - Styled Progress Bar Component
    
    A progress bar with customizable styling, including:
    - Background and fill colors
    - Optional 3-patch texture support
    - Text display (percentage, value, or custom)
    - Animation support
    
    Usage:
        local bar = CUI_ProgressBar:new(x, y, width, height)
        bar:setProgress(0.75)
        bar:setColors(bgColor, fillColor)
]]

require "ISUI/ISPanel"

CUI_ProgressBar = ISPanel:derive("CUI_ProgressBar")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

--==============================================================================
-- CONSTRUCTOR
--==============================================================================

function CUI_ProgressBar:new(x, y, width, height)
    height = height or math.floor(FONT_HGT_SMALL * 0.8)
    
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o:noBackground()
    
    -- Progress value (0.0 to 1.0)
    o.progress = 0
    o.targetProgress = 0
    o.animateProgress = false
    o.animationSpeed = 0.1
    
    -- Colors
    o.bgColor = {r=0.12, g=0.12, b=0.15, a=1}
    o.fillColor = {r=0.4, g=0.7, b=0.4, a=1}
    o.borderColor = {r=0.25, g=0.22, b=0.30, a=0.6}
    o.textColor = {r=1, g=1, b=1, a=0.85}
    
    -- Optional gradient for fill
    o.fillGradient = false
    o.fillColorEnd = nil
    
    -- Text display
    o.showText = true
    o.textMode = "percentage"  -- "percentage", "value", "custom", "none"
    o.customText = nil
    o.maxValue = 100
    o.currentValue = 0
    o.textFont = UIFont.Small
    
    -- Textures for 3-patch (optional)
    o.bgTextures = nil  -- {left, middle, right}
    o.fillTextures = nil  -- {left, middle, right}
    
    -- Border
    o.showBorder = true
    o.borderWidth = 1
    
    -- Corner rounding (visual only, drawn with small rects)
    o.cornerRadius = 0
    
    return o
end

function CUI_ProgressBar:initialise()
    ISPanel.initialise(self)
end

--==============================================================================
-- CONFIGURATION
--==============================================================================

function CUI_ProgressBar:setProgress(value, animate)
    value = math.max(0, math.min(1, value or 0))
    
    if animate and self.animateProgress then
        self.targetProgress = value
    else
        self.progress = value
        self.targetProgress = value
    end
end

function CUI_ProgressBar:getProgress()
    return self.progress
end

function CUI_ProgressBar:setAnimated(enabled, speed)
    self.animateProgress = enabled
    self.animationSpeed = speed or 0.1
end

function CUI_ProgressBar:setValue(current, max)
    self.currentValue = current or 0
    self.maxValue = max or 100
    self:setProgress(self.maxValue > 0 and (self.currentValue / self.maxValue) or 0)
end

function CUI_ProgressBar:setBgColor(r, g, b, a)
    self.bgColor = {r=r, g=g, b=b, a=a or 1}
end

function CUI_ProgressBar:setFillColor(r, g, b, a)
    self.fillColor = {r=r, g=g, b=b, a=a or 1}
end

function CUI_ProgressBar:setFillGradient(startColor, endColor)
    self.fillGradient = true
    self.fillColor = startColor
    self.fillColorEnd = endColor
end

function CUI_ProgressBar:setBorderColor(r, g, b, a)
    self.borderColor = {r=r, g=g, b=b, a=a or 0.6}
end

function CUI_ProgressBar:setTextColor(r, g, b, a)
    self.textColor = {r=r, g=g, b=b, a=a or 0.85}
end

function CUI_ProgressBar:setShowText(show)
    self.showText = show
end

function CUI_ProgressBar:setTextMode(mode)
    self.textMode = mode  -- "percentage", "value", "custom", "none"
end

function CUI_ProgressBar:setCustomText(text)
    self.customText = text
    self.textMode = "custom"
end

function CUI_ProgressBar:setTextFont(font)
    self.textFont = font
end

function CUI_ProgressBar:setBgTextures(left, middle, right)
    self.bgTextures = {left=left, middle=middle, right=right}
end

function CUI_ProgressBar:setFillTextures(left, middle, right)
    self.fillTextures = {left=left, middle=middle, right=right}
end

function CUI_ProgressBar:setShowBorder(show)
    self.showBorder = show
end

--==============================================================================
-- UPDATE
--==============================================================================

function CUI_ProgressBar:update()
    ISPanel.update(self)
    
    -- Animate progress if enabled
    if self.animateProgress and self.progress ~= self.targetProgress then
        local diff = self.targetProgress - self.progress
        local step = diff * self.animationSpeed
        
        if math.abs(diff) < 0.001 then
            self.progress = self.targetProgress
        else
            self.progress = self.progress + step
        end
    end
end

--==============================================================================
-- RENDERING
--==============================================================================

function CUI_ProgressBar:prerender()
    -- Background
    self:drawBackground()
    
    -- Fill
    self:drawFill()
    
    -- Border
    if self.showBorder then
        self:drawBorder()
    end
end

function CUI_ProgressBar:render()
    -- Text overlay
    if self.showText and self.textMode ~= "none" then
        self:drawTextOverlay()
    end
end

function CUI_ProgressBar:drawBackground()
    local bg = self.bgColor
    
    if self.bgTextures then
        self:draw3Patch(0, 0, self.width, self.height, self.bgTextures, bg.a, bg.r, bg.g, bg.b)
    else
        self:drawRect(0, 0, self.width, self.height, bg.a, bg.r, bg.g, bg.b)
    end
end

function CUI_ProgressBar:drawFill()
    if self.progress <= 0 then return end
    
    local fillWidth = math.floor(self.width * self.progress)
    if fillWidth <= 0 then return end
    
    local fill = self.fillColor
    
    if self.fillTextures then
        -- Use stencil to clip the fill
        self:setStencilRect(0, 0, fillWidth, self.height)
        self:draw3Patch(0, 0, self.width, self.height, self.fillTextures, fill.a, fill.r, fill.g, fill.b)
        self:clearStencilRect()
    else
        if self.fillGradient and self.fillColorEnd then
            -- Simple gradient approximation using segments
            local segments = 10
            local segWidth = fillWidth / segments
            for i = 0, segments - 1 do
                local t = i / (segments - 1)
                local r = fill.r + (self.fillColorEnd.r - fill.r) * t
                local g = fill.g + (self.fillColorEnd.g - fill.g) * t
                local b = fill.b + (self.fillColorEnd.b - fill.b) * t
                self:drawRect(i * segWidth, 0, segWidth + 1, self.height, fill.a, r, g, b)
            end
        else
            self:drawRect(0, 0, fillWidth, self.height, fill.a, fill.r, fill.g, fill.b)
        end
    end
end

function CUI_ProgressBar:drawBorder()
    local border = self.borderColor
    self:drawRectBorder(0, 0, self.width, self.height, border.a, border.r, border.g, border.b)
end

function CUI_ProgressBar:drawTextOverlay()
    local text = ""
    
    if self.textMode == "percentage" then
        text = string.format("%.0f%%", self.progress * 100)
    elseif self.textMode == "value" then
        text = string.format("%.0f / %.0f", self.currentValue, self.maxValue)
    elseif self.textMode == "custom" and self.customText then
        text = self.customText
    else
        return
    end
    
    local textWidth = getTextManager():MeasureStringX(self.textFont, text)
    local fontHeight = getTextManager():getFontHeight(self.textFont)
    
    local textX = (self.width - textWidth) / 2
    local textY = (self.height - fontHeight) / 2
    
    local tc = self.textColor
    self:drawText(text, textX, textY, tc.r, tc.g, tc.b, tc.a, self.textFont)
end

function CUI_ProgressBar:draw3Patch(x, y, width, height, textures, a, r, g, b)
    if not textures or not textures.left or not textures.middle or not textures.right then
        return
    end
    
    local leftTex = textures.left
    local midTex = textures.middle
    local rightTex = textures.right
    
    local leftWidth = leftTex:getWidth()
    local rightWidth = rightTex:getWidth()
    local middleWidth = width - leftWidth - rightWidth
    
    if middleWidth < 0 then
        -- Not enough space, just draw the middle stretched
        self:drawTextureScaled(midTex, x, y, width, height, a, r, g, b)
        return
    end
    
    -- Left cap
    self:drawTextureScaled(leftTex, x, y, leftWidth, height, a, r, g, b)
    
    -- Middle (stretched)
    self:drawTextureScaled(midTex, x + leftWidth, y, middleWidth, height, a, r, g, b)
    
    -- Right cap
    self:drawTextureScaled(rightTex, x + leftWidth + middleWidth, y, rightWidth, height, a, r, g, b)
end

return CUI_ProgressBar





