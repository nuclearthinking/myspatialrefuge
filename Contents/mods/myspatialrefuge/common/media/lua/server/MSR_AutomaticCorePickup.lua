require "00_core/00_MSR"
require "MSR_UpgradeData"
local UpgradeEvents = require "MSR_UpgradeEvents"
local InventoryAuthority = require "MSR_InventoryAuthority"

local AutomaticCorePickup = MSR.register("AutomaticCorePickup")
local LOG = L.logger("CorePickup")
if not AutomaticCorePickup then
    return MSR.AutomaticCorePickup
end

local Config = MSR.Config
local UpgradeData = MSR.UpgradeData
local getPlayerUpgradeLevel = UpgradeData.getPlayerUpgradeLevel
local getLevelEffects = UpgradeData.getLevelEffects
local isInstanceOf = instanceof
local getCurrentCell = getCell
local getTime = getTimestamp
local getTimeMs = getTimestampMs
local getOnlinePlayersList = getOnlinePlayers
local haloTextHelper = HaloTextHelper

local CORE_ITEM = Config.CORE_ITEM or "Base.MagicalCore"
-- TextDrawObject 42.20 does not parse an image nested inside a color tag.
-- Build the tags in sequence and use HaloTextHelper's raw-text overload.
local CORE_HALO_PREFIX = "[img=media/textures/item_ZombieCore_Halo.png]  [col=137,232,148]+"
local CORE_HALO_SUFFIX = "[/]"
local UPGRADE_ID = Config.UPGRADES.AUTOMATIC_CORE_PICKUP
local OWNER_KEY = "MSR_AutomaticCoreOwner"
local PROTECTED_UNTIL_KEY = "MSR_AutomaticCoreProtectedUntil"
local PENDING_TOKEN_KEY = "MSR_AutomaticCorePickupToken"

local OWNER_PROTECTION_SECONDS = 30
local MIN_MOVEMENT_SCAN_INTERVAL_MS = 500
local MOVEMENT_SETTLE_MS = 100
local CORPSE_RETRY_INTERVAL_MS = 250
local CORPSE_WAIT_TIMEOUT_MS = 10000
local CORELESS_CACHE_MS = 5000
local FEEDBACK_INTERVAL_MS = 500
local MAX_SCAN_RADIUS = 2
local MAX_CORPSES_PER_TICK = 32
local MAX_CORES_PER_TICK = 8
local MAX_WORK_MS_PER_TICK = 2

---@class CorePickupSearchBucket
---@field key string
---@field x integer
---@field y integer
---@field z integer
---@field pendingCount integer
---@field tokens table<string, boolean>
---@field nextAttemptAtMs number
---@field objectIndex integer
---@field queued boolean

---@class CorePickupPendingEntry
---@field token string
---@field expiresAtMs number
---@field bucket CorePickupSearchBucket
---@field resolved boolean

---@class CorePickupScanCursor
---@field centerX integer
---@field centerY integer
---@field centerZ integer
---@field playerX number
---@field playerY number
---@field playerZ number
---@field radiusSquared number
---@field scanRadius integer
---@field squareIndex integer
---@field objectIndex integer
---@field version integer

---@class CorePickupPlayerState
---@field player IsoPlayer
---@field label string
---@field radius number
---@field queued boolean
---@field abandoning boolean
---@field pendingByToken table<string, CorePickupPendingEntry>
---@field pendingOrder CorePickupPendingEntry[]
---@field pendingOrderHead integer
---@field pendingCount integer
---@field searchBuckets table<string, CorePickupSearchBucket>
---@field bucketQueue CorePickupSearchBucket[]
---@field bucketQueueHead integer
---@field bucketQueueTail integer
---@field readyCorpses IsoDeadBody[]
---@field readyHead integer
---@field readyTail integer
---@field readyCount integer
---@field readySet table<IsoDeadBody, boolean>
---@field movementRequested boolean
---@field movementDueAtMs number?
---@field movementVersion integer
---@field movementCursor CorePickupScanCursor?
---@field lastMovementX integer?
---@field lastMovementY integer?
---@field lastMovementZ integer?
---@field lastMovementScanAtMs number
---@field feedbackCount integer
---@field feedbackDueAtMs number?
---@field batchActive boolean
---@field batchQueued integer
---@field batchInspected integer
---@field batchTransferred integer
---@field batchTimedOut integer
---@field batchAbandoned integer
---@field batchBlocked integer

