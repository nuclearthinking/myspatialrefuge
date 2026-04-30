--[[
    CUI_Tools.lua - Cultivation UI Utility Functions
    
    A collection of utility functions for UI development:
    - Text truncation with proper width measurement
    - Percentage-based texture drawing
    - 3-patch and 9-patch texture drawing for scalable UI elements
]]

CUI_Tools = CUI_Tools or {}

--==============================================================================
-- TEXT UTILITIES
--==============================================================================

--- Truncate text to fit within a maximum width using binary search
--- @param text string The text to truncate
--- @param maxWidth number Maximum width in pixels
--- @param font UIFont Font to use for measurement (default: UIFont.Small)
--- @param suffix string Suffix to append when truncated (default: "...")
--- @return string Truncated text
function CUI_Tools.truncateText(text, maxWidth, font, suffix)
    if not text or text == "" then
        return ""
    end

    font = font or UIFont.Small
    suffix = suffix or "..."
    
    local originalWidth = getTextManager():MeasureStringX(font, text)

    if originalWidth <= maxWidth then
        return text
    end

    local suffixWidth = getTextManager():MeasureStringX(font, suffix)

    if suffixWidth >= maxWidth then
        return ""
    end

    local textMaxWidth = maxWidth - suffixWidth

    -- Binary search for optimal truncation point
    local left = 1
    local right = string.len(text)
    local bestLength = 0
    
    while left <= right do
        local mid = math.floor((left + right) / 2)
        local truncatedText = string.sub(text, 1, mid)
        local truncatedWidth = getTextManager():MeasureStringX(font, truncatedText)
        
        if truncatedWidth <= textMaxWidth then
            bestLength = mid
            left = mid + 1
        else
            right = mid - 1
        end
    end

    if bestLength == 0 then
        return suffix
    end

    local finalText = string.sub(text, 1, bestLength)
    return finalText .. suffix
end

--- Measure text width for a given font
--- @param text string Text to measure
--- @param font UIFont Font to use
--- @return number Width in pixels
function CUI_Tools.measureText(text, font)
    font = font or UIFont.Small
    return getTextManager():MeasureStringX(font, text)
end

--- Get font height
--- @param font UIFont Font to measure
--- @return number Height in pixels
function CUI_Tools.getFontHeight(font)
    font = font or UIFont.Small
    return getTextManager():getFontHeight(font)
end

--==============================================================================
-- PERCENTAGE DRAWING
--==============================================================================

--- Draw a texture with percentage fill (left to right)
--- Uses the Java DrawTexturePercentage method
--- @param panel ISUIElement The panel to draw on
--- @param texture Texture The texture to draw
--- @param percentage number Fill percentage (0.0 to 1.0)
--- @param x number X position
--- @param y number Y position
--- @param width number Width
--- @param height number Height
--- @param a number Alpha
--- @param r number Red
--- @param g number Green
--- @param b number Blue
function CUI_Tools.drawTexturePercentage(panel, texture, percentage, x, y, width, height, a, r, g, b)
    if panel.javaObject ~= nil and texture then
        panel.javaObject:DrawTexturePercentage(texture, percentage, x, y, width, height, r, g, b, a)
    end
end

--- Draw a texture with percentage fill (bottom to top)
--- @param panel ISUIElement The panel to draw on
--- @param texture Texture The texture to draw
--- @param percentage number Fill percentage (0.0 to 1.0)
--- @param x number X position
--- @param y number Y position
--- @param width number Width
--- @param height number Height
--- @param a number Alpha
--- @param r number Red
--- @param g number Green
--- @param b number Blue
function CUI_Tools.drawTexturePercentageBottomUp(panel, texture, percentage, x, y, width, height, a, r, g, b)
    if panel.javaObject ~= nil and texture then
        panel.javaObject:DrawTexturePercentageBottomUp(texture, percentage, x, y, width, height, r, g, b, a)
    end
end

--==============================================================================
-- THREE-PATCH DRAWING (3-slice scaling)
--==============================================================================

CUI_Tools.ThreePatch = {}

