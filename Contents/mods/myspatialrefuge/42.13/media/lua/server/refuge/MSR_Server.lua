-- Spatial Refuge Server Module
-- Server-side command handlers and generation for multiplayer persistence
-- Server generates refuge structures so they persist in map save

require "shared/MSR_Config"
require "shared/MSR_Shared"
require "shared/MSR_Data"
require "shared/MSR_Validation"
require "shared/MSR_Migration"
require "shared/MSR_UpgradeData"
require "shared/MSR_Transaction"
require "shared/MSR_Integrity"

MSR_Server = MSR_Server or {}


-----------------------------------------------------------
-- Shared helpers needed by shared code (server-side)
-----------------------------------------------------------

-- Relic container cache per player for server-side performance
-- Key: username, Value: {container, refugeId, cacheTime}
local _serverRelicContainerCache = {}
local CACHE_DURATION = 5  -- seconds

-- Invalidate server-side relic container cache for a player
function MSR.InvalidateRelicContainerCache(username)
    if username then
        _serverRelicContainerCache[username] = nil
    end
end

-- Get Sacred Relic container for a player (for item source access)
-- Returns: ItemContainer if found, nil otherwise
-- NOTE: Must exist on server so shared/SpatialRefugeTransaction can include relic storage in MP validation/consumption.
-- Uses caching to avoid expensive grid searches on every call
-- @param player: The player
-- @param bypassCache: (optional) If true, always do a fresh lookup (for transactions)
function MSR.GetRelicContainer(player, bypassCache)
    if not player then return nil end
    if not MSR.Data or not MSR.Data.GetRefugeDataByUsername then return nil end
    
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
    
    -- Check cache validity (skip if bypassCache is true - used for transactions)
    if not bypassCache then
        local cached = _serverRelicContainerCache[username]
        if cached and cached.refugeId == refugeId and (now - cached.cacheTime) < CACHE_DURATION then
            -- Cache hit
            return cached.container
        end
    end
    
    -- Cache miss or bypass - need to search for relic
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
    
    -- Update cache (even when bypassing, so next call benefits)
    _serverRelicContainerCache[username] = {
        container = container,
        refugeId = refugeId,
        cacheTime = now
    }
    
    return container
end

-----------------------------------------------------------
-- Server-Side State Tracking (authoritative, not client ModData)
-----------------------------------------------------------

-- Track last request time per player to prevent spam
local lastRequestTime = {}
local REQUEST_COOLDOWN = 2  -- seconds between requests

-- Server-authoritative cooldown tracking (prevents client manipulation)
local serverCooldowns = {
    teleport = {},     -- username -> timestamp
    relicMove = {}     -- username -> timestamp
}

-- Get current timestamp with fallback
local function getServerTimestamp()
    return getTimestamp and getTimestamp() or os.time()
end

-- Check server-side teleport cooldown
local function checkTeleportCooldown(username)
    local lastTeleport = serverCooldowns.teleport[username] or 0
    local now = getServerTimestamp()
    local cooldown = MSR.Config.TELEPORT_COOLDOWN or 60
    local remaining = cooldown - (now - lastTeleport)
    
    if remaining > 0 then
        return false, math.ceil(remaining)
    end
    return true, 0
end

-- Update server-side teleport cooldown
local function updateTeleportCooldown(username)
    serverCooldowns.teleport[username] = getServerTimestamp()
end

-- Check server-side relic move cooldown
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

-- Update server-side relic move cooldown
local function updateRelicMoveCooldown(username)
    serverCooldowns.relicMove[username] = getServerTimestamp()
end

-- Check if player can make a request (rate limiting)
local function canProcessRequest(player)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    local now = getTimestamp and getTimestamp() or os.time()
    
    if lastRequestTime[username] and now - lastRequestTime[username] < REQUEST_COOLDOWN then
        return false  -- Rate limited
    end
    
    lastRequestTime[username] = now
    return true
end

