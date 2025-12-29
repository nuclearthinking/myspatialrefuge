-- Spatial Refuge Transaction Module
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

-- Prevent double-loading
if SpatialRefugeTransaction and SpatialRefugeTransaction._loaded then
    return SpatialRefugeTransaction
end

SpatialRefugeTransaction = SpatialRefugeTransaction or {}
SpatialRefugeTransaction._loaded = true

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

-- Auto-rollback timeout in ticks (5 seconds = 300 ticks at 60 ticks/sec)
local TRANSACTION_TIMEOUT_TICKS = 300

-- Transaction states
SpatialRefugeTransaction.STATE = {
    PENDING = "PENDING",
    COMMITTED = "COMMITTED",
    ROLLED_BACK = "ROLLED_BACK"
}

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
    local username = player:getUsername() or "unknown"
    local timestamp = getTimestamp and getTimestamp() or os.time()
    return string.format("%s_%s_%d_%d", username, transactionType, timestamp, transactionCounter)
end

-----------------------------------------------------------
-- Item Locking
-- Locked items are stored in player ModData to survive reconnects
-----------------------------------------------------------

-- Get locked items storage for a player
local function getLockedItemsStorage(player)
    if not player then return nil end
    local pmd = player:getModData()
    if not pmd._lockedTransactionItems then
        pmd._lockedTransactionItems = {}
    end
    return pmd._lockedTransactionItems
end

-- Lock items for a transaction (mark as unavailable)
-- Returns: table of locked item references, or nil if not enough items
local function lockItems(player, itemType, count)
    if not player or not itemType or count <= 0 then return nil end
    
    local inv = player:getInventory()
    if not inv then return nil end
    
    -- Get current available count (excluding already locked items)
    local lockedStorage = getLockedItemsStorage(player)
    local alreadyLockedCount = 0
    
    if lockedStorage[itemType] then
        alreadyLockedCount = #lockedStorage[itemType]
    end
    
    local totalAvailable = inv:getCountType(itemType)
    local availableCount = totalAvailable - alreadyLockedCount
    
    if availableCount < count then
        return nil -- Not enough unlocked items
    end
    
    -- Find and lock specific item instances
    local items = inv:getItems()
    local lockedItems = {}
    local lockedCount = 0
    
    -- Build set of already locked item IDs for fast lookup
    local alreadyLockedIds = {}
    if lockedStorage[itemType] then
        for _, itemId in ipairs(lockedStorage[itemType]) do
            alreadyLockedIds[itemId] = true
        end
    end
    
    for i = 0, items:size() - 1 do
        if lockedCount >= count then break end
        
        local item = items:get(i)
        if item and item:getFullType() == itemType then
            local itemId = item:getID()
            if not alreadyLockedIds[itemId] then
                table.insert(lockedItems, itemId)
                lockedCount = lockedCount + 1
            end
        end
    end
    
    if lockedCount < count then
        return nil -- Couldn't find enough items (shouldn't happen if count was correct)
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
    
    local lockedStorage = getLockedItemsStorage(player)
    if not lockedStorage[itemType] then return end
    
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

