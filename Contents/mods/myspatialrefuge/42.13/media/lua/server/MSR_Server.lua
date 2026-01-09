-- Explicit core module loading for dedicated server compatibility
-- On dedicated servers, automatic directory scanning may not complete before server code runs
require "shared/00_core/00_MSR"
require "shared/00_core/01_KahluaCompat"
require "shared/00_core/02_Logging"
require "shared/00_core/03_Difficulty"
require "shared/00_core/04_Env"

require "shared/00_core/05_Config"
require "shared/MSR_Shared"
require "shared/00_core/06_Data"
require "shared/MSR_Validation"
require "shared/MSR_Migration"
require "shared/MSR_UpgradeData"
require "shared/MSR_Transaction"
require "shared/MSR_Integrity"
require "shared/MSR_UpgradeLogic"
require "shared/MSR_ReadingSpeed"
require "shared/MSR_RoomPersistence"
require "shared/MSR_RefugeExpansion"
require "shared/MSR_ZombieClear"

MSR_Server = MSR_Server or {}

local _serverRelicContainerCache = {}
local CACHE_DURATION = 5

-- Pending upgrade tracking for duplicate request protection
local pendingUpgrades = {}  -- Key: "username_upgradeId" -> timestamp
local PENDING_TIMEOUT = 10  -- seconds

-- Completion cooldown - prevents rapid-fire upgrades
local upgradeCompletionTimes = {}  -- Key: "username_upgradeId" -> timestamp
local COMPLETION_COOLDOWN = 1  -- seconds

function MSR_Server.InvalidateRelicContainerCacheForUser(username)
    if username then
        _serverRelicContainerCache[username] = nil
    end
end

function MSR_Server.GetRelicContainer(player, bypassCache)
    if not player then return nil end
    
    local username = nil
    if player.getUsername then
        local ok, name = pcall(function() return player:getUsername() end)
        if ok then username = name end
    end
    if not username then return nil end
    
    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
    if not refugeData then return nil end
    
    local now = getTimestamp and getTimestamp() or 0
    local refugeId = refugeData.refugeId
    
    if not bypassCache then
        local cached = _serverRelicContainerCache[username]
        if cached and cached.refugeId == refugeId and (now - cached.cacheTime) < CACHE_DURATION then
            return cached.container
        end
    end
    local relicX = refugeData.relicX or refugeData.centerX
    local relicY = refugeData.relicY or refugeData.centerY
    local relicZ = refugeData.relicZ or refugeData.centerZ or 0
    local radius = refugeData.radius or 1
    
    local relic = MSR.Shared.FindRelicInRefuge(relicX, relicY, relicZ, radius, refugeId)
    if not relic then 
        _serverRelicContainerCache[username] = nil
        return nil 
    end
    
    local container = nil
    if relic.getContainer then
        container = relic:getContainer()
    end
    
    _serverRelicContainerCache[username] = {
        container = container,
        refugeId = refugeId,
        cacheTime = now
    }
    
    return container
end

local lastRequestTime = {}
local REQUEST_COOLDOWN = 2

local serverCooldowns = {
    teleport = {},
    relicMove = {}
}

local function getServerTimestamp()
    return K.time()
end

local function checkTeleportCooldown(username)
    local lastTeleport = serverCooldowns.teleport[username] or 0
    local now = getServerTimestamp()
    local cooldown = MSR.Config.getTeleportCooldown()
    local remaining = cooldown - (now - lastTeleport)
    
    if remaining > 0 then
        return false, math.ceil(remaining)
    end
    return true, 0
end

local function updateTeleportCooldown(username, penaltySeconds)
    penaltySeconds = penaltySeconds or 0
    -- Store current time + penalty (same logic as client)
    -- This makes cooldown check: (now + penalty) + cooldown from now
    serverCooldowns.teleport[username] = getServerTimestamp() + penaltySeconds
    
    if penaltySeconds > 0 then
        L.debug("Server", "Applied encumbrance penalty for " .. username .. ": " .. penaltySeconds .. "s")
    end
end

-- Calculate encumbrance penalty for a player (server-side)
-- Penalty is always enabled and scaled by difficulty via D.negativeValue()
local function getEncumbrancePenalty(player)
    if not player then return 0 end
    
    -- Use the shared validation function (applies difficulty scaling)
    local penalty = MSR.Validation.GetEncumbrancePenalty(player)
    return penalty
end

local function checkRelicMoveCooldown(username)
    local lastMove = serverCooldowns.relicMove[username] or 0
    local now = getServerTimestamp()
    local cooldown = MSR.Config.RELIC_MOVE_COOLDOWN or 120
    local remaining = cooldown - (now - lastMove)
    
    if remaining > 0 then
        return false, math.ceil(remaining)
    end
    return true, 0
end

local function updateRelicMoveCooldown(username)
    serverCooldowns.relicMove[username] = getServerTimestamp()
end

