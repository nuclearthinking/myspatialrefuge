--[[
    MSR_Widgets.lua - Drawing blocks shared by every refuge screen.

    These are draw calls, not UI elements: they are meant to be called from a
    panel's prerender(). Anything that needs to be clickable stays an ISButton so
    we keep hover states, sounds and joypad focus for free.
]]

local Theme = require "ui/MSR_Theme"

local Widgets = {}
local M = Theme.metrics
local C = Theme.color
local CHECKMARK_TEXTURE = getTexture("media/textures/checkmark_16x16.png") --[[@as Texture]]

--- Window frame with brass corner brackets, drawn last so nothing paints over it.
function Widgets.windowFrame(panel, w, h)
    Theme.border(panel, 0, 0, w, h, C.borderHi)
    Theme.border(panel, 1, 1, w - 2, h - 2, C.border)
    local n = M.cornerBracket
    local corners = {
        { 1, 1, 1, 1 },
        { w - 2, 1, -1, 1 },
        { 1, h - 2, 1, -1 },
        { w - 2, h - 2, -1, -1 },
    }
    for i = 1, #corners do
        local cx, cy, sx, sy = corners[i][1], corners[i][2], corners[i][3], corners[i][4]
        local x0 = sx > 0 and cx or cx - n
        local y0 = sy > 0 and cy or cy - n
        Theme.fill(panel, x0, cy, n, 1, C.brass)
        Theme.fill(panel, cx, y0, 1, n, C.brass)
    end
end

--- Section caption with a rule running to the right edge.
function Widgets.sectionHeader(panel, x, y, w, label)
    Theme.text(panel, label, x, y, C.brassHi, UIFont.Small)
    local labelW = getTextManager():MeasureStringX(UIFont.Small, label)
    local lineX = x + labelW + M.pad
    if lineX < x + w then
        Theme.fill(panel, lineX, y + math.floor(M.fontSmall / 2), x + w - lineX, 1, C.divider)
    end
    return y + M.fontSmall + M.padSmall
end

--- Resource bar with a ghost segment showing what a pending action would add.
function Widgets.resourceBar(panel, x, y, w, h, value, capacity, preview)
    capacity = math.max(1, capacity or 1)
    Theme.box(panel, x, y, w, h, C.inset, C.border)
    local inner = w - 2
    local filled = math.floor(inner * math.min(1, (value or 0) / capacity))
    if preview and preview > 0 then
        local ghost = math.floor(inner * math.min(1, ((value or 0) + preview) / capacity))
        Theme.fill(panel, x + 1, y + 1, ghost, h - 2, C.accentDim)
    end
    if filled > 0 then
        Theme.fill(panel, x + 1, y + 1, filled, h - 2, C.accent)
    end
    for tick = x + 5, x + w - 2, 6 do                 -- segmented, like vanilla bars
        Theme.fill(panel, tick, y + 1, 1, h - 2, C.inset, 0.35)
    end
end

--- Tri-state checkbox: nothing / part of the stack / the whole stack.
function Widgets.checkbox(panel, x, y, state)
    local s = M.checkboxSize
    local on = state == "on" or state == "partial"
    Theme.box(panel, x, y, s, s, C.inset, on and C.accent or C.border)
    if state == "on" then
        local inset = math.max(2, math.floor(s * 0.25))
        Theme.fill(panel, x + inset, y + inset, s - inset * 2, s - inset * 2, C.accentHi)
    elseif state == "partial" then
        local inset = math.max(2, math.floor(s * 0.25))
        Theme.fill(panel, x + inset, y + math.floor(s / 2) - 1, s - inset * 2, 2, C.accent)
    end
    return s
end

--- Row background plus the lilac selection rail on the left edge.
function Widgets.rowBackground(panel, x, y, w, h, selected, enabled)
    local fillColor = C.row
    if not enabled then
        fillColor = C.rowMuted
    elseif selected then
        fillColor = C.rowActive
    end
    Theme.box(panel, x, y, w, h, fillColor, selected and C.borderHi or C.divider)
    if selected then
        Theme.fill(panel, x, y, 3, h, C.accent)
    end
end

--- "have / need" line used by upgrades and buildables alike.
function Widgets.costRow(panel, x, y, w, texture, label, have, need, suffix)
    local h = M.headerRowHeight + M.padSmall
    local ok = (have or 0) >= (need or 0)
    Theme.box(panel, x, y, w, h, C.row, C.divider)
    local textX = x + M.padSmall
    if texture then
        local iconSize = h - M.padSmall * 2
        panel:drawTextureScaledAspect(texture, x + M.padSmall, y + M.padSmall,
            iconSize, iconSize, 1, 1, 1, 1)
        textX = x + iconSize + M.pad
    end
    Theme.text(panel, label, textX, y + M.padSmall, ok and C.text or C.textDim, UIFont.Small)
    local value = Theme.formatNumber(have) .. " / " .. Theme.formatNumber(need) .. (suffix or "")
    Theme.textRight(panel, value, x + w - M.pad, y + M.padSmall, ok and C.ok or C.bad, UIFont.Small)
    return y + h + M.padTiny