---@class CorePickupTickBudget
---@field startedAtMs number
---@field corpsesInspected integer
---@field coresTransferred integer
---@field contexts table<CorePickupPlayerState, table>

-- Player keys and corpse keys are weak so disconnected players and unloaded
-- bodies cannot be retained by the recovery cache.
---@type table<IsoPlayer, CorePickupPlayerState>
local scanStateByPlayer = setmetatable({}, { __mode = "k" })
---@type table<IsoDeadBody, number>
local corelessUntilByCorpse = setmetatable({}, { __mode = "k" })
---@type table<string, CorePickupPlayerState>
local pendingStateByToken = {}

---@type CorePickupPlayerState[]
local workQueue = {}
local workQueueHead = 1
local workQueueTail = 0
local dispatcherActive = false
local tokenSequence = 0

local Dispatcher = {}

local function dispatcherTick()
    Dispatcher.process()
end

local function showPickupFeedback(player, collected)
    -- HaloTextHelper performs the owning-client sync in multiplayer. Calls are
    -- aggregated by player instead of emitting one packet for every core.
    haloTextHelper.addText(
        player,
        CORE_HALO_PREFIX .. tostring(collected) .. CORE_HALO_SUFFIX,
        "[br/]"
    )
end

local function getPlayerLabel(player)
    local username = player:getUsername()
    if username and username ~= "" then
        return username
    end

    return tostring(player:getOnlineID())
end

local function getPickupRadiusForLevel(level)
    if level <= 0 then
        return 0
    end

    local effects = getLevelEffects(UPGRADE_ID, level)
    return tonumber(effects.corePickupRadius) or 0
end

---@return CorePickupPlayerState
local function createScanState(player)
    return {
        player = player,
        label = getPlayerLabel(player),
        radius = getPickupRadiusForLevel(getPlayerUpgradeLevel(player, UPGRADE_ID)),
        queued = false,
        abandoning = false,
        pendingByToken = {},
        pendingOrder = {},
        pendingOrderHead = 1,
        pendingCount = 0,
        searchBuckets = {},
        bucketQueue = {},
        bucketQueueHead = 1,
        bucketQueueTail = 0,
        readyCorpses = {},
        readyHead = 1,
        readyTail = 0,
        readyCount = 0,
        readySet = setmetatable({}, { __mode = "k" }),
        movementRequested = false,
        movementVersion = 0,
        lastMovementScanAtMs = 0,
        feedbackCount = 0,
        batchActive = false,
        batchQueued = 0,
        batchInspected = 0,
        batchTransferred = 0,
        batchTimedOut = 0,
        batchAbandoned = 0,
        batchBlocked = 0
    }
end

---@return CorePickupPlayerState
local function getScanState(player)
    local state = scanStateByPlayer[player]
    if state then return state end

    state = createScanState(player)
    scanStateByPlayer[player] = state
    return state
end

local function isPlayerConnected(player)
    if not player or not MSR.isPlayerValid(player) then return false end
    if not MSR.Env.isServer() then return true end

    local onlinePlayers = getOnlinePlayersList()
    local count = onlinePlayers and onlinePlayers:size() or 0
    for index = 0, count - 1 do
        if onlinePlayers:get(index) == player then return true end
    end

    return false
end

local function isPlayerEligible(state)
    local player = state.player
    return isPlayerConnected(player)
        and not player:isDead()
        and not player:getVehicle()
        and state.radius > 0
end

local function hasStateWork(state)
    return state.pendingCount > 0
        or state.readyCount > 0
        or state.movementRequested
        or state.movementCursor ~= nil
        or state.feedbackCount > 0
        or state.abandoning
end

local function startDispatcher()
    if dispatcherActive then return end
    dispatcherActive = true
    Events.OnTick.Add(dispatcherTick)
end

local function enqueueState(state)
    if state.queued then return end
    state.queued = true
    workQueueTail = workQueueTail + 1
    workQueue[workQueueTail] = state
    startDispatcher()
end

---@return CorePickupPlayerState?
local function popState()
    if workQueueHead > workQueueTail then return nil end

    local state = workQueue[workQueueHead]
    workQueue[workQueueHead] = nil
    workQueueHead = workQueueHead + 1
    if workQueueHead > workQueueTail then
        workQueueHead = 1
        workQueueTail = 0
    end

    if state then state.queued = false end
    return state
end

