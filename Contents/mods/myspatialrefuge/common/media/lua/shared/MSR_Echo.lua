-- Persistent, server-authoritative Echo currency for a Spatial Refuge.

require "00_core/00_MSR"
require "00_core/Config"
require "00_core/Data"
require "MSR_Transaction"
require "MSR_InventoryAuthority"
require "MSR_RefugeGeometry"
require "MSR_Integrity"

local Echo = MSR.register("Echo")
if not Echo then return MSR.Echo end

local Config = MSR.Config
local Data = MSR.Data
local LOG = L.logger("Echo")

local ITEM_VALUES = {
    [Config.CORE_ITEM] = Config.ECHO.CORE_VALUE,
}
local MAX_ABSORB_ITEMS = math.floor(Config.ECHO.CAPACITY / Config.ECHO.CORE_VALUE)

local function isInteger(value)
    return type(value) == "number" and value == value and value == math.floor(value)
end

local function copyHistory(history)
    local copy = {}
    for index = 1, #history do copy[index] = history[index] end
    return copy
end

local function getWorldAgeHours()
    local gameTime = getGameTime and getGameTime() or nil
    if gameTime and gameTime.getWorldAgeHours then
        return gameTime:getWorldAgeHours()
    end
    return 0
end

local function ensureState(refugeData)
    if not refugeData then return nil end
    if type(refugeData.echo) ~= "table" then
        refugeData.echo = { balance = 0, history = {} }
    end
    if not isInteger(refugeData.echo.balance) then refugeData.echo.balance = 0 end
    refugeData.echo.balance = math.max(0, math.min(Config.ECHO.CAPACITY, refugeData.echo.balance))
    if type(refugeData.echo.history) ~= "table" then refugeData.echo.history = {} end
    return refugeData.echo
end

local function appendHistory(state, operation)
    local entry = {
        id = operation.id,
        type = operation.type,
        delta = operation.delta,
        reason = operation.reason,
        balanceAfter = state.balance,
        worldAgeHours = getWorldAgeHours(),
    }
    table.insert(state.history, entry)
    while #state.history > Config.ECHO.HISTORY_LIMIT do table.remove(state.history, 1) end
    return entry
end

local function beginChange(refugeData, delta, operationId, operationType, reason)
    if not Data.CanModifyData() then return nil, "Echo can only be modified authoritatively" end
    if not refugeData then return nil, "Refuge data unavailable" end
    if not isInteger(delta) or delta == 0 then return nil, "Invalid Echo amount" end
    if type(operationId) ~= "string" or operationId == "" or #operationId > 128 then
        return nil, "Invalid Echo operation ID"
    end
    if type(operationType) ~= "string" or operationType == "" then return nil, "Invalid Echo operation type" end

    local existing = Echo.FindHistoryEntry(refugeData, operationId)
    if existing then return nil, "Duplicate Echo operation", existing end

    local state = ensureState(refugeData)
    if not state then return nil, "Echo state unavailable" end
    local nextBalance = state.balance + delta
    if nextBalance < 0 then return nil, "Not enough Echo" end
    if nextBalance > Config.ECHO.CAPACITY then return nil, "Echo capacity exceeded" end

    local receipt = {
        refugeData = refugeData,
        previousBalance = state.balance,
        previousHistory = copyHistory(state.history),
        finalized = false,
    }
    state.balance = nextBalance
    receipt.entry = appendHistory(state, {
        id = operationId,
        type = operationType,
        delta = delta,
        reason = reason,
    })
    return receipt, nil, nil
end

function Echo.GetCapacity()
    return Config.ECHO.CAPACITY
end

function Echo.GetBalance(refugeData)
    local state = refugeData and refugeData.echo or nil
    local balance = state and tonumber(state.balance) or 0
    if not isInteger(balance) then return 0 end
    return math.max(0, math.min(Config.ECHO.CAPACITY, balance))
end

function Echo.GetHistory(refugeData)
    local state = refugeData and refugeData.echo or nil
    return state and type(state.history) == "table" and state.history or {}
end

function Echo.GetItemValue(itemOrType)
    local itemType = itemOrType
    if type(itemOrType) ~= "string" and itemOrType and itemOrType.getFullType then
        itemType = itemOrType:getFullType()
    end
    return type(itemType) == "string" and ITEM_VALUES[itemType] or nil
end