-- Consume locked items (actually remove from inventory)
local function consumeLockedItems(player, itemType, itemIds)
    if not player or not itemType or not itemIds then return false end
    
    local inv = player:getInventory()
    if not inv then return false end
    
    -- Build set of IDs to consume
    local consumeSet = {}
    for _, itemId in ipairs(itemIds) do
        consumeSet[itemId] = true
    end
    
    -- Find and remove items by ID
    local items = inv:getItems()
    local toRemove = {}
    
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item:getFullType() == itemType then
            if consumeSet[item:getID()] then
                table.insert(toRemove, item)
            end
        end
    end
    
    -- Remove items
    for _, item in ipairs(toRemove) do
        inv:Remove(item)
    end
    
    -- Clear from locked storage
    unlockItems(player, itemType, itemIds)
    
    return #toRemove == #itemIds
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
function SpatialRefugeTransaction.Begin(player, transactionType, itemRequirements)
    if not player then return nil, "Invalid player" end
    if not transactionType then return nil, "Invalid transaction type" end
    if not itemRequirements or next(itemRequirements) == nil then 
        return nil, "No items specified" 
    end
    
    -- Check if there's already a pending transaction of this type
    local existing = SpatialRefugeTransaction.GetPending(player, transactionType)
    if existing then
        return nil, "Transaction already in progress"
    end
    
    -- Try to lock all required items
    local lockedItems = {}
    local lockFailed = false
    local failReason = nil
    
    for itemType, count in pairs(itemRequirements) do
        local locked = lockItems(player, itemType, count)
        if not locked then
            lockFailed = true
            failReason = "Not enough " .. itemType
            break
        end
        lockedItems[itemType] = {
            count = count,
            itemIds = locked
        }
    end
    
    -- If any lock failed, unlock all previously locked items
    if lockFailed then
        for itemType, data in pairs(lockedItems) do
            unlockItems(player, itemType, data.itemIds)
        end
        return nil, failReason
    end
    
    -- Create transaction object
    local transactionId = generateTransactionId(player, transactionType)
    local transaction = {
        id = transactionId,
        type = transactionType,
        lockedItems = lockedItems,
        createdAt = getTimestamp and getTimestamp() or os.time(),
        createdTick = 0,  -- Will be set by timeout handler
        status = SpatialRefugeTransaction.STATE.PENDING
    }
    
    -- Store transaction
    if not activeTransactions[player] then
        activeTransactions[player] = {}
    end
    activeTransactions[player][transactionType] = transaction
    
    -- Start timeout handler
    SpatialRefugeTransaction._startTimeoutHandler(player, transactionType, transactionId)
    
    if getDebug() then
        local itemList = {}
        for itemType, data in pairs(lockedItems) do
            table.insert(itemList, data.count .. "x " .. itemType)
        end
        print("[SpatialRefugeTransaction] BEGIN " .. transactionId .. 
              " - Locked: " .. table.concat(itemList, ", "))
    end
    
    return transaction, nil
end

-- Commit a transaction (consume the locked items)
-- @param player: The player
-- @param transactionId: The transaction ID to commit
-- @return: true on success, false on failure
function SpatialRefugeTransaction.Commit(player, transactionId)
    if not player or not transactionId then return false end
    
    -- Find the transaction
    local playerTransactions = activeTransactions[player]
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
        if getDebug() then
            print("[SpatialRefugeTransaction] COMMIT failed - transaction not found: " .. transactionId)
        end
        return false
    end
    
    if transaction.status ~= SpatialRefugeTransaction.STATE.PENDING then
        if getDebug() then
            print("[SpatialRefugeTransaction] COMMIT failed - transaction not pending: " .. transactionId)
        end
        return false
    end
    
    -- Consume all locked items
    local allConsumed = true
    for itemType, data in pairs(transaction.lockedItems) do
        if not consumeLockedItems(player, itemType, data.itemIds) then
            allConsumed = false
            -- Note: This shouldn't happen in normal operation
            -- Items might have been somehow removed externally
        end
    end
    
    -- Update transaction status
    transaction.status = SpatialRefugeTransaction.STATE.COMMITTED
    
    -- Remove from active transactions
    playerTransactions[transactionType] = nil
    
    if getDebug() then
        print("[SpatialRefugeTransaction] COMMIT " .. transactionId .. 
              " - Items consumed: " .. tostring(allConsumed))
    end
    
    return allConsumed
end

-- Rollback a transaction (unlock the items)
-- @param player: The player
-- @param transactionId: The transaction ID to rollback (optional - can use transactionType)
-- @param transactionType: The transaction type (used if transactionId is nil)
-- @return: true on success, false on failure
function SpatialRefugeTransaction.Rollback(player, transactionId, transactionType)
    if not player then return false end
    
    local playerTransactions = activeTransactions[player]
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
        if getDebug() then
            print("[SpatialRefugeTransaction] ROLLBACK - no transaction found")
        end
        return false
    end
    
    if transaction.status ~= SpatialRefugeTransaction.STATE.PENDING then
        if getDebug() then
            print("[SpatialRefugeTransaction] ROLLBACK - transaction not pending: " .. transaction.id)
        end
        return false
    end
    
    -- Unlock all items
    for itemType, data in pairs(transaction.lockedItems) do
        unlockItems(player, itemType, data.itemIds)
    end
    
    -- Update transaction status
    transaction.status = SpatialRefugeTransaction.STATE.ROLLED_BACK
    
    -- Remove from active transactions
    if tType then
        playerTransactions[tType] = nil
    end
    
    if getDebug() then
        print("[SpatialRefugeTransaction] ROLLBACK " .. transaction.id .. " - Items unlocked")
    end
    
    return true
