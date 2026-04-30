--[[
    CUI_Framework.lua - Cultivation UI Framework
    
    A UI framework for the Spatial Refuge mod providing reusable components:
    
    CONFIGURATION:
    - CUI_Config          - Centralized scaled layout constants and theme colors
    
    UTILITIES:
    - CUI_Tools           - Text truncation, color utilities, patch drawing,
                            native NinePatchTexture support (Build 42+)
    
    SCROLL COMPONENTS:
    - CUI_ScrollBar       - Custom styled scrollbar
    - CUI_ScrollView      - Smooth scrolling container
    - CUI_VirtualScrollView - High-performance virtual scrolling list
    
    UI COMPONENTS:
    - CUI_Button          - Styled button with states and icon support
    - CUI_ToggleButton    - Toggle button with active/inactive states
    - CUI_SearchBox       - Search input with clear button
    - CUI_ProgressBar     - Styled progress bar with animation
    
    Usage:
        require "ui/framework/CUI_Framework"
        
        -- Use config for scaled layout values
        local Config = require "ui/framework/CUI_Config"
        local padding = Config.padding
        local headerHeight = Config.headerHeight
        
        -- Use components
        local button = CUI_Button:new(x, y, w, h, "Click Me", self, self.onClick)
        local toggle = CUI_ToggleButton:new(x, y, size, icon, self, self.onToggle)
        local search = CUI_SearchBox:new(x, y, w, h)
        local progress = CUI_ProgressBar:new(x, y, w, h)
        local scrollView = CUI_ScrollView:new(x, y, w, h)
        local virtualList = CUI_VirtualScrollView:new(x, y, w, h)
        
        -- Use utilities
        local truncated = CUI_Tools.truncateText("Long text...", 100, UIFont.Small)
        local lighterColor = CUI_Tools.lightenColor(myColor, 0.2)
        
        -- Use native 9-patch (Build 42+)
        CUI_Tools.NativeNinePatch.drawOnPanel(panel, "media/ui/Panel.png", 0, 0, w, h, 0.1, 0.1, 0.1, 1)
]]

-- Load configuration first
require "ui/framework/CUI_Config"

-- Load utilities
require "ui/framework/CUI_Tools"

-- Load scroll components
require "ui/framework/CUI_ScrollBar"
require "ui/framework/CUI_ScrollView"
require "ui/framework/CUI_VirtualScrollView"

-- Load UI components
require "ui/framework/CUI_Button"
require "ui/framework/CUI_ToggleButton"
require "ui/framework/CUI_SearchBox"
require "ui/framework/CUI_ProgressBar"

-- Framework metadata
CUI_Framework = CUI_Framework or {}
CUI_Framework.VERSION = "1.1.0"
CUI_Framework.AUTHOR = "MySpatialCore"

--- Get framework version
function CUI_Framework.getVersion()
    return CUI_Framework.VERSION
end

--- Check if all core components are loaded
function CUI_Framework.isLoaded()
    return CUI_Tools ~= nil 
        and CUI_ScrollBar ~= nil 
        and CUI_ScrollView ~= nil 
        and CUI_VirtualScrollView ~= nil
        and CUI_Button ~= nil
        and CUI_ToggleButton ~= nil
        and CUI_SearchBox ~= nil
        and CUI_ProgressBar ~= nil
end

--- Check if native NinePatch is available (Build 42+)
function CUI_Framework.hasNativeNinePatch()
    return CUI_Tools.NativeNinePatch and CUI_Tools.NativeNinePatch.isAvailable()
end

--- Get the configuration object
function CUI_Framework.getConfig()
    return require "ui/framework/CUI_Config"
end

--- Get theme colors from config
function CUI_Framework.getColors()
    local Config = require "ui/framework/CUI_Config"
    return Config.colors
end

print("[CUI_Framework] Cultivation UI Framework v" .. CUI_Framework.VERSION .. " loaded")

if CUI_Framework.hasNativeNinePatch() then
    print("[CUI_Framework] Native NinePatchTexture API available")
end

return CUI_Framework
