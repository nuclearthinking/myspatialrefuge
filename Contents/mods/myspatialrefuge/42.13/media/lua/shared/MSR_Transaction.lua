-- MSR_Transaction - Transaction Module
-- Provides transactional item consumption for client-server actions
-- 
-- Pattern:
-- 1. Client calls BeginTransaction() - locks items, returns transaction ID
-- 2. Client sends request to server with transaction ID
-- 3. Server validates and responds with success/failure
-- 4. Client calls CommitTransaction() on success (items consumed)
-- 5. Client calls RollbackTransaction() on failure (items unlocked)
--
-- Features:
-- - Items are "locked" during pending transaction (can't be used elsewhere)
-- - Auto-rollback on timeout (prevents permanently locked items)
-- - Transaction IDs prevent duplicate processing
-- - Works for any item type (cores, materials, etc.)

require "shared/MSR"
require "shared/MSR_PlayerMessage"

-- Prevent double-loading
if MSR.Transaction and MSR.Transaction._loaded then
    return MSR.Transaction
end

MSR.Transaction = MSR.Transaction or {}
MSR.Transaction._loaded = true

-- Local alias
local Transaction = MSR.Transaction

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

-- Auto-rollback timeout in ticks (5 seconds = 300 ticks at 60 ticks/sec)
local TRANSACTION_TIMEOUT_TICKS = 300

-- Transaction states
Transaction.STATE = {
    PENDING = "PENDING",
    COMMITTED = "COMMITTED",
    ROLLED_BACK = "ROLLED_BACK"
}

-- Debug logger (silent unless getDebug() is true)
local function logDebug(message)
    if getDebug and getDebug() then
        print("[Transaction] " .. tostring(message))
    end
end

-- Safely call a player method (guards against disconnected/null IsoPlayer references)
-- Returns the method result or nil if the call fails
local function safePlayerCall(player, methodName)
    if not player or not methodName then return nil end

    -- Resolve numeric player index to IsoPlayer if provided
    if type(player) == "number" and getSpecificPlayer then
        local resolved = getSpecificPlayer(player)
        if not resolved then return nil end
        player = resolved
    end

    -- Safely fetch the method to avoid indexing errors on unexpected types
    local okMethod, method = pcall(function() return player[methodName] end)
    if not okMethod or not method then return nil end

    local okCall, result = pcall(method, player)
    if not okCall then return nil end
    return result
end

-- Resolve a player reference to a live IsoPlayer object when possible
local function resolvePlayer(player)
    if not player then return nil end

    if type(player) == "number" and getSpecificPlayer then
        return getSpecificPlayer(player)
    end

    -- If we were passed an IsoPlayer, re-resolve by playerNum to avoid stale refs
    if (type(player) == "userdata" or type(player) == "table") and player.getPlayerNum and getSpecificPlayer then
        local ok, num = pcall(function() return player:getPlayerNum() end)
        if ok and num ~= nil then
            local resolved = getSpecificPlayer(num)
            if resolved then
                return resolved
            end
        end
    end

    return player
end

-----------------------------------------------------------
-- Transaction Storage
-- Uses weak keys so transactions are cleaned up when player disconnects
-----------------------------------------------------------

-- Active transactions per player: player -> { transactionType -> transaction }
local activeTransactions = setmetatable({}, {__mode = "k"})

-- Transaction counter for unique IDs
local transactionCounter = 0

-- Generate unique transaction ID
local function generateTransactionId(player, transactionType)
    transactionCounter = transactionCounter + 1
    local username = safePlayerCall(player, "getUsername") or "unknown"
    local timestamp = getTimestamp and getTimestamp() or 0
    return string.format("%s_%s_%d_%d", username, transactionType, timestamp, transactionCounter)
end

-----------------------------------------------------------
-- Item Locking
-- Locked items are stored in player ModData to survive reconnects
-----------------------------------------------------------

-- Get locked items storage for a player
local function getLockedItemsStorage(player)
    local resolvedPlayer = resolvePlayer(player)
    if not resolvedPlayer then return nil end
    local pmd = safePlayerCall(resolvedPlayer, "getModData")
    if not pmd then return nil end
    if not pmd._lockedTransactionItems then
        pmd._lockedTransactionItems = {}
    end
    return pmd._lockedTransactionItems
end

-- Lock items for a transaction (mark as unavailable)
-- Returns: table of locked item references, or nil if not enough items
-- NOTE: Uses all item sources (inventory + Sacred Relic container)
local function lockItems(player, itemType, count)
    if not player or not itemType or count <= 0 then return nil end
    player = resolvePlayer(player)
    if not player then return nil end
    
    -- Get locked items storage
    local lockedStorage = getLockedItemsStorage(player)
    if not lockedStorage then return nil end
    
    -- Build set of already locked item IDs for fast lookup
    local alreadyLockedIds = {}
    local alreadyLockedCount = 0
    if lockedStorage[itemType] then
        alreadyLockedCount = #lockedStorage[itemType]
        for _, itemId in ipairs(lockedStorage[itemType]) do
            alreadyLockedIds[itemId] = true
        end
    end
    
    -- Get all item sources (inventory + relic container)
    -- IMPORTANT: Bypass cache for transaction safety - always get fresh container reference
    local sources = {}
    local inv = safePlayerCall(player, "getInventory")
    if inv then
        table.insert(sources, inv)
    end
    
    -- Add Sacred Relic container if available (bypass cache for transaction safety)
    if MSR and MSR.GetRelicContainer then
        local relicContainer = MSR.GetRelicContainer(player, true)  -- bypassCache = true
        if relicContainer then
            table.insert(sources, relicContainer)
        end
    end
    
    if #sources == 0 then return nil end
    
    -- Count total available items across all sources
    local totalAvailable = 0
    for _, container in ipairs(sources) do
        if container and container.getCountType then
            totalAvailable = totalAvailable + container:getCountType(itemType)
        end
    end
    
    local availableCount = totalAvailable - alreadyLockedCount
    
    if availableCount < count then
        logDebug("lockItems: Not enough " .. itemType .. " (need " .. count .. ", available " .. availableCount .. ")")
        return nil -- Not enough unlocked items
    end
    
    -- Find and lock specific item instances from all sources
    local lockedItems = {}
    local lockedCount = 0
    
    for _, container in ipairs(sources) do
        if lockedCount >= count then break end
        if container and container.getItems then
            local items = container:getItems()
            if items then
                for i = 0, items:size() - 1 do
                    if lockedCount >= count then break end
                    
                    local item = items:get(i)
                    if item and item:getFullType() == itemType then
                        local itemId = item:getID()
                        if not alreadyLockedIds[itemId] then
                            table.insert(lockedItems, itemId)
                            alreadyLockedIds[itemId] = true  -- Prevent double-locking
                            lockedCount = lockedCount + 1
                        end
                    end
                end
            end
        end
    end
    
    if lockedCount < count then
        logDebug("lockItems: Could only find " .. lockedCount .. " of " .. count .. " items")
        return nil -- Couldn't find enough items (shouldn't happen if count was correct)
    end
    
    -- Store locked item IDs
    if not lockedStorage[itemType] then
        lockedStorage[itemType] = {}
    end
    for _, itemId in ipairs(lockedItems) do
        table.insert(lockedStorage[itemType], itemId)
    end
    
    logDebug("lockItems: Locked " .. lockedCount .. " of " .. itemType)
    return lockedItems
