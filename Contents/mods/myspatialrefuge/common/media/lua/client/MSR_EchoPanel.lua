require "ISUI/ISPanel"
require "ISUI/ISButton"
require "MSR_Echo"
require "MSR_Transaction"
require "MSR_UpgradeItemCache"
require "MSR_PlayerMessage"

--[[
    Absorption screen.

    One row per absorbable item type: click the row (or its checkbox) to take the
    whole stack, then trim it with - / + / MAX. The running total is always on
    screen in the summary panel on the right, and a single button commits
    everything at once.
]]

---@class MSREchoRowButtons
---@field minus ISButton
---@field plus ISButton
---@field max ISButton

---@class MSR_EchoPanel : ISPanel
---@field parentWindow MSR_UpgradeWindow
---@field player IsoPlayer
---@field sources table
---@field balance number
---@field capacity number
---@field padding number
---@field rowButtons MSREchoRowButtons[]
---@field echoTexture Texture?
---@field relicTexture Texture
---@field pending boolean
---@field pendingOperationId string|nil
---@field pendingStartedAt number|nil
MSR_EchoPanel = ISPanel:derive("MSR_EchoPanel")
MSR_EchoPanel.TRANSACTION_TYPE = "ECHO_ABSORB"

local Theme = require "ui/MSR_Theme"
local Widgets = require "ui/MSR_Widgets"
local M = Theme.metrics
local C = Theme.color

local SUMMARY_RATIO = 0.34
local MIN_SUMMARY_WIDTH = math.floor(M.fontSmall * 17)
local ROW_STEPPER_HEIGHT = math.max(
    M.fontMedium + M.padTiny * 2, M.fontSmall + M.padSmall * 2)
local ROW_STEPPER_GAP = M.padTiny
local RELIC_PORTRAIT_WIDTH = 128
local RELIC_PORTRAIT_HEIGHT = 160
local RELIC_PORTRAIT = getTexture("media/ui/SacredCore_128x160.png") --[[@as Texture]]
local RELIC_PORTRAIT_ASPECT = RELIC_PORTRAIT_HEIGHT / RELIC_PORTRAIT_WIDTH
local RESPONSE_TIMEOUT_SECONDS = 15

function MSR_EchoPanel:new(x, y, width, height, parentWindow)
    local o = ISPanel:new(x, y, width, height) --[[@as MSR_EchoPanel]]
    setmetatable(o, self)
    self.__index = self
    o.parentWindow = parentWindow
    o.player = parentWindow.player
    o.padding = M.pad
    o.sources = {}
    o.balance = 0
    o.capacity = MSR.Echo.GetCapacity()
    o.pending = false
    o.pendingOperationId = nil
    o.pendingStartedAt = nil
    o.rowButtons = {}
    local _, echoTexture = MSR.UpgradeItemCache.getItemMeta(MSR.Config.ECHO.DISPLAY_ITEM, o.player)
    o.echoTexture = echoTexture
    o.relicTexture = RELIC_PORTRAIT
    o.drawFrame = false
    return o
end

function MSR_EchoPanel:initialise()
    ISPanel.initialise(self)
end

local function createButton(panel, title, callback, kind)
    local button = ISButton:new(0, 0, 50, M.stepperHeight, title, panel, callback)
    button:initialise()
    Theme.styleButton(button, kind)
    panel:addChild(button)
    return button
end

function MSR_EchoPanel:createChildren()
    self.selectAllButton = createButton(self, getText("UI_Echo_SelectAll"), self.onSelectAll)
    self.resetButton = createButton(self, getText("UI_Echo_Reset"), self.onReset)
    self.absorbButton = createButton(self, getText("UI_Echo_Absorb"), self.onAbsorb, "primary")
    self.absorbButton:setFont(UIFont.Medium)
    self:refresh()
end

--==============================================================================
-- DATA
--==============================================================================