--- Every item type the relic can absorb, richest first.
--- The absorption screen builds its rows from this, so adding a source is a data
--- change here rather than a UI change. Note that Echo.AbsorbAllocation still
--- validates a single-type allocation, so a new entry needs server support too.
function Echo.GetSources()
    local sources = {}
    for itemType, value in pairs(ITEM_VALUES) do
        sources[#sources + 1] = { type = itemType, value = value }
    end
    table.sort(sources, function(a, b)
        if a.value == b.value then return a.type < b.type end
        return a.value > b.value
    end)
    return sources
end

function Echo.FindHistoryEntry(refugeData, operationId)
    if type(operationId) ~= "string" then return nil end
    local history = Echo.GetHistory(refugeData)
    for index = #history, 1, -1 do
        if history[index] and history[index].id == operationId then return history[index] end
    end
    return nil
end

function Echo.GetMaxAbsorbCount(refugeData, availableCoreCount)
    local available = math.max(0, math.floor(tonumber(availableCoreCount) or 0))
    local freeCapacity = Echo.GetCapacity() - Echo.GetBalance(refugeData)
    return math.min(available, math.floor(freeCapacity / Config.ECHO.CORE_VALUE))
end

function Echo.IsPlayerNearOwnRelic(player, refugeData)
    if not player or not refugeData then return false end
    local playerX = player.getX and player:getX() or nil
    local playerY = player.getY and player:getY() or nil
    local playerZ = player.getZ and player:getZ() or nil
    local relicX = tonumber(refugeData.relicX)
    local relicY = tonumber(refugeData.relicY)
    local relicZ = tonumber(refugeData.relicZ or refugeData.centerZ)
    if not playerX or not playerY or playerZ == nil or not relicX or not relicY or not relicZ then
        return false
    end
    if math.floor(playerZ) ~= math.floor(relicZ) then return false end
    if math.max(math.abs(playerX - relicX), math.abs(playerY - relicY)) > 3 then return false end
    if not MSR.RefugeGeometry.ContainsTile(refugeData, playerX, playerY) then return false end
    return MSR.Integrity.FindRelic(refugeData) ~= nil
end

local function validateCoreAllocation(allocation)
    if type(allocation) ~= "table" then return nil, "Invalid core allocation" end
    local itemTypes = 0
    for itemType in pairs(allocation) do
        itemTypes = itemTypes + 1
        if itemType ~= Config.CORE_ITEM then return nil, "Only Zombie Cores can be absorbed" end
    end
    if itemTypes ~= 1 then return nil, "No Zombie Cores selected" end

    local itemIds = allocation[Config.CORE_ITEM]
    if type(itemIds) ~= "table" or #itemIds < 1 then return nil, "No Zombie Cores selected" end
    if #itemIds > MAX_ABSORB_ITEMS then return nil, "Core allocation exceeds Echo capacity" end
    local seen = {}
    local visited = 0
    for index, itemId in pairs(itemIds) do
        visited = visited + 1
        if visited > MAX_ABSORB_ITEMS then return nil, "Invalid core allocation" end
        if type(index) ~= "number" or index < 1 or index > #itemIds or index ~= math.floor(index)
            or type(itemId) ~= "number" or itemId ~= math.floor(itemId) or seen[itemId]
        then
            return nil, "Invalid core allocation"
        end
        seen[itemId] = true
    end
    if visited ~= #itemIds then return nil, "Invalid core allocation" end
    return #itemIds, nil
end

--- Atomically consume exact Zombie Core IDs and credit their server-known value.
function Echo.AbsorbAllocation(player, allocation, operationId)
    if not Data.CanModifyData() then return false, "Echo absorption requires authority", nil end
    local playerObj = MSR.resolvePlayer(player)
    if not playerObj then return false, "Invalid player", nil end
    local refugeData = Data.GetRefugeData(playerObj)
    if not refugeData then return false, "Refuge data unavailable", nil end
    if type(operationId) ~= "string" or operationId == "" or #operationId > 128 then
        return false, "Invalid Echo operation ID", nil
    end

    local existing = Echo.FindHistoryEntry(refugeData, operationId)
    if existing then
        if existing.type == "absorb" then return true, nil, existing, true end
        return false, "Duplicate Echo operation", nil
    end
    if not Echo.IsPlayerNearOwnRelic(playerObj, refugeData) then
        return false, "Player is not near their Sacred Relic", nil
    end

    local coreCount, allocationError = validateCoreAllocation(allocation)
    if not coreCount then return false, allocationError, nil end
    local amount = coreCount * Config.ECHO.CORE_VALUE
    if not Echo.CanCredit(refugeData, amount) then return false, "Echo capacity exceeded", nil end

    local sources = MSR.Transaction.GetItemRoots(playerObj, true)
    local itemReceipt, consumeError = MSR.InventoryAuthority.consumeWithReceipt(
        playerObj,
        sources,
        allocation,
        MSR.Transaction.IsItemAvailable
    )
    if not itemReceipt then return false, consumeError or "Failed to absorb Zombie Cores", nil end

    local echoReceipt, echoError = Echo.BeginCredit(
        refugeData,
        amount,
        operationId,
        "absorb",
        Config.CORE_ITEM .. ":" .. tostring(coreCount)
    )
    if not echoReceipt then
        MSR.InventoryAuthority.refundReceipt(playerObj, itemReceipt)
        return false, echoError or "Failed to credit Echo", nil
    end
    if not Data.SaveRefugeData(refugeData) then
        Echo.RollbackReceipt(echoReceipt, false)
        MSR.InventoryAuthority.refundReceipt(playerObj, itemReceipt)
        return false, "Failed to persist Echo absorption", nil
    end

    Echo.FinalizeReceipt(echoReceipt)
    MSR.InventoryAuthority.finalizeReceipt(itemReceipt)
    return true, nil, echoReceipt.entry, false
end

function Echo.CanCredit(refugeData, amount)
    return isInteger(amount) and amount > 0
        and Echo.GetBalance(refugeData) + amount <= Echo.GetCapacity()
end

function Echo.CanSpend(refugeData, amount)
    return isInteger(amount) and amount >= 0 and Echo.GetBalance(refugeData) >= amount
end

function Echo.BeginCredit(refugeData, amount, operationId, operationType, reason)
    local existing = Echo.FindHistoryEntry(refugeData, operationId)
    if existing then return nil, "Duplicate Echo operation", existing end
    if not Echo.CanCredit(refugeData, amount) then return nil, "Echo capacity exceeded" end
    return beginChange(refugeData, amount, operationId, operationType or "absorb", reason)
end

function Echo.BeginSpend(refugeData, amount, operationId, operationType, reason)
    if not isInteger(amount) or amount < 0 then return nil, "Invalid Echo amount" end
    if amount == 0 then
        return { refugeData = refugeData, finalized = false, noChange = true }, nil, nil
    end
    if not Echo.CanSpend(refugeData, amount) then return nil, "Not enough Echo" end
    return beginChange(refugeData, -amount, operationId, operationType or "upgrade", reason)
end

function Echo.FinalizeReceipt(receipt)
    if not receipt or receipt.finalized then return false end
    receipt.finalized = true
    receipt.previousHistory = nil
    return true
end

function Echo.RollbackReceipt(receipt, persist)
    if not receipt or receipt.finalized then return false end
    receipt.finalized = true
    if receipt.noChange then return true end

    local state = ensureState(receipt.refugeData)
    if not state then return false end
    state.balance = receipt.previousBalance
    state.history = receipt.previousHistory or {}
    if persist and not Data.SaveRefugeData(receipt.refugeData) then
        LOG.error("Failed to persist Echo rollback for %s", tostring(receipt.refugeData.username))
        return false
    end
    return true
end

function Echo.Credit(refugeData, amount, operationId, operationType, reason)
    local receipt, errorMessage, existing = Echo.BeginCredit(
        refugeData, amount, operationId, operationType, reason
    )
    if not receipt then return false, errorMessage, existing end
    if not Data.SaveRefugeData(refugeData) then
        Echo.RollbackReceipt(receipt, false)
        return false, "Failed to persist Echo credit", nil
    end
    Echo.FinalizeReceipt(receipt)
    return true, nil, receipt.entry
end

function Echo.TrySpend(refugeData, amount, operationId, operationType, reason)
    local receipt, errorMessage, existing = Echo.BeginSpend(
        refugeData, amount, operationId, operationType, reason
    )
    if not receipt then return false, errorMessage, existing end
    if not Data.SaveRefugeData(refugeData) then
        Echo.RollbackReceipt(receipt, false)
        return false, "Failed to persist Echo spend", nil
    end
    Echo.FinalizeReceipt(receipt)
    return true, nil, receipt.entry
end

return MSR.Echo