-----------------------------------------------------------
-- Validation Helpers
-- Note: Most validation logic is now in shared/MSR.Validation.lua
-----------------------------------------------------------

-- Validate player refuge access (security check)
-- Delegates to shared validation module
function MSR_Server.ValidateRefugeAccess(player, refugeId)
    return MSR.Validation.ValidateRefugeAccess(player, refugeId)
end

-- Check if player can enter refuge (validation)
-- Delegates to shared validation module
function MSR_Server.CanPlayerEnterRefuge(player)
    return MSR.Validation.CanEnterRefuge(player)
end

-----------------------------------------------------------
-- Request Handlers
-----------------------------------------------------------

-- Handle ModData Request - Client asking for their refuge data on connect
-- This is the authoritative source - server creates refuge if needed
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
    
    -- Get return position if any
    local returnPos = MSR.Data.GetReturnPositionByUsername(username)
    
    L.debug("Server", "Sending ModData to " .. username .. ": refuge at " .. 
          refugeData.centerX .. "," .. refugeData.centerY .. " tier " .. refugeData.tier)
    
    -- Send refuge data to client (using serialization helper for DRY)
    sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.MODDATA_RESPONSE, {
        refugeData = MSR.Data.SerializeRefugeData(refugeData),
        returnPosition = returnPos
    })
    
    -- Also transmit global ModData for good measure
    MSR.Data.TransmitModData()
end

-- Handle Enter Refuge Request - Phase 1
-- Two-phase approach for MP persistence:
-- Phase 1: Server sends TeleportTo, client teleports and waits for chunks
-- Phase 2: Client sends ChunksReady, server generates structures (chunks now loaded!)
function MSR_Server.HandleEnterRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Server-authoritative teleport cooldown check
    local canTeleport, remaining = checkTeleportCooldown(username)
    if not canTeleport then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = "IGUI_PortalCharging",
            messageArgs = { remaining }
        })
        return
    end
    
    -- Validate player can enter
    local canEnter, reason = MSR_Server.CanPlayerEnterRefuge(player)
    if not canEnter then
        -- Send error response
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            message = reason
        })
        return
    end
    
    -- Get or create refuge data
    local refugeData = MSR.Data.GetOrCreateRefugeData(player)
    if not refugeData then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            message = "Failed to create refuge data"
        })
        return
    end
    
    -- Save return position from args (validate it's not already in refuge)
    if args and args.returnX and args.returnY and args.returnZ then
        MSR.Data.SaveReturnPositionByUsername(username, args.returnX, args.returnY, args.returnZ)
    end
    
    L.debug("Server", "Phase 1: Sending TeleportTo for " .. username)
    
    -- Update server-side teleport cooldown
    updateTeleportCooldown(username)
    
    -- Phase 1: Tell client to teleport (no generation yet)
    -- Client will teleport, wait for chunks to load, then send ChunksReady
    sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.TELEPORT_TO, {
        centerX = refugeData.centerX,
        centerY = refugeData.centerY,
        centerZ = refugeData.centerZ,
        tier = refugeData.tier,
        radius = refugeData.radius,
        refugeId = refugeData.refugeId
    })
end