function MSR_EchoPanel:refresh()
    local refugeData = MSR.Data.GetRefugeData(self.player)
    self.balance = MSR.Echo.GetBalance(refugeData)
    self.capacity = MSR.Echo.GetCapacity()

    local previous = {}
    for _, source in ipairs(self.sources) do
        previous[source.type] = source.selected
    end

    self.sources = {}
    for _, entry in ipairs(MSR.Echo.GetSources()) do
        local available = MSR.Transaction.GetMultiSourceCount(self.player, entry.type, true)
        local displayName, texture = MSR.UpgradeItemCache.getItemMeta(entry.type, self.player)
        self.sources[#self.sources + 1] = {
            type = entry.type,
            value = entry.value,
            available = available,
            name = displayName or entry.type,
            texture = texture,
            selected = math.min(previous[entry.type] or 0, available),
        }
    end

    self:clampSelection()
    self:layoutControls()
    self:updateButtons()
end

--- Free capacity is shared by every row, so trim from the cheapest one first.
function MSR_EchoPanel:clampSelection()
    local free = math.max(0, self.capacity - self.balance)
    local spent = 0.0
    for _, source in ipairs(self.sources) do
        source.selected = math.max(0, math.min(source.selected, source.available))
        spent = spent + source.selected * source.value
    end
    for index = #self.sources, 1, -1 do
        local source = self.sources[index]
        while spent > free and source.selected > 0 do
            source.selected = source.selected - 1
            spent = spent - source.value
        end
    end
end

function MSR_EchoPanel:maxCountFor(source)
    local free = math.max(0, self.capacity - self.balance - self:selectedTotal()
        + source.selected * source.value)
    if source.value <= 0 then return 0 end
    return math.min(source.available, math.floor(free / source.value))
end

function MSR_EchoPanel:selectedTotal()
    local total = 0.0
    for _, source in ipairs(self.sources) do
        total = total + source.selected * source.value
    end
    return total
end

function MSR_EchoPanel:selectedItems()
    local count, types = 0, 0
    for _, source in ipairs(self.sources) do
        count = count + source.selected
        if source.selected > 0 then types = types + 1 end
    end
    return count, types
end

function MSR_EchoPanel:availableItems()
    local count = 0
    for _, source in ipairs(self.sources) do
        count = count + source.available
    end
    return count
end

--==============================================================================
-- LAYOUT
--==============================================================================

function MSR_EchoPanel:listWidth()
    local summary = math.max(MIN_SUMMARY_WIDTH, math.floor(self.width * SUMMARY_RATIO))
    return self.width - summary - M.padLarge, summary
end

function MSR_EchoPanel.rowY(index)
    return M.pad + M.buttonHeight + M.pad + M.headerRowHeight + M.padTiny
        + (index - 1) * (M.rowHeight + M.padTiny)
end

function MSR_EchoPanel:layoutControls()
    local listW, summaryW = self:listWidth()
    local summaryX = self.width - summaryW

    local toolbarW = math.floor(M.fontSmall * 13)
    self.selectAllButton:setX(M.pad)
    self.selectAllButton:setY(M.pad)
    self.selectAllButton:setWidth(toolbarW)
    self.selectAllButton:setHeight(M.buttonHeight)
    self.resetButton:setX(M.pad * 2 + toolbarW)
    self.resetButton:setY(M.pad)
    self.resetButton:setWidth(math.floor(M.fontSmall * 7))
    self.resetButton:setHeight(M.buttonHeight)

    self.absorbButton:setX(summaryX + M.pad)
    self.absorbButton:setY(self.height - M.buttonHeight * 2 - M.pad)
    self.absorbButton:setWidth(summaryW - M.pad * 2)
    self.absorbButton:setHeight(math.floor(M.buttonHeight * 1.4))

    self:layoutRowButtons(listW)
end