local function stopDispatcherIfIdle()
    if workQueueTail > 0 or not dispatcherActive then return end
    dispatcherActive = false
    Events.OnTick.Remove(dispatcherTick)
end

local function isWorkTimeExhausted(budget)
    return getTimeMs() - budget.startedAtMs >= MAX_WORK_MS_PER_TICK
end

local function beginBatch(state)
    if state.batchActive then return end
    state.batchActive = true
    state.batchQueued = 0
    state.batchInspected = 0
    state.batchTransferred = 0
    state.batchTimedOut = 0
    state.batchAbandoned = 0
    state.batchBlocked = 0
end

local function finishBatchIfDone(state)
    if not state.batchActive or state.pendingCount > 0 or state.readyCount > 0 then return end

    LOG.debug(
        "Automatic core batch for %s: queued=%d, inspected=%d, transferred=%d, timedOut=%d, abandoned=%d, blocked=%d",
        state.label,
        state.batchQueued,
        state.batchInspected,
        state.batchTransferred,
        state.batchTimedOut,
        state.batchAbandoned,
        state.batchBlocked
    )
    state.batchActive = false
end

local function addPickupFeedback(state, collected, nowMs)
    if collected <= 0 then return end
    state.feedbackCount = state.feedbackCount + collected
    state.feedbackDueAtMs = state.feedbackDueAtMs or (nowMs + FEEDBACK_INTERVAL_MS)
    enqueueState(state)
end

local function flushPickupFeedback(state, nowMs)
    if state.feedbackCount <= 0
        or not state.feedbackDueAtMs
        or nowMs < state.feedbackDueAtMs
    then
        return false
    end

    showPickupFeedback(state.player, state.feedbackCount)
    state.feedbackCount = 0
    state.feedbackDueAtMs = nil
    return true
end

local function canCollectFromCorpse(player, corpse, now)
    local modData = corpse:getModData()
    local owner = modData and modData[OWNER_KEY] or nil
    local protectedUntil = modData and tonumber(modData[PROTECTED_UNTIL_KEY]) or 0

    if not owner or protectedUntil <= now then
        return true
    end

    return player:getUsername() == owner
end

