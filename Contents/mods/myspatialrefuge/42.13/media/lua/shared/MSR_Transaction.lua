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

require "shared/core/MSR"
require "shared/core/MSR_Env"
require "shared/core/MSR_04_Inventory"
require "shared/MSR_Config"
require "shared/MSR_PlayerMessage"

if MSR.Transaction and MSR.Transaction._loaded then
    return MSR.Transaction
end

MSR.Transaction = MSR.Transaction or {}
MSR.Transaction._loaded = true

local Transaction = MSR.Transaction

Transaction.STATE = {
    PENDING = "PENDING",
    COMMITTED = "COMMITTED",      -- SP: items consumed locally
    FINALIZED = "FINALIZED",      -- MP: server consumed items, local locks cleared
    ROLLED_BACK = "ROLLED_BACK"   -- Failed: items unlocked, not consumed
}



-- Use shared utilities from MSR namespace
local function resolvePlayer(player)
    return MSR.resolvePlayer(player)
end

local function safePlayerCall(player, methodName)
    return MSR.safePlayerCall(player, methodName)
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
    local timestamp = K.time()
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

-- Get all item sources for a player (inventory + nested containers + Sacred Relic storage)
local function getItemSources(player, bypassCache)
    local inv = safePlayerCall(player, "getInventory")
    local sources = inv and MSR.Inventory.collectNestedContainers(inv) or {}
    
    -- Sacred Relic container (separate storage)
    local getRelicContainer = (MSR and MSR.GetRelicContainer) or (MSR_Server and MSR_Server.GetRelicContainer)
    if getRelicContainer then
        local rc = getRelicContainer(player, bypassCache)
        if rc then
            table.insert(sources, rc)
        end
    end
    return sources
end

-----------------------------------------------------------
-- Item Availability Checks
-- Based on ISInventoryTransferAction.lua patterns
-----------------------------------------------------------

-- Check if item can be locked for consumption
local function isItemAvailableForLock(item, container)
    if not item then return false, "nil item" end
    
    if item.getIsCraftingConsumed and item:getIsCraftingConsumed() then
        return false, "crafting consumed"
    end
    
    if item.isFavorite and item:isFavorite() then
        return false, "favorite"
    end
    
    if container and container.isRemoveItemAllowed then
        if not container:isRemoveItemAllowed(item) then
            return false, "removal not allowed"
        end
    end
    
    return true, nil
end

-- Public API: Used by UI to filter available items
function Transaction.IsItemAvailable(item, container)
    return isItemAvailableForLock(item, container)
end


-- Lock items for a transaction. Returns locked item IDs or nil if not enough.
local function lockItems(player, itemType, count)
    if not player or not itemType or count <= 0 then return nil end
    player = resolvePlayer(player)
    if not player then return nil end
    
    local lockedStorage = getLockedItemsStorage(player)
    if not lockedStorage then return nil end
    
    local alreadyLockedIds = {}
    local alreadyLockedCount = 0
    if lockedStorage[itemType] then
        alreadyLockedCount = #lockedStorage[itemType]
        for _, itemId in ipairs(lockedStorage[itemType]) do
            alreadyLockedIds[itemId] = true
        end
    end
    
    local sources = getItemSources(player, true)  -- bypass cache
    if #sources == 0 then return nil end
    
    local totalAvailable = 0
    for _, container in ipairs(sources) do
        if container and container.getCountType then
            totalAvailable = totalAvailable + container:getCountType(itemType)
        end
    end
    
    local availableCount = totalAvailable - alreadyLockedCount
    
    if availableCount < count then
        L.debug("Transaction", "lockItems: Not enough " .. itemType .. " (need " .. count .. ", available " .. availableCount .. ")")
        return nil
    end
    
    local lockedItems = {}
    local lockedCount = 0
    
    for _, container in ipairs(sources) do
        if lockedCount >= count then break end
        local items = container and container.getItems and container:getItems()
        if K.isIterable(items) then
            for _, item in K.iter(items) do
                if lockedCount >= count then break end
                if item and item:getFullType() == itemType then
                    local itemId = item:getID()
                    if not alreadyLockedIds[itemId] then
                        local available = isItemAvailableForLock(item, container)
                        if available then
                            table.insert(lockedItems, itemId)
                            alreadyLockedIds[itemId] = true
                            lockedCount = lockedCount + 1
                        end
                    end
                end
            end
        end
    end
    
    if lockedCount < count then
        L.debug("Transaction", "lockItems: Could only find " .. lockedCount .. " of " .. count .. " items (some may be unavailable)")
        return nil -- Couldn't find enough available items
    end
    
    -- Store locked item IDs
    if not lockedStorage[itemType] then
        lockedStorage[itemType] = {}
    end
    for _, itemId in ipairs(lockedItems) do
        table.insert(lockedStorage[itemType], itemId)
    end
    
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