--- One -/+/MAX trio per row, rebuilt when the set of sources changes.
function MSR_EchoPanel:layoutRowButtons(listW)
    local stepW = ROW_STEPPER_HEIGHT
    local maxW = getTextManager():MeasureStringX(UIFont.Small, getText("UI_Echo_Max"))
        + M.padSmall * 2
    local valueW = getTextManager():MeasureStringX(UIFont.Medium, "000") + M.padSmall * 2
    local giveW = math.floor(M.fontSmall * 5)
    local groupW = stepW * 2 + valueW + maxW + ROW_STEPPER_GAP * 3
    local groupX = M.pad + listW - giveW - groupW - M.pad

    for index, source in ipairs(self.sources) do
        local buttons = self.rowButtons[index]
        if not buttons then
            buttons = {
                minus = createButton(self, "-", self.onRowMinus),
                plus = createButton(self, "+", self.onRowPlus),
                max = createButton(self, getText("UI_Echo_Max"), self.onRowMax),
            }
            buttons.minus:setFont(UIFont.Medium)
            buttons.plus:setFont(UIFont.Medium)
            buttons.max:setFont(UIFont.Small)
            for _, button in pairs(buttons) do
                button.onClickArgs = { index }
            end
            self.rowButtons[index] = buttons
        end
        for _, button in pairs(buttons) do
            button.onClickArgs = { index }
            button:setVisible(source.available > 0)
            button:setHeight(ROW_STEPPER_HEIGHT)
        end
        local y = self.rowY(index) + math.floor((M.rowHeight - ROW_STEPPER_HEIGHT) / 2)
        buttons.minus:setX(groupX)
        buttons.minus:setY(y)
        buttons.minus:setWidth(stepW)
        local valueX = groupX + stepW + ROW_STEPPER_GAP
        buttons.plus:setX(valueX + valueW + ROW_STEPPER_GAP)
        buttons.plus:setY(y)
        buttons.plus:setWidth(stepW)
        buttons.max:setX(valueX + valueW + ROW_STEPPER_GAP + stepW + ROW_STEPPER_GAP)
        buttons.max:setY(y)
        buttons.max:setWidth(maxW)
        source.valueBoxX = valueX
        source.valueBoxW = valueW
        source.giveRight = M.pad + listW - M.pad
    end

    for index = #self.sources + 1, #self.rowButtons do
        for _, button in pairs(self.rowButtons[index]) do
            button:setVisible(false)
        end
    end
end

function MSR_EchoPanel:onResize()
    self:layoutControls()
end

--==============================================================================
-- INTERACTION
--==============================================================================

function MSR_EchoPanel:updateButtons()
    local total = self:selectedTotal()
    local canEdit = not self.pending
    self.absorbButton:setEnable(canEdit and total > 0)
    self.selectAllButton:setEnable(canEdit and self:availableItems() > 0)
    self.resetButton:setEnable(canEdit and total > 0)
    for index, source in ipairs(self.sources) do
        local buttons = self.rowButtons[index]
        if buttons then
            buttons.minus:setEnable(canEdit and source.selected > 0)
            buttons.plus:setEnable(canEdit and source.selected < self:maxCountFor(source))
            buttons.max:setEnable(canEdit and self:maxCountFor(source) > 0)
        end
    end
end

function MSR_EchoPanel:onRowMinus(_button, index)
    if self.pending then return end
    local source = self.sources[index]
    if not source then return end
    source.selected = math.max(0, source.selected - 1)
    self:updateButtons()
end

function MSR_EchoPanel:onRowPlus(_button, index)
    if self.pending then return end
    local source = self.sources[index]
    if not source then return end
    source.selected = math.min(self:maxCountFor(source), source.selected + 1)
    self:updateButtons()
end

function MSR_EchoPanel:onRowMax(_button, index)
    if self.pending then return end
    local source = self.sources[index]
    if not source then return end
    source.selected = self:maxCountFor(source)
    self:updateButtons()
end

function MSR_EchoPanel:onSelectAll()
    if self.pending then return end
    for _, source in ipairs(self.sources) do
        source.selected = self:maxCountFor(source)
    end
    self:updateButtons()
end

function MSR_EchoPanel:onReset()
    if self.pending then return end
    for _, source in ipairs(self.sources) do
        source.selected = 0
    end
    self:updateButtons()
end

--- Clicking anywhere on a row toggles the whole stack.
function MSR_EchoPanel:onMouseDown(x, y)
    if self.pending then return false end
    local listW = self:listWidth()
    for index, source in ipairs(self.sources) do
        local rowY = self.rowY(index)
        if y >= rowY and y <= rowY + M.rowHeight and x <= listW + M.pad then
            if source.available <= 0 then return false end
            if source.selected > 0 then
                source.selected = 0
            else
                source.selected = self:maxCountFor(source)
            end
            self:updateButtons()
            return true
        end
    end
    return false