end

--- Table header strip: { {label, offsetX}, ... }
function Widgets.columnHeader(panel, x, y, w, columns)
    local h = M.headerRowHeight
    Theme.box(panel, x, y, w, h, C.inset, C.divider)
    for i = 1, #columns do
        Theme.text(panel, columns[i][1], x + columns[i][2],
            y + math.floor((h - M.fontSmall) / 2), C.textMuted, UIFont.Small)
    end
    return y + h + M.padTiny
end

--- Level pips: filled squares for earned levels, hollow for the rest.
--- Reads at a glance where a numeric "2 / 5" needs parsing.
function Widgets.levelPips(panel, x, y, current, max, size)
    size = size or math.max(5, math.floor(M.fontSmall * 0.55))
    local gap = math.max(2, math.floor(size * 0.45))
    for i = 1, max do
        local px = x + (i - 1) * (size + gap)
        if i <= current then
            Theme.fill(panel, px, y, size, size, C.accent)
        else
            Theme.box(panel, px, y, size, size, C.inset, C.border)
        end
    end
    return x + max * (size + gap)
end

--- Item icon in a sunken slot, so mixed-size textures line up.
function Widgets.iconSlot(panel, texture, x, y, size, dimmed)
    Theme.box(panel, x, y, size, size, C.inset, C.divider)
    if texture then
        local inset = math.max(2, math.floor(size * 0.08))
        panel:drawTextureScaledAspect(texture, x + inset, y + inset,
            size - inset * 2, size - inset * 2, dimmed and 0.35 or 1, 1, 1, 1)
    else
        Theme.fill(panel, x + 2, y + 2, size - 4, 1, C.divider)
        Theme.fill(panel, x + 2, y + size - 3, size - 4, 1, C.divider)
    end
end

--- Compact completed-state mark backed by a dedicated UI texture.
function Widgets.checkMark(panel, right, y, size)
    size = size or 16

    local x = right - size
    panel:drawTextureScaledAspect(CHECKMARK_TEXTURE, x, y, size, size, 1, 1, 1, 1)
    return size
end

--- Small lock glyph for gated entries (no unicode - PZ fonts lack the glyphs).
function Widgets.lockMark(panel, x, y, size)
    size = size or M.fontSmall
    local bodyH = math.floor(size * 0.55)
    local bodyY = y + size - bodyH
    Theme.box(panel, x, bodyY, size, bodyH, C.rowMuted, C.textMuted)
    local shW = math.max(2, size - 4)
    Theme.border(panel, x + math.floor((size - shW) / 2), y + 1,
        shW, size - bodyH + 1, C.textMuted)
end

--- Word wrap that respects the engine's font metrics.
function Widgets.wrapText(text, maxWidth, font)
    local lines = {}
    local current = ""
    for word in tostring(text or ""):gmatch("%S+") do
        local candidate = current == "" and word or (current .. " " .. word)
        if getTextManager():MeasureStringX(font, candidate) <= maxWidth then
            current = candidate
        else
            if current ~= "" then lines[#lines + 1] = current end
            current = word
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end

--- "label ......... value" row on a quiet background.
function Widgets.keyValueRow(panel, x, y, w, label, value, valueColor)
    local h = M.headerRowHeight + M.padSmall
    Theme.box(panel, x, y, w, h, C.row, C.divider)
    Theme.text(panel, label, x + M.pad, y + M.padSmall, C.textDim, UIFont.Small)
    Theme.textRight(panel, value, x + w - M.pad, y + M.padSmall,
        valueColor or C.text, UIFont.Small)
    return y + h + M.padTiny
end

--- "label   before -> after" row for effect changes. `before` may be nil.
function Widgets.deltaRow(panel, x, y, w, label, before, after)
    local h = M.headerRowHeight + M.padSmall
    Theme.box(panel, x, y, w, h, C.row, C.divider)
    Theme.text(panel, label, x + M.pad, y + M.padSmall, C.textDim, UIFont.Small)
    local right = x + w - M.pad
    local afterW = getTextManager():MeasureStringX(UIFont.Small, after)
    Theme.textRight(panel, after, right, y + M.padSmall, C.ok, UIFont.Small)
    if before and before ~= after then
        local arrow = " -> "
        local arrowW = getTextManager():MeasureStringX(UIFont.Small, arrow)
        Theme.textRight(panel, arrow, right - afterW, y + M.padSmall, C.textMuted, UIFont.Small)
        Theme.textRight(panel, before, right - afterW - arrowW, y + M.padSmall,
            C.textMuted, UIFont.Small)
    end
    return y + h + M.padTiny
end

return Widgets