local function consumeLockedItems(player, itemType, itemIds)
    if not player or not itemType or not itemIds then return false end
    player = resolvePlayer(player)
    if not player then return false end
    
    local sources = getItemSources(player, true)
    if #sources == 0 then return false end
    
    local consumeSet = {}
    for _, itemId in ipairs(itemIds) do consumeSet[itemId] = true end
    
    local needsSync = MSR.Env.needsClientSync() and sendRemoveItemFromContainer
    local totalRemoved = 0
    
    for _, container in ipairs(sources) do
        local items = container and container.getItems and container:getItems()
        if K.isIterable(items) then
            local toRemove = {}
            for _, item in K.iter(items) do
                if item and item:getFullType() == itemType and consumeSet[item:getID()] then
                    table.insert(toRemove, item)
                    consumeSet[item:getID()] = nil
                end
            end
            for _, item in ipairs(toRemove) do
                container:Remove(item)
                if needsSync then sendRemoveItemFromContainer(container, item) end
                totalRemoved = totalRemoved + 1
            end
        end
    end
    
    unlockItems(player, itemType, itemIds)
    local success = totalRemoved == #itemIds
    if not success then
        L.debug("Transaction", "consumeLockedItems: Partial removal - " .. totalRemoved .. "/" .. #itemIds .. " " .. itemType)
    end
    return success
end

-----------------------------------------------------------
-- Public API
-----------------------------------------------------------

-- Begin a new transaction
-- Begin a transaction with optional substitution support
-- @param player: The player starting the transaction
-- @param transactionType: String identifier (e.g., "UPGRADE", "CRAFT")
-- @param itemRequirements: Either:
--   - Hash table: {itemType = count} for simple requirements
--   - Array: {{type="...", count=N, substitutes={...}}, ...} for substitution support
-- @return: transaction object on success, nil on failure
-- @return: error message if failed
function Transaction.Begin(player, transactionType, itemRequirements)
    -- Fail-fast validation
    if not player then error("Transaction.Begin: player is required") end
    if not transactionType then error("Transaction.Begin: transactionType is required") end
    if not itemRequirements then error("Transaction.Begin: itemRequirements is required") end
    if type(itemRequirements) ~= "table" then error("Transaction.Begin: itemRequirements must be a table") end
    
    -- Runtime validation (returns error, not exception)
    local playerObj = resolvePlayer(player)
    if not playerObj then return nil, "Invalid player" end
    
    local username = safePlayerCall(playerObj, "getUsername")
    if not username then return nil, "Player not connected" end
    
    -- Detect format: array of {type, count, substitutes} vs hash {itemType = count}
    -- If first key is numeric, it's an array format with potential substitutes
    local resolvedRequirements = itemRequirements
    if K.isArrayLike(itemRequirements) then
        -- Array format - resolve substitutions
        local resolved, err = Transaction.ResolveSubstitutions(playerObj, itemRequirements)
        if not resolved then
            return nil, err
        end
        resolvedRequirements = resolved
    end
    
    if K.isEmpty(resolvedRequirements) then return nil, "No items specified" end
    
    -- Check for existing transaction
    local existing = Transaction.GetPending(playerObj, transactionType)
    if existing then return nil, "Transaction already in progress" end
    
    -- Lock items
    local lockedItems = {}
    for itemType, count in pairs(resolvedRequirements) do
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
        createdAt = K.time(),
        status = Transaction.STATE.PENDING
    }
    
    -- Store transaction
    if not activeTransactions[playerObj] then
        activeTransactions[playerObj] = {}
    end
    activeTransactions[playerObj][transactionType] = transaction
    
    -- Start timeout handler
    Transaction._startTimeoutHandler(playerObj, transactionType, transactionId)
    
    return transaction, nil