-- Handle ChunksReady - Phase 2
-- Client has teleported, now server needs to wait for ITS chunks to load
-- (Client chunks and ServerMap chunks are separate systems)
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
    
    -- Server needs to wait for its own chunks to load around the player
    -- Use tick-based waiting similar to client-side approach
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
        
        -- Check if player is still valid (use pcall to handle disconnected/invalid player objects)
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
        
        -- Check ALL corners of the refuge area to ensure all chunks are loaded
        -- This is critical because relic may have been moved to a corner
        -- and that corner could be in a different chunk than the center
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
            -- Only use getGridSquare - don't create empty cells
            -- If square doesn't exist, chunk isn't loaded yet
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
            
            -- Check if refuge needs repair/generation using lightweight integrity check
            local needsFullSetup = false
            if MSR.Integrity and MSR.Integrity.CheckNeedsRepair then
                needsFullSetup = MSR.Integrity.CheckNeedsRepair(refugeDataRef)
            else
                -- Fallback: always regenerate if integrity module not available
                needsFullSetup = true
            end
            
            if needsFullSetup then
                L.debug("Server", "Refuge needs setup/repair, running EnsureRefugeStructures")
                -- Full generation only when needed (first time or after corruption)
                MSR.Shared.EnsureRefugeStructures(refugeDataRef, playerRef)
            else
                L.debug("Server", "Refuge already set up, skipping full generation")
                -- Quick validation via integrity system (lighter than full regeneration)
                MSR.Integrity.ValidateAndRepair(refugeDataRef, {
                    source = "enter_server",
                    player = playerRef
                })
                -- Clear zombies that may have spawned
                MSR.Shared.ClearZombiesFromArea(
                    refugeDataRef.centerX, refugeDataRef.centerY, refugeDataRef.centerZ,
                    refugeDataRef.radius or 1, true, playerRef
                )
            end
            
            -- Transmit ModData to ensure client has refuge data for context menus
            MSR.Data.TransmitModData()
            
            if L.isDebug() then
                -- Log the ModData state for debugging
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
            
            -- Send confirmation to client
            sendServerCommand(playerRef, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.GENERATION_COMPLETE, {
                centerX = refugeDataRef.centerX,
                centerY = refugeDataRef.centerY,
                centerZ = refugeDataRef.centerZ,
                tier = refugeDataRef.tier,
                radius = refugeDataRef.radius
            })
            
            L.debug("Server", "Phase 2 complete: Sent GenerationComplete to " .. usernameRef)
        end
        
        -- Timeout
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

-- Handle Exit Refuge Request
function MSR_Server.HandleExitRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Server-authoritative teleport cooldown check (exit also uses teleport cooldown)
    local canTeleport, remaining = checkTeleportCooldown(username)
    if not canTeleport then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = "IGUI_PortalCharging",
            messageArgs = { remaining }
        })
        return
    end
    
    -- Get return position
    local returnPos = MSR.Data.GetReturnPositionByUsername(username)
    
    if not returnPos then
        -- No return position found - use default safe location
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            message = "Return position not found"
        })
        return
    end
    
    -- Update server-side teleport cooldown
    updateTeleportCooldown(username)
    
    -- Clear return position before sending response
    MSR.Data.ClearReturnPositionByUsername(username)
    
    -- Send success response with return coordinates
    sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.EXIT_READY, {
        returnX = returnPos.x,
        returnY = returnPos.y,
        returnZ = returnPos.z
    })
    
    L.debug("Server", "Sent ExitReady to " .. username)
end

-- Handle Move Relic Request
function MSR_Server.HandleMoveRelicRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Note: No need to validate player is in refuge - context menu only appears
    -- when player is standing next to the relic, which is inside the refuge
    
    -- Check cooldown using SERVER-SIDE storage (not client ModData - prevents manipulation)
    local canMove, remaining = checkRelicMoveCooldown(username)
    if not canMove then
        -- Send translation key with format args for cooldown message
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = "IGUI_CannotMoveRelicYet",
            messageArgs = { remaining }
        })
        return
    end
    
    -- Get refuge data
    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
    if not refugeData then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = "IGUI_MoveRelic_NoRefugeData"
        })
        return
    end
    
    -- Extract corner info from args
    local cornerDx = args and args.cornerDx or 0
    local cornerDy = args and args.cornerDy or 0
    local cornerName = args and args.cornerName or "Unknown"
    
    -- SECURITY: Validate and sanitize corner values using shared validation
    local isValid, sanitizedDx, sanitizedDy = MSR.Validation.ValidateCornerOffset(cornerDx, cornerDy)
    if not isValid then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = "IGUI_MoveRelic_DestinationBlocked"
        })
        return
    end
    cornerDx = sanitizedDx
    cornerDy = sanitizedDy
    
    -- Log the request details
    print("[MSR_Server] HandleMoveRelicRequest: " .. username .. " -> " .. cornerName)
    print("[MSR_Server]   cornerDx=" .. tostring(cornerDx) .. " cornerDy=" .. tostring(cornerDy))
    print("[MSR_Server]   refugeData: center=" .. refugeData.centerX .. "," .. refugeData.centerY .. " radius=" .. refugeData.radius)
    
    local targetX = refugeData.centerX + (cornerDx * refugeData.radius)
    local targetY = refugeData.centerY + (cornerDy * refugeData.radius)
    print("[MSR_Server]   Target position: " .. targetX .. "," .. targetY)
    
    -- Perform the move using shared function
    local success, errorCode = MSR.Shared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName)
    
    print("[MSR_Server]   MoveRelic result: success=" .. tostring(success) .. " errorCode=" .. tostring(errorCode))
    
    if success then
        -- Update cooldown using SERVER-SIDE storage (authoritative)
        updateRelicMoveCooldown(username)
        
        -- Save relic position to ModData (server-authoritative)
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
        -- Send translation key for error message
        local translationKey = MSR.Shared.GetMoveRelicTranslationKey(errorCode)
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ERROR, {
            messageKey = translationKey
        })
    end
