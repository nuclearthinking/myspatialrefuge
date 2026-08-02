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
local Scheduler = MSR.Scheduler
local getPlayerUpgradeLevel = UpgradeData.getPlayerUpgradeLevel
local getLevelEffects = UpgradeData.getLevelEffects
local isInstanceOf = instanceof
local getCurrentCell = getCell
local getTime = getTimestamp
local getTimeMs = getTimestampMs
local haloTextHelper = HaloTextHelper

local CORE_ITEM = Config.CORE_ITEM or "Base.MagicalCore"
-- TextDrawObject 42.20 does not parse an image nested inside a color tag.
-- Build the tags in sequence and use HaloTextHelper's raw-text overload.
-- Halo notes allow arbitrary image paths, so use the same full-path form as
-- vanilla foraging; short-name item lookup does not resolve this mod texture.
local CORE_HALO_PREFIX = "[img=media/textures/item_ZombieCore_Halo.png]  [col=137,232,148]+"
local CORE_HALO_SUFFIX = "[/]"
local UPGRADE_ID = Config.UPGRADES.AUTOMATIC_CORE_PICKUP
local OWNER_KEY = "MSR_AutomaticCoreOwner"
local PROTECTED_UNTIL_KEY = "MSR_AutomaticCoreProtectedUntil"
local OWNER_PROTECTION_SECONDS = 30
local MIN_SCAN_INTERVAL_MS = 500
local MOVEMENT_SETTLE_MS = 100
local MAX_SCAN_RADIUS = 2

-- Cached per-player radius makes the common OnPlayerMove path an O(1) lookup.
-- Weak keys release state on disconnect without a permanent cleanup event.
local scanStateByPlayer = setmetatable({}, { __mode = "k" })

local function showPickupFeedback(player, collected)
    -- HaloTextHelper renders locally in SP and sends the built-in HaloText packet
    -- to the owning client in MP/dedicated. One aggregated message per successful
    -- collection avoids UI/network work for every individual core.
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

local function getScanState(player)
    local state = scanStateByPlayer[player]
    if state then return state end

    state = {
        radius = getPickupRadiusForLevel(getPlayerUpgradeLevel(player, UPGRADE_ID))
    }
    scanStateByPlayer[player] = state
    return state
end