end

-- Commit a transaction (consume the locked items)
-- @param player: The player
-- @param transactionId: The transaction ID to commit
-- @return: true on success, false on failure
function Transaction.Commit(player, transactionId)
    -- Fail-fast validation
    if not player then error("Transaction.Commit: player is required") end
    if not transactionId then error("Transaction.Commit: transactionId is required") end
    
    local playerObj = resolvePlayer(player)
    if not playerObj then return false end
    
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
        L.debug("Transaction", "COMMIT failed - transaction not found: " .. tostring(transactionId))
        return false
    end
    
    if transaction.status ~= Transaction.STATE.PENDING then
        L.debug("Transaction", "COMMIT failed - transaction not pending: " .. tostring(transactionId) .. " (status=" .. tostring(transaction.status) .. ")")
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
    
    if not allConsumed then
        L.debug("Transaction", "COMMIT " .. transactionId .. " - partial consumption (some items unavailable)")
    end
    
    return allConsumed
end

-- Rollback a transaction (unlock the items)
-- @param player: The player
-- @param transactionId: The transaction ID to rollback (optional - can use transactionType)
-- @param transactionType: The transaction type (used if transactionId is nil)
-- @return: true on success, false on failure
function Transaction.Rollback(player, transactionId, transactionType)
    -- Fail-fast validation
    if not player then error("Transaction.Rollback: player is required") end
    if not transactionId and not transactionType then 
        error("Transaction.Rollback: transactionId or transactionType is required") 
    end
    
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
        L.debug("Transaction", "ROLLBACK - no transaction found (id=" .. tostring(transactionId) .. ", type=" .. tostring(transactionType) .. ")")
        return false
    end
    
    if transaction.status ~= Transaction.STATE.PENDING then
        L.debug("Transaction", "ROLLBACK - transaction not pending: " .. transaction.id .. " (status=" .. tostring(transaction.status) .. ")")
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
    
    return true
end

-- Finalize a transaction (server already consumed items, just clear local locks)
-- Use this for MP success case - semantically different from Rollback (which implies failure)
-- @param player: The player
-- @param transactionId: The transaction ID to finalize
-- @return: true on success, false on failure
function Transaction.Finalize(player, transactionId)
    -- Fail-fast validation
    if not player then error("Transaction.Finalize: player is required") end
    if not transactionId then error("Transaction.Finalize: transactionId is required") end
    
    local playerObj = resolvePlayer(player)
    if not playerObj then return false end
    
    local playerTransactions = activeTransactions[playerObj]
    if not playerTransactions then return false end
    
    local transaction = nil
    local tType = nil
    
    -- Find by ID
    for t, trans in pairs(playerTransactions) do
        if trans.id == transactionId then
            transaction = trans
            tType = t
            break
        end
    end
    
    if not transaction then
        L.debug("Transaction", "FINALIZE - no transaction found (id=" .. tostring(transactionId) .. ")")
        return false
    end
    
    if transaction.status ~= Transaction.STATE.PENDING then
        L.debug("Transaction", "FINALIZE - transaction not pending: " .. transaction.id .. " (status=" .. tostring(transaction.status) .. ")")
        return false
    end
    
    -- Unlock all items (server already consumed them, we just clear local locks)
    for itemType, data in pairs(transaction.lockedItems) do
        unlockItems(playerObj, itemType, data.itemIds)
    end
    
    -- Update transaction status
    transaction.status = Transaction.STATE.FINALIZED
    
    -- Remove from active transactions
    if tType then
        playerTransactions[tType] = nil
    end
    
    return true
end

