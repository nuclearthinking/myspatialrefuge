-- Spatial Refuge Server Module
-- Server-side command handlers and generation for multiplayer persistence
-- Server generates refuge structures so they persist in map save

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeShared"
require "shared/SpatialRefugeData"
require "shared/SpatialRefugeValidation"
require "shared/SpatialRefugeMigration"
require "shared/SpatialRefugeUpgradeData"

SpatialRefugeServer = SpatialRefugeServer or {}

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
    local cooldown = SpatialRefugeConfig.TELEPORT_COOLDOWN or 60
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
    local cooldown = SpatialRefugeConfig.RELIC_MOVE_COOLDOWN or 120
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
-- Note: Most validation logic is now in shared/SpatialRefugeValidation.lua
-----------------------------------------------------------

-- Validate player refuge access (security check)
-- Delegates to shared validation module
function SpatialRefugeServer.ValidateRefugeAccess(player, refugeId)
    return SpatialRefugeValidation.ValidateRefugeAccess(player, refugeId)
end

-- Check if player can enter refuge (validation)
-- Delegates to shared validation module
function SpatialRefugeServer.CanPlayerEnterRefuge(player)
    return SpatialRefugeValidation.CanEnterRefuge(player)
end

-----------------------------------------------------------
-- Request Handlers
-----------------------------------------------------------

-- Handle ModData Request - Client asking for their refuge data on connect
-- This is the authoritative source - server creates refuge if needed
function SpatialRefugeServer.HandleModDataRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    if getDebug() then
        print("[SpatialRefugeServer] ModData request from " .. username)
    end
    
    if SpatialRefugeMigration.NeedsMigration(player) then
        SpatialRefugeMigration.MigratePlayer(player)
    end
    
    local refugeData = SpatialRefugeData.GetOrCreateRefugeData(player)
    if not refugeData then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "Failed to get or create refuge data"
        })
        return
    end
    
    -- Get return position if any
    local returnPos = SpatialRefugeData.GetReturnPositionByUsername(username)
    
    if getDebug() then
        print("[SpatialRefugeServer] Sending ModData to " .. username .. ": refuge at " .. 
              refugeData.centerX .. "," .. refugeData.centerY .. " tier " .. refugeData.tier)
    end
    
    -- Send refuge data to client
    sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.MODDATA_RESPONSE, {
        refugeData = {
            refugeId = refugeData.refugeId,
            username = refugeData.username,
            centerX = refugeData.centerX,
            centerY = refugeData.centerY,
            centerZ = refugeData.centerZ,
            tier = refugeData.tier,
            radius = refugeData.radius,
            relicX = refugeData.relicX,
            relicY = refugeData.relicY,
            relicZ = refugeData.relicZ
        },
        returnPosition = returnPos
    })
    
    -- Also transmit global ModData for good measure
    SpatialRefugeData.TransmitModData()
end