local function canProcessRequest(player)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    local now = getTimestamp and getTimestamp() or K.time()
    
    if lastRequestTime[username] and now - lastRequestTime[username] < REQUEST_COOLDOWN then
        return false
    end
    
    lastRequestTime[username] = now
    return true
end

-----------------------------------------------------------
-- ID-Based Item Consumption (Server-Authoritative)
-- Uses game-aligned patterns from ISTransferAction, ISCraftAction
-----------------------------------------------------------

-- Consume specific items by ID with network sync
-- @param player: The player whose items to consume
-- @param lockedItemIds: Table of {itemType = {itemId1, itemId2, ...}}
-- @return: true if all items consumed, false if any item not found
local function consumeItemsByIds(player, lockedItemIds)
    if not player or not lockedItemIds then return false end
    
    -- Only need ROOT containers - getItemById searches recursively through nested containers
    -- This is more efficient than iterating all nested containers
    local sources = {}
    local inv = MSR.safePlayerCall(player, "getInventory")
    if inv then table.insert(sources, inv) end
    
    -- Sacred Relic container (if available)
    local getRelicContainer = MSR.GetRelicContainer or (MSR_Server and MSR_Server.GetRelicContainer)
    if getRelicContainer then
        local rc = getRelicContainer(player, true)
        if rc then table.insert(sources, rc) end
    end
    
    if #sources == 0 then 
        L.debug("Server", "[DEBUG] consumeItemsByIds: No item sources found")
        return false 
    end
    
    L.debug("Server", "[DEBUG] consumeItemsByIds: Processing " .. K.count(lockedItemIds) .. " item types from " .. #sources .. " root sources")
    
    local totalConsumed = 0
    local totalExpected = 0
    
    for itemType, itemIds in pairs(lockedItemIds) do
        L.debug("Server", "[DEBUG] consumeItemsByIds: Processing " .. #itemIds .. " IDs for " .. itemType)
        totalExpected = totalExpected + #itemIds
        
        for _, targetId in ipairs(itemIds) do
            local found = false
            
            for _, container in ipairs(sources) do
                if not container then break end
                
                -- Use getItemById for fast lookup (game pattern from ISCraftAction, ISMoveableCursor)
                -- Note: getItemById searches recursively through nested containers
                local item = container:getItemById(targetId)
                
                if item then
                    -- Get the ACTUAL container the item is in (may be nested - bag inside inventory)
                    -- getItemById finds items recursively, so item may not be directly in 'container'
                    local actualContainer = item:getContainer()
                    if not actualContainer then
                        L.debug("Server", "[DEBUG] consumeItemsByIds: Item " .. targetId .. " has no container (orphaned)")
                        break
                    end
                    
                    -- Verify item still in its actual container (game pattern from ISInventoryTransferAction:85)
                    if not actualContainer:contains(item) then
                        L.debug("Server", "[DEBUG] consumeItemsByIds: Item " .. targetId .. " found but not in actual container (race condition)")
                        break
                    end
                    
                    -- Verify item type matches (safety check)
                    if item:getFullType() ~= itemType then
                        L.debug("Server", "[DEBUG] consumeItemsByIds: Item " .. targetId .. " type mismatch: expected " .. itemType .. ", got " .. item:getFullType())
                        break
                    end
                    
                    L.debug("Server", "[DEBUG] consumeItemsByIds: Consuming item " .. targetId .. " (" .. itemType .. ") from " .. tostring(actualContainer:getType()))
                    
                    -- Use DoRemoveItem for proper removal (game pattern from ISTransferAction:98)
                    actualContainer:DoRemoveItem(item)
                    
                    -- Sync removal to clients (game pattern from ISTransferAction:99-101)
                    sendRemoveItemFromContainer(actualContainer, item)
                    
                    found = true
                    totalConsumed = totalConsumed + 1
                    break
                end
            end
            
            if not found then
                L.debug("Server", "[DEBUG] consumeItemsByIds: Item " .. targetId .. " (" .. itemType .. ") NOT FOUND - may have been moved/consumed")
                -- Don't fail immediately - continue processing other items
                -- Final success is determined by total consumed count
            end
        end
    end
    
    L.debug("Server", "[DEBUG] consumeItemsByIds: Consumed " .. totalConsumed .. "/" .. totalExpected .. " items")
    
    return totalConsumed == totalExpected
end

function MSR_Server.ValidateRefugeAccess(player, refugeId)
    return MSR.Validation.ValidateRefugeAccess(player, refugeId)
end

function MSR_Server.CanPlayerEnterRefuge(player)
    return MSR.Validation.CanEnterRefuge(player)
end

function MSR_Server.HandleModDataRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    L.debug("Server", "ModData request from " .. username)
    
    if MSR.Migration.NeedsMigration(player) then
        MSR.Migration.MigratePlayer(player)
    end
    
    local refugeData = MSR.Data.GetOrCreateRefugeData(player)
    if not refugeData then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            message = "Failed to get or create refuge data"
        })
        return
    end
    
    local returnPos = MSR.Data.GetReturnPositionByUsername(username)
    
    L.debug("Server", "Sending ModData to " .. username .. ": refuge at " .. 
          refugeData.centerX .. "," .. refugeData.centerY .. " tier " .. refugeData.tier)
    
    sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.MODDATA_RESPONSE, {
        refugeData = MSR.Data.SerializeRefugeData(refugeData),
        returnPosition = returnPos
    })
    
    MSR.Data.TransmitModData()
