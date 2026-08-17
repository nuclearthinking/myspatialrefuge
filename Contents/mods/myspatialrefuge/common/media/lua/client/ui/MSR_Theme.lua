--[[
    MSR_Theme.lua - Colours and metrics for the refuge interface.

    The palette is sampled from the mod's own art so the UI reads as part of the
    same object as the relic: warm stone and brass for structure, relic lilac for
    energy, and only three semantic colours (ok / warn / bad).

        stone / brass  <- media/texturepacks/2x/myspatialrefuge.png
        relic lilac    <- media/ui/SacredCore_128x160.png, item_ExperienceEssence.png

    Metrics derive from font heights, so everything scales with the game's UI
    scale exactly like ui/framework/CUI_Config does.

    Colours are {r, g, b, a} tables in 0..1. Use the helpers instead of calling
    drawRect/drawText directly - the engine's argument order differs between them
    (drawRect takes a,r,g,b while drawText takes r,g,b,a) and mixing them up is
    the easiest way to get a magenta panel.
]]

local Theme = {}

local FONT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_LARGE = getTextManager():getFontHeight(UIFont.Large)

local function rgb(hex, a)
    return {
        r = math.floor(hex / 65536) % 256 / 255,
        g = math.floor(hex / 256) % 256 / 255,
        b = hex % 256 / 255,
        a = a or 1,
    }
end

Theme.color = {
    windowBg   = rgb(0x1a1613, 0.96),
    titleBg    = rgb(0x241d19, 1),
    stripBg    = rgb(0x1d1815, 1),
    panel      = rgb(0x221c18, 1),
    inset      = rgb(0x12100e, 1),
    row        = rgb(0x1e1a16, 1),
    rowActive  = rgb(0x2b2320, 1),
    rowMuted   = rgb(0x161311, 1),

    border     = rgb(0x3b322b, 1),
    borderHi   = rgb(0x584a3f, 1),
    divider    = rgb(0x2b2420, 1),

    brass      = rgb(0x8d7261, 1),
    brassHi    = rgb(0xd0b19a, 1),
    brassDim   = rgb(0x5c4a3d, 1),

    accentDim  = rgb(0x795d87, 1),
    accent     = rgb(0xb797c7, 1),
    accentHi   = rgb(0xcfaad8, 1),
    accentFill = rgb(0x241c2b, 1),

    text       = rgb(0xe8e2dc, 1),
    textDim    = rgb(0xa99f97, 1),
    textMuted  = rgb(0x6e665f, 1),

    ok         = rgb(0x8fb85f, 1),
    warn       = rgb(0xd9a441, 1),
    bad        = rgb(0xc2604c, 1),

    buttonBg      = rgb(0x2a231f, 1),
    buttonHover   = rgb(0x3a3129, 1),
    buttonPrimary = rgb(0x4a3358, 1),
    buttonPrimaryHover = rgb(0x5d4270, 1),
}

Theme.metrics = {
    fontSmall = FONT_SMALL,
    fontMedium = FONT_MEDIUM,
    fontLarge = FONT_LARGE,

    padTiny = math.max(2, math.floor(FONT_SMALL * 0.2)),
    padSmall = math.max(3, math.floor(FONT_SMALL * 0.4)),
    pad = math.max(5, math.floor(FONT_SMALL * 0.6)),
    padLarge = math.max(7, math.floor(FONT_SMALL * 0.9)),

    rowHeight = math.floor(FONT_SMALL * 3.9),
    historyRowHeight = math.floor(FONT_SMALL * 1.9),
    headerRowHeight = math.floor(FONT_SMALL * 1.6),
    buttonHeight = math.floor(FONT_MEDIUM * 1.7),
    stepperHeight = math.floor(FONT_MEDIUM * 1.6),
    iconSize = math.floor(FONT_SMALL * 2.4),
    checkboxSize = math.floor(FONT_SMALL * 1.1),
    barHeight = math.max(10, math.floor(FONT_SMALL * 0.9)),
    cornerBracket = math.floor(FONT_SMALL * 1.1),
}

--- panel:drawRect wrapper (engine wants alpha first).
function Theme.fill(panel, x, y, w, h, c, alphaOverride)
    panel:drawRect(x, y, w, h, alphaOverride or c.a, c.r, c.g, c.b)
end

function Theme.border(panel, x, y, w, h, c, alphaOverride)
    panel:drawRectBorder(x, y, w, h, alphaOverride or c.a, c.r, c.g, c.b)
end

function Theme.box(panel, x, y, w, h, fillColor, borderColor)
    if fillColor then Theme.fill(panel, x, y, w, h, fillColor) end
    if borderColor then Theme.border(panel, x, y, w, h, borderColor) end
end

function Theme.text(panel, str, x, y, c, font)
    panel:drawText(str, x, y, c.r, c.g, c.b, c.a, font or UIFont.Small)
end

function Theme.textRight(panel, str, right, y, c, font)
    font = font or UIFont.Small
    local w = getTextManager():MeasureStringX(font, str)
    panel:drawText(str, right - w, y, c.r, c.g, c.b, c.a, font)
end

function Theme.textCentre(panel, str, centre, y, c, font)
    font = font or UIFont.Small
    local w = getTextManager():MeasureStringX(font, str)
    panel:drawText(str, centre - math.floor(w / 2), y, c.r, c.g, c.b, c.a, font)
end

--- Thousands separator: 12400 -> "12 400". Keeps big Echo numbers readable.
function Theme.formatNumber(value)
    local n = math.floor(tonumber(value) or 0)
    local sign = n < 0 and "-" or ""
    local digits = tostring(math.abs(n))
    local out = ""
    while #digits > 3 do
        out = " " .. digits:sub(-3) .. out
        digits = digits:sub(1, -4)
    end
    return sign .. digits .. out
end

--- Apply the theme to a stock ISButton so we do not have to reimplement buttons.
function Theme.styleButton(button, kind)
    local bg = kind == "primary" and Theme.color.buttonPrimary or Theme.color.buttonBg
    local hover = kind == "primary" and Theme.color.buttonPrimaryHover or Theme.color.buttonHover
    local brd = kind == "primary" and Theme.color.accent or Theme.color.borderHi
    button:setBackgroundRGBA(bg.r, bg.g, bg.b, bg.a)
    button:setBorderRGBA(brd.r, brd.g, brd.b, brd.a)
    button.backgroundColorMouseOver = { r = hover.r, g = hover.g, b = hover.b, a = hover.a }
    return button
end

return Theme