-- Handle Enter Refuge Request - Phase 1
-- Two-phase approach for MP persistence:
-- Phase 1: Server sends TeleportTo, client teleports and waits for chunks
-- Phase 2: Client sends ChunksReady, server generates structures (chunks now loaded!)
function SpatialRefugeServer.HandleEnterRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Server-authoritative teleport cooldown check
    local canTeleport, remaining = checkTeleportCooldown(username)
    if not canTeleport then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "Refuge portal charging... (" .. remaining .. "s)"
        })
        return
    end
    
    -- Validate player can enter
    local canEnter, reason = SpatialRefugeServer.CanPlayerEnterRefuge(player)
    if not canEnter then
        -- Send error response
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = reason
        })
        return
    end
    
    -- Get or create refuge data
    local refugeData = SpatialRefugeData.GetOrCreateRefugeData(player)
    if not refugeData then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "Failed to create refuge data"
        })
        return
    end
    
    -- Save return position from args (validate it's not already in refuge)
    if args and args.returnX and args.returnY and args.returnZ then
        SpatialRefugeData.SaveReturnPositionByUsername(username, args.returnX, args.returnY, args.returnZ)
    end
    
    if getDebug() then
        print("[SpatialRefugeServer] Phase 1: Sending TeleportTo for " .. username)
    end
    
    -- Update server-side teleport cooldown
    updateTeleportCooldown(username)
    
    -- Phase 1: Tell client to teleport (no generation yet)
    -- Client will teleport, wait for chunks to load, then send ChunksReady
    sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.TELEPORT_TO, {
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
function SpatialRefugeServer.HandleChunksReady(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Get refuge data
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    if not refugeData then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "No refuge data found"
        })
        return
    end
    
    if getDebug() then
        print("[SpatialRefugeServer] Phase 2: Waiting for server chunks to load for " .. username)
    end
    
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
            if getDebug() then
                print("[SpatialRefugeServer] Player disconnected during chunk wait for " .. tostring(usernameRef))
            end
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
            
            if getDebug() then
                print("[SpatialRefugeServer] All refuge chunks loaded after " .. tickCount .. " ticks for " .. usernameRef)
            end
            
            -- Now generate structures (pass player for MP zombie sync)
            SpatialRefugeShared.EnsureRefugeStructures(refugeDataRef, playerRef)
            
            -- Transmit ModData to ensure client has refuge data for context menus
            SpatialRefugeData.TransmitModData()
            
            if getDebug() then
                -- Log the ModData state for debugging
                local registry = SpatialRefugeData.GetRefugeRegistry()
                local count = 0
                if registry then
                    for k, v in pairs(registry) do
                        count = count + 1
                        print("[SpatialRefugeServer] ModData contains refuge: " .. tostring(k))
                    end
                end
                print("[SpatialRefugeServer] Total refuges in ModData: " .. count)
            end
            
            -- Send confirmation to client
            sendServerCommand(playerRef, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.GENERATION_COMPLETE, {
                centerX = refugeDataRef.centerX,
                centerY = refugeDataRef.centerY,
                centerZ = refugeDataRef.centerZ,
                tier = refugeDataRef.tier,
                radius = refugeDataRef.radius
            })
            
            if getDebug() then
                print("[SpatialRefugeServer] Phase 2 complete: Sent GenerationComplete to " .. usernameRef)
            end
        end
        
        -- Timeout
        if tickCount >= maxTicks and not generated then
            Events.OnTick.Remove(waitForServerChunks)
            
            if getDebug() then
                print("[SpatialRefugeServer] Timeout waiting for server chunks for " .. usernameRef)
            end
            
            sendServerCommand(playerRef, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
                message = "Server could not load refuge area"
            })
        end
    end
    
    Events.OnTick.Add(waitForServerChunks)
end

-- Handle Exit Refuge Request
function SpatialRefugeServer.HandleExitRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Server-authoritative teleport cooldown check (exit also uses teleport cooldown)
    local canTeleport, remaining = checkTeleportCooldown(username)
    if not canTeleport then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "Refuge portal charging... (" .. remaining .. "s)"
        })
        return
    end
    
    -- Get return position
    local returnPos = SpatialRefugeData.GetReturnPositionByUsername(username)
    
    if not returnPos then
        -- No return position found - use default safe location
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "Return position not found"
        })
        return
    end
    
    -- Update server-side teleport cooldown
    updateTeleportCooldown(username)
    
    -- Clear return position before sending response
    SpatialRefugeData.ClearReturnPositionByUsername(username)
    
    -- Send success response with return coordinates
    sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.EXIT_READY, {
        returnX = returnPos.x,
        returnY = returnPos.y,
        returnZ = returnPos.z
    })
    
    if getDebug() then
        print("[SpatialRefugeServer] Sent ExitReady to " .. username)
    end
end