end

-----------------------------------------------------------
-- Feature Upgrade Handler
-----------------------------------------------------------

-- Handle Feature Upgrade Request (new upgrade system)
function MSR_Server.HandleFeatureUpgradeRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Extract args
    local upgradeId = args and args.upgradeId
    local targetLevel = args and args.targetLevel
    local transactionId = args and args.transactionId
    
    L.debug("Server", "HandleFeatureUpgradeRequest: " .. username .. 
          " upgradeId=" .. tostring(upgradeId) .. " targetLevel=" .. tostring(targetLevel))
    
    if not upgradeId or not targetLevel then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Invalid upgrade request"
        })
        return
    end
    
    -- Get upgrade definition
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    if not upgrade then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Unknown upgrade: " .. tostring(upgradeId)
        })
        return
    end
    
    -- Validate dependencies
    if not MSR.UpgradeData.isUpgradeUnlocked(player, upgradeId) then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Dependencies not met"
        })
        return
    end
    
    -- Validate current level
    local currentLevel = MSR.UpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    
    if targetLevel <= currentLevel then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Already at this level"
        })
        return
    end
    
    if targetLevel > currentLevel + 1 then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Must upgrade one level at a time"
        })
        return
    end
    
    if targetLevel > upgrade.maxLevel then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
            transactionId = transactionId,
            reason = "Exceeds max level"
        })
        return
    end
    
    -- Get level requirements for item validation
    local levelData = MSR.UpgradeData.getLevelData(upgradeId, targetLevel)
    local requirements = levelData and levelData.requirements or {}
    
    -- Validate player has required items (server-side anti-cheat)
    if #requirements > 0 then
        for _, req in ipairs(requirements) do
            local itemType = req.type
            local needed = req.count or 1
            
            -- IMPORTANT: Use multi-source counting (inventory + Sacred Relic container)
            -- so server-side validation matches client-side availability in MP.
            local available = MSR.Transaction.GetMultiSourceCount(player, itemType)
            
            -- Check substitutes if primary type insufficient
            if available < needed and req.substitutes then
                for _, subType in ipairs(req.substitutes) do
                    available = available + MSR.Transaction.GetMultiSourceCount(player, subType)
                    if available >= needed then break end
                end
            end
            
            if available < needed then
                local itemName = itemType:match("%.(.+)$") or itemType
                sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                    transactionId = transactionId,
                    reason = "Not enough " .. itemName
                })
                return
            end
        end
    end
    
    -- Special case: expand_refuge triggers the actual refuge expansion
    if upgradeId == "expand_refuge" then
        -- Get current refuge data
        local refugeData = MSR.Data.GetRefugeDataByUsername(username)
        if not refugeData then
            sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                transactionId = transactionId,
                reason = "No refuge data found"
            })
            return
        end
        
        -- Use shared validation for upgrade prerequisites
        local canUpgrade, reason, tierConfig = MSR.Validation.CanUpgradeRefuge(player, refugeData)
        if not canUpgrade then
            sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                transactionId = transactionId,
                reason = reason or "Cannot upgrade refuge"
            })
            return
        end
        
        -- Verify chunks are loaded for the NEW radius
        local newRadius = tierConfig.radius
        local cell = getCell()
        if not cell then
            sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                transactionId = transactionId,
                reason = "World not ready"
            })
            return
        end
        
        -- Check all corners of the NEW radius are loaded
        local cornerOffsets = {
            {0, 0},
            {-newRadius - 1, -newRadius - 1},
            {newRadius + 1, -newRadius - 1},
            {-newRadius - 1, newRadius + 1},
            {newRadius + 1, newRadius + 1}
        }
        
        for _, offset in ipairs(cornerOffsets) do
            local x = refugeData.centerX + offset[1]
            local y = refugeData.centerY + offset[2]
            local square = cell:getGridSquare(x, y, refugeData.centerZ)
            if not square or not square:getChunk() then
                sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                    transactionId = transactionId,
                    reason = "Refuge area not fully loaded. Move around and try again."
                })
                return
            end
        end
        
        -- Capture old radius BEFORE expansion
        local oldRadius = refugeData.radius
        local newTier = (refugeData.tier or 0) + 1
        
        -- Perform expansion using shared module
        local success = MSR.Shared.ExpandRefuge(refugeData, newTier, player)
        
        if success then
            print("[MSR_Server] expand_refuge: ExpandRefuge SUCCESS")
            
            -- Reposition relic to its assigned corner after expansion
            -- IMPORTANT: Search using OLD radius where relic currently is located
            local relic = MSR.Shared.FindRelicInRefuge(
                refugeData.centerX, refugeData.centerY, refugeData.centerZ,
                oldRadius, -- Use OLD radius - relic is at old corner position
                refugeData.refugeId
            )
            if relic then
                local md = relic:getModData()
                if md and md.assignedCorner then
                    -- Relic has an assigned corner, reposition it to new radius
                    local cornerDx = md.assignedCornerDx or 0
                    local cornerDy = md.assignedCornerDy or 0
                    -- Pass the already-found relic to avoid redundant search
                    local moveSuccess, moveMessage = MSR.Shared.MoveRelic(refugeData, cornerDx, cornerDy, md.assignedCorner, relic)
                    
                    if moveSuccess then
                        -- Update relic position in ModData only if move succeeded (server-authoritative)
                        local newRelicX = refugeData.centerX + (cornerDx * refugeData.radius)
                        local newRelicY = refugeData.centerY + (cornerDy * refugeData.radius)
                        refugeData.relicX = newRelicX
                        refugeData.relicY = newRelicY
                        refugeData.relicZ = refugeData.centerZ
                        
                        print("[MSR_Server] expand_refuge: Repositioned relic to " .. md.assignedCorner)
                        print("[MSR_Server] expand_refuge: New relic position: " .. newRelicX .. "," .. newRelicY)
                    else
                        -- Move failed - relic stays at old position, don't update ModData
                        -- This prevents position desync between physical relic and stored data
                        print("[MSR_Server] expand_refuge: WARNING - Failed to reposition relic: " .. tostring(moveMessage))
                        print("[MSR_Server] expand_refuge: Relic remains at current position, ModData unchanged")
                    end
                else
                    print("[MSR_Server] expand_refuge: Relic has no assigned corner, not moving")
                end
            else
                print("[MSR_Server] expand_refuge: Could not find relic to reposition")
            end
            
            print("[MSR_Server] expand_refuge: " .. username .. " expanded to tier " .. newTier)
            
            -- Run integrity check after expansion to ensure everything is valid
            MSR.Integrity.ValidateAndRepair(refugeData, {
                source = "upgrade",
                player = player
            })
            
            -- Save updated refuge data
            MSR.Data.SaveRefugeData(refugeData)
            
            -- Send success response with ALL data needed for client-side cleanup
            -- Client needs location and radius info to clean up stale wall objects
            sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_COMPLETE, {
                transactionId = transactionId,
                upgradeId = upgradeId,
                newLevel = targetLevel,
                -- Include refuge location data for client-side wall cleanup
                centerX = refugeData.centerX,
                centerY = refugeData.centerY,
                centerZ = refugeData.centerZ,
                oldRadius = oldRadius,
                newRadius = refugeData.radius,
                newTier = newTier,
                refugeData = MSR.Data.SerializeRefugeData(refugeData)
            })
            L.debug("Server", "expand_refuge: Sent FeatureUpgradeComplete")
        else
            print("[MSR_Server] expand_refuge: ExpandRefuge FAILED")
            sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR, {
                transactionId = transactionId,
                reason = "Expansion failed"
            })
        end
        print("[MSR_Server] expand_refuge: ========================================")
    else
        -- Standard upgrade: Update player level in ModData
        MSR.UpgradeData.setPlayerUpgradeLevel(player, upgradeId, targetLevel)
        
        L.debug("Server", "Feature upgrade: " .. username .. " upgraded " .. upgradeId .. " to level " .. targetLevel)
        
        -- Refresh refugeData after the upgrade to get updated upgrades table
        local updatedRefugeData = MSR.Data.GetRefugeData(player)
        
        -- Debug: Print upgrades after save (using helper)
        if L.isDebug() then
            if updatedRefugeData and updatedRefugeData.upgrades then
                L.debug("Server", "Upgrades after save: " .. MSR.Data.FormatUpgradesTable(updatedRefugeData.upgrades))
            else
                L.debug("Server", "WARNING: No upgrades in refugeData after save!")
            end
        end
        
        -- Send success response with updated refugeData including upgrades
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.FEATURE_UPGRADE_COMPLETE, {
            transactionId = transactionId,
            upgradeId = upgradeId,
            newLevel = targetLevel,
            refugeData = MSR.Data.SerializeRefugeData(updatedRefugeData)
        })
    end