--- Draw a horizontal 3-patch texture (left, middle, right)
--- Left and right maintain aspect ratio, middle stretches
--- @param panel ISUIElement The panel to draw on
--- @param x number X position
--- @param y number Y position
--- @param width number Total width
--- @param height number Height
--- @param leftTexture Texture Left edge texture
--- @param middleTexture Texture Middle (stretchable) texture
--- @param rightTexture Texture Right edge texture
--- @param alpha number Alpha (default 1.0)
--- @param r number Red (default 1.0)
--- @param g number Green (default 1.0)
--- @param b number Blue (default 1.0)
function CUI_Tools.ThreePatch.drawHorizontal(panel, x, y, width, height, leftTexture, middleTexture, rightTexture, alpha, r, g, b)
    x = math.floor(x)
    y = math.floor(y)
    width = math.floor(width)
    height = math.floor(height)
    
    alpha = alpha or 1.0
    r = r or 1.0
    g = g or 1.0
    b = b or 1.0
    
    local leftOriginalWidth = leftTexture:getWidth()
    local leftOriginalHeight = leftTexture:getHeight()
    local rightOriginalWidth = rightTexture:getWidth()
    local rightOriginalHeight = rightTexture:getHeight()
    
    -- Calculate left and right scaled widths (maintain aspect ratio)
    local heightRatio = height / leftOriginalHeight
    local leftActualWidth = math.floor(leftOriginalWidth * heightRatio)
    
    heightRatio = height / rightOriginalHeight
    local rightActualWidth = math.floor(rightOriginalWidth * heightRatio)
    
    local minSidesWidth = leftActualWidth + rightActualWidth
    
    -- Handle case where width is too small for sides
    if width <= minSidesWidth then
        local leftRatio = leftActualWidth / minSidesWidth
        leftActualWidth = math.floor(width * leftRatio)
        rightActualWidth = width - leftActualWidth
        
        panel:drawTextureScaled(leftTexture, x, y, leftActualWidth, height, alpha, r, g, b)
        panel:drawTextureScaled(rightTexture, x + leftActualWidth, y, rightActualWidth, height, alpha, r, g, b)
    else
        local middleWidth = width - leftActualWidth - rightActualWidth
        panel:drawTextureScaled(leftTexture, x, y, leftActualWidth, height, alpha, r, g, b)
        panel:drawTextureScaled(middleTexture, x + leftActualWidth, y, middleWidth, height, alpha, r, g, b)
        panel:drawTextureScaled(rightTexture, x + leftActualWidth + middleWidth, y, rightActualWidth, height, alpha, r, g, b)
    end
end

--- Draw a vertical 3-patch texture (top, middle, bottom)
--- Top and bottom maintain aspect ratio, middle stretches
--- @param panel ISUIElement The panel to draw on
--- @param x number X position
--- @param y number Y position
--- @param width number Width
--- @param height number Total height
--- @param topTexture Texture Top edge texture
--- @param middleTexture Texture Middle (stretchable) texture
--- @param bottomTexture Texture Bottom edge texture
--- @param alpha number Alpha (default 1.0)
--- @param r number Red (default 1.0)
--- @param g number Green (default 1.0)
--- @param b number Blue (default 1.0)
function CUI_Tools.ThreePatch.drawVertical(panel, x, y, width, height, topTexture, middleTexture, bottomTexture, alpha, r, g, b)
    x = math.floor(x)
    y = math.floor(y)
    width = math.floor(width)
    height = math.floor(height)

    alpha = alpha or 1.0
    r = r or 1.0
    g = g or 1.0
    b = b or 1.0

    local topOriginalWidth = topTexture:getWidth()
    local topOriginalHeight = topTexture:getHeight()
    local bottomOriginalWidth = bottomTexture:getWidth()
    local bottomOriginalHeight = bottomTexture:getHeight()
    
    -- Calculate top and bottom scaled heights (maintain aspect ratio)
    local widthRatio = width / topOriginalWidth
    local topActualHeight = math.floor(topOriginalHeight * widthRatio)
    
    widthRatio = width / bottomOriginalWidth
    local bottomActualHeight = math.floor(bottomOriginalHeight * widthRatio)
    
    local minSidesHeight = topActualHeight + bottomActualHeight
    
    -- Handle case where height is too small for sides
    if height <= minSidesHeight then
        local topRatio = topActualHeight / minSidesHeight
        topActualHeight = math.floor(height * topRatio)
        bottomActualHeight = height - topActualHeight
        
        panel:drawTextureScaled(topTexture, x, y, width, topActualHeight, alpha, r, g, b)
        panel:drawTextureScaled(bottomTexture, x, y + topActualHeight, width, bottomActualHeight, alpha, r, g, b)
    else
        local middleHeight = height - topActualHeight - bottomActualHeight

        panel:drawTextureScaled(topTexture, x, y, width, topActualHeight, alpha, r, g, b)
        panel:drawTextureScaled(middleTexture, x, y + topActualHeight, width, middleHeight, alpha, r, g, b)
        panel:drawTextureScaled(bottomTexture, x, y + topActualHeight + middleHeight, width, bottomActualHeight, alpha, r, g, b)
    end
