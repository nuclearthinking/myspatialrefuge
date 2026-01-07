-- MSR_Inventory - Inventory and Container Utilities
-- Provides helpers for working with player inventory, containers, and items
--
-- USAGE: After this module loads, use `MSR.Inventory` anywhere:
--   MSR.Inventory.collectNestedContainers(inv)  - Get all nested containers
--   MSR.Inventory.getPlayerContainers(player)   - Get player's containers

require "shared/core/MSR"

if MSR.Inventory and MSR.Inventory._loaded then
    return MSR.Inventory
end

MSR.Inventory = {}
MSR.Inventory._loaded = true

local Inventory = MSR.Inventory

-----------------------------------------------------------
-- Container Collection
-----------------------------------------------------------

--- Collect all nested container inventories (bags inside bags, etc.)
--- @param rootContainer ItemContainer The root container to start from
--- @param maxDepth number? Maximum recursion depth (default 3, prevents infinite loops)
--- @return ItemContainer[] Array of all containers including the root
function Inventory.collectNestedContainers(rootContainer, maxDepth)
    if not rootContainer then return {} end
    
    maxDepth = maxDepth or 3
    local allContainers = {rootContainer}
    local currentLevel = {rootContainer}
    local depth = 0
    
    while #currentLevel > 0 and depth < maxDepth do
        local nextLevel = {}
        for _, container in ipairs(currentLevel) do
            if container and container.getItemsFromCategory then
                local containerItems = container:getItemsFromCategory("Container")
                if containerItems and containerItems:size() > 0 then
                    for j = 0, containerItems:size() - 1 do
                        local containerItem = containerItems:get(j)
                        local nestedInv = containerItem:getInventory()
                        if nestedInv then
                            table.insert(allContainers, nestedInv)
                            table.insert(nextLevel, nestedInv)
                        end
                    end
                end
            end
        end
        currentLevel = nextLevel
        depth = depth + 1
    end
    
    return allContainers
end

--- Get all item sources for a player (inventory + nested containers)
--- Does NOT include mod-specific containers like Sacred Relic
--- @param player IsoPlayer The player
--- @param includeNested boolean? Whether to include nested containers (default true)
--- @return ItemContainer[] Array of containers
function Inventory.getPlayerContainers(player, includeNested)
    if includeNested == nil then includeNested = true end
    
    local inv = MSR.safePlayerCall(player, "getInventory")
    if not inv then return {} end
    
    if includeNested then
        return Inventory.collectNestedContainers(inv)
    else
        return {inv}
    end
end

--- Count items of a type across multiple containers
--- @param containers ItemContainer[] Array of containers to search
--- @param itemType string Full item type (e.g., "Base.MagicalCore")
--- @return number Total count
function Inventory.countItemType(containers, itemType)
    local total = 0
    for _, container in ipairs(containers) do
        if container and container.getCountType then
            total = total + container:getCountType(itemType)
        end
    end
    return total
end

--- Find item by ID across containers (getItemById searches recursively)
--- @param containers ItemContainer[] Array of containers to search
--- @param itemId number Item ID to find
--- @return InventoryItem|nil, ItemContainer|nil The item and its actual container
function Inventory.findItemById(containers, itemId)
    for _, container in ipairs(containers) do
        if container and container.getItemById then
            local item = container:getItemById(itemId)
            if item then
                local actualContainer = item:getContainer() -- May differ from search container
                return item, actualContainer
            end
        end
    end
    return nil, nil
end

return MSR.Inventory
