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

--- Validate only the IDs supplied by the caller. This intentionally does not
--- compare the allocation against a recipe; the mod does not implement an
--- anti-cheat policy for modified clients.
--- @param sources ItemContainer[]
--- @param allocation table<string, integer[]>
--- @param isAvailable function?
--- @return boolean
function InventoryAuthority.validateAllocation(sources, allocation, isAvailable)
    if not sources or not allocation then return false end

    for itemType, itemIds in pairs(allocation) do
        for index = 1, #itemIds do
            local item = InventoryAuthority.findItemById(sources, itemIds[index], itemType, isAvailable)
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