-- Handle Upgrade Refuge Request
function SpatialRefugeServer.HandleUpgradeRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Extract transaction info from args
    local coreCost = args and args.coreCost or 0
    local transactionId = args and args.transactionId or nil
    
    -- Get current refuge data
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    
    -- Use shared validation for upgrade prerequisites
    local canUpgrade, reason, tierConfig = SpatialRefugeValidation.CanUpgradeRefuge(player, refugeData)
    if not canUpgrade then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = reason,
            transactionId = transactionId,  -- Include for transaction rollback
            transactionType = "REFUGE_UPGRADE",
            coreRefund = coreCost  -- Legacy fallback
        })
        return
    end
    
    local currentTier = refugeData.tier or 0
    local newTier = currentTier + 1
    
    -- Note: Core consumption validated client-side before request
    -- Server refunds cores on failure via coreRefund in error response
    
    -- CRITICAL: Verify chunks are loaded for the NEW radius before modifying structures
    -- The new walls will be at a larger radius, those chunks must be loaded
    local newRadius = tierConfig.radius
    local cell = getCell()
    if not cell then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "World not ready",
            transactionId = transactionId,
            transactionType = "REFUGE_UPGRADE",
            coreRefund = coreCost
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
        -- Only use getGridSquare - don't create empty cells
        local square = cell:getGridSquare(x, y, refugeData.centerZ)
        if not square or not square:getChunk() then
            sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
                message = "Refuge area not fully loaded. Move around and try again.",
                transactionId = transactionId,
                transactionType = "REFUGE_UPGRADE",
                coreRefund = coreCost
            })
            return
        end
    end
    
    -- CRITICAL: Capture old radius BEFORE expansion
    -- After ExpandRefuge, refugeData.radius will be the NEW radius
    -- We need the OLD radius to find the relic at its current position
    local oldRadius = refugeData.radius
    
    -- Perform expansion using shared module (pass player for MP zombie sync)
    local success = SpatialRefugeShared.ExpandRefuge(refugeData, newTier, player)
    
    if success then
        -- Reposition relic to its assigned corner (if any) after expansion
        -- This is crucial - relic may be outside new walls if not repositioned
        -- IMPORTANT: Search using OLD radius where relic currently is located
        local relic = SpatialRefugeShared.FindRelicInRefuge(
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
                SpatialRefugeShared.MoveRelic(refugeData, cornerDx, cornerDy, md.assignedCorner)
                
                -- Update relic position in ModData (server-authoritative)
                local newRelicX = refugeData.centerX + (cornerDx * refugeData.radius)
                local newRelicY = refugeData.centerY + (cornerDy * refugeData.radius)
                refugeData.relicX = newRelicX
                refugeData.relicY = newRelicY
                refugeData.relicZ = refugeData.centerZ
                
                if getDebug() then
                    print("[SpatialRefugeServer] Repositioned relic to " .. md.assignedCorner .. " after upgrade")
                    print("[SpatialRefugeServer] Updated relic position in ModData: " .. newRelicX .. "," .. newRelicY)
                end
            end
        end
        
        -- Save updated refuge data (includes new tier, radius, and relic position)
        SpatialRefugeData.SaveRefugeData(refugeData)
        
        -- Send success response with full updated refugeData
        -- Client needs this to update its local copy AND refresh visual state
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.UPGRADE_COMPLETE, {
            newTier = newTier,
            newRadius = refugeData.radius,
            oldRadius = oldRadius,  -- Include old radius for client-side cleanup
            displayName = tierConfig.displayName,
            centerX = refugeData.centerX,
            centerY = refugeData.centerY,
            centerZ = refugeData.centerZ,
            transactionId = transactionId,  -- Include for transaction commit
            -- Include full refugeData for client to update local copy
            refugeData = {
                refugeId = refugeData.refugeId,
                username = refugeData.username,
                centerX = refugeData.centerX,
                centerY = refugeData.centerY,
                centerZ = refugeData.centerZ,
                tier = refugeData.tier,
                radius = refugeData.radius,
                relicX = refugeData.relicX,
                relicY = refugeData.relicY,
                relicZ = refugeData.relicZ
            }
        })
        
        if getDebug() then
            print("[SpatialRefugeServer] Upgraded refuge for " .. username .. " to tier " .. newTier)
        end
    else
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "Upgrade failed",
            transactionId = transactionId,
            transactionType = "REFUGE_UPGRADE",
            coreRefund = coreCost  -- Legacy fallback
        })
    end
end

