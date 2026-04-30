--[[
    CUI_Config.lua - Centralized Configuration for CUI Framework
    
    All layout constants are computed based on font heights for proper
    scaling across different screen resolutions and UI scale settings.
    
    Usage:
        local Config = require "ui/framework/CUI_Config"
        local padding = Config.padding
        local buttonHeight = Config.buttonHeight
]]

local CUI_Config = {}

-- Cache font heights (computed once at load time)
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)

--==============================================================================
-- BASE SPACING & SIZING
--==============================================================================

-- Padding values (scaled from small font)
CUI_Config.paddingTiny = math.floor(FONT_HGT_SMALL * 0.2)
CUI_Config.paddingSmall = math.floor(FONT_HGT_SMALL * 0.4)
CUI_Config.padding = math.floor(FONT_HGT_SMALL * 0.6)
CUI_Config.paddingLarge = math.floor(FONT_HGT_SMALL * 0.8)

-- Common element heights
CUI_Config.headerHeight = math.floor(FONT_HGT_MEDIUM * 2.2)
CUI_Config.titleHeight = math.floor((FONT_HGT_MEDIUM * 1.2) / 2) * 2
CUI_Config.buttonHeight = math.floor(FONT_HGT_MEDIUM * 1.5)
CUI_Config.inputHeight = math.floor(FONT_HGT_SMALL * 1.8)
CUI_Config.slotHeight = math.floor(FONT_HGT_SMALL * 2.5)

-- Button sizes
CUI_Config.buttonSmall = math.floor(FONT_HGT_SMALL * 1.2)
CUI_Config.buttonMedium = math.floor(FONT_HGT_MEDIUM * 1.2)
CUI_Config.buttonLarge = math.floor(FONT_HGT_MEDIUM * 1.6)

-- Icon sizes
CUI_Config.iconSmall = math.floor(FONT_HGT_SMALL)
CUI_Config.iconMedium = math.floor(FONT_HGT_MEDIUM * 1.2)
CUI_Config.iconLarge = math.floor(FONT_HGT_MEDIUM * 2)
CUI_Config.iconXLarge = math.floor(FONT_HGT_MEDIUM * 3)

--==============================================================================
-- SCROLLING
--==============================================================================

CUI_Config.scrollBarWidth = math.floor(FONT_HGT_SMALL * 0.6)
CUI_Config.scrollViewSpacing = math.max(math.floor(FONT_HGT_SMALL / 19), 1)
CUI_Config.scrollSensitivity = math.floor(FONT_HGT_MEDIUM * 2)

--==============================================================================
-- BORDERS & DIVIDERS
--==============================================================================

CUI_Config.borderWidth = 1
CUI_Config.dividerHeight = 2
CUI_Config.accentBarHeight = 3

--==============================================================================
-- ANIMATION & TIMING
--==============================================================================

CUI_Config.animationSpeed = 0.15
CUI_Config.hoverTransitionSpeed = 0.1
CUI_Config.scrollSmoothness = 0.2

--==============================================================================
-- WINDOW DEFAULTS
--==============================================================================

CUI_Config.windowMinWidth = math.floor(FONT_HGT_SMALL * 20)
CUI_Config.windowMinHeight = math.floor(FONT_HGT_SMALL * 15)
CUI_Config.windowDefaultWidth = math.floor(FONT_HGT_SMALL * 30)
CUI_Config.windowDefaultHeight = math.floor(FONT_HGT_SMALL * 25)

--==============================================================================
-- TECHNIQUE WINDOW SPECIFIC
--==============================================================================

CUI_Config.techniqueWindow = {
    width = math.floor(FONT_HGT_SMALL * 32),
    minHeight = math.floor(FONT_HGT_SMALL * 26),
    maxHeight = math.floor(FONT_HGT_SMALL * 45),
    
    cultivationIconSize = math.floor(FONT_HGT_MEDIUM * 2.8),
    cultivationRowHeight = math.floor(FONT_HGT_SMALL * 9.5),
    
    -- Slot height: name(medium) + stage(small) + description(small) + effects(small) + padding
    techniqueSlotHeight = FONT_HGT_MEDIUM + (FONT_HGT_SMALL * 3) + math.floor(FONT_HGT_SMALL * 1.8),
    techniqueSlotSpacing = math.floor(FONT_HGT_SMALL * 0.5),
    techniqueSlotPadding = math.floor(FONT_HGT_SMALL * 0.6),
    
    closeButtonSize = math.floor(FONT_HGT_MEDIUM * 1.4),
}

--==============================================================================
-- FONT HEIGHT ACCESSORS
--==============================================================================

CUI_Config.fontSmall = FONT_HGT_SMALL
CUI_Config.fontMedium = FONT_HGT_MEDIUM
CUI_Config.fontLarge = FONT_HGT_LARGE

-- Get font height by UIFont enum
function CUI_Config.getFontHeight(font)
    if font == UIFont.Small then
        return FONT_HGT_SMALL
    elseif font == UIFont.Medium then
        return FONT_HGT_MEDIUM
    elseif font == UIFont.Large then
        return FONT_HGT_LARGE
    else
        return getTextManager():getFontHeight(font)
    end
end

--==============================================================================
-- THEME COLORS
--==============================================================================

CUI_Config.colors = {
    -- Backgrounds
    bgMain = {r=0.06, g=0.05, b=0.08, a=0.96},
    bgHeader = {r=0.10, g=0.08, b=0.14, a=1},
    bgSection = {r=0.08, g=0.07, b=0.10, a=0.9},
    bgSlot = {r=0.10, g=0.12, b=0.10, a=0.85},
    bgPlaceholder = {r=0.09, g=0.08, b=0.11, a=0.8},
    bgInput = {r=0.12, g=0.12, b=0.15, a=1},
    
    -- Accents
    accentPrimary = {r=0.65, g=0.45, b=0.85, a=1},
    accentBody = {r=0.85, g=0.55, b=0.25, a=1},
    accentSpirit = {r=0.45, g=0.65, b=0.95, a=1},
    accentSuccess = {r=0.4, g=0.7, b=0.4, a=1},
    accentWarning = {r=0.85, g=0.65, b=0.25, a=1},
    accentDanger = {r=0.85, g=0.35, b=0.35, a=1},
    
    -- Text
    textPrimary = {r=0.92, g=0.90, b=0.88, a=1},
    textSecondary = {r=0.70, g=0.68, b=0.72, a=1},
    textDim = {r=0.55, g=0.52, b=0.58, a=1},
    textMuted = {r=0.40, g=0.38, b=0.42, a=1},
    textSuccess = {r=0.5, g=0.8, b=0.5, a=1},
    
    -- Borders
    borderMain = {r=0.30, g=0.25, b=0.38, a=1},
    borderLight = {r=0.35, g=0.32, b=0.42, a=0.6},
    borderDivider = {r=0.25, g=0.22, b=0.30, a=0.6},
    
    -- Button states
    buttonNormal = {r=0.18, g=0.16, b=0.22, a=0.9},
    buttonHover = {r=0.25, g=0.22, b=0.30, a=0.95},
    buttonPressed = {r=0.12, g=0.10, b=0.15, a=0.95},
    buttonActive = {r=0.35, g=0.28, b=0.45, a=0.95},
}

-- Helper to get color as separate r,g,b,a values
function CUI_Config.getColor(colorName)
    local c = CUI_Config.colors[colorName]
    if c then
        return c.r, c.g, c.b, c.a
    end
    return 1, 1, 1, 1
end

return CUI_Config

