--[[
    MSR_CardList.lua - Scrollable, grouped, selectable list of cards.

    The workhorse of the refuge UI: the upgrades tab, the structures tab and any
    future screen that offers "a set of things to pick from" render through this
    one component, so they all scroll, group and highlight the same way.

    Data-driven: the owner hands over an ordered array of plain tables and a
    selection callback. A card:

        {
            id       = "faster_reading",     -- required, returned on select
            group    = "Comfort",            -- optional; a header row is drawn
                                             -- whenever it changes between cards
            icon     = texture,              -- optional Texture (already resolved)
            title    = "Faster Reading",
            note     = "1 000 Echo",         -- optional bottom line
            state    = "ready",              -- ready | poor | locked | max | plain
            pips     = { current, max },     -- optional level pips
        }

    States drive presentation only: ready = lilac dot (affordable right now),
    poor = the note turns red (cost not met), locked = dimmed with a lock mark,
    max = green check mark. The list never decides game logic - owners precompute states.
]]

require "ISUI/ISPanel"

local Theme = require "ui/MSR_Theme"
local Widgets = require "ui/MSR_Widgets"
local M = Theme.metrics
local C = Theme.color

---@class MSR_CardList : ISPanel
---@field owner any
---@field onSelect fun(owner: any, id: string)|nil
---@field cards table[]
---@field selectedId string?
MSR_CardList = ISPanel:derive("MSR_CardList")

local CARD_H = math.floor(M.fontSmall * 4.4)
local HEADER_H = M.fontSmall + M.pad

function MSR_CardList:new(x, y, width, height, owner, onSelect)
    local o = ISPanel:new(x, y, width, height) --[[@as MSR_CardList]]
    setmetatable(o, self)
    self.__index = self
    o.owner = owner
    o.onSelect = onSelect
    o.cards = {}
    o.entries = {}
    o.contentHeight = 0
    o.scrollOffset = 0
    o.selectedId = nil
    o.drawFrame = false
    return o
end

function MSR_CardList:initialise()
    ISPanel.initialise(self)
end

--==============================================================================
-- DATA
--==============================================================================

function MSR_CardList:setCards(cards)
    self.cards = cards or {}
    self:rebuildLayout()
end

--- Flatten cards into draw entries, inserting a header whenever `group` changes.
function MSR_CardList:rebuildLayout()
    self.entries = {}
    local y = M.padSmall
    local lastGroup = nil
    for _, card in ipairs(self.cards) do
        if card.group and card.group ~= lastGroup then
            if lastGroup ~= nil then y = y + M.padSmall end
            self.entries[#self.entries + 1] = { header = card.group, y = y, h = HEADER_H }
            y = y + HEADER_H
            lastGroup = card.group
        end
        self.entries[#self.entries + 1] = { card = card, y = y, h = CARD_H }
        y = y + CARD_H + M.padTiny
    end
    self.contentHeight = y + M.padSmall
    self:clampScroll()
end

function MSR_CardList:setSelected(id)
    self.selectedId = id
end

function MSR_CardList:getCard(id)
    for _, card in ipairs(self.cards) do
        if card.id == id then return card end
    end
    return nil
end

--- First card that is actually selectable - used for the initial selection.
function MSR_CardList:firstSelectableId()
    for _, card in ipairs(self.cards) do
        if card.state ~= "locked" then return card.id end
    end
    return self.cards[1] and self.cards[1].id or nil
end

--==============================================================================
-- SCROLLING
--==============================================================================

function MSR_CardList:clampScroll()
    local maxScroll = math.max(0, self.contentHeight - self.height)
    self.scrollOffset = math.max(0, math.min(self.scrollOffset, maxScroll))
end

function MSR_CardList:onMouseWheel(del)
    if self.contentHeight <= self.height then return false end
    self.scrollOffset = self.scrollOffset + del * (CARD_H + M.padTiny)
    self:clampScroll()
    return true
end

--==============================================================================
-- INTERACTION
--==============================================================================

function MSR_CardList:onMouseDown(_x, y)
    local worldY = y + self.scrollOffset
    for _, entry in ipairs(self.entries) do
        if entry.card and worldY >= entry.y and worldY <= entry.y + entry.h then
            self.selectedId = entry.card.id
            if self.onSelect then self.onSelect(self.owner, entry.card.id) end
            return true
        end
    end
    return false
end

--==============================================================================
-- RENDER
--==============================================================================

function MSR_CardList:renderCard(card, y)
    local w = self.width
    local locked = card.state == "locked"
    local selected = card.id == self.selectedId
    Widgets.rowBackground(self, 0, y, w, CARD_H, selected, not locked)

    local iconSize = CARD_H - M.padSmall * 2
    Widgets.iconSlot(self, card.icon, M.padSmall, y + M.padSmall, iconSize, locked)

    local textX = M.padSmall + iconSize + M.pad
    local titleColor = locked and C.textMuted or C.text
    Theme.text(self, card.title or card.id, textX, y + M.padSmall, titleColor, UIFont.Medium)

    local midY = y + M.padSmall + M.fontMedium + M.padTiny
    if card.pips and card.pips[2] and card.pips[2] > 0 then
        local pipSize = math.max(5, math.floor(M.fontSmall * 0.55))
        local endX = Widgets.levelPips(self, textX, midY + math.floor((M.fontSmall - pipSize) / 2),
            card.pips[1], card.pips[2], pipSize)
        Theme.text(self, tostring(card.pips[1]) .. " / " .. tostring(card.pips[2]),
            endX + M.padSmall, midY, C.textMuted, UIFont.Small)
        midY = midY + M.fontSmall + M.padTiny
    end

    if card.note and card.note ~= "" then
        local noteColor = C.textDim
        if card.state == "poor" then noteColor = C.bad end
        if locked then noteColor = C.textMuted end
        Theme.text(self, card.note, textX, midY, noteColor, UIFont.Small)
    end

    -- Trailing state mark
    if card.state == "max" then
        local markSize = 16
        Widgets.checkMark(self, w - M.padSmall,
            y + math.floor((CARD_H - markSize) / 2), markSize)
    elseif locked then
        Widgets.lockMark(self, w - M.padSmall - M.fontSmall, y + M.padSmall)
    elseif card.state == "ready" then
        local r = math.max(3, math.floor(M.fontSmall * 0.3))
        Theme.fill(self, w - M.padSmall - r * 2, y + M.padSmall + r, r * 2, r * 2, C.accent)
    end
end

function MSR_CardList:prerender()
    Theme.box(self, 0, 0, self.width, self.height, C.inset, C.divider)
    self:setStencilRect(0, 0, self.width, self.height)
    for _, entry in ipairs(self.entries) do
        local y = entry.y - self.scrollOffset
        if y + entry.h >= 0 and y <= self.height then
            if entry.header then
                Widgets.sectionHeader(self, M.padSmall, y + M.padTiny,
                    self.width - M.padSmall * 2, entry.header)
            else
                self:renderCard(entry.card, y)
            end
        end
    end
end

function MSR_CardList:render()
    self:clearStencilRect()
    if self.contentHeight > self.height then
        local trackH = self.height
        local barH = math.max(20, math.floor(trackH * self.height / self.contentHeight))
        local maxScroll = self.contentHeight - self.height
        local barY = math.floor((trackH - barH) * (self.scrollOffset / maxScroll))
        Theme.fill(self, self.width - 4, barY, 3, barH, C.borderHi)
    end
end

function MSR_CardList:onResize()
    self:rebuildLayout()
end

return MSR_CardList