end

--==============================================================================
-- NINE-PATCH DRAWING (9-slice scaling)
--==============================================================================

CUI_Tools.NinePatch = {}

--- Draw a 9-patch texture for scalable panels
--- Corners maintain size, edges stretch in one direction, center stretches both
--- @param panel ISUIElement The panel to draw on
--- @param x number X position
--- @param y number Y position
--- @param width number Total width
--- @param height number Total height
--- @param textures table Table with keys: topLeft, top, topRight, left, middle, right, bottomLeft, bottom, bottomRight
--- @param alpha number Alpha (default 1.0)
--- @param r number Red (default 1.0)
--- @param g number Green (default 1.0)
--- @param b number Blue (default 1.0)
function CUI_Tools.NinePatch.draw(panel, x, y, width, height, textures, alpha, r, g, b)
    x = math.floor(x)
    y = math.floor(y)
    width = math.floor(width)
    height = math.floor(height)
    
    alpha = alpha or 1.0
    r = r or 1.0
    g = g or 1.0
    b = b or 1.0
    
    -- Get corner sizes
    local cornerTopLeftWidth = textures.topLeft:getWidth()
    local cornerTopLeftHeight = textures.topLeft:getHeight()
    local cornerTopRightWidth = textures.topRight:getWidth()
    local cornerTopRightHeight = textures.topRight:getHeight()
    local cornerBottomLeftWidth = textures.bottomLeft:getWidth()
    local cornerBottomLeftHeight = textures.bottomLeft:getHeight()
    local cornerBottomRightWidth = textures.bottomRight:getWidth()
    local cornerBottomRightHeight = textures.bottomRight:getHeight()
    
    -- Calculate minimum size
    local minWidth = cornerTopLeftWidth + cornerTopRightWidth
    local minHeight = cornerTopLeftHeight + cornerBottomLeftHeight
    
    -- Scale factor if too small
    local scale = 1.0
    if width < minWidth then
        scale = width / minWidth
    end
    if height < minHeight and (height / minHeight) < scale then
        scale = height / minHeight
    end
    
    -- Apply scale to corners
    local actualCornerTopLeftWidth = math.floor(cornerTopLeftWidth * scale)
    local actualCornerTopLeftHeight = math.floor(cornerTopLeftHeight * scale)
    local actualCornerTopRightWidth = math.floor(cornerTopRightWidth * scale)
    local actualCornerTopRightHeight = math.floor(cornerTopRightHeight * scale)
    local actualCornerBottomLeftWidth = math.floor(cornerBottomLeftWidth * scale)
    local actualCornerBottomLeftHeight = math.floor(cornerBottomLeftHeight * scale)
    local actualCornerBottomRightWidth = math.floor(cornerBottomRightWidth * scale)
    local actualCornerBottomRightHeight = math.floor(cornerBottomRightHeight * scale)
    
    -- Calculate middle section sizes
    local middleWidth = width - actualCornerTopLeftWidth - actualCornerTopRightWidth
    local middleHeight = height - actualCornerTopLeftHeight - actualCornerBottomLeftHeight
    
    if middleWidth < 0 then middleWidth = 0 end
    if middleHeight < 0 then middleHeight = 0 end
    
    -- Draw corners
    panel:drawTextureScaled(textures.topLeft, x, y, 
        actualCornerTopLeftWidth, actualCornerTopLeftHeight, alpha, r, g, b)
    
    panel:drawTextureScaled(textures.topRight, 
        x + width - actualCornerTopRightWidth, y, 
        actualCornerTopRightWidth, actualCornerTopRightHeight, alpha, r, g, b)
    
    panel:drawTextureScaled(textures.bottomLeft, 
        x, y + height - actualCornerBottomLeftHeight, 
        actualCornerBottomLeftWidth, actualCornerBottomLeftHeight, alpha, r, g, b)
    
    panel:drawTextureScaled(textures.bottomRight, 
        x + width - actualCornerBottomRightWidth, y + height - actualCornerBottomRightHeight, 
        actualCornerBottomRightWidth, actualCornerBottomRightHeight, alpha, r, g, b)
    
    -- Draw edges
    if middleWidth > 0 then
        panel:drawTextureScaled(textures.top, 
            x + actualCornerTopLeftWidth, y, 
            middleWidth, actualCornerTopLeftHeight, alpha, r, g, b)
        
        panel:drawTextureScaled(textures.bottom, 
            x + actualCornerBottomLeftWidth, y + height - actualCornerBottomLeftHeight, 
            middleWidth, actualCornerBottomLeftHeight, alpha, r, g, b)
    end
    
    if middleHeight > 0 then
        panel:drawTextureScaled(textures.left, 
            x, y + actualCornerTopLeftHeight, 
            actualCornerTopLeftWidth, middleHeight, alpha, r, g, b)
        
        panel:drawTextureScaled(textures.right, 
            x + width - actualCornerTopRightWidth, y + actualCornerTopRightHeight, 
            actualCornerTopRightWidth, middleHeight, alpha, r, g, b)
    end
    
    -- Draw center
    if middleWidth > 0 and middleHeight > 0 then
        panel:drawTextureScaled(textures.middle, 
            x + actualCornerTopLeftWidth, y + actualCornerTopLeftHeight, 
            middleWidth, middleHeight, alpha, r, g, b)
    end