end

function MSR_Server.HandleEnterRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    local canTeleport, remaining = checkTeleportCooldown(username)
    if not canTeleport then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = "IGUI_PortalCharging",
            messageArgs = { remaining }
        })
        return
    end
    
    local canEnter, reason = MSR_Server.CanPlayerEnterRefuge(player)
    if not canEnter then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            message = reason
        })
        return
    end
    
    local refugeData = MSR.Data.GetOrCreateRefugeData(player)
    if not refugeData then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            message = "Failed to create refuge data"
        })
        return
    end
    
    -- Handle vehicle data - only accept if player has vehicle_teleport upgrade
    local acceptVehicleData = false
    if args and args.fromVehicle and args.vehicleId then
        -- Server-side validation: check upgrade ownership (anti-cheat)
        if refugeData.upgrades then
            local vehicleTeleportLevel = refugeData.upgrades[MSR.Config.UPGRADES.VEHICLE_TELEPORT] or 0
            acceptVehicleData = vehicleTeleportLevel >= 1
        end
        
        if not acceptVehicleData then
            L.debug("Server", "Client sent vehicle data but doesn't have upgrade - ignoring")
        else
            L.debug("Server", string.format("Accepting vehicle data: id=%s seat=%s", 
                tostring(args.vehicleId), tostring(args.vehicleSeat)))
        end
    end
    
    -- Save return position (with or without vehicle data)
    if args and args.returnX and args.returnY and args.returnZ then
        if acceptVehicleData then
            MSR.Data.SaveReturnPositionWithVehicle(username, args.returnX, args.returnY, args.returnZ,
                args.vehicleId, args.vehicleSeat, args.vehicleX, args.vehicleY, args.vehicleZ)
        else
            MSR.Data.SaveReturnPositionByUsername(username, args.returnX, args.returnY, args.returnZ)
        end
    end
    
    L.debug("Server", "Phase 1: Sending TeleportTo for " .. username)
    
    -- Calculate encumbrance penalty BEFORE teleport (weight may change after)
    local encumbrancePenalty = getEncumbrancePenalty(player)
    updateTeleportCooldown(username, encumbrancePenalty)
    
    sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.TELEPORT_TO, {
        centerX = refugeData.centerX,
        centerY = refugeData.centerY,
        centerZ = refugeData.centerZ,
        tier = refugeData.tier,
        radius = refugeData.radius,
        refugeId = refugeData.refugeId,
        encumbrancePenalty = encumbrancePenalty
    })
end