end

-- Unlock items from a transaction (make available again)
local function unlockItems(player, itemType, itemIds)
    if not player or not itemType or not itemIds then return end
    player = resolvePlayer(player)
    if not player then return end
    
    local lockedStorage = getLockedItemsStorage(player)
    if not lockedStorage or not lockedStorage[itemType] then return end
    
    -- Build set of IDs to unlock
    local unlockSet = {}
    for _, itemId in ipairs(itemIds) do
        unlockSet[itemId] = true
    end
    
    -- Remove from locked storage
    local newLocked = {}
    for _, itemId in ipairs(lockedStorage[itemType]) do
        if not unlockSet[itemId] then
            table.insert(newLocked, itemId)
        end
    end
    
    if #newLocked > 0 then
        lockedStorage[itemType] = newLocked
    else
        lockedStorage[itemType] = nil
    end
end

-- Consume locked items (actually remove from all sources)
-- NOTE: Uses all item sources (inventory + Sacred Relic container)
local function consumeLockedItems(player, itemType, itemIds)
    if not player or not itemType or not itemIds then return false end
    player = resolvePlayer(player)
    if not player then return false end
    
    -- Get all item sources (inventory + relic container)
    -- IMPORTANT: Bypass cache for transaction safety - always get fresh container reference
    local sources = {}
    local inv = safePlayerCall(player, "getInventory")
    if inv then
        table.insert(sources, inv)
    end
    
    -- Add Sacred Relic container if available (bypass cache for transaction safety)
    if MSR and MSR.GetRelicContainer then
        local relicContainer = MSR.GetRelicContainer(player, true)  -- bypassCache = true
        if relicContainer then
            table.insert(sources, relicContainer)
        end
    end
    
    if #sources == 0 then return false end
    
    -- Build set of IDs to consume
    local consumeSet = {}
    for _, itemId in ipairs(itemIds) do
        consumeSet[itemId] = true
    end
    
    -- Find and remove items by ID from all sources
    local totalRemoved = 0
    
    for _, container in ipairs(sources) do
        if container and container.getItems then
            local items = container:getItems()
            if items then
                local toRemove = {}
                
                for i = 0, items:size() - 1 do
                    local item = items:get(i)
                    if item and item:getFullType() == itemType then
                        if consumeSet[item:getID()] then
                            table.insert(toRemove, item)
                            consumeSet[item:getID()] = nil  -- Mark as found
                        end
                    end
                end
                
                -- Remove items from this container
                for _, item in ipairs(toRemove) do
                    container:Remove(item)
                    totalRemoved = totalRemoved + 1
                end
            end
        end
    end
    
    -- Clear from locked storage
    unlockItems(player, itemType, itemIds)
    
    logDebug("consumeLockedItems: Removed " .. totalRemoved .. " of " .. #itemIds .. " " .. itemType)
    return totalRemoved == #itemIds
end

-----------------------------------------------------------
-- Public API
-----------------------------------------------------------

-- Begin a new transaction
-- @param player: The player starting the transaction
-- @param transactionType: String identifier (e.g., "UPGRADE", "CRAFT")
-- @param itemRequirements: Table of {itemType = count} pairs
-- @return: transaction object on success, nil on failure
-- @return: error message if failed
function Transaction.Begin(player, transactionType, itemRequirements)
    -- Validate player
    local playerObj = resolvePlayer(player)
    if not playerObj then return nil, "Invalid player" end
    
    local username = safePlayerCall(playerObj, "getUsername")
    if not username then return nil, "Player not connected" end
    
    -- Validate inputs
    if not transactionType then return nil, "Invalid transaction type" end
    if not itemRequirements or type(itemRequirements) ~= "table" then
        return nil, "No items specified"
    end
    
    -- Check if table has any items (Kahlua doesn't have next())
    local hasItems = false
    for _ in pairs(itemRequirements) do
        hasItems = true
        break
    end
    if not hasItems then return nil, "No items specified" end
    
    -- Check for existing transaction
    local existing = Transaction.GetPending(playerObj, transactionType)
    if existing then return nil, "Transaction already in progress" end
    
    -- Lock items
    local lockedItems = {}
    for itemType, count in pairs(itemRequirements) do
        local locked = lockItems(playerObj, itemType, count)
        if not locked then
            -- Rollback partial locks
            for lockedType, data in pairs(lockedItems) do
                unlockItems(playerObj, lockedType, data.itemIds)
            end
            return nil, "Not enough " .. itemType
        end
        lockedItems[itemType] = { count = count, itemIds = locked }
    end
    
    -- Create transaction
    local transactionId = generateTransactionId(playerObj, transactionType)
    local transaction = {
        id = transactionId,
        type = transactionType,
        lockedItems = lockedItems,
        createdAt = getTimestamp and getTimestamp() or 0,
        status = Transaction.STATE.PENDING
    }
    
    -- Store transaction
    if not activeTransactions[playerObj] then
        activeTransactions[playerObj] = {}
    end
    activeTransactions[playerObj][transactionType] = transaction
    
    -- Start timeout handler
    Transaction._startTimeoutHandler(playerObj, transactionType, transactionId)
    
    logDebug("BEGIN " .. transactionId .. " for " .. username)
    
    return transaction, nil
end

-- Commit a transaction (consume the locked items)
-- @param player: The player
-- @param transactionId: The transaction ID to commit
-- @return: true on success, false on failure
function Transaction.Commit(player, transactionId)
    local playerObj = resolvePlayer(player)
    if not playerObj or not transactionId then return false end
    
    -- Find the transaction
    local playerTransactions = activeTransactions[playerObj]
    if not playerTransactions then return false end
    
    local transaction = nil
    local transactionType = nil
    
    for tType, t in pairs(playerTransactions) do
        if t.id == transactionId then
            transaction = t
            transactionType = tType
            break
        end
    end
    
    if not transaction then
        logDebug("COMMIT failed - transaction not found: " .. tostring(transactionId))
        return false
    end
    
    if transaction.status ~= Transaction.STATE.PENDING then
        logDebug("COMMIT failed - transaction not pending: " .. tostring(transactionId) .. " (status=" .. tostring(transaction.status) .. ")")
        return false
    end
    
    -- Consume all locked items
    local allConsumed = true
    for itemType, data in pairs(transaction.lockedItems) do
        if not consumeLockedItems(playerObj, itemType, data.itemIds) then
            allConsumed = false
            -- Note: This shouldn't happen in normal operation
            -- Items might have been somehow removed externally
        end
    end
    
    -- Update transaction status
    transaction.status = Transaction.STATE.COMMITTED
    
    -- Remove from active transactions
    playerTransactions[transactionType] = nil
    
    logDebug("COMMIT " .. transactionId .. " - Items consumed: " .. tostring(allConsumed))
    
    return allConsumed
end

-- Rollback a transaction (unlock the items)
-- @param player: The player
-- @param transactionId: The transaction ID to rollback (optional - can use transactionType)
-- @param transactionType: The transaction type (used if transactionId is nil)
-- @return: true on success, false on failure
function Transaction.Rollback(player, transactionId, transactionType)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false end
    
    local playerTransactions = activeTransactions[playerObj]
    if not playerTransactions then return false end
    
    local transaction = nil
    local tType = nil
    
    -- Find by ID first, then by type
    if transactionId then
        for t, trans in pairs(playerTransactions) do
            if trans.id == transactionId then
                transaction = trans
                tType = t
                break
            end
        end
    elseif transactionType then
        transaction = playerTransactions[transactionType]
        tType = transactionType
    end
    
    if not transaction then
        logDebug("ROLLBACK - no transaction found (id=" .. tostring(transactionId) .. ", type=" .. tostring(transactionType) .. ")")
        return false
    end
    
    if transaction.status ~= Transaction.STATE.PENDING then
        logDebug("ROLLBACK - transaction not pending: " .. transaction.id .. " (status=" .. tostring(transaction.status) .. ")")
        return false
    end
    
    -- Unlock all items
    for itemType, data in pairs(transaction.lockedItems) do
        unlockItems(playerObj, itemType, data.itemIds)
    end
    
    -- Update transaction status
    transaction.status = Transaction.STATE.ROLLED_BACK
    
    -- Remove from active transactions
    if tType then
        playerTransactions[tType] = nil
    end
    
    logDebug("ROLLBACK " .. transaction.id .. " - Items unlocked")
    
    return true
end

-- Get a pending transaction for a player
-- @param player: The player
-- @param transactionType: The transaction type to look for
-- @return: transaction object or nil
function Transaction.GetPending(player, transactionType)
    local playerObj = resolvePlayer(player)
    if not playerObj or not transactionType then return nil end
    
    local playerTransactions = activeTransactions[playerObj]
    if not playerTransactions then return nil end
    
    local transaction = playerTransactions[transactionType]
    if transaction and transaction.status == Transaction.STATE.PENDING then
        return transaction
    end
    
    return nil
end

-- Check how many of an item type are currently available (not locked)
-- @param player: The player
-- @param itemType: The item type to check
-- @return: count of available items
function Transaction.GetAvailableCount(player, itemType)
    local playerObj = resolvePlayer(player)
    if not playerObj or not itemType then return 0 end
    
    local inv = safePlayerCall(playerObj, "getInventory")
    if not inv then return 0 end
    
    local totalCount = inv:getCountType(itemType)
    
    local lockedStorage = getLockedItemsStorage(playerObj)
    local lockedCount = 0
    if lockedStorage and lockedStorage[itemType] then
        lockedCount = #lockedStorage[itemType]
    end
    
    return math.max(0, totalCount - lockedCount)
end

-----------------------------------------------------------
-- Timeout Handler
-- Auto-rollback transactions that don't complete in time
-----------------------------------------------------------

function Transaction._startTimeoutHandler(player, transactionType, transactionId)
    local tickCount = 0
    local playerRef = player
    local typeRef = transactionType
    local idRef = transactionId
    
    local function checkTimeout()
        tickCount = tickCount + 1
        
        -- Check if transaction still exists and is pending
        local transaction = Transaction.GetPending(playerRef, typeRef)
        
        if not transaction or transaction.id ~= idRef then
            -- Transaction was committed or rolled back elsewhere
            Events.OnTick.Remove(checkTimeout)
            return
        end
        
        -- Check timeout
        if tickCount >= TRANSACTION_TIMEOUT_TICKS then
            Events.OnTick.Remove(checkTimeout)
            
            logDebug("TIMEOUT - Auto-rollback: " .. idRef)
            
            -- Auto-rollback
            Transaction.Rollback(playerRef, idRef)
            
            -- Notify player
            if playerRef then
                local PM = MSR.PlayerMessage
                PM.Say(playerRef, PM.ACTION_TIMEOUT_ITEMS_UNLOCKED)
            end
        end
    end
    
    Events.OnTick.Add(checkTimeout)
end

-----------------------------------------------------------
-- Cleanup on player disconnect/death
-----------------------------------------------------------

local function OnPlayerDisconnect(player)
    local playerObj = resolvePlayer(player)
    if not playerObj then return end
    
    -- Rollback any pending transactions
    local playerTransactions = activeTransactions[playerObj]
    if playerTransactions then
        for transactionType, transaction in pairs(playerTransactions) do
            if transaction.status == Transaction.STATE.PENDING then
                Transaction.Rollback(playerObj, transaction.id)
            end
        end
    end
    
    -- Clear transaction storage
    activeTransactions[playerObj] = nil
    
    -- Clear locked items storage
    local pmd = safePlayerCall(playerObj, "getModData")
    if pmd then
        pmd._lockedTransactionItems = nil
    end
    logDebug("Disconnect cleanup for player " .. (safePlayerCall(playerObj, "getUsername") or "unknown"))
end

-- Register cleanup handlers
if Events.OnPlayerDeath then
    Events.OnPlayerDeath.Add(OnPlayerDisconnect)
end

-----------------------------------------------------------
-- Multi-Source Item Support (for Upgrade System)
-- Extends transaction to work with multiple item containers
-----------------------------------------------------------

-- Get all item sources for a player (inventory + Sacred Relic storage)
-- @param player: The player
-- @param bypassCache: (optional) If true, bypass container cache (for transactions)
-- @return: Array of ItemContainer objects
function Transaction.GetItemSources(player, bypassCache)
    local playerObj = resolvePlayer(player)
    if not playerObj then return {} end
    
    local sources = {}
    
    -- Player inventory
    local inv = safePlayerCall(playerObj, "getInventory")
    if inv then
        table.insert(sources, inv)
    end
    
    -- Sacred Relic storage (if player is in refuge and has access)
    -- This requires SpatialRefuge module to be loaded
    if MSR and MSR.GetRelicContainer then
        local relicContainer = MSR.GetRelicContainer(playerObj, bypassCache)
        if relicContainer then
            table.insert(sources, relicContainer)
        end
    end
    
    return sources
end

-- Count items across all sources
-- @param player: The player
-- @param itemType: The item type to count
-- @return: Total count across all sources
function Transaction.GetMultiSourceCount(player, itemType)
    local playerObj = resolvePlayer(player)
    if not playerObj or not itemType then return 0 end
    
    local sources = Transaction.GetItemSources(playerObj)
    local totalCount = 0
    
    for _, container in ipairs(sources) do
        if container and container.getCountType then
            totalCount = totalCount + container:getCountType(itemType)
        end
    end
    
    -- Subtract locked items
    local lockedStorage = getLockedItemsStorage(playerObj)
    local lockedCount = 0
    if lockedStorage and lockedStorage[itemType] then
        lockedCount = #lockedStorage[itemType]
    end
    
    return math.max(0, totalCount - lockedCount)
end

-- Count items with substitutions across all sources
-- @param player: The player
-- @param requirement: Requirement table with type and substitutes
-- @return: Total count of matching items, table of {itemType = count}
function Transaction.GetSubstitutionCount(player, requirement)
    local playerObj = resolvePlayer(player)
    if not playerObj or not requirement then return 0, {} end
    
    local counts = {}
    local total = 0
    
    -- Primary type
    local primaryCount = Transaction.GetMultiSourceCount(playerObj, requirement.type)
    if primaryCount > 0 then
        counts[requirement.type] = primaryCount
        total = total + primaryCount
    end
    
    -- Substitutes
    if requirement.substitutes then
        for _, subType in ipairs(requirement.substitutes) do
            local subCount = Transaction.GetMultiSourceCount(playerObj, subType)
            if subCount > 0 then
                counts[subType] = subCount
                total = total + subCount
            end
        end
    end
    
    return total, counts
end

-- Resolve substitutions to specific item types that will be consumed
-- @param player: The player
-- @param requirements: Array of requirement tables
-- @return: Table of {itemType = count} for transaction, or nil if not enough items
function Transaction.ResolveSubstitutions(player, requirements)
    local playerObj = resolvePlayer(player)
    if not playerObj or not requirements then return nil end
    
    -- First pass: gather all unique item types and their initial available counts
    -- This ensures we don't double-count items when multiple requirements share types
    local initialCounts = {}
    
    for _, req in ipairs(requirements) do
        -- Track primary type
        if req.type and not initialCounts[req.type] then
            initialCounts[req.type] = Transaction.GetMultiSourceCount(playerObj, req.type)
        end
        -- Track substitutes
        if req.substitutes then
            for _, subType in ipairs(req.substitutes) do
                if not initialCounts[subType] then
                    initialCounts[subType] = Transaction.GetMultiSourceCount(playerObj, subType)
                end
            end
        end
    end
    
    -- Second pass: allocate items to requirements, tracking what's been resolved
    local resolved = {}
    
    for _, req in ipairs(requirements) do
        local needed = req.count or 1
        local remaining = needed
        
        -- Try primary type first
        -- Calculate available count: initial count minus what's already been resolved
        -- This ensures we don't over-count when this type was used as a substitute earlier
        if initialCounts[req.type] then
            local alreadyResolved = resolved[req.type] or 0
            local actuallyAvailable = initialCounts[req.type] - alreadyResolved
            if actuallyAvailable > 0 then
                local toUse = math.min(remaining, actuallyAvailable)
                resolved[req.type] = alreadyResolved + toUse
                remaining = remaining - toUse
            end
        end
        
        -- Try substitutes if needed
        -- Calculate available count: initial count minus what's already been resolved
        -- This ensures we don't over-count when this substitute was used as a primary type earlier
        if remaining > 0 and req.substitutes then
            for _, subType in ipairs(req.substitutes) do
                if initialCounts[subType] then
                    local alreadyResolved = resolved[subType] or 0
                    local actuallyAvailable = initialCounts[subType] - alreadyResolved
                    if actuallyAvailable > 0 then
                        local toUse = math.min(remaining, actuallyAvailable)
                        if toUse > 0 then
                            resolved[subType] = alreadyResolved + toUse
                            remaining = remaining - toUse
                        end
                    end
                end
                if remaining <= 0 then break end
            end
        end
        
        -- Check if we have enough
        if remaining > 0 then
            local itemName = req.type:match("%.(.+)$") or req.type
            return nil, "Not enough " .. itemName
        end
    end
    
    return resolved
end

-- Begin a transaction with substitution support
-- @param player: The player
-- @param transactionType: Transaction type string
-- @param requirements: Array of requirement tables (with type, count, substitutes)
-- @return: transaction object on success, nil on failure
-- @return: error message if failed
function Transaction.BeginWithSubstitutions(player, transactionType, requirements)
    -- Resolve substitutions first
    local resolved, err = Transaction.ResolveSubstitutions(player, requirements)
    if not resolved then
        return nil, err
    end
    
    -- Use standard Begin with resolved items
    return MSR.Transaction.Begin(player, transactionType, resolved)
end

return MSR.Transaction