end

--==============================================================================
-- NATIVE NINE-PATCH (Build 42+)
--==============================================================================

--- Use the native NinePatchTexture API (Build 42+)
--- This is more efficient than manual 9-patch drawing
CUI_Tools.NativeNinePatch = {}

-- Cache for loaded NinePatchTexture objects
local ninePatchCache = {}

--- Get or create a NinePatchTexture from a path
--- Uses caching to avoid reloading the same texture
--- @param texturePath string Path to the 9-patch texture (e.g., "media/ui/Panel.png")
--- @return NinePatchTexture|nil The NinePatchTexture object, or nil if not available
function CUI_Tools.NativeNinePatch.get(texturePath)
    if not texturePath then return nil end
    
    -- Check cache first
    if ninePatchCache[texturePath] then
        return ninePatchCache[texturePath]
    end
    
    -- Try to get from the native API
    if NinePatchTexture and NinePatchTexture.getSharedTexture then
        local ninePatch = NinePatchTexture.getSharedTexture(texturePath)
        if ninePatch then
            ninePatchCache[texturePath] = ninePatch
            return ninePatch
        end
    end
    
    return nil
end

--- Draw a native 9-patch texture at absolute coordinates
--- @param texturePath string Path to the 9-patch texture
--- @param absX number Absolute X position
--- @param absY number Absolute Y position
--- @param width number Width
--- @param height number Height
--- @param r number Red (0-1)
--- @param g number Green (0-1)
--- @param b number Blue (0-1)
--- @param a number Alpha (0-1)
--- @return boolean True if drawn successfully
function CUI_Tools.NativeNinePatch.render(texturePath, absX, absY, width, height, r, g, b, a)
    local ninePatch = CUI_Tools.NativeNinePatch.get(texturePath)
    if ninePatch then
        ninePatch:render(absX, absY, width, height, r or 0.1, g or 0.1, b or 0.1, a or 1)
        return true
    end
    return false
end