local function getPickupRadius(player)
    return getScanState(player).radius
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

    -- The back slot is the default bag destination when no equipped container
    -- already holds a core. Remaining worn locations retain the game's stable
    -- WornItems order, followed by primary and secondary hand containers.
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

    -- Containers that already hold cores keep affinity while preserving the
    -- stable equipment order. Empty equipped containers follow afterwards.
    for index = 1, #withoutCore do
        withCore[#withCore + 1] = withoutCore[index]
    end

    -- The player's root inventory is always the final fallback, even when it
    -- already contains cores: an eligible equipped bag remains preferable.
    local playerInventory = player:getInventory()
    if playerInventory and playerInventory:hasRoomFor(player, coreItem) then
        withCore[#withCore + 1] = playerInventory
    end

    return withCore
end

local function transferCores(player, rootContainer, context, firstItem)
    local collected = 0
    local item = firstItem

    if not context.destinations then
        context.destinations = buildDestinationPlan(player, item)
        context.destinationIndex = 1
    end

    while item do
        local sourceContainer = item:getContainer()
        if not sourceContainer then break end

        local moved = false
        while context.destinationIndex <= #context.destinations do
            local destinationContainer = context.destinations[context.destinationIndex]
            if sourceContainer ~= destinationContainer
                and InventoryAuthority.moveItem(player, sourceContainer, destinationContainer, item)
            then
                moved = true
                break
            end

            -- A destination can fill while collecting a batch. Advance to the
            -- next equipped container and finally the root inventory.
            context.destinationIndex = context.destinationIndex + 1
        end

        if not moved then break end

        collected = collected + 1
        item = rootContainer:getFirstTypeRecurse(CORE_ITEM)
    end

    return collected, item
end

local function collectFromCorpse(player, corpse, context)
    local rootContainer = corpse:getContainer()
    if not rootContainer then return 0, context end

    -- The Java-side recursive lookup is cheaper than walking every corpse item
    -- through Lua. It also avoids creating ModData for coreless corpses.
    local firstCore = rootContainer:getFirstTypeRecurse(CORE_ITEM)
    if not firstCore then return 0, context end

    -- Most scanned corpses do not contain a core. Read the protection timestamp
    -- only after Java has found one, and at most once for the whole area scan.
    context = context or {}
    context.now = context.now or getTime()
    if not canCollectFromCorpse(player, corpse, context.now) then return 0, context end

    local collected = transferCores(player, rootContainer, context, firstCore)
    return collected, context
end

local function isObjectInRange(object, playerX, playerY, playerZ, radiusSquared)
    if object:getZ() ~= playerZ then return false end

    local deltaX = object:getX() - playerX
    local deltaY = object:getY() - playerY
    return deltaX * deltaX + deltaY * deltaY <= radiusSquared
end

local function onZombieDead(zombie)
    if not zombie then return end

    local rootContainer = zombie:getInventory()
    if not rootContainer then return end

    local firstCore = rootContainer:getFirstTypeRecurse(CORE_ITEM)
    if not firstCore then return end

    local killer = zombie:getAttackedBy()
    if killer and isInstanceOf(killer, "IsoPlayer") then
        local radius = getPickupRadius(killer)

        -- A new corpse is handled directly, so a stationary killer gets the core
        -- without starting a general area scan or a tick-based delayed task.
        if radius > 0 and not killer:getVehicle() then
            local killerX = killer:getX()
            local killerY = killer:getY()
            local killerZ = killer:getZ()
            if isObjectInRange(zombie, killerX, killerY, killerZ, radius * radius) then
                local collected, remainingCore = transferCores(killer, rootContainer, {}, firstCore)
                if collected > 0 then
                    showPickupFeedback(killer, collected)
                    LOG.debug("Collected %d new zombie core(s) for %s", collected, getPlayerLabel(killer))
                end

                if not remainingCore then return end
            end
        end

        local username = killer:getUsername()
        if username and username ~= "" then
            local modData = zombie:getModData()
            modData[OWNER_KEY] = username
            modData[PROTECTED_UNTIL_KEY] = getTime() + OWNER_PROTECTION_SECONDS
            LOG.debug("Reserved zombie core for %s for %d seconds", username, OWNER_PROTECTION_SECONDS)
            return
        end
    end

    local modData = zombie:getModData()
    modData[OWNER_KEY] = nil
    modData[PROTECTED_UNTIL_KEY] = nil
    LOG.debug("Zombie core has no player owner")
end

local function collectNearbyCores(player, radius, square)
    square = square or player:getCurrentSquare()
    if not square then return 0 end

    local cell = getCurrentCell()
    if not cell then return 0 end

    local centerX = square:getX()
    local centerY = square:getY()
    local centerZ = square:getZ()
    local playerX = player:getX()
    local playerY = player:getY()
    local playerZ = player:getZ()
    local radiusSquared = radius * radius
    local scanRadius = radius > 1 and MAX_SCAN_RADIUS or 1
    local context = nil
    local collected = 0

    for offsetX = -scanRadius, scanRadius do
        for offsetY = -scanRadius, scanRadius do
            local nearbySquare = cell:getGridSquare(centerX + offsetX, centerY + offsetY, centerZ)
            if nearbySquare then
                local corpses = nearbySquare:getDeadBodys()
                local corpseCount = corpses and corpses:size() or 0
                for index = 0, corpseCount - 1 do
                    local corpse = corpses:get(index)
                    if corpse and isObjectInRange(corpse, playerX, playerY, playerZ, radiusSquared) then
                        local corpseCollected
                        corpseCollected, context = collectFromCorpse(player, corpse, context)
                        collected = collected + corpseCollected
                    end
                end
            end
        end
    end

    return collected
end

local function processPlayerScan(player)
    if not player or not MSR.isPlayerValid(player) or player:isDead() or player:getVehicle() then return end

    local state = scanStateByPlayer[player]
    if not state or state.radius <= 0 then return end

    local square = player:getCurrentSquare()
    if not square then return end

    local squareX = square:getX()
    local squareY = square:getY()
    local squareZ = square:getZ()
    if state.x == squareX and state.y == squareY and state.z == squareZ then return end

    local nowMs = getTimeMs()
    local remainingLockMs = MIN_SCAN_INTERVAL_MS - (nowMs - (state.scannedAt or 0))
    if remainingLockMs > 0 then
        -- Keep the latest Java position pending. Movement events do not create
        -- additional tasks while this keyed task is waiting.
        Scheduler.coalesce(state.taskKey, remainingLockMs, processPlayerScan, player)
        return
    end

    state.x = squareX
    state.y = squareY
    state.z = squareZ
    state.scannedAt = nowMs

    local collected = collectNearbyCores(player, state.radius, square)
    if collected > 0 then
        showPickupFeedback(player, collected)
        LOG.debug(
            "Collected %d zombie core(s) for %s within %.1f tiles",
            collected,
            getPlayerLabel(player),
            state.radius
        )
    end
end

local function schedulePlayerScan(player, state, delayMs)
    if not state.taskKey then state.taskKey = {} end
    if Scheduler.isScheduled(state.taskKey) then return end

    Scheduler.coalesce(state.taskKey, delayMs, processPlayerScan, player)
end

local function onPlayerMove(player)
    if not player or player:getVehicle() then return end

    local state = getScanState(player)
    if state.radius <= 0 then return end

    -- OnPlayerMove may precede remote coordinate application. One short keyed
    -- delay coalesces same-tile movement and reads the final Java square later.
    schedulePlayerScan(player, state, MOVEMENT_SETTLE_MS)
end

local function onUpgradeLevelChanged(player, upgradeId, _, newLevel)
    if upgradeId ~= UPGRADE_ID or not player then return end

    local state = scanStateByPlayer[player]
    if not state then
        state = {}
        scanStateByPlayer[player] = state
    end
    state.radius = getPickupRadiusForLevel(newLevel)
    state.x = nil
    state.y = nil
    state.z = nil

    if state.radius <= 0 and state.taskKey then
        Scheduler.cancel(state.taskKey)
    end
end

UpgradeEvents.OnLevelChanged.Add(onUpgradeLevelChanged)
Events.OnZombieDead.Add(onZombieDead)
Events.OnPlayerMove.Add(onPlayerMove)

return AutomaticCorePickup