end

-- Get a pending transaction for a player
-- @param player: The player
-- @param transactionType: The transaction type to look for
-- @return: transaction object or nil
function SpatialRefugeTransaction.GetPending(player, transactionType)
    if not player or not transactionType then return nil end
    
    local playerTransactions = activeTransactions[player]
    if not playerTransactions then return nil end
    
    local transaction = playerTransactions[transactionType]
    if transaction and transaction.status == SpatialRefugeTransaction.STATE.PENDING then
        return transaction
    end
    
    return nil
end

-- Check how many of an item type are currently available (not locked)
-- @param player: The player
-- @param itemType: The item type to check
-- @return: count of available items
function SpatialRefugeTransaction.GetAvailableCount(player, itemType)
    if not player or not itemType then return 0 end
    
    local inv = player:getInventory()
    if not inv then return 0 end
    
    local totalCount = inv:getCountType(itemType)
    
    local lockedStorage = getLockedItemsStorage(player)
    local lockedCount = 0
    if lockedStorage[itemType] then
        lockedCount = #lockedStorage[itemType]
    end
    
    return math.max(0, totalCount - lockedCount)
end

-----------------------------------------------------------
-- Timeout Handler
-- Auto-rollback transactions that don't complete in time
-----------------------------------------------------------

function SpatialRefugeTransaction._startTimeoutHandler(player, transactionType, transactionId)
    local tickCount = 0
    local playerRef = player
    local typeRef = transactionType
    local idRef = transactionId
    
    local function checkTimeout()
        tickCount = tickCount + 1
        
        -- Check if transaction still exists and is pending
        local transaction = SpatialRefugeTransaction.GetPending(playerRef, typeRef)
        
        if not transaction or transaction.id ~= idRef then
            -- Transaction was committed or rolled back elsewhere
            Events.OnTick.Remove(checkTimeout)
            return
        end
        
        -- Check timeout
        if tickCount >= TRANSACTION_TIMEOUT_TICKS then
            Events.OnTick.Remove(checkTimeout)
            
            if getDebug() then
                print("[SpatialRefugeTransaction] TIMEOUT - Auto-rollback: " .. idRef)
            end
            
            -- Auto-rollback
            SpatialRefugeTransaction.Rollback(playerRef, idRef)
            
            -- Notify player
            if playerRef and playerRef.Say then
                local ok, _ = pcall(function() playerRef:Say("Action timed out - items unlocked") end)
            end
        end
    end
    
    Events.OnTick.Add(checkTimeout)
end

-----------------------------------------------------------
-- Cleanup on player disconnect/death
-----------------------------------------------------------

local function OnPlayerDisconnect(player)
    if not player then return end
    
    -- Rollback any pending transactions
    local playerTransactions = activeTransactions[player]
    if playerTransactions then
        for transactionType, transaction in pairs(playerTransactions) do
            if transaction.status == SpatialRefugeTransaction.STATE.PENDING then
                SpatialRefugeTransaction.Rollback(player, transaction.id)
            end
        end
    end
    
    -- Clear transaction storage
    activeTransactions[player] = nil
    
    -- Clear locked items storage
    if player.getModData then
        local pmd = player:getModData()
        if pmd then
            pmd._lockedTransactionItems = nil
        end
    end
end

-- Register cleanup handlers
if Events.OnPlayerDeath then
    Events.OnPlayerDeath.Add(OnPlayerDisconnect)
end

return SpatialRefugeTransaction