function MSR_Server.HandleChunksReady(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Get refuge data
    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
    if not refugeData then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            message = "No refuge data found"
        })
        return
    end
    
    L.debug("Server", "Phase 2: Waiting for server chunks to load for " .. username)
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local playerRef = player
    local usernameRef = username
    local refugeDataRef = refugeData
    local tickCount = 0
    local maxTicks = 300  -- 5 seconds max
    local generated = false
    
    local function waitForServerChunks()
        tickCount = tickCount + 1
        
        local playerValid = false
        if playerRef then
            local ok, result = pcall(function() return playerRef:getUsername() end)
            playerValid = ok and result ~= nil
        end
        
        if not playerValid then
            Events.OnTick.Remove(waitForServerChunks)
            L.debug("Server", "Player disconnected during chunk wait for " .. tostring(usernameRef))
            return
        end
        
        local cell = getCell()
        if not cell then return end
        
        local allChunksLoaded = true
        local cornerOffsets = {
            {0, 0},      -- Center
            {-radius, -radius},  -- NW corner
            {radius, -radius},   -- NE corner  
            {-radius, radius},   -- SW corner
            {radius, radius}     -- SE corner
        }
        
        for _, offset in ipairs(cornerOffsets) do
            local checkX = centerX + offset[1]
            local checkY = centerY + offset[2]
            local square = cell:getGridSquare(checkX, checkY, centerZ)
            if not square then
                allChunksLoaded = false
                break
            end
            local chunk = square:getChunk()
            if not chunk then
                allChunksLoaded = false
                break
            end
        end
        
        if allChunksLoaded and not generated then
            generated = true
            Events.OnTick.Remove(waitForServerChunks)
            
            L.debug("Server", "All refuge chunks loaded after " .. tickCount .. " ticks for " .. usernameRef)
            
            -- Server-side: Restore room IDs from saved ModData
            -- This must happen on server for multiplayer to work correctly
            if MSR.RoomPersistence and MSR.RoomPersistence.RestoreServer then
                local restored = MSR.RoomPersistence.RestoreServer(refugeDataRef)
                if restored > 0 then
                    L.debug("Server", string.format("Restored %d room IDs from ModData (server-side)", restored))
                end
            end
            
            -- Quick check: if relic exists, refuge is already generated - skip full integrity check
            -- Only do full check if relic is missing (recovery scenario) or first generation
            local quickRelicCheck = MSR.Shared.FindRelicInRefuge(
                refugeDataRef.centerX, refugeDataRef.centerY, refugeDataRef.centerZ,
                refugeDataRef.radius or 1, refugeDataRef.refugeId
            )
            
            if not quickRelicCheck then
                -- Relic missing - need full setup (recovery scenario)
                L.debug("Server", "Relic missing - running EnsureRefugeStructures")
                MSR.Shared.EnsureRefugeStructures(refugeDataRef, playerRef)
            else
                -- Relic exists - refuge is already generated, skip integrity check on normal entry
                -- Only clear zombies that may have spawned
                L.debug("Server", "Refuge already generated - skipping integrity check")
                MSR.Shared.ClearZombiesFromArea(
                    refugeDataRef.centerX, refugeDataRef.centerY, refugeDataRef.centerZ,
                    refugeDataRef.radius or 1, true, playerRef
                )
            end
            
            -- Simple square recalculation for visibility/lighting updates
            -- Room IDs were already restored by RoomPersistence.RestoreServer() above
            -- We only need a single RecalcAllWithNeighbours pass for proper rendering
            local recalcTickCount = 0
            local RECALC_DELAY_TICKS = 60  -- 1 second delay for chunks to fully initialize
            local function delayedBuildingRecalc()
                recalcTickCount = recalcTickCount + 1
                if recalcTickCount < RECALC_DELAY_TICKS then return end
                
                Events.OnTick.Remove(delayedBuildingRecalc)
                
                local cell = getCell()
                if not cell then return end
                
                local centerX = refugeDataRef.centerX
                local centerY = refugeDataRef.centerY
                local centerZ = refugeDataRef.centerZ
                local radius = refugeDataRef.radius or 1
                local recalculated = 0
                
                -- Single pass: RecalcAllWithNeighbours for visibility/lighting
                for x = centerX - radius - 1, centerX + radius + 1 do
                    for y = centerY - radius - 1, centerY + radius + 1 do
                        local square = cell:getGridSquare(x, y, centerZ)
                        if square and square:getChunk() then
                            square:RecalcAllWithNeighbours(true)
                            recalculated = recalculated + 1
                        end
                    end
                end
                
                L.debug("Server", "Recalculated " .. recalculated .. " squares for visibility")
            end
            Events.OnTick.Add(delayedBuildingRecalc)
            
            -- Room IDs are saved by client on exit, synced to server for persistence
            -- No periodic save needed - game handles room discovery properly
            
            MSR.Data.TransmitModData()
            
            if L.isDebug() then
                local registry = MSR.Data.GetRefugeRegistry()
                local count = 0
                if registry then
                    for k, v in pairs(registry) do
                        count = count + 1
                        L.debug("Server", "ModData contains refuge: " .. tostring(k))
                    end
                end
                L.debug("Server", "Total refuges in ModData: " .. count)
            end
            
            sendServerCommand(playerRef, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.GENERATION_COMPLETE, {
                centerX = refugeDataRef.centerX,
                centerY = refugeDataRef.centerY,
                centerZ = refugeDataRef.centerZ,
                tier = refugeDataRef.tier,
                radius = refugeDataRef.radius,
                roomIds = refugeDataRef.roomIds  -- Include roomIds for cutaway fix in MP
            })
            
            L.debug("Server", "Phase 2 complete: Sent GenerationComplete to " .. usernameRef)
        end
        
        if tickCount >= maxTicks and not generated then
            Events.OnTick.Remove(waitForServerChunks)
            
            L.debug("Server", "Timeout waiting for server chunks for " .. usernameRef)
            
            sendServerCommand(playerRef, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
                message = "Server could not load refuge area"
            })
        end
    end
    
    Events.OnTick.Add(waitForServerChunks)
end