end

-----------------------------------------------------------
-- Client Command Handler
-----------------------------------------------------------

-- Main command dispatcher
local function OnClientCommand(module, command, player, args)
    -- Only handle our namespace
    if module ~= MSR.Config.COMMAND_NAMESPACE then return end
    
    -- Some commands are exempt from rate limiting
    local isExemptFromRateLimit = (
        command == MSR.Config.COMMANDS.CHUNKS_READY or
        command == MSR.Config.COMMANDS.REQUEST_MODDATA
    )
    
    -- Rate limit check (skip for exempt commands)
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
    else
        L.debug("Server", "Unknown command: " .. tostring(command))
    end
end

-----------------------------------------------------------
-- Stranded Player Recovery (Login Handler)
-----------------------------------------------------------

-- Check if all refuge chunks are loaded on the server
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

-- Check if a player is stranded in refuge (logged in at refuge coords with missing structures)
-- This function waits for chunks to load before checking/regenerating
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
        
        -- Check if player is still valid (use pcall to handle disconnected/invalid player objects)
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
            return  -- Keep waiting
        end
        
        -- Chunks loaded, do the check only once
        if checked then return end
        checked = true
        Events.OnTick.Remove(waitForChunksAndCheck)
        
        L.debug("Server", "Chunks loaded for " .. usernameRef .. " after " .. tickCount .. " ticks, checking structures...")
        
        -- Now safely check if Sacred Relic exists
        local hasRelic = MSR.Shared.FindRelicInRefuge(
            refugeDataRef.centerX, refugeDataRef.centerY, refugeDataRef.centerZ,
            refugeDataRef.radius, refugeDataRef.refugeId
        )
        
        if not hasRelic then
            -- Relic genuinely missing - regenerate structures
            L.debug("Server", "Regenerating structures for stranded player " .. usernameRef)
            
            MSR.Shared.EnsureRefugeStructures(refugeDataRef, playerRef)
        else
            L.debug("Server", "Structures intact for " .. usernameRef .. ", no regeneration needed")
        end
    end
    
    Events.OnTick.Add(waitForChunksAndCheck)