end

function MSR_EchoPanel:setPending(pending, operationId)
    self.pending = pending == true
    if self.pending then
        self.pendingOperationId = operationId or self.pendingOperationId
        self.pendingStartedAt = self.pendingStartedAt or K.time()
    else
        self.pendingOperationId = nil
        self.pendingStartedAt = nil
    end
    self:updateButtons()
end

function MSR_EchoPanel:isResponseCurrent(operationId)
    if not self.pending then return true end
    return type(operationId) == "string" and operationId == self.pendingOperationId
end

function MSR_EchoPanel:onTransactionTimeout(operationId)
    if not self.pending or operationId ~= self.pendingOperationId then return end
    self:setPending(false)
    self:refresh()
end

function MSR_EchoPanel:buildAllocationRequest()
    local request = {}
    for _, source in ipairs(self.sources) do
        if source.selected > 0 then
            request[#request + 1] = { type = source.type, count = source.selected }
        end
    end
    return request
end

function MSR_EchoPanel:onAbsorb()
    if self.pending then return end
    local request = self:buildAllocationRequest()
    if #request == 0 then return end

    local transaction, transactionError = MSR.Transaction.Begin(
        self.player,
        MSR_EchoPanel.TRANSACTION_TYPE,
        request
    )
    if not transaction then
        MSR.PlayerMessage.SayRaw(self.player, tostring(transactionError or getText("UI_Echo_Error")))
        self:refresh()
        return
    end

    self:setPending(true, transaction.id)
    local allocation = MSR.Transaction.CopyAllocation(transaction)
    if MSR.Env.isMultiplayerClient() then
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_ECHO_ABSORB, {
            operationId = transaction.id,
            allocation = allocation,
        })
        return
    end

    local success, errorMessage = MSR.Echo.AbsorbAllocation(self.player, allocation, transaction.id)
    if success then
        MSR.Transaction.Finalize(self.player, transaction.id)
        MSR.PlayerMessage.SayRaw(self.player, getText("UI_Echo_AbsorbSuccess"))
    else
        MSR.Transaction.Rollback(self.player, transaction.id)
        MSR.PlayerMessage.SayRaw(self.player, tostring(errorMessage or getText("UI_Echo_Error")))
    end
    self:setPending(false)
    self:refresh()
end

function MSR_EchoPanel:onServerComplete(operationId)
    if not self:isResponseCurrent(operationId) then return end
    self:setPending(false)
    self:refresh()
end

function MSR_EchoPanel:onServerError(operationId)
    if not self:isResponseCurrent(operationId) then return end
    self:setPending(false)
    self:refresh()
end

function MSR_EchoPanel:update()
    ISPanel.update(self)
    if not self.pending
        or not self.pendingStartedAt
        or K.time() - self.pendingStartedAt <= RESPONSE_TIMEOUT_SECONDS
    then
        return
    end

    local operationId = self.pendingOperationId
    if operationId then MSR.Transaction.Rollback(self.player, operationId) end
    self:setPending(false)
    MSR.Data.RequestModDataFromServer(true)
    self:refresh()
    MSR.PlayerMessage.Say(self.player, MSR.PlayerMessage.ACTION_TIMEOUT_ITEMS_UNLOCKED)
end

--==============================================================================
-- RENDER
--==============================================================================

local function operationLabel(operationType)
    return getText("UI_Echo_History_" .. tostring(operationType or "unknown"))
end