-- Handle Move Relic Request
function SpatialRefugeServer.HandleMoveRelicRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Note: No need to validate player is in refuge - context menu only appears
    -- when player is standing next to the relic, which is inside the refuge
    
    -- Check cooldown using SERVER-SIDE storage (not client ModData - prevents manipulation)
    local canMove, remaining = checkRelicMoveCooldown(username)
    if not canMove then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "Cannot move relic yet. Wait " .. remaining .. " seconds."
        })
        return
    end
    
    -- Get refuge data
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    if not refugeData then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "No refuge found"
        })
        return
    end
    
    -- Extract corner info from args
    local cornerDx = args and args.cornerDx or 0
    local cornerDy = args and args.cornerDy or 0
    local cornerName = args and args.cornerName or "Unknown"
    
    -- SECURITY: Validate and sanitize corner values using shared validation
    local isValid, sanitizedDx, sanitizedDy = SpatialRefugeValidation.ValidateCornerOffset(cornerDx, cornerDy)
    if not isValid then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = "Invalid relic position"
        })
        return
    end
    cornerDx = sanitizedDx
    cornerDy = sanitizedDy
    
    -- Log the request details
    print("[SpatialRefugeServer] HandleMoveRelicRequest: " .. username .. " -> " .. cornerName)
    print("[SpatialRefugeServer]   cornerDx=" .. tostring(cornerDx) .. " cornerDy=" .. tostring(cornerDy))
    print("[SpatialRefugeServer]   refugeData: center=" .. refugeData.centerX .. "," .. refugeData.centerY .. " radius=" .. refugeData.radius)
    
    local targetX = refugeData.centerX + (cornerDx * refugeData.radius)
    local targetY = refugeData.centerY + (cornerDy * refugeData.radius)
    print("[SpatialRefugeServer]   Target position: " .. targetX .. "," .. targetY)
    
    -- Perform the move using shared function
    local success, message = SpatialRefugeShared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName)
    
    print("[SpatialRefugeServer]   MoveRelic result: success=" .. tostring(success) .. " message=" .. tostring(message))
    
    if success then
        -- Update cooldown using SERVER-SIDE storage (authoritative)
        updateRelicMoveCooldown(username)
        
        -- Save relic position to ModData (server-authoritative)
        refugeData.relicX = targetX
        refugeData.relicY = targetY
        refugeData.relicZ = refugeData.centerZ
        SpatialRefugeData.SaveRefugeData(refugeData)
        
        if getDebug() then
            print("[SpatialRefugeServer] Saved relic position to ModData: " .. targetX .. "," .. targetY)
        end
        
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.MOVE_RELIC_COMPLETE, {
            cornerName = cornerName,
            cornerDx = cornerDx,
            cornerDy = cornerDy,
            -- Include full refugeData for client to update local copy
            refugeData = {
                refugeId = refugeData.refugeId,
                username = refugeData.username,
                centerX = refugeData.centerX,
                centerY = refugeData.centerY,
                centerZ = refugeData.centerZ,
                tier = refugeData.tier,
                radius = refugeData.radius,
                relicX = refugeData.relicX,
                relicY = refugeData.relicY,
                relicZ = refugeData.relicZ
            }
        })
        
        if getDebug() then
            print("[SpatialRefugeServer] Moved relic for " .. username .. " to " .. cornerName)
        end
    else
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.ERROR, {
            message = message or "Move failed"
        })
    end
end

-----------------------------------------------------------
-- Feature Upgrade Handler
-----------------------------------------------------------

-- Handle Feature Upgrade Request (new upgrade system)
function SpatialRefugeServer.HandleFeatureUpgradeRequest(player, args)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Extract args
    local upgradeId = args and args.upgradeId
    local targetLevel = args and args.targetLevel
    local transactionId = args and args.transactionId
    
    if not upgradeId or not targetLevel then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, "FeatureUpgradeError", {
            transactionId = transactionId,
            reason = "Invalid upgrade request"
        })
        return
    end
    
    -- Get upgrade definition
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    if not upgrade then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, "FeatureUpgradeError", {
            transactionId = transactionId,
            reason = "Unknown upgrade: " .. tostring(upgradeId)
        })
        return
    end
    
    -- Validate dependencies
    if not SpatialRefugeUpgradeData.isUpgradeUnlocked(player, upgradeId) then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, "FeatureUpgradeError", {
            transactionId = transactionId,
            reason = "Dependencies not met"
        })
        return
    end
    
    -- Validate current level
    local currentLevel = SpatialRefugeUpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    if targetLevel <= currentLevel then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, "FeatureUpgradeError", {
            transactionId = transactionId,
            reason = "Already at this level"
        })
        return
    end
    
    if targetLevel > currentLevel + 1 then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, "FeatureUpgradeError", {
            transactionId = transactionId,
            reason = "Must upgrade one level at a time"
        })
        return
    end
    
    if targetLevel > upgrade.maxLevel then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, "FeatureUpgradeError", {
            transactionId = transactionId,
            reason = "Exceeds max level"
        })
        return
    end
    
    -- Server trusts that client has the items (transaction locked them)
    -- Update player level in ModData
    SpatialRefugeUpgradeData.setPlayerUpgradeLevel(player, upgradeId, targetLevel)
    
    if getDebug() then
        print("[SpatialRefugeServer] Feature upgrade: " .. username .. " upgraded " .. upgradeId .. " to level " .. targetLevel)
    end
    
    -- Send success response
    sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, "FeatureUpgradeComplete", {
        transactionId = transactionId,
        upgradeId = upgradeId,
        newLevel = targetLevel
    })