--- Draw a native 9-patch texture on a panel (uses panel's absolute coords)
--- @param panel ISUIElement The panel to draw on
--- @param texturePath string Path to the 9-patch texture
--- @param x number X position relative to panel
--- @param y number Y position relative to panel
--- @param width number Width
--- @param height number Height
--- @param r number Red (0-1, default 0.1)
--- @param g number Green (0-1, default 0.1)
--- @param b number Blue (0-1, default 0.1)
--- @param a number Alpha (0-1, default 1)
--- @return boolean True if drawn successfully
function CUI_Tools.NativeNinePatch.drawOnPanel(panel, texturePath, x, y, width, height, r, g, b, a)
    local ninePatch = CUI_Tools.NativeNinePatch.get(texturePath)
    if ninePatch then
        local absX = panel:getAbsoluteX() + (x or 0)
        local absY = panel:getAbsoluteY() + (y or 0)
        ninePatch:render(absX, absY, width, height, r or 0.1, g or 0.1, b or 0.1, a or 1)
        return true
    end
    return false
end

--- Check if native NinePatchTexture API is available
--- @return boolean True if the API is available
function CUI_Tools.NativeNinePatch.isAvailable()
    return NinePatchTexture ~= nil and NinePatchTexture.getSharedTexture ~= nil
end

--- Clear the NinePatchTexture cache
function CUI_Tools.NativeNinePatch.clearCache()
    ninePatchCache = {}
end

--==============================================================================
-- PANEL BACKGROUND HELPER
--==============================================================================

--- Draw a styled panel background using native 9-patch if available,
--- falling back to solid color if not
--- @param panel ISUIElement The panel to draw on
--- @param texturePath string|nil Path to 9-patch texture (optional)
--- @param x number X position
--- @param y number Y position
--- @param width number Width
--- @param height number Height
--- @param color table Color table with r, g, b, a fields
--- @param fallbackToRect boolean If true, draw a rectangle if texture not found
function CUI_Tools.drawPanelBackground(panel, texturePath, x, y, width, height, color, fallbackToRect)
    color = color or {r=0.1, g=0.1, b=0.1, a=1}
    fallbackToRect = fallbackToRect ~= false  -- Default true
    
    -- Try native 9-patch first
    if texturePath and CUI_Tools.NativeNinePatch.isAvailable() then
        if CUI_Tools.NativeNinePatch.drawOnPanel(panel, texturePath, x, y, width, height, 
            color.r, color.g, color.b, color.a) then
            return true
        end
    end
    
    -- Fallback to solid rectangle
    if fallbackToRect then
        panel:drawRect(x, y, width, height, color.a, color.r, color.g, color.b)
    end
    
    return false
end

--==============================================================================
-- COLOR UTILITIES
--==============================================================================

--- Lighten a color by a percentage
--- @param color table Color table with r, g, b, a fields
--- @param amount number Amount to lighten (0.0 to 1.0)
--- @return table New color table
function CUI_Tools.lightenColor(color, amount)
    return {
        r = math.min(1.0, color.r + (1.0 - color.r) * amount),
        g = math.min(1.0, color.g + (1.0 - color.g) * amount),
        b = math.min(1.0, color.b + (1.0 - color.b) * amount),
        a = color.a or 1.0
    }
end

--- Darken a color by a percentage
--- @param color table Color table with r, g, b, a fields
--- @param amount number Amount to darken (0.0 to 1.0)
--- @return table New color table
function CUI_Tools.darkenColor(color, amount)
    return {
        r = math.max(0.0, color.r * (1.0 - amount)),
        g = math.max(0.0, color.g * (1.0 - amount)),
        b = math.max(0.0, color.b * (1.0 - amount)),
        a = color.a or 1.0
    }
end

--- Interpolate between two colors
--- @param colorA table First color
--- @param colorB table Second color
--- @param t number Interpolation factor (0.0 = colorA, 1.0 = colorB)
--- @return table Interpolated color
function CUI_Tools.lerpColor(colorA, colorB, t)
    t = math.max(0, math.min(1, t))
    return {
        r = colorA.r + (colorB.r - colorA.r) * t,
        g = colorA.g + (colorB.g - colorA.g) * t,
        b = colorA.b + (colorB.b - colorA.b) * t,
        a = (colorA.a or 1.0) + ((colorB.a or 1.0) - (colorA.a or 1.0)) * t
    }
end

print("[CUI_Tools] Cultivation UI Tools loaded")

return CUI_Tools