-- Get a pending transaction for a player
-- @param player: The player
-- @param transactionType: The transaction type to look for
-- @return: transaction object or nil
function Transaction.GetPending(player, transactionType)
    -- Fail-fast validation
    if not player then error("Transaction.GetPending: player is required") end
    if not transactionType then error("Transaction.GetPending: transactionType is required") end
    
    local playerObj = resolvePlayer(player)
    if not playerObj then return nil end
    
    local playerTransactions = activeTransactions[playerObj]
    if not playerTransactions then return nil end
    
    local transaction = playerTransactions[transactionType]
    if transaction and transaction.status == Transaction.STATE.PENDING then
        return transaction
    end
    
    return nil
end

-----------------------------------------------------------
-- Timeout Handler
-- Auto-rollback transactions that don't complete in time
-- Uses a single periodic check instead of per-transaction OnTick
-----------------------------------------------------------

-- Timeout is stored in transaction.createdAt, checked periodically
local TIMEOUT_CHECK_INTERVAL_SECONDS = 5  -- Check every 5 seconds (matches EveryTenSeconds / 2)
local TIMEOUT_SECONDS = 5  -- 5 seconds (MSR.Config.TRANSACTION_TIMEOUT_TICKS / 60)

-- No-op: timeout info is in transaction.createdAt, checked by periodic handler
function Transaction._startTimeoutHandler(player, transactionType, transactionId)
    -- Timeout is checked by _checkAllTransactionTimeouts() periodically
    -- Transaction.createdAt is set in Transaction.Begin()
end

-- Batch check all pending transactions for timeout
-- Called by EveryTenSeconds event handler
function Transaction._checkAllTransactionTimeouts()
    local now = K.time()
    local timeoutThreshold = now - TIMEOUT_SECONDS
    
    -- Iterate all players with transactions
    for playerObj, playerTransactions in pairs(activeTransactions) do
        if playerTransactions then
            for transactionType, transaction in pairs(playerTransactions) do
                if transaction and transaction.status == Transaction.STATE.PENDING then
                    -- Check if transaction has timed out
                    if transaction.createdAt and transaction.createdAt < timeoutThreshold then
                        L.debug("Transaction", "TIMEOUT - Auto-rollback: " .. tostring(transaction.id))
                        
                        -- Auto-rollback
                        Transaction.Rollback(playerObj, transaction.id)
                        
                        -- Notify player
                        local resolved = resolvePlayer(playerObj)
                        if resolved then
                            local PM = MSR.PlayerMessage
                            if PM and PM.Say then
                                PM.Say(resolved, PM.ACTION_TIMEOUT_ITEMS_UNLOCKED)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Register periodic timeout check (runs every 10 seconds)
-- Only on client-side (where transactions are initiated)
local _timeoutHandlerRegistered = false
local function registerTimeoutHandler()
    if _timeoutHandlerRegistered then return end
    if MSR.Env.isDedicatedServer() then return end
    if not Events.EveryTenSeconds then return end
    
    Events.EveryTenSeconds.Add(Transaction._checkAllTransactionTimeouts)
    _timeoutHandlerRegistered = true
end

-- Register on game start
if Events.OnGameStart then
    Events.OnGameStart.Add(registerTimeoutHandler)
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
end

-- Register cleanup handlers
if Events.OnPlayerDeath then
    Events.OnPlayerDeath.Add(OnPlayerDisconnect)
end

-----------------------------------------------------------
-- Startup Cleanup
-- Clears stale locked items from crashed/disconnected sessions
-----------------------------------------------------------

local _startupCleanupDone = false

local function cleanupStaleLocksOnGameStart()
    if _startupCleanupDone then return end
    if MSR.Env.isDedicatedServer() then return end
    
    local player = getPlayer and getPlayer()
    if not player then return end  -- Will retry on next event
    
    local pmd = safePlayerCall(player, "getModData")
    if not pmd then return end
    
    if pmd._lockedTransactionItems then
        pmd._lockedTransactionItems = nil
    end
    
    activeTransactions[player] = nil
    _startupCleanupDone = true
end