function MSR_Server.HandleExitRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- No cooldown check on exit - player can always leave refuge
    -- Cooldown only applies to ENTERING the refuge
    
    local returnPos = MSR.Data.GetReturnPositionByUsername(username)
    
    if not returnPos then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            message = "Return position not found"
        })
        return
    end
    
    -- Server-side: Save room IDs before player exits
    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
    if refugeData and MSR.RoomPersistence and MSR.RoomPersistence.SaveServerOnExit then
        MSR.RoomPersistence.SaveServerOnExit(refugeData)
    end
    
    -- Don't update cooldown on exit - preserve the penalty from enter
    MSR.Data.ClearReturnPositionByUsername(username)
    
    -- Build response with vehicle data if present
    local response = {
        returnX = returnPos.x,
        returnY = returnPos.y,
        returnZ = returnPos.z
    }
    
    -- Include vehicle data only if it was saved (nil otherwise)
    if returnPos.fromVehicle then
        response.fromVehicle = returnPos.fromVehicle
        response.vehicleId = returnPos.vehicleId
        response.vehicleSeat = returnPos.vehicleSeat
        response.vehicleX = returnPos.vehicleX
        response.vehicleY = returnPos.vehicleY
        response.vehicleZ = returnPos.vehicleZ
        L.debug("Server", string.format("Including vehicle data in exit: id=%s seat=%s pos=%.1f,%.1f,%.1f", 
            tostring(returnPos.vehicleId), tostring(returnPos.vehicleSeat),
            returnPos.vehicleX or 0, returnPos.vehicleY or 0, returnPos.vehicleZ or 0))
    end
    
    sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.EXIT_READY, response)
    
    L.debug("Server", "Sent ExitReady to " .. username)
end

function MSR_Server.HandleMoveRelicRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    local canMove, remaining = checkRelicMoveCooldown(username)
    if not canMove then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = "IGUI_CannotMoveRelicYet",
            messageArgs = { remaining }
        })
        return
    end
    
    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
    if not refugeData then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = "IGUI_MoveRelic_NoRefugeData"
        })
        return
    end
    
    local cornerDx = args and args.cornerDx or 0
    local cornerDy = args and args.cornerDy or 0
    local cornerName = args and args.cornerName or "Unknown"
    
    local isValid, sanitizedDx, sanitizedDy = MSR.Validation.ValidateCornerOffset(cornerDx, cornerDy)
    if not isValid then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = "IGUI_MoveRelic_DestinationBlocked"
        })
        return
    end
    cornerDx = sanitizedDx
    cornerDy = sanitizedDy
    
    print("[MSR_Server] HandleMoveRelicRequest: " .. username .. " -> " .. cornerName)
    print("[MSR_Server]   cornerDx=" .. tostring(cornerDx) .. " cornerDy=" .. tostring(cornerDy))
    print("[MSR_Server]   refugeData: center=" .. refugeData.centerX .. "," .. refugeData.centerY .. " radius=" .. refugeData.radius)
    
    local targetX = refugeData.centerX + (cornerDx * refugeData.radius)
    local targetY = refugeData.centerY + (cornerDy * refugeData.radius)
    print("[MSR_Server]   Target position: " .. targetX .. "," .. targetY)
    
    local success, errorCode = MSR.Shared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName)
    
    print("[MSR_Server]   MoveRelic result: success=" .. tostring(success) .. " errorCode=" .. tostring(errorCode))
    
    if success then
        updateRelicMoveCooldown(username)
        
        refugeData.relicX = targetX
        refugeData.relicY = targetY
        refugeData.relicZ = refugeData.centerZ
        MSR.Data.SaveRefugeData(refugeData)
        
        L.debug("Server", "Saved relic position to ModData: " .. targetX .. "," .. targetY)
        
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.MOVE_RELIC_COMPLETE, {
            cornerName = cornerName,
            cornerDx = cornerDx,
            cornerDy = cornerDy,
            refugeData = MSR.Data.SerializeRefugeData(refugeData)
        })
        
        L.debug("Server", "Moved relic for " .. username .. " to " .. cornerName)
    else
        local translationKey = MSR.Shared.GetMoveRelicTranslationKey(errorCode)
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = translationKey
        })
    end
end

function MSR_Server.HandleFeatureUpgradeRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Extract args
    local upgradeId = args and args.upgradeId
    local targetLevel = args and args.targetLevel
    local transactionId = args and args.transactionId
    local lockedItemIds = args and args.lockedItemIds
    
    -- Reused for pending checks and completion recording
    local lockKey = upgradeId and (username .. "_" .. upgradeId) or nil
    local now = K.time()
    
    local function clearPendingLock()
        if lockKey then
            pendingUpgrades[lockKey] = nil
        end
    end
    
    L.debug("Server", "HandleFeatureUpgradeRequest: " .. username .. 
          " upgradeId=" .. tostring(upgradeId) .. " targetLevel=" .. tostring(targetLevel))
    
    -- Duplicate request protection
    if lockKey then
        if pendingUpgrades[lockKey] then
            local elapsed = now - pendingUpgrades[lockKey]
            if elapsed < PENDING_TIMEOUT then
                L.debug("Server", "Rejecting duplicate upgrade request for " .. lockKey .. " (elapsed: " .. elapsed .. "s)")
                sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                    transactionId = transactionId,
                    reason = "UPGRADE_ALREADY_PROCESSING"
                })
                return
            end
            -- Expired lock - will be overwritten below
        end
        
        -- Completion cooldown check
        local completionTime = upgradeCompletionTimes[lockKey]
        if completionTime then
            local timeSinceComplete = now - completionTime
            if timeSinceComplete < COMPLETION_COOLDOWN then
                L.debug("Server", "Rejecting upgrade request for " .. lockKey .. " (cooldown: " .. string.format("%.1f", timeSinceComplete) .. "s)")
                sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                    transactionId = transactionId,
                    reason = "UPGRADE_COOLDOWN"
                })
                return
            end
            -- Cooldown expired - clear stale entry
            upgradeCompletionTimes[lockKey] = nil
        end
        
        -- Set pending lock
        pendingUpgrades[lockKey] = now
    end
    
    if lockedItemIds and not K.isEmpty(lockedItemIds) then
        L.debug("Server", "HandleFeatureUpgradeRequest: Received lockedItemIds with " .. K.count(lockedItemIds) .. " item types")
        for itemType, ids in pairs(lockedItemIds) do
            L.debug("Server", "  " .. itemType .. ": " .. #ids .. " items")
        end
    else
        L.debug("Server", "[DEBUG] HandleFeatureUpgradeRequest: No lockedItemIds received, will use type-based consumption")
    end
    
    if not upgradeId or not targetLevel then
        clearPendingLock()
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Invalid upgrade request"
        })
        return
    end
    
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    if not upgrade then
        clearPendingLock()
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Unknown upgrade: " .. tostring(upgradeId)
        })
        return
    end
    
    if not MSR.UpgradeData.isUpgradeUnlocked(player, upgradeId) then
        clearPendingLock()
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Dependencies not met"
        })
        return
    end
    
    local currentLevel = MSR.UpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    
    if targetLevel <= currentLevel then
        clearPendingLock()
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Already at this level"
        })
        return
    end
    
    if targetLevel > currentLevel + 1 then
        clearPendingLock()
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Must upgrade one level at a time"
        })
        return
    end
    
    if targetLevel > upgrade.maxLevel then
        clearPendingLock()
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Exceeds max level"
        })
        return
    end
    
    -- Use getNextLevelRequirements for difficulty-scaled costs
    local requirements = MSR.UpgradeData.getNextLevelRequirements(player, upgradeId) or {}
    
    if #requirements > 0 then
        for _, req in ipairs(requirements) do
            local itemType = req.type
            local needed = req.count or 1
            
            local available = MSR.Transaction.GetMultiSourceCount(player, itemType)
            
            if available < needed and req.substitutes then
                for _, subType in ipairs(req.substitutes) do
                    available = available + MSR.Transaction.GetMultiSourceCount(player, subType)
                    if available >= needed then break end
                end
            end
            
            if available < needed then
                local itemName = itemType:match("%.(.+)$") or itemType
                clearPendingLock()
                sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                    transactionId = transactionId,
                    reason = "Not enough " .. itemName
                })
                return
            end
        end
    end
    
    if #requirements > 0 then
        local consumed = false
        
        -- Prefer ID-based consumption (more precise, prevents wrong item consumption)
        if lockedItemIds and not K.isEmpty(lockedItemIds) then
            L.debug("Server", "[DEBUG] HandleFeatureUpgradeRequest: Using ID-based consumption")
            consumed = consumeItemsByIds(player, lockedItemIds)
            
            if not consumed then
                L.debug("Server", "[DEBUG] HandleFeatureUpgradeRequest: ID-based consumption failed, some items may have been moved")
            end
        else
            -- Fallback to type-based consumption (backwards compatibility)
            L.debug("Server", "[DEBUG] HandleFeatureUpgradeRequest: Using type-based consumption (fallback)")
            consumed = MSR.UpgradeLogic.consumeItems(player, requirements)
        end
        
        if not consumed then
            L.debug("Server", "HandleFeatureUpgradeRequest: Failed to consume items for " .. username)
            clearPendingLock()
            sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                transactionId = transactionId,
                reason = "Failed to consume required items"
            })
            return
        end
        L.debug("Server", "HandleFeatureUpgradeRequest: Consumed items for " .. tostring(upgradeId))
    end
    
    -- Use handler pattern for upgrades with special logic
    local handler = MSR.UpgradeLogic.getHandler(upgradeId)
    local success, errorMsg, resultData = true, nil, nil
    
    if handler then
        success, errorMsg, resultData = handler.apply(player, targetLevel)
    else
        -- Generic upgrade: just set level
        MSR.UpgradeData.setPlayerUpgradeLevel(player, upgradeId, targetLevel)
    end
    
    if not success then
        L.debug("Server", upgradeId .. ": FAILED - " .. tostring(errorMsg))
        clearPendingLock()
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = errorMsg or "Upgrade failed"
        })
        return
    end
    
    L.debug("Server", "Feature upgrade: " .. username .. " upgraded " .. upgradeId .. " to level " .. targetLevel)
    
    -- Build response with common fields
    local refugeData = MSR.Data.GetRefugeData(player)
    local response = {
        transactionId = transactionId,
        upgradeId = upgradeId,
        newLevel = targetLevel,
        refugeData = MSR.Data.SerializeRefugeData(refugeData)
    }
    
    -- Add handler-specific response data (e.g., expansion needs center/radius for client cleanup)
    if handler and handler.getResponseData then
        local extraData = handler.getResponseData(refugeData, resultData)
        if extraData then
            for k, v in pairs(extraData) do
                response[k] = v
            end
        end
    end
    
    -- Record completion time for cooldown
    if lockKey then
        upgradeCompletionTimes[lockKey] = now
    end
    clearPendingLock()
    sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_COMPLETE, response)