function MSR_EchoPanel:renderSourceRow(index, source, x, width)
    local y = self.rowY(index)
    local enabled = source.available > 0
    local selected = source.selected > 0
    Widgets.rowBackground(self, x, y, width, M.rowHeight, selected, enabled)

    local state = "off"
    if not enabled then
        state = "disabled"
    elseif source.selected >= source.available and source.selected > 0 then
        state = "on"
    elseif source.selected > 0 then
        state = "partial"
    end
    local checkX = x + M.pad
    Widgets.checkbox(self, checkX, y + math.floor((M.rowHeight - M.checkboxSize) / 2), state)

    local iconX = checkX + M.checkboxSize + M.pad
    if source.texture then
        self:drawTextureScaledAspect(source.texture, iconX,
            y + math.floor((M.rowHeight - M.iconSize) / 2), M.iconSize, M.iconSize, 1, 1, 1, 1)
    end

    local textX = iconX + M.iconSize + M.pad
    Theme.text(self, source.name, textX, y + M.padSmall,
        enabled and C.text or C.textMuted, UIFont.Medium)
    local rate = getText("UI_Echo_RatePerItem", Theme.formatNumber(source.value))
    Theme.text(self, rate, textX, y + M.padSmall + M.fontMedium, C.textMuted, UIFont.Small)

    local countText = enabled and ("x" .. Theme.formatNumber(source.available)) or "-"
    Theme.text(self, countText, x + math.floor(width * 0.46), y + math.floor(M.rowHeight / 2)
        - math.floor(M.fontSmall / 2), enabled and C.textDim or C.textMuted, UIFont.Small)

    if enabled and source.valueBoxX then
        local boxY = y + math.floor((M.rowHeight - ROW_STEPPER_HEIGHT) / 2)
        Theme.box(self, source.valueBoxX, boxY,
            source.valueBoxW, ROW_STEPPER_HEIGHT, C.inset, C.borderHi)
        Theme.textCentre(self, tostring(source.selected),
            source.valueBoxX + math.floor(source.valueBoxW / 2),
            boxY + math.floor((ROW_STEPPER_HEIGHT - M.fontMedium) / 2), C.text, UIFont.Medium)
    end

    local give = source.selected * source.value
    local giveText = give > 0 and ("+" .. Theme.formatNumber(give)) or "-"
    Theme.textRight(self, giveText, x + width - M.pad,
        y + math.floor(M.rowHeight / 2) - math.floor(M.fontMedium / 2),
        give > 0 and C.accentHi or C.textMuted, UIFont.Medium)
end

function MSR_EchoPanel:renderSummary(x, width)
    local total = self:selectedTotal()
    local items = self:selectedItems()
    Theme.box(self, x, 0, width, self.height, C.inset, C.border)
    Theme.fill(self, x + 1, 1, width - 2, 2, C.brass)

    local description = getText("UI_Echo_RelicDescription")
    local descriptionLines = Widgets.wrapText(description, width - M.pad * 4, UIFont.Small)
    local boxH = M.fontLarge * 2 + M.fontSmall + M.pad * 3 + M.padSmall
    local boxY = self.absorbButton:getY() - M.padLarge - boxH

    local y = M.pad
    local contentAfterArt = M.pad + M.fontSmall + M.padSmall
        + #descriptionLines * M.fontSmall + M.padLarge
    local maxArtH = boxY - y - contentAfterArt
    maxArtH = math.max(maxArtH, M.iconSize)
    local artW = math.min(width - M.pad * 4, math.floor(M.fontSmall * 15),
        math.floor(maxArtH / RELIC_PORTRAIT_ASPECT))
    local artH = math.floor(artW * RELIC_PORTRAIT_ASPECT)
    self:drawTextureScaledAspect(self.relicTexture, x + math.floor((width - artW) / 2), y,
        artW, artH, 1, 1, 1, 1)
    y = y + artH + M.pad

    local centreX = x + math.floor(width / 2)
    Theme.textCentre(self, getText("UI_Echo_RelicAbsorbs"), centreX, y,
        C.brassHi, UIFont.Small)
    y = y + M.fontSmall + M.padSmall

    for _, line in ipairs(descriptionLines) do
        Theme.textCentre(self, line, centreX, y, C.textDim, UIFont.Small)
        y = y + M.fontSmall
    end

    Theme.box(self, x + M.pad, boxY, width - M.pad * 2, boxH, C.accentFill, C.accentDim)
    local labelY = boxY + M.pad
    Theme.text(self, getText("UI_Echo_YouWillGet"), x + M.pad * 2, labelY, C.brassHi, UIFont.Small)
    local echoGainText = "+" .. getText("UI_Refuge_CostEcho", Theme.formatNumber(total))
    Theme.text(self, echoGainText, x + M.pad * 2,
        labelY + M.fontSmall + M.padSmall, C.accentHi, UIFont.Large)
    Theme.text(self, getText("UI_Echo_ItemsSelected", tostring(items),
        tostring(self:availableItems())), x + M.pad * 2, boxY + boxH - M.pad - M.fontSmall,
        C.textDim, UIFont.Small)
    Theme.textRight(self, Theme.formatNumber(self.balance) .. " > "
        .. Theme.formatNumber(self.balance + total), x + width - M.pad * 2,
        boxY + boxH - M.pad - M.fontSmall, C.text, UIFont.Small)
    Theme.textCentre(self, getText("UI_Echo_AbsorbWarning"), x + math.floor(width / 2),
        self.height - M.fontSmall - M.padSmall, C.textMuted, UIFont.Small)