end

-----------------------------------------------------------
-- Server-Side Death Handler (Multiplayer Authoritative)
-----------------------------------------------------------

-- Handle player death on server (authoritative for MP)
local function OnPlayerDeathServer(player)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Check if player died inside their refuge
    if not MSR.Data.IsPlayerInRefugeCoords(player) then
        return -- Not in refuge, nothing to do
    end
    
    L.debug("Server", "Player " .. username .. " died in refuge")
    
    -- Get refuge data before we delete it
    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
    
    -- Get return position (to move corpse there)
    local returnPos = MSR.Data.GetReturnPositionByUsername(username)
    
    -- Move corpse to last world position (where they entered from)
    if returnPos then
        local corpse = player:getCorpse()
        if corpse then
            corpse:setX(returnPos.x)
            corpse:setY(returnPos.y)
            corpse:setZ(returnPos.z)
            
            L.debug("Server", "Moved corpse to " .. returnPos.x .. "," .. returnPos.y)
        end
    end
    
    -- Delete refuge data from ModData
    -- NOTE: We do NOT delete physical structures here - they persist in world save
    -- This is intentional: the refuge space can be reused by a new character
    -- or cleaned up by admin tools if needed
    MSR.Data.DeleteRefugeData(player)
    
    -- Clear return position
    MSR.Data.ClearReturnPositionByUsername(username)
    
    -- Clear server-side cooldowns for this player
    serverCooldowns.teleport[username] = nil
    serverCooldowns.relicMove[username] = nil
    
    L.debug("Server", "Cleaned up refuge data for " .. username)