end

-----------------------------------------------------------
-- Client Command Handler
-----------------------------------------------------------

-- Main command dispatcher
local function OnClientCommand(module, command, player, args)
    -- Only handle our namespace
    if module ~= MSR.Config.COMMAND_NAMESPACE then return end
    
    -- Some commands are exempt from rate limiting
    -- Feature upgrades use transaction IDs and level validation for protection
    local isExemptFromRateLimit = (
        command == MSR.Config.COMMANDS.CHUNKS_READY or
        command == MSR.Config.COMMANDS.REQUEST_MODDATA or
        command == MSR.Config.COMMANDS.REQUEST_FEATURE_UPGRADE
    )
    
    if not isExemptFromRateLimit and not canProcessRequest(player) then
        L.debug("Server", "Rate limited request from " .. tostring(player:getUsername()))
        return
    end
    
    -- Dispatch to appropriate handler
    if command == MSR.Config.COMMANDS.REQUEST_MODDATA then
        MSR_Server.HandleModDataRequest(player, args)
    elseif command == MSR.Config.COMMANDS.REQUEST_ENTER then
        MSR_Server.HandleEnterRequest(player, args)
    elseif command == MSR.Config.COMMANDS.CHUNKS_READY then
        MSR_Server.HandleChunksReady(player, args)
    elseif command == MSR.Config.COMMANDS.REQUEST_EXIT then
        MSR_Server.HandleExitRequest(player, args)
    elseif command == MSR.Config.COMMANDS.REQUEST_MOVE_RELIC then
        MSR_Server.HandleMoveRelicRequest(player, args)
    elseif command == MSR.Config.COMMANDS.REQUEST_FEATURE_UPGRADE then
        MSR_Server.HandleFeatureUpgradeRequest(player, args)
    elseif command == MSR.Config.COMMANDS.SYNC_CLIENT_DATA then
        -- Handle client data sync (roomIds, etc.)
        -- In MP, clients can't write to ModData - server acts as data store
        if MSR.RoomPersistence and MSR.RoomPersistence.HandleSyncFromClient then
            MSR.RoomPersistence.HandleSyncFromClient(player, args)
        end
    else
        L.debug("Server", "Unknown command: " .. tostring(command))
    end
end

local function areRefugeChunksLoaded(refugeData)
    local cell = getCell()
    if not cell then return false end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    
    -- Check all corners and center
    local checkPoints = {
        {0, 0},           -- Center
        {-radius, -radius}, -- NW
        {radius, -radius},  -- NE
        {-radius, radius},  -- SW
        {radius, radius}    -- SE
    }
    
    for _, offset in ipairs(checkPoints) do
        local x = centerX + offset[1]
        local y = centerY + offset[2]
        local square = cell:getGridSquare(x, y, centerZ)
        if not square then return false end
        local chunk = square:getChunk()
        if not chunk then return false end
    end
    
    return true
end