end

function MSR_EchoPanel:renderHistory(x, y, width)
    local refugeData = MSR.Data.GetRefugeData(self.player)
    local history = MSR.Echo.GetHistory(refugeData)
    y = Widgets.sectionHeader(self, x, y, width, getText("UI_Echo_History"))
    if #history == 0 then
        Theme.text(self, getText("UI_Echo_HistoryEmpty"), x, y, C.textMuted, UIFont.Small)
        return
    end

    local rowH = M.historyRowHeight
    local rows = math.max(0, math.floor((self.height - y - M.pad) / (rowH + M.padTiny)))
    local shown = 0
    for index = #history, 1, -1 do
        if shown >= rows then break end
        local entry = history[index]
        if entry then
            local rowY = y + shown * (rowH + M.padTiny)
            Theme.box(self, x, rowY, width, rowH, C.row, C.divider)
            local textY = rowY + math.floor((rowH - M.fontSmall) / 2)
            Theme.text(self, operationLabel(entry.type), x + M.pad, textY, C.text, UIFont.Small)
            local delta = tonumber(entry.delta) or 0
            local deltaText = (delta >= 0 and "+" or "") .. Theme.formatNumber(delta)
            Theme.textRight(self, deltaText, x + width - math.floor(width * 0.18), textY,
                delta >= 0 and C.ok or C.warn, UIFont.Small)
            Theme.textRight(self, Theme.formatNumber(entry.balanceAfter or 0),
                x + width - M.pad, textY, C.textDim, UIFont.Small)
            shown = shown + 1
        end
    end
end

function MSR_EchoPanel:prerender()
    Theme.box(self, 0, 0, self.width, self.height, C.panel, C.border)

    local listW, summaryW = self:listWidth()
    local listX = M.pad

    local selectedCount, selectedTypes = self:selectedItems()
    local selectionLeft = self.resetButton:getX() + self.resetButton:getWidth() + M.pad
    local selectionRight = listX + listW
    Theme.textCentre(self, getText("UI_Echo_SelectionSummary", tostring(selectedTypes),
        tostring(selectedCount)), selectionLeft + math.floor((selectionRight - selectionLeft) / 2),
        M.pad + math.floor((M.buttonHeight - M.fontSmall) / 2), C.textDim, UIFont.Small)

    local headerY = M.pad + M.buttonHeight + M.pad
    Widgets.columnHeader(self, listX, headerY, listW, {
        { getText("UI_Echo_ColItem"), M.pad },
        { getText("UI_Echo_ColHave"), math.floor(listW * 0.46) },
        { getText("UI_Echo_ColTake"), math.floor(listW * 0.60) },
        { getText("UI_Echo_ColGives"), math.floor(listW * 0.88) },
    })

    for index, source in ipairs(self.sources) do
        self:renderSourceRow(index, source, listX, listW)
    end

    local historyY = self.rowY(#self.sources + 1) + M.pad
    self:renderHistory(listX, historyY, listW)

    self:renderSummary(self.width - summaryW, summaryW)
end

return MSR_EchoPanel