end

-----------------------------------------------------------
-- Client Command Handler
-----------------------------------------------------------

-- Main command dispatcher
local function OnClientCommand(module, command, player, args)
    -- Only handle our namespace
    if module ~= SpatialRefugeConfig.COMMAND_NAMESPACE then return end
    
    -- Some commands are exempt from rate limiting
    local isExemptFromRateLimit = (
        command == SpatialRefugeConfig.COMMANDS.CHUNKS_READY or
        command == SpatialRefugeConfig.COMMANDS.REQUEST_MODDATA
    )
    
    -- Rate limit check (skip for exempt commands)
    if not isExemptFromRateLimit and not canProcessRequest(player) then
        if getDebug() then
            print("[SpatialRefugeServer] Rate limited request from " .. tostring(player:getUsername()))
        end
        return
    end
    
    -- Dispatch to appropriate handler
    if command == SpatialRefugeConfig.COMMANDS.REQUEST_MODDATA then
        SpatialRefugeServer.HandleModDataRequest(player, args)
    elseif command == SpatialRefugeConfig.COMMANDS.REQUEST_ENTER then
        SpatialRefugeServer.HandleEnterRequest(player, args)
    elseif command == SpatialRefugeConfig.COMMANDS.CHUNKS_READY then
        SpatialRefugeServer.HandleChunksReady(player, args)
    elseif command == SpatialRefugeConfig.COMMANDS.REQUEST_EXIT then
        SpatialRefugeServer.HandleExitRequest(player, args)
    elseif command == SpatialRefugeConfig.COMMANDS.REQUEST_UPGRADE then
        SpatialRefugeServer.HandleUpgradeRequest(player, args)
    elseif command == SpatialRefugeConfig.COMMANDS.REQUEST_MOVE_RELIC then
        SpatialRefugeServer.HandleMoveRelicRequest(player, args)
    elseif command == "RequestFeatureUpgrade" then
        SpatialRefugeServer.HandleFeatureUpgradeRequest(player, args)
    else
        if getDebug() then
            print("[SpatialRefugeServer] Unknown command: " .. tostring(command))
        end
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
function SpatialRefugeServer.CheckAndRecoverStrandedPlayer(player)
    if not player then return end
    
    -- Check if player is at refuge coordinates
    if not SpatialRefugeData.IsPlayerInRefugeCoords(player) then
        return  -- Not in refuge area, nothing to do
    end
    
    local username = player:getUsername()
    if not username then return end
    
    -- Get player's refuge data
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    if not refugeData then
        -- Player is in refuge coords but has no refuge data - unusual situation
        if getDebug() then
            print("[SpatialRefugeServer] Player " .. username .. " in refuge coords but no data found")
        end
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
            if getDebug() then
                print("[SpatialRefugeServer] Player disconnected during stranded check for " .. tostring(usernameRef))
            end
            return
        end
        
        -- Check if chunks are loaded
        if not areRefugeChunksLoaded(refugeDataRef) then
            if tickCount >= maxTicks then
                Events.OnTick.Remove(waitForChunksAndCheck)
                if getDebug() then
                    print("[SpatialRefugeServer] Timeout waiting for refuge chunks for " .. usernameRef)
                end
            end
            return  -- Keep waiting
        end
        
        -- Chunks loaded, do the check only once
        if checked then return end
        checked = true
        Events.OnTick.Remove(waitForChunksAndCheck)
        
        if getDebug() then
            print("[SpatialRefugeServer] Chunks loaded for " .. usernameRef .. " after " .. tickCount .. " ticks, checking structures...")
        end
        
        -- Now safely check if Sacred Relic exists
        local hasRelic = SpatialRefugeShared.FindRelicInRefuge(
            refugeDataRef.centerX, refugeDataRef.centerY, refugeDataRef.centerZ,
            refugeDataRef.radius, refugeDataRef.refugeId
        )
        
        if not hasRelic then
            -- Relic genuinely missing - regenerate structures
            if getDebug() then
                print("[SpatialRefugeServer] Regenerating structures for stranded player " .. usernameRef)
            end
            
            SpatialRefugeShared.EnsureRefugeStructures(refugeDataRef, playerRef)
        else
            if getDebug() then
                print("[SpatialRefugeServer] Structures intact for " .. usernameRef .. ", no regeneration needed")
            end
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
    if not SpatialRefugeData.IsPlayerInRefugeCoords(player) then
        return -- Not in refuge, nothing to do
    end
    
    if getDebug() then
        print("[SpatialRefugeServer] Player " .. username .. " died in refuge")
    end
    
    -- Get refuge data before we delete it
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    
    -- Get return position (to move corpse there)
    local returnPos = SpatialRefugeData.GetReturnPositionByUsername(username)
    
    -- Move corpse to last world position (where they entered from)
    if returnPos then
        local corpse = player:getCorpse()
        if corpse then
            corpse:setX(returnPos.x)
            corpse:setY(returnPos.y)
            corpse:setZ(returnPos.z)
            
            if getDebug() then
                print("[SpatialRefugeServer] Moved corpse to " .. returnPos.x .. "," .. returnPos.y)
            end
        end
    end
    
    -- Delete refuge data from ModData
    -- NOTE: We do NOT delete physical structures here - they persist in world save
    -- This is intentional: the refuge space can be reused by a new character
    -- or cleaned up by admin tools if needed
    SpatialRefugeData.DeleteRefugeData(player)
    
    -- Clear return position
    SpatialRefugeData.ClearReturnPositionByUsername(username)
    
    -- Clear server-side cooldowns for this player
    serverCooldowns.teleport[username] = nil
    serverCooldowns.relicMove[username] = nil
    
    if getDebug() then
        print("[SpatialRefugeServer] Cleaned up refuge data for " .. username)
    end