-- Only register cleanup when client component exists (singleplayer, coop host, MP client)
-- Transaction system manages client-side item locking, not needed on dedicated servers
-- Use OnGameStart for initial attempt, EveryOneMinute as backup if player not ready
if not MSR.Env.isDedicatedServer() then
    if Events.OnGameStart then
        Events.OnGameStart.Add(cleanupStaleLocksOnGameStart)
    end
    if Events.EveryOneMinute then
        Events.EveryOneMinute.Add(cleanupStaleLocksOnGameStart)
    end
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
    if not player then error("Transaction.GetItemSources: player is required") end
    local playerObj = resolvePlayer(player)
    if not playerObj then return {} end
    return getItemSources(playerObj, bypassCache)
end

-- Count items across all sources
-- @param player: The player
-- @param itemType: The item type to count
-- @param filtered: (optional) If true, only count items that pass availability checks (favorites, crafting, etc.)
-- @return: Total count across all sources
function Transaction.GetMultiSourceCount(player, itemType, filtered)
    -- Fail-fast validation
    if not player then error("Transaction.GetMultiSourceCount: player is required") end
    if not itemType then error("Transaction.GetMultiSourceCount: itemType is required") end
    
    local playerObj = resolvePlayer(player)
    if not playerObj then return 0 end
    
    local sources = Transaction.GetItemSources(playerObj)
    local totalCount = 0
    
    -- Get already locked item IDs for this type
    local lockedStorage = getLockedItemsStorage(playerObj)
    local lockedIds = {}
    if lockedStorage and lockedStorage[itemType] then
        for _, itemId in ipairs(lockedStorage[itemType]) do
            lockedIds[itemId] = true
        end
    end
    
    if filtered then
        -- Iterate items and apply availability filter (same logic as lockItems)
        for _, container in ipairs(sources) do
            local items = container and container.getItems and container:getItems()
            if K.isIterable(items) then
                for _, item in K.iter(items) do
                    if item and item:getFullType() == itemType then
                        local itemId = item:getID()
                        -- Skip already locked items
                        if not lockedIds[itemId] then
                            -- Apply availability filter
                            local available, _ = isItemAvailableForLock(item, container)
                            if available then
                                totalCount = totalCount + 1
                            end
                        end
                    end
                end
            end
        end
    else
        -- Fast path: use container:getCountType() and subtract locked
        for _, container in ipairs(sources) do
            if container and container.getCountType then
                totalCount = totalCount + container:getCountType(itemType)
            end
        end
        
        -- Subtract locked items count
        local lockedCount = 0
        if lockedStorage and lockedStorage[itemType] then
            lockedCount = #lockedStorage[itemType]
        end
        totalCount = totalCount - lockedCount
    end
    
    return math.max(0, totalCount)
end

-- Count items with substitutions across all sources
-- @param player: The player
-- @param requirement: Requirement table with type and substitutes
-- @param filtered: (optional) If true, only count items that pass availability checks
-- @return: Total count of matching items, table of {itemType = count}
function Transaction.GetSubstitutionCount(player, requirement, filtered)
    -- Fail-fast validation
    if not player then error("Transaction.GetSubstitutionCount: player is required") end
    if not requirement then error("Transaction.GetSubstitutionCount: requirement is required") end
    
    local playerObj = resolvePlayer(player)
    if not playerObj then return 0, {} end
    
    local counts = {}
    local total = 0
    
    -- Primary type
    local primaryCount = Transaction.GetMultiSourceCount(playerObj, requirement.type, filtered)
    if primaryCount > 0 then
        counts[requirement.type] = primaryCount
        total = total + primaryCount
    end
    
    -- Substitutes (dedupe: skip types already counted)
    if requirement.substitutes then
        for _, subType in ipairs(requirement.substitutes) do
            if not counts[subType] then
                local subCount = Transaction.GetMultiSourceCount(playerObj, subType, filtered)
                if subCount > 0 then
                    counts[subType] = subCount
                    total = total + subCount
                end
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
    -- Fail-fast validation
    if not player then error("Transaction.ResolveSubstitutions: player is required") end
    if not requirements then error("Transaction.ResolveSubstitutions: requirements is required") end
    
    local playerObj = resolvePlayer(player)
    if not playerObj then return nil end
    
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

return MSR.Transaction