local function addDestinationCandidate(player, coreItem, containerItem, seenItems, withCore, withoutCore)
    if not containerItem or seenItems[containerItem] then return end
    seenItems[containerItem] = true

    if not isInstanceOf(containerItem, "InventoryContainer") then return end

    local container = containerItem:getInventory()
    if not container or not container:hasRoomFor(player, coreItem) then return end

    local destinations = container:containsType(CORE_ITEM) and withCore or withoutCore
    destinations[#destinations + 1] = container
end

local function buildDestinationPlan(player, coreItem)
    local withCore = {}
    local withoutCore = {}
    local seenItems = {}

    addDestinationCandidate(
        player,
        coreItem,
        player:getClothingItem_Back(),
        seenItems,
        withCore,
        withoutCore
    )

    local wornItems = player:getWornItems()
    local wornCount = wornItems and wornItems:size() or 0
    for index = 0, wornCount - 1 do
        local wornItem = wornItems:get(index)
        addDestinationCandidate(
            player,
            coreItem,
            wornItem and wornItem:getItem() or nil,
            seenItems,
            withCore,
            withoutCore
        )
    end

    addDestinationCandidate(
        player,
        coreItem,
        player:getPrimaryHandItem(),
        seenItems,
        withCore,
        withoutCore
    )
    addDestinationCandidate(
        player,
        coreItem,
        player:getSecondaryHandItem(),
        seenItems,
        withCore,
        withoutCore
    )

    for index = 1, #withoutCore do
        withCore[#withCore + 1] = withoutCore[index]
    end

    local playerInventory = player:getInventory()
    if playerInventory and playerInventory:hasRoomFor(player, coreItem) then
        withCore[#withCore + 1] = playerInventory
    end

    return withCore
end

---@return InventoryItem?
local function findDirectCore(rootContainer)
    local items = rootContainer:getItems()
    local itemCount = items and items:size() or 0
    for index = 0, itemCount - 1 do
        local item = items:get(index)
        if item and item:getFullType() == CORE_ITEM and item:getContainer() == rootContainer then
            return item
        end
    end

    return nil
end

--- Transfer only from the root corpse container whose parent was validated as
--- an IsoDeadBody. This prevents ContainerID from resolving a live zombie.
---@return integer, InventoryItem?, string
local function transferCores(player, rootContainer, context, firstItem, maxItems)
    local collected = 0
    local item = firstItem

    if not context.destinations then
        context.destinations = buildDestinationPlan(player, item)
        context.destinationIndex = 1
    end

    while item and collected < maxItems do
        if item:getContainer() ~= rootContainer then
            return collected, item, "invalid"
        end

        local moved = false
        while context.destinationIndex <= #context.destinations do
            local destinationContainer = context.destinations[context.destinationIndex]
            if rootContainer ~= destinationContainer
                and InventoryAuthority.moveItem(player, rootContainer, destinationContainer, item)
            then
                moved = true
                break
            end

            context.destinationIndex = context.destinationIndex + 1
        end

        if not moved then return collected, item, "blocked" end

        collected = collected + 1
        item = findDirectCore(rootContainer)
    end

    if item then return collected, item, "budget" end
    return collected, nil, "done"
end

--- The caller may synchronize an item only after this validates the corpse,
--- square, and root container parent. The empty cache is shared by discovery
--- and movement recovery without retaining unloaded bodies.
---@return integer, string
local function collectFromCorpse(state, corpse, context, maxItems, nowMs)
    if not corpse or not isInstanceOf(corpse, "IsoDeadBody") then return 0, "invalid" end
    if not corpse:getSquare() then return 0, "invalid" end

    local rootContainer = corpse:getContainer()
    if not rootContainer or rootContainer:getParent() ~= corpse then return 0, "invalid" end

    local cachedUntil = corelessUntilByCorpse[corpse]
    if cachedUntil and cachedUntil > nowMs then return 0, "empty" end
    if cachedUntil then corelessUntilByCorpse[corpse] = nil end

    local firstCore = findDirectCore(rootContainer)
    if not firstCore then
        corelessUntilByCorpse[corpse] = nowMs + CORELESS_CACHE_MS
        return 0, "empty"
    end

    if not canCollectFromCorpse(state.player, corpse, getTime()) then return 0, "protected" end
    if maxItems <= 0 then return 0, "budget" end

    local collected, remainingCore, status = transferCores(
        state.player,
        rootContainer,
        context,
        firstCore,
        maxItems
    )
    if not remainingCore then
        corelessUntilByCorpse[corpse] = nowMs + CORELESS_CACHE_MS
    end
    return collected, status
end

local function resetPendingStorageIfEmpty(state)
    if state.pendingCount > 0 then return end

    state.pendingByToken = {}
    state.pendingOrder = {}
    state.pendingOrderHead = 1
    state.searchBuckets = {}
    state.bucketQueue = {}
    state.bucketQueueHead = 1
    state.bucketQueueTail = 0
end

local function enqueueBucket(state, bucket)
    if bucket.queued or bucket.pendingCount <= 0 then return end
    bucket.queued = true
    state.bucketQueueTail = state.bucketQueueTail + 1
    state.bucketQueue[state.bucketQueueTail] = bucket
end

---@return CorePickupSearchBucket?
local function popBucket(state)
    if state.bucketQueueHead > state.bucketQueueTail then return nil end

    local bucket = state.bucketQueue[state.bucketQueueHead]
    state.bucketQueue[state.bucketQueueHead] = nil
    state.bucketQueueHead = state.bucketQueueHead + 1
    if state.bucketQueueHead > state.bucketQueueTail then
        state.bucketQueueHead = 1
        state.bucketQueueTail = 0
    end

    if bucket then bucket.queued = false end
    return bucket
end

local function removePendingEntry(state, entry, timedOut)
    if entry.resolved then return end
    entry.resolved = true
    state.pendingByToken[entry.token] = nil
    pendingStateByToken[entry.token] = nil
    state.pendingCount = math.max(0, state.pendingCount - 1)

    local bucket = entry.bucket
    if bucket.tokens[entry.token] then
        bucket.tokens[entry.token] = nil
        bucket.pendingCount = math.max(0, bucket.pendingCount - 1)
    end
    if bucket.pendingCount <= 0 then
        state.searchBuckets[bucket.key] = nil
    end

    if timedOut and state.batchActive then
        state.batchTimedOut = state.batchTimedOut + 1
    end
    resetPendingStorageIfEmpty(state)
end

local function queueReadyCorpse(state, corpse)
    if state.abandoning or state.readySet[corpse] then return end
    state.readySet[corpse] = true
    state.readyTail = state.readyTail + 1
    state.readyCorpses[state.readyTail] = corpse
    state.readyCount = state.readyCount + 1
    enqueueState(state)
end

---@return IsoDeadBody?
local function popReadyCorpse(state)
    if state.readyHead > state.readyTail then return nil end

    local corpse = state.readyCorpses[state.readyHead]
    state.readyCorpses[state.readyHead] = nil
    state.readyHead = state.readyHead + 1
    state.readyCount = math.max(0, state.readyCount - 1)
    if state.readyHead > state.readyTail then
        state.readyCorpses = {}
        state.readyHead = 1
        state.readyTail = 0
    end
    return corpse
end

--- Clear the copied token as soon as an addressable body is found. If its
--- owner is still waiting, route that body to the owner's ready queue.
---@return CorePickupPlayerState?, boolean
local function detectPendingCorpse(corpse, nowMs)
    local modData = corpse:getModData()
    local tokenValue = modData and modData[PENDING_TOKEN_KEY] or nil
    if not tokenValue then return nil, false end

    modData[PENDING_TOKEN_KEY] = nil
    local token = tostring(tokenValue)
    local state = pendingStateByToken[token]
    local entry = state and state.pendingByToken[token] or nil
    if not state or not entry or entry.resolved then return nil, false end

    if nowMs >= entry.expiresAtMs then
        removePendingEntry(state, entry, true)
        finishBatchIfDone(state)
        return nil, false
    end

    removePendingEntry(state, entry, false)
    if not state.abandoning then queueReadyCorpse(state, corpse) end
    return state, true
end

local function queuePendingToken(state, token, square, nowMs)
    if state.abandoning then return end

    beginBatch(state)
    local key = tostring(square:getX()) .. ":" .. tostring(square:getY()) .. ":" .. tostring(square:getZ())
    local bucket = state.searchBuckets[key]
    if not bucket then
        bucket = {
            key = key,
            x = square:getX(),
            y = square:getY(),
            z = square:getZ(),
            pendingCount = 0,
            tokens = {},
            nextAttemptAtMs = nowMs,
            objectIndex = 0,
            queued = false
        }
        state.searchBuckets[key] = bucket
    else
        bucket.nextAttemptAtMs = math.min(bucket.nextAttemptAtMs, nowMs)
    end

    local entry = {
        token = token,
        expiresAtMs = nowMs + CORPSE_WAIT_TIMEOUT_MS,
        bucket = bucket,
        resolved = false
    }
    state.pendingByToken[token] = entry
    state.pendingOrder[#state.pendingOrder + 1] = entry
    state.pendingCount = state.pendingCount + 1
    pendingStateByToken[token] = state
    bucket.tokens[token] = true
    bucket.pendingCount = bucket.pendingCount + 1
    state.batchQueued = state.batchQueued + 1

    enqueueBucket(state, bucket)
    enqueueState(state)
end

local function markStateAbandoned(state)
    if state.abandoning then return end
    state.abandoning = state.pendingCount > 0
    if state.batchActive then
        state.batchAbandoned = state.batchAbandoned + state.pendingCount + state.readyCount
    end

    state.readyCorpses = {}
    state.readyHead = 1
    state.readyTail = 0
    state.readyCount = 0
    state.readySet = setmetatable({}, { __mode = "k" })
    state.movementRequested = false
    state.movementDueAtMs = nil
    state.movementCursor = nil
    state.feedbackCount = 0
    state.feedbackDueAtMs = nil

    if not state.abandoning then finishBatchIfDone(state) end
end

local function abandonPendingUnit(state, budget)
    local inspected = 0
    while state.pendingCount > 0 and inspected < 16 and not isWorkTimeExhausted(budget) do
        local entry = state.pendingOrder[state.pendingOrderHead]
        if not entry then break end
        state.pendingOrderHead = state.pendingOrderHead + 1
        inspected = inspected + 1
        if not entry.resolved then removePendingEntry(state, entry, false) end
    end

    if state.pendingCount <= 0 then
        state.abandoning = false
        resetPendingStorageIfEmpty(state)
        finishBatchIfDone(state)
    end
    return inspected > 0
end

local function expirePendingUnit(state, nowMs)
    local inspected = 0
    while inspected < 16 do
        local entry = state.pendingOrder[state.pendingOrderHead]
        if not entry then return false end
        if not entry.resolved and nowMs < entry.expiresAtMs then return inspected > 0 end

        state.pendingOrderHead = state.pendingOrderHead + 1
        inspected = inspected + 1
        if not entry.resolved then
            removePendingEntry(state, entry, true)
            finishBatchIfDone(state)
            return true
        end
    end
    return true
end

local function isObjectInRange(object, playerX, playerY, playerZ, radiusSquared)
    if object:getZ() ~= playerZ then return false end

    local deltaX = object:getX() - playerX
    local deltaY = object:getY() - playerY
    return deltaX * deltaX + deltaY * deltaY <= radiusSquared
end

local function finishBucketCycle(state, bucket, nowMs)
    bucket.objectIndex = 0
    if bucket.pendingCount > 0 then
        bucket.nextAttemptAtMs = nowMs + CORPSE_RETRY_INTERVAL_MS
        enqueueBucket(state, bucket)
    else
        state.searchBuckets[bucket.key] = nil
    end
end

local function processSearchBucketUnit(state, budget, nowMs)
    local bucket = popBucket(state)
    local discarded = 0
    while bucket and bucket.pendingCount <= 0 and discarded < 8 do
        state.searchBuckets[bucket.key] = nil
        bucket = popBucket(state)
        discarded = discarded + 1
    end
    if not bucket then return discarded > 0 end

    if nowMs < bucket.nextAttemptAtMs then
        enqueueBucket(state, bucket)
        return discarded > 0
    end

    local cell = getCurrentCell()
    local square = cell and cell:getGridSquare(bucket.x, bucket.y, bucket.z) or nil
    if not square then
        finishBucketCycle(state, bucket, nowMs)
        return true
    end

    local objects = square:getStaticMovingObjects()
    local objectCount = objects and objects:size() or 0
    while bucket.objectIndex < objectCount do
        if isWorkTimeExhausted(budget) then
            enqueueBucket(state, bucket)
            return true
        end

        local object = objects:get(bucket.objectIndex)
        if object and isInstanceOf(object, "IsoDeadBody") then
            if budget.corpsesInspected >= MAX_CORPSES_PER_TICK then
                enqueueBucket(state, bucket)
                return false
            end

            bucket.objectIndex = bucket.objectIndex + 1
            budget.corpsesInspected = budget.corpsesInspected + 1
            if state.batchActive then state.batchInspected = state.batchInspected + 1 end
            ---@cast object IsoDeadBody
            detectPendingCorpse(object, nowMs)

            if bucket.objectIndex >= objectCount then
                finishBucketCycle(state, bucket, nowMs)
            else
                enqueueBucket(state, bucket)
            end
            return true
        end

        bucket.objectIndex = bucket.objectIndex + 1
    end

    finishBucketCycle(state, bucket, nowMs)
    return true
end

local function getTickContext(state, budget)
    local context = budget.contexts[state]
    if context then return context end

    context = {}
    budget.contexts[state] = context
    return context
end

local function processReadyCorpseUnit(state, budget, nowMs)
    if state.readyCount <= 0 or budget.coresTransferred >= MAX_CORES_PER_TICK then return false end

    local corpse = popReadyCorpse(state)
    if not corpse then return false end

    local remainingBudget = MAX_CORES_PER_TICK - budget.coresTransferred
    local collected, status = collectFromCorpse(
        state,
        corpse,
        getTickContext(state, budget),
        remainingBudget,
        nowMs
    )
    budget.coresTransferred = budget.coresTransferred + collected
    if state.batchActive then state.batchTransferred = state.batchTransferred + collected end
    addPickupFeedback(state, collected, nowMs)

    if status == "budget" then
        state.readyTail = state.readyTail + 1
        state.readyCorpses[state.readyTail] = corpse
        state.readyCount = state.readyCount + 1
    else
        state.readySet[corpse] = nil
        if status == "blocked" and state.batchActive then
            state.batchBlocked = state.batchBlocked + 1
        end
    end

    finishBatchIfDone(state)
    return true
end

local function completeMovementScan(state, cursor, nowMs)
    state.lastMovementX = cursor.centerX
    state.lastMovementY = cursor.centerY
    state.lastMovementZ = cursor.centerZ
    state.lastMovementScanAtMs = nowMs
    state.movementCursor = nil

    if state.movementVersion == cursor.version then
        state.movementRequested = false
        state.movementDueAtMs = nil
    else
        state.movementRequested = true
        state.movementDueAtMs = nowMs + MOVEMENT_SETTLE_MS
    end
end

---@return CorePickupScanCursor?
local function createMovementCursor(state, nowMs)
    local square = state.player:getCurrentSquare()
    if not square then return nil end

    local squareX = square:getX()
    local squareY = square:getY()
    local squareZ = square:getZ()
    if state.lastMovementX == squareX
        and state.lastMovementY == squareY
        and state.lastMovementZ == squareZ
    then
        state.movementRequested = false
        state.movementDueAtMs = nil
        return nil
    end

    local earliestStart = math.max(
        state.movementDueAtMs or nowMs,
        state.lastMovementScanAtMs + MIN_MOVEMENT_SCAN_INTERVAL_MS
    )
    if nowMs < earliestStart then return nil end

    local radius = state.radius
    return {
        centerX = squareX,
        centerY = squareY,
        centerZ = squareZ,
        playerX = state.player:getX(),
        playerY = state.player:getY(),
        playerZ = state.player:getZ(),
        radiusSquared = radius * radius,
        scanRadius = radius > 1 and MAX_SCAN_RADIUS or 1,
        squareIndex = 0,
        objectIndex = 0,
        version = state.movementVersion
    }
end

local function processMovementUnit(state, budget, nowMs)
    if not state.movementRequested and not state.movementCursor then return false end

    local cursor = state.movementCursor
    if cursor then
        local currentSquare = state.player:getCurrentSquare()
        if not currentSquare then return false end
        if currentSquare:getX() ~= cursor.centerX
            or currentSquare:getY() ~= cursor.centerY
            or currentSquare:getZ() ~= cursor.centerZ
        then
            state.movementCursor = nil
            state.movementDueAtMs = nowMs + MOVEMENT_SETTLE_MS
            return true
        end
    else
        cursor = createMovementCursor(state, nowMs)
        if not cursor then return false end
        state.movementCursor = cursor
    end

    local cell = getCurrentCell()
    if not cell then return false end

    local sideLength = cursor.scanRadius * 2 + 1
    local squareCount = sideLength * sideLength
    while cursor.squareIndex < squareCount do
        if isWorkTimeExhausted(budget) then return true end

        local offsetX = cursor.squareIndex % sideLength - cursor.scanRadius
        local offsetY = math.floor(cursor.squareIndex / sideLength) - cursor.scanRadius
        local square = cell:getGridSquare(
            cursor.centerX + offsetX,
            cursor.centerY + offsetY,
            cursor.centerZ
        )
        local objects = square and square:getStaticMovingObjects() or nil
        local objectCount = objects and objects:size() or 0

        while cursor.objectIndex < objectCount do
            if isWorkTimeExhausted(budget) then return true end

            local object = objects and objects:get(cursor.objectIndex) or nil
            if object and isInstanceOf(object, "IsoDeadBody") then
                if budget.corpsesInspected >= MAX_CORPSES_PER_TICK then return false end

                cursor.objectIndex = cursor.objectIndex + 1
                budget.corpsesInspected = budget.corpsesInspected + 1
                ---@cast object IsoDeadBody
                if isObjectInRange(
                    object,
                    cursor.playerX,
                    cursor.playerY,
                    cursor.playerZ,
                    cursor.radiusSquared
                ) then
                    local _, wasPending = detectPendingCorpse(object, nowMs)
                    if not wasPending then
                        local remainingBudget = MAX_CORES_PER_TICK - budget.coresTransferred
                        local collected, status = collectFromCorpse(
                            state,
                            object,
                            getTickContext(state, budget),
                            remainingBudget,
                            nowMs
                        )
                        budget.coresTransferred = budget.coresTransferred + collected
                        addPickupFeedback(state, collected, nowMs)

                        if status == "budget" then
                            cursor.objectIndex = cursor.objectIndex - 1
                        end
                    end
                end

                return true
            end

            cursor.objectIndex = cursor.objectIndex + 1
        end

        cursor.squareIndex = cursor.squareIndex + 1
        cursor.objectIndex = 0
    end

    completeMovementScan(state, cursor, nowMs)
    return true
end

local function processStateUnit(state, budget, nowMs)
    if not isPlayerEligible(state) then
        markStateAbandoned(state)
        if state.abandoning then return abandonPendingUnit(state, budget) end
        return true
    end

    if state.abandoning then return abandonPendingUnit(state, budget) end
    if flushPickupFeedback(state, nowMs) then return true end
    if expirePendingUnit(state, nowMs) then return true end
    if state.readyCount > 0 then return processReadyCorpseUnit(state, budget, nowMs) end
    if state.pendingCount > 0 and processSearchBucketUnit(state, budget, nowMs) then return true end
    return processMovementUnit(state, budget, nowMs)
end

function Dispatcher.process()
    local budget = {
        startedAtMs = getTimeMs(),
        corpsesInspected = 0,
        coresTransferred = 0,
        contexts = {}
    }
    local idleVisits = 0

    while workQueueTail > 0
        and budget.corpsesInspected < MAX_CORPSES_PER_TICK
        and budget.coresTransferred < MAX_CORES_PER_TICK
        and not isWorkTimeExhausted(budget)
    do
        local state = popState()
        if not state then break end

        local progressed = processStateUnit(state, budget, getTimeMs())
        finishBatchIfDone(state)
        if hasStateWork(state) then enqueueState(state) end

        if progressed then
            idleVisits = 0
        else
            idleVisits = idleVisits + 1
            local queuedCount = workQueueTail > 0 and (workQueueTail - workQueueHead + 1) or 0
            if queuedCount <= 0 or idleVisits >= queuedCount then break end
        end
    end

    stopDispatcherIfIdle()
end

local function createPendingToken(zombie)
    tokenSequence = tokenSequence + 1
    if tokenSequence > 2147483647 then tokenSequence = 1 end
    return tostring(getTimeMs()) .. ":" .. tostring(zombie:getOnlineID()) .. ":" .. tostring(tokenSequence)
end

local function onZombieDead(zombie)
    if not zombie then return end

    local rootContainer = zombie:getInventory()
    if not rootContainer or not rootContainer:getFirstTypeRecurse(CORE_ITEM) then return end

    local killer = zombie:getAttackedBy()
    local playerKiller = killer and isInstanceOf(killer, "IsoPlayer") and killer or nil
    local modData = zombie:getModData()
    local token = createPendingToken(zombie)
    modData[PENDING_TOKEN_KEY] = token

    if playerKiller then
        ---@cast playerKiller IsoPlayer
        local username = playerKiller:getUsername()
        if username and username ~= "" then
            modData[OWNER_KEY] = username
            modData[PROTECTED_UNTIL_KEY] = getTime() + OWNER_PROTECTION_SECONDS
        else
            modData[OWNER_KEY] = nil
            modData[PROTECTED_UNTIL_KEY] = nil
        end

        local state = getScanState(playerKiller)
        -- IsoDeadBody uses the cell square resolved from the zombie's precise
        -- coordinates on the server, which can differ from currentSquare while
        -- movement state is being finalized.
        local cell = getCurrentCell()
        local square = cell and cell:getGridSquare(
            zombie:getX(),
            zombie:getY(),
            zombie:getZ()
        ) or zombie:getCurrentSquare()
        if state.radius > 0
            and not state.abandoning
            and not playerKiller:isDead()
            and not playerKiller:getVehicle()
            and square
            and isObjectInRange(
                zombie,
                playerKiller:getX(),
                playerKiller:getY(),
                playerKiller:getZ(),
                state.radius * state.radius
            )
        then
            queuePendingToken(state, token, square, getTimeMs())
        end
        return
    end

    modData[OWNER_KEY] = nil
    modData[PROTECTED_UNTIL_KEY] = nil
end

local function onPlayerMove(player)
    if not player or player:isDead() or player:getVehicle() then return end

    local state = getScanState(player)
    if state.radius <= 0 or state.abandoning then return end

    state.movementVersion = state.movementVersion + 1
    if not state.movementRequested then
        state.movementRequested = true
        state.movementDueAtMs = getTimeMs() + MOVEMENT_SETTLE_MS
    end
    enqueueState(state)
end

local function onUpgradeLevelChanged(player, upgradeId, _, newLevel)
    if upgradeId ~= UPGRADE_ID or not player then return end

    local state = getScanState(player)
    state.radius = getPickupRadiusForLevel(newLevel)
    state.lastMovementX = nil
    state.lastMovementY = nil
    state.lastMovementZ = nil
    state.movementCursor = nil

    if state.radius <= 0 then
        markStateAbandoned(state)
        if hasStateWork(state) then enqueueState(state) end
    end
end

UpgradeEvents.OnLevelChanged.Add(onUpgradeLevelChanged)
Events.OnZombieDead.Add(onZombieDead)
Events.OnPlayerMove.Add(onPlayerMove)

return AutomaticCorePickup