function MSR_Server.CheckAndRecoverStrandedPlayer(player)
    if not player then return end
    
    -- Check if player is at refuge coordinates
    if not MSR.Data.IsPlayerInRefugeCoords(player) then
        return  -- Not in refuge area, nothing to do
    end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Get player's refuge data
    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
    if not refugeData then
        -- Player is in refuge coords but has no refuge data - unusual situation
        L.debug("Server", "Player " .. username .. " in refuge coords but no data found")
        return
    end
    
    -- CRITICAL: Wait for chunks to load before checking for structures
    -- Otherwise we might think structures are missing when they're just not loaded yet
    local playerRef = player
    local usernameRef = username
    local refugeDataRef = refugeData
    local tickCount = 0
    local maxTicks = 300  -- 5 seconds max wait
    local checked = false
    
    local function waitForChunksAndCheck()
        tickCount = tickCount + 1
        
        local playerValid = false
        if playerRef then
            local ok, result = pcall(function() return playerRef:getUsername() end)
            playerValid = ok and result ~= nil
        end
        
        if not playerValid then
            Events.OnTick.Remove(waitForChunksAndCheck)
            L.debug("Server", "Player disconnected during stranded check for " .. tostring(usernameRef))
            return
        end
        
        -- Check if chunks are loaded
        if not areRefugeChunksLoaded(refugeDataRef) then
            if tickCount >= maxTicks then
                Events.OnTick.Remove(waitForChunksAndCheck)
                L.debug("Server", "Timeout waiting for refuge chunks for " .. usernameRef)
            end
            return
        end
        
        if checked then return end
        checked = true
        Events.OnTick.Remove(waitForChunksAndCheck)
        
        L.debug("Server", "Chunks loaded for " .. usernameRef .. " after " .. tickCount .. " ticks, checking structures...")
        
        local hasRelic = MSR.Shared.FindRelicInRefuge(
            refugeDataRef.centerX, refugeDataRef.centerY, refugeDataRef.centerZ,
            refugeDataRef.radius, refugeDataRef.refugeId
        )
        
        if not hasRelic then
            L.debug("Server", "Regenerating structures for stranded player " .. usernameRef)
            MSR.Shared.EnsureRefugeStructures(refugeDataRef, playerRef)
        else
            L.debug("Server", "Structures intact for " .. usernameRef .. ", no regeneration needed")
        end
    end
    
    Events.OnTick.Add(waitForChunksAndCheck)
end

-- NOTE: Periodic zombie clearing is handled by MSR.ZombieClear module
-- It self-registers on EveryOneMinute for both client and server

local function OnPlayerDeathServer(player)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    if not MSR.Data.IsPlayerInRefugeCoords(player) then
        return
    end
    
    L.debug("Server", "Player " .. username .. " died in refuge")
    
    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
    local returnPos = MSR.Data.GetReturnPositionByUsername(username)
    
    if returnPos then
        local corpse = player:getCorpse()
        if corpse then
            corpse:setX(returnPos.x)
            corpse:setY(returnPos.y)
            corpse:setZ(returnPos.z)
            
            L.debug("Server", "Moved corpse to " .. returnPos.x .. "," .. returnPos.y)
        end
    end
    
    MSR.Data.DeleteRefugeData(player)
    MSR.Data.ClearReturnPositionByUsername(username)
    
    serverCooldowns.teleport[username] = nil
    serverCooldowns.relicMove[username] = nil
    
    L.debug("Server", "Cleaned up refuge data for " .. username)
end

local function OnServerStart()
    -- Defensive check: ensure core modules loaded properly
    if not MSR or not MSR.Data then
        print("[MSR] CRITICAL ERROR: Core modules failed to load!")
        print("[MSR] MSR=" .. tostring(MSR) .. ", MSR.Data=" .. tostring(MSR and MSR.Data))
        return
    end
    
    L.debug("Server", "Server initialized")
    
    MSR.Data.InitializeModData()
    MSR.Data.TransmitModData()
end

local function OnPlayerFullyConnected(player)
    if not player then return end
    if not MSR or not MSR.Data then return end
    
    local playerUsername = player:getUsername() or "unknown"
    
    L.debug("Server", "OnPlayerFullyConnected called for: " .. playerUsername)
    
    local tickCount = 0
    local function delayedTransmit()
        tickCount = tickCount + 1
        if tickCount < 30 then return end
        
        Events.OnTick.Remove(delayedTransmit)
        
        MSR.Data.TransmitModData()
        
        if L.isDebug() then
            L.debug("Server", "Transmitted ModData to " .. playerUsername)
            local registry = MSR.Data.GetRefugeRegistry()
            if registry then
                local count = 0
                for k, v in pairs(registry) do
                    count = count + 1
                end
                L.debug("Server", "ModData has " .. count .. " refuge entries")
            else
                L.debug("Server", "WARNING: Registry is nil!")
            end
        end
    end
    
    Events.OnTick.Add(delayedTransmit)
end

local function OnPlayerConnect(player)
    if not player then return end
    
    local username = player:getUsername() or "unknown"
    
    if MSR.Migration.NeedsMigration(player) then
        local success, message = MSR.Migration.MigratePlayer(player)
        if success then
            print("[MSR_Server] " .. username .. ": " .. message)
            MSR.Data.TransmitModData()
        end
    end
    
    L.debug("Server", "Player connected: " .. username)
end

Events.OnServerStarted.Add(OnServerStart)
Events.OnClientCommand.Add(OnClientCommand)
Events.OnPlayerDeath.Add(OnPlayerDeathServer)
-- NOTE: EveryOneMinute zombie clearing is handled by MSR.ZombieClear module

if Events.OnPlayerConnect then
    Events.OnPlayerConnect.Add(OnPlayerConnect)
    Events.OnPlayerConnect.Add(OnPlayerFullyConnected)
end

if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(function(playerIndex, player)
        if MSR.Env.isServer() then
            OnPlayerConnect(player)
            OnPlayerFullyConnected(player)
        end
    end)
end

L.debug("Server", "Server module loaded")

return MSR_Server
