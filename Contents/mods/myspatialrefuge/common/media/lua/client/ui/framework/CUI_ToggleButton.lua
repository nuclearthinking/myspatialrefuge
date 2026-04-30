--[[
    CUI_ToggleButton.lua - Toggle Button with Active/Inactive States
    
    A button that can be toggled between active and inactive states,
    with customizable colors for each state.
    
    Usage:
        local button = CUI_ToggleButton:new(x, y, size, icon, target, onclick)
        button:setActive(true)
        button:setActiveColor(0.8, 0.5, 0.2)
]]

require "ISUI/ISButton"

CUI_ToggleButton = ISButton:derive("CUI_ToggleButton")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

--==============================================================================
-- CONSTRUCTOR
--==============================================================================

function CUI_ToggleButton:new(x, y, size, iconTexture, target, onclick)
    local o = ISButton:new(x, y, size, size, "", target, onclick)
    setmetatable(o, self)
    self.__index = self
    
    o:setDisplayBackground(false)
    o.iconTexture = iconTexture
    o.iconSizeRatio = 0.7
    
    -- State
    o.isActive = false
    o.isToggleButton = true
    
    -- Colors
    o.activeColor = {r=0.85, g=0.55, b=0.25}
    o.inactiveColor = {r=0.2, g=0.2, b=0.2}
    o.iconColor = {r=0.9, g=0.9, b=0.9}
    
    -- Background textures (optional)
    o.bgTexture = nil
    o.borderTexture = nil
    
    return o
end

function CUI_ToggleButton:initialise()
    ISButton.initialise(self)
end

--==============================================================================
-- CONFIGURATION
--==============================================================================

function CUI_ToggleButton:setIcon(iconTexture)
    self.iconTexture = iconTexture
end

function CUI_ToggleButton:setIconSizeRatio(ratio)
    self.iconSizeRatio = ratio
end

function CUI_ToggleButton:setActive(active)
    self.isActive = active
end

function CUI_ToggleButton:isActiveState()
    return self.isActive
end

function CUI_ToggleButton:toggle()
    self.isActive = not self.isActive
end

function CUI_ToggleButton:setActiveColor(r, g, b)
    self.activeColor = {r=r, g=g, b=b}
end

function CUI_ToggleButton:setInactiveColor(r, g, b)
    self.inactiveColor = {r=r, g=g, b=b}
end

function CUI_ToggleButton:setIconColor(r, g, b)
    self.iconColor = {r=r, g=g, b=b}
end

function CUI_ToggleButton:setBgTexture(texture)
    self.bgTexture = texture
end

function CUI_ToggleButton:setBorderTexture(texture)
    self.borderTexture = texture
end

--==============================================================================
-- RENDERING
--==============================================================================

function CUI_ToggleButton:prerender()
    -- Don't call parent prerender - we handle our own background
end

function CUI_ToggleButton:render()
    local baseColor = self.isActive and self.activeColor or self.inactiveColor
    local r, g, b = baseColor.r, baseColor.g, baseColor.b
    local alpha = 0.85
    
    -- Adjust for hover/pressed states
    if self.pressed then
        r = r * 0.7
        g = g * 0.7
        b = b * 0.7
        alpha = 0.9
    elseif self:isMouseOver() then
        r = math.min(r * 1.25, 1)
        g = math.min(g * 1.25, 1)
        b = math.min(b * 1.25, 1)
        alpha = 0.95
    end
    
    -- Draw background
    if self.bgTexture then
        self:drawTextureScaled(self.bgTexture, 0, 0, self.width, self.height, alpha, r, g, b)
    else
        -- Default rounded rectangle style
        self:drawRect(0, 0, self.width, self.height, alpha, r, g, b)
    end
    
    -- Draw border
    if self.borderTexture then
        self:drawTextureScaled(self.borderTexture, 0, 0, self.width, self.height, 1, 0.4, 0.4, 0.4)
    else
        local borderAlpha = self.isActive and 0.6 or 0.3
        self:drawRectBorder(0, 0, self.width, self.height, borderAlpha, 0.5, 0.5, 0.5)
    end
    
    -- Draw icon
    if self.iconTexture then
        local iconSize = math.floor(math.min(self.width, self.height) * self.iconSizeRatio)
        local iconX = math.floor((self.width - iconSize) / 2)
        local iconY = math.floor((self.height - iconSize) / 2)
        
        local iconAlpha = self:isMouseOver() and 1.0 or 0.85
        self:drawTextureScaled(
            self.iconTexture, 
            iconX, iconY, 
            iconSize, iconSize, 
            iconAlpha, 
            self.iconColor.r, self.iconColor.g, self.iconColor.b
        )
    end
    
    -- Draw active indicator (small dot or glow)
    if self.isActive then
        local indicatorSize = 4
        local indicatorX = self.width - indicatorSize - 3
        local indicatorY = 3
        self:drawRect(indicatorX, indicatorY, indicatorSize, indicatorSize, 
            1, self.activeColor.r, self.activeColor.g, self.activeColor.b)
    end
end

--==============================================================================
-- MOUSE HANDLING
--==============================================================================

function CUI_ToggleButton:onMouseUp(x, y)
    if self.pressed and self:isMouseOver() then
        -- Toggle state before calling onclick
        if self.isToggleButton then
            self:toggle()
        end
        
        if self.onclick then
            self.onclick(self.target, self)
        end
        
        getSoundManager():playUISound("UIActivateButton")
    end
    
    self.pressed = false
    return true
end

return CUI_ToggleButton





