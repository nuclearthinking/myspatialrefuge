-- Shared primitives for authoritative inventory mutations.
-- Callers keep ownership of selection policy (requirements, substitutions,
-- protected items); this module only validates and applies chosen mutations.

require "00_core/00_MSR"

local InventoryAuthority = MSR.register("InventoryAuthority")
if not InventoryAuthority then
    return MSR.InventoryAuthority
end

local needsClientSync = MSR.Env.needsClientSync
local hasServerAuthority = MSR.Env.hasServerAuthority
local syncRemoveItem = sendRemoveItemFromContainer
local syncAddItem = sendAddItemToContainer
local LOG = L.logger("InventoryAuthority")

local function canMutate()
    return hasServerAuthority()
end

--- Find one item through a list of root or direct containers.
--- ItemContainer:getItemWithIDRecursiv searches nested containers in Java.
--- @param sources ItemContainer[]
--- @param itemId integer
--- @param expectedType string?
--- @param isAvailable function?
--- @return InventoryItem|nil, ItemContainer|nil
function InventoryAuthority.findItemById(sources, itemId, expectedType, isAvailable)
    if not sources then return nil, nil end

    for index = 1, #sources do
        local rootContainer = sources[index]
        local item = rootContainer and rootContainer:getItemWithIDRecursiv(itemId) or nil
        if item then
            local actualContainer = item:getContainer()
            if actualContainer
                and actualContainer:contains(item)
                and (not expectedType or item:getFullType() == expectedType)
                and (not isAvailable or isAvailable(item, actualContainer))
            then
                return item, actualContainer
            end
        end
    end

    return nil, nil
end

--- Validate only the IDs supplied by the caller. Recipe validation is handled
--- separately by the authoritative upgrade coordinator.
--- @param sources ItemContainer[]
--- @param allocation table<string, integer[]>
--- @param isAvailable function?
--- @return boolean
function InventoryAuthority.validateAllocation(sources, allocation, isAvailable)
    if not sources or type(allocation) ~= "table" then return false end

    for itemType, itemIds in pairs(allocation) do
        if type(itemType) ~= "string" or type(itemIds) ~= "table" then return false end
        for index = 1, #itemIds do
            local itemId = itemIds[index]
            if type(itemId) ~= "number" or itemId ~= math.floor(itemId) then return false end
            local item = InventoryAuthority.findItemById(sources, itemId, itemType, isAvailable)
            if not item then return false end
        end
    end

    return true
end

--- Remove one existing item and synchronize the mutation when running in an MP
--- server process.
--- @param container ItemContainer
--- @param item InventoryItem
--- @return boolean
function InventoryAuthority.removeItem(container, item)
    if not canMutate() or not container or not item or not container:contains(item) then
        return false
    end

    container:DoRemoveItem(item)
    if container:contains(item) then return false end

    if needsClientSync() and syncRemoveItem then
        syncRemoveItem(container, item)
    end
    return true
end

--- Add an item object or full item type and synchronize it on an MP server.
--- @param container ItemContainer
--- @param itemOrType InventoryItem|string
--- @return InventoryItem|nil
function InventoryAuthority.addItem(container, itemOrType)
    if not canMutate() or not container or not itemOrType then return nil end

    local added = container:AddItem(itemOrType)
    if added and needsClientSync() and syncAddItem then
        syncAddItem(container, added)
    end
    return added
end

--- Move an existing item between containers as one authoritative operation.
--- @param player IsoPlayer
--- @param sourceContainer ItemContainer
--- @param destinationContainer ItemContainer
--- @param item InventoryItem
--- @return boolean
function InventoryAuthority.moveItem(player, sourceContainer, destinationContainer, item)
    if not canMutate() or not sourceContainer or not destinationContainer or not item then
        return false
    end
    if sourceContainer == destinationContainer then return sourceContainer:contains(item) end
    if not sourceContainer:contains(item) then return false end
    if not destinationContainer:hasRoomFor(player, item) then return false end

    sourceContainer:DoRemoveItem(item)
    local added = destinationContainer:AddItem(item)
    if not added then
        sourceContainer:AddItem(item)
        return false
    end

    if needsClientSync() then
        if syncRemoveItem then syncRemoveItem(sourceContainer, item) end
        if syncAddItem then syncAddItem(destinationContainer, item) end
    end
    return true
end

--- Consume a caller-selected allocation of item IDs.
--- @param sources ItemContainer[]
--- @param allocation table<string, integer[]>
--- @param isAvailable function?
--- @return boolean, number, number
function InventoryAuthority.consumeByIds(sources, allocation, isAvailable)
    if not canMutate() or not sources or not allocation then return false, 0, 0 end

    local consumed = 0
    local expected = 0
    for itemType, itemIds in pairs(allocation) do
        expected = expected + #itemIds
        for index = 1, #itemIds do
            local item, container = InventoryAuthority.findItemById(
                sources,
                itemIds[index],
                itemType,
                isAvailable
            )
            if item and InventoryAuthority.removeItem(container, item) then
                consumed = consumed + 1
            end
        end
    end

    return consumed == expected, consumed, expected