end

-----------------------------------------------------------
-- Server Events
-----------------------------------------------------------

-- Server initialization
local function OnServerStart()
    L.debug("Server", "Server initialized")
    
    -- Initialize ModData
    MSR.Data.InitializeModData()
    
    -- Transmit existing ModData to any connected clients
    MSR.Data.TransmitModData()
end

-- Transmit ModData to newly connected players
local function OnPlayerFullyConnected(player)
    if not player then return end
    
    local playerUsername = player:getUsername() or "unknown"
    
    L.debug("Server", "OnPlayerFullyConnected called for: " .. playerUsername)
    
    -- Small delay to ensure client is ready to receive
    local tickCount = 0
    local function delayedTransmit()
        tickCount = tickCount + 1
        if tickCount < 30 then return end -- Wait ~0.5 seconds
        
        Events.OnTick.Remove(delayedTransmit)
        
        -- Transmit ModData so new player has refuge data
        MSR.Data.TransmitModData()
        
        if L.isDebug() then
            L.debug("Server", "Transmitted ModData to " .. playerUsername)
            -- Log what we're transmitting
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

-- Stranded player recovery DISABLED: structures persist in map save
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

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnServerStarted.Add(OnServerStart)
Events.OnClientCommand.Add(OnClientCommand)
Events.OnPlayerDeath.Add(OnPlayerDeathServer)

-- Note: OnPlayerConnect may need to be changed based on PZ version
-- Alternative events: Events.OnConnected, Events.OnCreatePlayer
if Events.OnPlayerConnect then
    Events.OnPlayerConnect.Add(OnPlayerConnect)
    Events.OnPlayerConnect.Add(OnPlayerFullyConnected)
elseif Events.OnConnected then
    -- OnConnected fires on client, but we can use OnCreatePlayer on server
    -- This is a fallback
end

-- OnCreatePlayer is more reliable for detecting when a player joins
if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(function(playerIndex, player)
        if isServer() then
            OnPlayerConnect(player)
            OnPlayerFullyConnected(player)
        end
    end)
end

L.debug("Server", "Server module loaded")

return MSR_Server