end

-----------------------------------------------------------
-- Server Events
-----------------------------------------------------------

-- Server initialization
local function OnServerStart()
    if getDebug() then
        print("[SpatialRefugeServer] Server initialized")
    end
    
    -- Initialize ModData
    SpatialRefugeData.InitializeModData()
    
    -- Transmit existing ModData to any connected clients
    SpatialRefugeData.TransmitModData()
end

-- Transmit ModData to newly connected players
local function OnPlayerFullyConnected(player)
    if not player then return end
    
    local playerUsername = player:getUsername() or "unknown"
    
    if getDebug() then
        print("[SpatialRefugeServer] OnPlayerFullyConnected called for: " .. playerUsername)
    end
    
    -- Small delay to ensure client is ready to receive
    local tickCount = 0
    local function delayedTransmit()
        tickCount = tickCount + 1
        if tickCount < 30 then return end -- Wait ~0.5 seconds
        
        Events.OnTick.Remove(delayedTransmit)
        
        -- Transmit ModData so new player has refuge data
        SpatialRefugeData.TransmitModData()
        
        if getDebug() then
            print("[SpatialRefugeServer] Transmitted ModData to " .. playerUsername)
            -- Log what we're transmitting
            local registry = SpatialRefugeData.GetRefugeRegistry()
            if registry then
                local count = 0
                for k, v in pairs(registry) do
                    count = count + 1
                end
                print("[SpatialRefugeServer] ModData has " .. count .. " refuge entries")
            else
                print("[SpatialRefugeServer] WARNING: Registry is nil!")
            end
        end
    end
    
    Events.OnTick.Add(delayedTransmit)
end

-- Stranded player recovery DISABLED: structures persist in map save
local function OnPlayerConnect(player)
    if not player then return end
    
    local username = player:getUsername() or "unknown"
    
    if SpatialRefugeMigration.NeedsMigration(player) then
        local success, message = SpatialRefugeMigration.MigratePlayer(player)
        if success then
            print("[SpatialRefugeServer] " .. username .. ": " .. message)
            SpatialRefugeData.TransmitModData()
        end
    end
    
    if getDebug() then
        print("[SpatialRefugeServer] Player connected: " .. username)
    end
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

if getDebug() then
    print("[SpatialRefugeServer] Server module loaded")
end

return SpatialRefugeServer