end

--- Atomically consume an exact allocation and retain the removed item objects
--- until the caller commits its authoritative state.
--- @param player IsoPlayer
--- @param sources ItemContainer[]
--- @param allocation table<string, integer[]>
--- @param isAvailable function?
--- @return table|nil receipt
--- @return string|nil errorMessage
function InventoryAuthority.consumeWithReceipt(player, sources, allocation, isAvailable)
    if not canMutate() or not player or not sources or not allocation then
        return nil, "Invalid inventory transaction"
    end

    local resolved = {}
    local seenIds = {}
    for itemType, itemIds in pairs(allocation) do
        for index = 1, #itemIds do
            local itemId = itemIds[index]
            if seenIds[itemId] then return nil, "Duplicate item ID in allocation" end
            local lookupOk, item, container = pcall(
                InventoryAuthority.findItemById,
                sources,
                itemId,
                itemType,
                isAvailable
            )
            if not lookupOk then return nil, "Failed to resolve required item" end
            if not item or not container then return nil, "Required item is unavailable" end
            seenIds[itemId] = true
            table.insert(resolved, { item = item, container = container, itemType = itemType })
        end
    end

    local receipt = { entries = {}, finalized = false }
    for _, entry in ipairs(resolved) do
        local removeOk, removed = pcall(InventoryAuthority.removeItem, entry.container, entry.item)
        if not removeOk or not removed then
            local containsOk, stillContained = pcall(entry.container.contains, entry.container, entry.item)
            if not containsOk or not stillContained then
                -- Removal may have succeeded before a network-sync exception.
                table.insert(receipt.entries, entry)
            end
            InventoryAuthority.refundReceipt(player, receipt)
            return nil, "Failed to consume all required items"
        end
        table.insert(receipt.entries, entry)
    end

    return receipt, nil
end

--- Restore every exact item retained by a receipt.
--- @param player IsoPlayer
--- @param receipt table
--- @return boolean
function InventoryAuthority.refundReceipt(player, receipt)
    if not receipt or receipt.finalized then return false end
    local restoredAll = true
    local fallbackInventory = player and player.getInventory and player:getInventory() or nil
    local playerSquare = player and player.getSquare and player:getSquare() or nil

    for index = #receipt.entries, 1, -1 do
        local entry = receipt.entries[index]
        local restored = nil
        if entry.container then
            local ok, result = pcall(InventoryAuthority.addItem, entry.container, entry.item)
            restored = ok and result or nil
        end
        if not restored and fallbackInventory and fallbackInventory ~= entry.container then
            local ok, result = pcall(InventoryAuthority.addItem, fallbackInventory, entry.item)
            restored = ok and result or nil
        end
        if not restored and playerSquare and playerSquare.AddWorldInventoryItem then
            local ok, result = pcall(
                playerSquare.AddWorldInventoryItem,
                playerSquare,
                entry.item,
                0.5,
                0.5,
                0,
                true
            )
            restored = ok and result or nil
        end
        if not restored then
            restoredAll = false
            LOG.error("Failed to refund consumed item %s", tostring(entry.itemType))
        end
    end

    receipt.finalized = true
    return restoredAll
end

function InventoryAuthority.finalizeReceipt(receipt)
    if not receipt or receipt.finalized then return false end
    receipt.finalized = true
    receipt.entries = {}
    return true
end

--- Consume resolved type/count requirements from direct containers.
--- @param sources ItemContainer[]
--- @param requiredByType table<string, number>
--- @param isAvailable function?
--- @return boolean, number
function InventoryAuthority.consumeByType(sources, requiredByType, isAvailable)
    if not canMutate() or not sources or not requiredByType then return false, 0 end

    local totalConsumed = 0
    for itemType, requiredCount in pairs(requiredByType) do
        local remaining = tonumber(requiredCount) or 0
        for sourceIndex = 1, #sources do
            if remaining <= 0 then break end

            local container = sources[sourceIndex]
            local items = container and container:getItems() or nil
            local itemCount = items and items:size() or 0
            for itemIndex = itemCount - 1, 0, -1 do
                if remaining <= 0 then break end

                local item = items:get(itemIndex)
                if item
                    and item:getFullType() == itemType
                    and (not isAvailable or isAvailable(item, container))
                    and InventoryAuthority.removeItem(container, item)
                then
                    remaining = remaining - 1
                    totalConsumed = totalConsumed + 1
                end
            end
        end

        if remaining > 0 then return false, totalConsumed end
    end

    return true, totalConsumed
end

return InventoryAuthority
