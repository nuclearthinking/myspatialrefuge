-- Spatial Refuge Teleportation Module
-- Handles entry/exit teleportation with validation
-- Supports both multiplayer (server-authoritative) and singleplayer (client-side) paths

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeValidation"
require "shared/SpatialRefugeShared"

-- Assume dependencies are already loaded
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-----------------------------------------------------------
-- Environment Detection (cached - cannot change during session)
-----------------------------------------------------------

local _cachedIsServer = nil
local _cachedIsClient = nil
local _cachedIsMPClient = nil

-- Check if we're in multiplayer client mode (not host/SP) - cached for performance
local function isMultiplayerClient()
    if _cachedIsMPClient == nil then
        if _cachedIsClient == nil then _cachedIsClient = isClient() end
        if _cachedIsServer == nil then _cachedIsServer = isServer() end
        _cachedIsMPClient = _cachedIsClient and not _cachedIsServer
    end
    return _cachedIsMPClient
end

-- Check if we're in singleplayer - cached for performance
local function isSinglePlayer()
    if _cachedIsServer == nil then _cachedIsServer = isServer() end
    if _cachedIsClient == nil then _cachedIsClient = isClient() end
    -- SP: isServer() true, no client connected (or host)
    return _cachedIsServer or not _cachedIsClient
end

-----------------------------------------------------------
-- Validation
-- Note: Core validation logic is in shared/SpatialRefugeValidation.lua
-- Client adds cooldown checks using client-side state
-----------------------------------------------------------

-- Check if player can enter refuge
-- Returns: canEnter (boolean), reason (string)
function SpatialRefuge.CanEnterRefuge(player)
    -- Use shared validation for physical state checks
    local canEnter, reason = SpatialRefugeValidation.CanEnterRefuge(player)
    if not canEnter then
        return false, reason
    end
    
    -- Client-specific cooldown checks (using client-side state)
    -- Note: In MP, server also validates cooldowns with server-side state
    local now = getTimestamp and getTimestamp() or 0
    
    -- Check teleport cooldown
    local lastTeleport = SpatialRefuge.GetLastTeleportTime and SpatialRefuge.GetLastTeleportTime(player) or 0
    local cooldown = SpatialRefugeConfig.TELEPORT_COOLDOWN or 60
    local canTeleport, remaining = SpatialRefugeValidation.CheckCooldown(lastTeleport, cooldown, now)
    
    if not canTeleport then
        return false, SpatialRefugeValidation.FormatCooldownMessage("Refuge portal charging...", remaining)
    end
    
    -- Check combat teleport blocking (if recently damaged)
    local lastDamage = SpatialRefuge.GetLastDamageTime and SpatialRefuge.GetLastDamageTime(player) or 0
    local combatBlock = SpatialRefugeConfig.COMBAT_TELEPORT_BLOCK or 10
    local canCombat, _ = SpatialRefugeValidation.CheckCooldown(lastDamage, combatBlock, now)
    
    if not canCombat then
        return false, "Cannot teleport during combat!"
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Singleplayer Enter Logic (tick-based generation)
-----------------------------------------------------------

-- Singleplayer/host path - generate structures locally
local function doSingleplayerEnter(player, refugeData)
    local teleportX = refugeData.centerX
    local teleportY = refugeData.centerY
    local teleportZ = refugeData.centerZ
    local teleportPlayer = player
    local refugeId = refugeData.refugeId
    local tier = refugeData.tier or 0
    local tierData = SpatialRefugeConfig.TIERS[tier]
    local radius = tierData and tierData.radius or 1
    
    -- Schedule teleport on next tick (after timed action completes)
    local tickCount = 0
    local teleportDone = false
    local floorPrepared = false
    local relicCreated = false
    local wallsCreated = false
    local maxTicks = 600  -- 10 seconds max wait
    local centerSquareSeen = false
    local postTeleportWaitTicks = 20  -- ~0.33s
    
    local function doTeleport()
        tickCount = tickCount + 1
        
        -- First tick: Execute teleport
        if not teleportDone then
            teleportPlayer:teleportTo(teleportX, teleportY, teleportZ)
            
            -- Force chunk loading by rotating player view
            teleportPlayer:setDir(0)
            teleportDone = true
            return
        end
        
        -- Rotate player to force chunk loading in all directions
        if tickCount == 2 then
            teleportPlayer:setDir(1)
        elseif tickCount == 3 then
            teleportPlayer:setDir(2)
        elseif tickCount == 4 then
            teleportPlayer:setDir(3)
        elseif tickCount == 5 then
            teleportPlayer:setDir(0)
        end
        
        -- Wait a bit after rotation for chunks to fully load
        if tickCount < postTeleportWaitTicks then
            return
        end
        
        -- Check if center square exists and chunk is loaded
        local cell = getCell()
        if not cell then return end
        
        local centerSquare = cell:getGridSquare(teleportX, teleportY, teleportZ)
        local centerSquareExists = centerSquare ~= nil
        
        -- Also check that the chunk is fully loaded before modifying
        local chunkLoaded = false
        if centerSquareExists then
            local chunk = centerSquare:getChunk()
            chunkLoaded = chunk ~= nil
        end
        
        if centerSquareExists and chunkLoaded then
            centerSquareSeen = true
        end
        
        -- NOTE: In multiplayer, server handles structure generation via HandleChunksReady
        -- This client-side code only runs in singleplayer
        -- Floor generation removed - natural terrain should remain
        
        if not isMultiplayerClient() then
            -- SINGLEPLAYER ONLY: Create structures client-side
            -- (In MP, server creates and syncs via transmit)
            
            -- Mark floor as "done" without creating - natural terrain remains
            if not floorPrepared and centerSquareExists and chunkLoaded then
                -- Clear any zombies and corpses from the refuge area (force clean even in remote areas)
                if SpatialRefuge.ClearZombiesFromArea then
                    SpatialRefuge.ClearZombiesFromArea(teleportX, teleportY, teleportZ, radius, true)
                end
                floorPrepared = true
            end

            -- Try to create boundary walls (only once) - requires loaded chunks
            if not wallsCreated and centerSquareExists and chunkLoaded then
                -- Check if boundary squares exist and their chunks are loaded
                local boundarySquaresReady = true
                for x = -radius-1, radius+1 do
                    for y = -radius-1, radius+1 do
                        local isPerimeter = (x == -radius-1 or x == radius+1) or (y == -radius-1 or y == radius+1)
                        if isPerimeter then
                            local sq = cell:getGridSquare(teleportX + x, teleportY + y, teleportZ)
                            if not sq then
                                boundarySquaresReady = false
                                break
                            end
                            -- Also check chunk is loaded
                            local sqChunk = sq:getChunk()
                            if not sqChunk then
                                boundarySquaresReady = false
                                break
                            end
                        end
                    end
                    if not boundarySquaresReady then break end
                end
                
                if boundarySquaresReady and SpatialRefuge.CreateBoundaryWalls then
                    local wallsCount = SpatialRefuge.CreateBoundaryWalls(teleportX, teleportY, teleportZ, radius)
                    if wallsCount > 0 then
                        wallsCreated = true
                    end
                end
            end

            if not relicCreated and centerSquareExists and chunkLoaded and SpatialRefuge.CreateSacredRelic then
                local relic = SpatialRefuge.CreateSacredRelic(teleportX, teleportY, teleportZ, refugeId, radius)
                if relic then
                    relicCreated = true
                    
                    -- Sync position directly (avoids expensive FindRelicInRefuge search)
                    if refugeData.relicX == nil then
                        local relicSquare = relic:getSquare()
                        if relicSquare then
                            refugeData.relicX = relicSquare:getX()
                            refugeData.relicY = relicSquare:getY()
                            refugeData.relicZ = relicSquare:getZ()
                        else
                            refugeData.relicX = teleportX
                            refugeData.relicY = teleportY
                            refugeData.relicZ = teleportZ
                        end
                        SpatialRefugeData.SaveRefugeData(refugeData)
                    end
                end
            end
        else
            -- MULTIPLAYER: Server handles generation, just wait for sync
            -- Mark as done so we don't wait forever
            floorPrepared = true
            wallsCreated = true
            relicCreated = true
        end
        
        -- Stop if everything is done or max time reached
        if (floorPrepared and relicCreated and wallsCreated) or tickCount >= maxTicks then
            if tickCount >= maxTicks and not centerSquareSeen then
                teleportPlayer:Say("Refuge area not loaded. Adjust base coordinates.")
            end
            Events.OnTick.Remove(doTeleport)
        end
    end
    
    -- Schedule for next tick
    Events.OnTick.Add(doTeleport)
    
    -- Update teleport timestamp
    SpatialRefuge.UpdateTeleportTime(player)
    
    -- Visual/audio feedback
    addSound(player, refugeData.centerX, refugeData.centerY, refugeData.centerZ, 10, 1)
    player:Say("Entered Spatial Refuge")
    
    return true
end

-----------------------------------------------------------
-- Singleplayer Exit Logic
-----------------------------------------------------------

local function doSingleplayerExit(player, returnPos)
    local targetX = returnPos.x
    local targetY = returnPos.y
    local targetZ = returnPos.z
    
    -- Clear return position BEFORE teleport to prevent re-use issues
    SpatialRefuge.ClearReturnPosition(player)
    
    -- Update teleport timestamp
    SpatialRefuge.UpdateTeleportTime(player)
    
    -- Store references for the scheduled teleport
    local teleportPlayer = player
    local teleportX = targetX
    local teleportY = targetY
    local teleportZ = targetZ
    local teleportDone = false
    local tickCount = 0
    local maxTicks = 60
    
    -- Schedule teleport on next tick
    local function doExitTeleport()
        tickCount = tickCount + 1
        
        if not teleportDone then
            teleportPlayer:teleportTo(teleportX, teleportY, teleportZ)
            teleportPlayer:setLastX(teleportX)
            teleportPlayer:setLastY(teleportY)
            teleportPlayer:setLastZ(teleportZ)
            teleportDone = true
            
            -- Visual/audio feedback
            addSound(teleportPlayer, teleportX, teleportY, teleportZ, 10, 1)
            teleportPlayer:Say("Exited Spatial Refuge")
            return
        end
        
        -- Verify teleport worked on subsequent tick - retry if still in refuge
        if tickCount == 2 and SpatialRefuge.IsPlayerInRefuge(teleportPlayer) then
            teleportPlayer:teleportTo(teleportX, teleportY, teleportZ)
        end
        
        -- Stop after verification or timeout
        if tickCount >= 3 or tickCount >= maxTicks then
            Events.OnTick.Remove(doExitTeleport)
        end
    end
    
    -- Schedule for next tick
    Events.OnTick.Add(doExitTeleport)
    
    return true
end

-----------------------------------------------------------
-- Main Entry Point - EnterRefuge
-----------------------------------------------------------

-- Teleport player to their refuge
function SpatialRefuge.EnterRefuge(player)
    if not player then return false end
    
    -- CRITICAL: Double-check we're not already in refuge
    -- This prevents overwriting return position if somehow called while inside
    if SpatialRefuge.IsPlayerInRefuge and SpatialRefuge.IsPlayerInRefuge(player) then
        player:Say("Already in refuge!")
        return false
    end
    
    -- Validate player state
    local canEnter, reason = SpatialRefuge.CanEnterRefuge(player)
    if not canEnter then
        player:Say(reason)
        return false
    end
    
    -- Get current position for return
    local returnX = player:getX()
    local returnY = player:getY()
    local returnZ = player:getZ()
    
    if isMultiplayerClient() then
        -- ========== MULTIPLAYER PATH ==========
        -- Send request to server, server generates structures
        -- Client will teleport when server responds via OnServerCommand
        
        local args = { 
            returnX = returnX, 
            returnY = returnY, 
            returnZ = returnZ 
        }
        
        sendClientCommand(SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.REQUEST_ENTER, args)
        -- Message will be shown when TeleportTo is received
        
        if getDebug() then
            print("[SpatialRefuge] Sent RequestEnter to server")
        end
        
        return true
    else
        -- ========== SINGLEPLAYER PATH ==========
        -- Generate structures locally (existing behavior)
        
        -- Get or create refuge data
        local refugeData = SpatialRefuge.GetRefugeData(player)
        
        -- If no refuge exists, generate it first
        if not refugeData then
            player:Say("Generating Spatial Refuge...")
            refugeData = SpatialRefuge.GenerateNewRefuge(player)
            
            if not refugeData then
                player:Say("Failed to generate refuge!")
                return false
            end
        end
        
        -- Save current world position for return
        SpatialRefuge.SaveReturnPosition(player, returnX, returnY, returnZ)
        
        -- Execute singleplayer enter logic
        return doSingleplayerEnter(player, refugeData)
    end
end

-----------------------------------------------------------
-- Main Entry Point - ExitRefuge
-----------------------------------------------------------

-- Teleport player back to world from refuge
function SpatialRefuge.ExitRefuge(player)
    if not player then return false end
    
    if isMultiplayerClient() then
        -- ========== MULTIPLAYER PATH ==========
        -- Send request to server, server validates and sends return coords
        
        sendClientCommand(SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.REQUEST_EXIT, {})
        player:Say("Exiting Spatial Refuge...")
        
        if getDebug() then
            print("[SpatialRefuge] Sent RequestExit to server")
        end
        
        return true
    else
        -- ========== SINGLEPLAYER PATH ==========
        -- Handle exit locally
        
        -- Get return position (uses global ModData)
        local returnPos = SpatialRefuge.GetReturnPosition(player)
        if not returnPos then
            -- No return position - player may have died or data was cleared
            -- Fall back to default location
            player:Say("Return position lost - teleporting to default location")
            local refugeData = SpatialRefuge.GetRefugeData(player)
            if refugeData then
                -- Teleport to a default safe location in the world
                returnPos = { x = 10000, y = 10000, z = 0 }
            else
                player:Say("Cannot exit - no refuge data found")
                return false
            end
        end
        
        return doSingleplayerExit(player, returnPos)
    end
end

-----------------------------------------------------------
-- Server Response Handler (Multiplayer)
-----------------------------------------------------------

-- Handle responses from server
local function OnServerCommand(module, command, args)
    -- Only handle our namespace
    if module ~= SpatialRefugeConfig.COMMAND_NAMESPACE then return end
    
    local player = getPlayer()
    if not player then return end
    
    if command == SpatialRefugeConfig.COMMANDS.MODDATA_RESPONSE then
        -- Server sent our refuge data - store it locally
        if args and args.refugeData then
            local username = player:getUsername()
            if username and args.refugeData.username == username then
                -- Store in local ModData for context menus
                local modData = ModData.getOrCreate(SpatialRefugeConfig.MODDATA_KEY)
                if not modData[SpatialRefugeConfig.REFUGES_KEY] then
                    modData[SpatialRefugeConfig.REFUGES_KEY] = {}
                end
                modData[SpatialRefugeConfig.REFUGES_KEY][username] = args.refugeData
                
                -- Store return position if provided
                if args.returnPosition then
                    if not modData.ReturnPositions then
                        modData.ReturnPositions = {}
                    end
                    modData.ReturnPositions[username] = args.returnPosition
                end
                
                if getDebug() then
                    print("[SpatialRefuge] Received ModData from server: refuge at " .. 
                          args.refugeData.centerX .. "," .. args.refugeData.centerY .. 
                          " tier " .. args.refugeData.tier)
                end
            end
        end
        
    elseif command == SpatialRefugeConfig.COMMANDS.TELEPORT_TO then
        -- Phase 1: Server sent coordinates, client teleports and waits for chunks
        -- Then client tells server chunks are ready for server-side generation
        if args and args.centerX and args.centerY and args.centerZ then
            
            if getDebug() then
                print("[SpatialRefuge] TeleportTo received, teleporting to " .. args.centerX .. "," .. args.centerY)
            end
            
            local teleportX = args.centerX
            local teleportY = args.centerY
            local teleportZ = args.centerZ
            local teleportPlayer = player
            
            -- Teleport immediately
            player:teleportTo(teleportX, teleportY, teleportZ)
            player:Say("Entering Spatial Refuge...")
            
            -- Wait for chunks to load, then notify server
            local tickCount = 0
            local maxTicks = 300  -- 5 seconds max
            local chunksSent = false
            
            local function waitForChunks()
                tickCount = tickCount + 1
                
                -- Rotate player to help load chunks in all directions
                if tickCount <= 5 then
                    teleportPlayer:setDir(tickCount % 4)
                    return
                end
                
                -- Wait a bit for chunks to stabilize
                if tickCount < 30 then return end
                
                -- Check if center chunk is loaded
                local cell = getCell()
                if not cell then return end
                
                local centerSquare = cell:getGridSquare(teleportX, teleportY, teleportZ)
                if not centerSquare then return end
                
                local chunk = centerSquare:getChunk()
                if not chunk then return end
                
                -- Chunk is loaded! Notify server
                if not chunksSent then
                    chunksSent = true
                    Events.OnTick.Remove(waitForChunks)
                    
                    if getDebug() then
                        print("[SpatialRefuge] Chunks loaded, sending ChunksReady to server")
                    end
                    
                    -- Tell server chunks are ready - server will generate structures
                    sendClientCommand(SpatialRefugeConfig.COMMAND_NAMESPACE, 
                        SpatialRefugeConfig.COMMANDS.CHUNKS_READY, {})
                end
                
                -- Timeout
                if tickCount >= maxTicks and not chunksSent then
                    Events.OnTick.Remove(waitForChunks)
                    teleportPlayer:Say("Failed to load refuge area")
                end
            end
            
            Events.OnTick.Add(waitForChunks)
            SpatialRefuge.UpdateTeleportTime(player)
        end
        
    elseif command == SpatialRefugeConfig.COMMANDS.GENERATION_COMPLETE then
        -- Phase 2 complete: Server finished generating structures
        -- Confirm to player (structures should now be visible)
        if args and args.centerX then
            player:Say("Entered Spatial Refuge")
            
            -- Repair wall/relic properties that may not persist in map save
            -- (PZ map serialization doesn't preserve all IsoThumpable properties)
            local refugeData = SpatialRefuge.GetRefugeData and SpatialRefuge.GetRefugeData(player)
            if refugeData and SpatialRefugeShared and SpatialRefugeShared.RepairRefugeProperties then
                -- Delay slightly to ensure chunks are fully synced
                local repairTicks = 0
                local function delayedRepair()
                    repairTicks = repairTicks + 1
                    if repairTicks < 30 then return end -- ~0.5 sec delay
                    Events.OnTick.Remove(delayedRepair)
                    SpatialRefugeShared.RepairRefugeProperties(refugeData)
                end
                Events.OnTick.Add(delayedRepair)
            end
            
            -- Visual/audio feedback
            addSound(player, args.centerX, args.centerY, args.centerZ, 10, 1)
            
            if getDebug() then
                print("[SpatialRefuge] GenerationComplete received, structures ready at " .. args.centerX .. "," .. args.centerY)
            end
        end
        
    elseif command == SpatialRefugeConfig.COMMANDS.EXIT_READY then
        -- Server confirmed exit, teleport to return position
        if args and args.returnX and args.returnY and args.returnZ then
            player:teleportTo(args.returnX, args.returnY, args.returnZ)
            player:setLastX(args.returnX)
            player:setLastY(args.returnY)
            player:setLastZ(args.returnZ)
            player:Say("Exited Spatial Refuge")
            SpatialRefuge.UpdateTeleportTime(player)
            
            -- Visual/audio feedback
            addSound(player, args.returnX, args.returnY, args.returnZ, 10, 1)
            
            if getDebug() then
                print("[SpatialRefuge] ExitReady received, teleported to " .. args.returnX .. "," .. args.returnY)
            end
        end
        
    elseif command == SpatialRefugeConfig.COMMANDS.UPGRADE_COMPLETE then
        -- Server confirmed upgrade - commit transaction and update local ModData
        if args and args.newTier then
            -- Commit the transaction (consume locked cores)
            if args.transactionId and SpatialRefuge.CommitUpgradeTransaction then
                SpatialRefuge.CommitUpgradeTransaction(player, args.transactionId)
            end
            
            player:Say("Refuge upgraded to " .. (args.displayName or ("Tier " .. args.newTier)))
            
            -- Update local ModData with new refuge data from server
            if args.refugeData then
                local username = player:getUsername()
                if username and args.refugeData.username == username then
                    local modData = ModData.getOrCreate(SpatialRefugeConfig.MODDATA_KEY)
                    if modData[SpatialRefugeConfig.REFUGES_KEY] then
                        modData[SpatialRefugeConfig.REFUGES_KEY][username] = args.refugeData
                        
                        if getDebug() then
                            print("[SpatialRefuge] Updated local ModData: tier=" .. args.refugeData.tier .. 
                                  " radius=" .. args.refugeData.radius)
                        end
                    end
                end
            end
            
            -- Force client-side visual refresh and cleanup of stale wall objects
            -- The server has already removed old walls, but client may have cached them
            -- Two-phase approach: immediate cleanup + delayed fallback
            if args.centerX and args.centerY and args.centerZ then
                local oldRadius = args.oldRadius or 5
                local newRadius = args.newRadius or 3
                local centerX = args.centerX
                local centerY = args.centerY
                local centerZ = args.centerZ
                local scanRadius = math.max(oldRadius, newRadius) + 2
                
                -- Calculate new perimeter bounds once
                local newMinX = centerX - newRadius
                local newMaxX = centerX + newRadius
                local newMinY = centerY - newRadius
                local newMaxY = centerY + newRadius
                
                -- Helper function to check if position is on new perimeter
                local function isOnNewPerimeter(x, y)
                    -- North/South rows
                    if y == newMinY or y == newMaxY + 1 then
                        if x >= newMinX and x <= newMaxX + 1 then
                            return true
                        end
                    end
                    -- West/East columns
                    if x == newMinX or x == newMaxX + 1 then
                        if y >= newMinY and y <= newMaxY + 1 then
                            return true
                        end
                    end
                    return false
                end
                
                -- Cleanup function (used for both immediate and delayed)
                local function doClientCleanup(phase)
                    local cell = getCell()
                    if not cell then return 0 end
                    
                    local removedClient = 0
                    
                    for dx = -scanRadius, scanRadius do
                        for dy = -scanRadius, scanRadius do
                            local x = centerX + dx
                            local y = centerY + dy
                            local square = cell:getGridSquare(x, y, centerZ)
                            if square then
                                local objects = square:getObjects()
                                if objects and not isOnNewPerimeter(x, y) then
                                    local toRemove = {}
                                    for i = 0, objects:size() - 1 do
                                        local obj = objects:get(i)
                                        if obj and obj.getModData then
                                            local md = obj:getModData()
                                            if md and md.isRefugeBoundary then
                                                table.insert(toRemove, obj)
                                            end
                                        end
                                    end
                                    for _, obj in ipairs(toRemove) do
                                        if square.RemoveWorldObject then
                                            pcall(function() square:RemoveWorldObject(obj) end)
                                        end
                                        if obj.removeFromSquare then
                                            pcall(function() obj:removeFromSquare() end)
                                        end
                                        if obj.removeFromWorld then
                                            pcall(function() obj:removeFromWorld() end)
                                        end
                                        removedClient = removedClient + 1
                                    end
                                end
                                -- Force recalculation
                                square:RecalcAllWithNeighbours(true)
                            end
                        end
                    end
                    
                    if getDebug() then
                        print("[SpatialRefuge] Client cleanup (" .. phase .. "): removed " .. removedClient .. " stale walls")
                    end
                    
                    return removedClient
                end
                
                -- PHASE 1: Immediate cleanup
                if getDebug() then
                    print("[SpatialRefuge] Phase 1: Immediate client cleanup")
                end
                local immediateRemoved = doClientCleanup("immediate")
                
                -- PHASE 2: Delayed cleanup (fallback for any stragglers)
                local cleanupTicks = 0
                local function delayedCleanup()
                    cleanupTicks = cleanupTicks + 1
                    if cleanupTicks < 30 then return end  -- ~0.5 second delay
                    
                    Events.OnTick.Remove(delayedCleanup)
                    
                    if getDebug() then
                        print("[SpatialRefuge] Phase 2: Delayed client cleanup")
                    end
                    local delayedRemoved = doClientCleanup("delayed")
                    
                    -- Show message if any walls were cleaned in either phase
                    if delayedRemoved > 0 then
                        local playerObj = getPlayer()
                        if playerObj then
                            playerObj:Say("Refuge walls synced")
                        end
                    end
                end
                
                Events.OnTick.Add(delayedCleanup)
            end
            
            -- Invalidate cached boundary bounds so new size is used
            if SpatialRefuge.InvalidateBoundsCache then
                SpatialRefuge.InvalidateBoundsCache(player)
            end
            
            if getDebug() then
                print("[SpatialRefuge] UpgradeComplete received, new tier: " .. args.newTier)
            end
        end
        
    elseif command == SpatialRefugeConfig.COMMANDS.MOVE_RELIC_COMPLETE then
        -- Server confirmed relic move
        if args and args.cornerName then
            player:Say("Sacred Relic moved to " .. args.cornerName .. ".")
            
            -- Update local cooldown
            if SpatialRefuge.UpdateRelicMoveTime then
                SpatialRefuge.UpdateRelicMoveTime(player)
            end
            
            -- Update local ModData with new relic position from server
            if args.refugeData then
                local username = player:getUsername()
                if username and args.refugeData.username == username then
                    local modData = ModData.getOrCreate(SpatialRefugeConfig.MODDATA_KEY)
                    if modData[SpatialRefugeConfig.REFUGES_KEY] then
                        modData[SpatialRefugeConfig.REFUGES_KEY][username] = args.refugeData
                        
                        if getDebug() then
                            print("[SpatialRefuge] Updated local ModData: relicX=" .. 
                                  tostring(args.refugeData.relicX) .. " relicY=" .. tostring(args.refugeData.relicY))
                        end
                    end
                end
            end
            
            if getDebug() then
                print("[SpatialRefuge] MoveRelicComplete received, corner: " .. args.cornerName)
            end
        end
        
    elseif command == SpatialRefugeConfig.COMMANDS.CLEAR_ZOMBIES then
        -- Server sent zombie IDs to clear - remove matching zombies on client
        if args and args.zombieIDs and #args.zombieIDs > 0 then
            local cell = getCell()
            if cell then
                local zombieList = cell:getZombieList()
                local removed = 0
                
                if zombieList then
                    -- Build a lookup table for faster ID checking
                    local idLookup = {}
                    for _, id in ipairs(args.zombieIDs) do
                        idLookup[id] = true
                    end
                    
                    -- Iterate backwards and remove matching zombies
                    for i = zombieList:size() - 1, 0, -1 do
                        local zombie = zombieList:get(i)
                        if zombie and zombie.getOnlineID then
                            local onlineID = zombie:getOnlineID()
                            if onlineID and idLookup[onlineID] then
                                zombie:removeFromWorld()
                                zombie:removeFromSquare()
                                removed = removed + 1
                            end
                        end
                    end
                end
                
                if getDebug() then
                    print("[SpatialRefuge] Client cleared " .. removed .. " zombies by ID (received " .. #args.zombieIDs .. " IDs)")
                end
            end
        end
        
    elseif command == SpatialRefugeConfig.COMMANDS.ERROR then
        -- Server reported an error
        local message = args and args.message or "Refuge error"
        player:Say(message)
        
        -- Rollback any pending transaction (unlocks items)
        -- Transaction ID may be included in error response, or we rollback by type
        if args and args.transactionId and SpatialRefuge.RollbackUpgradeTransaction then
            SpatialRefuge.RollbackUpgradeTransaction(player, args.transactionId)
            if getDebug() then
                print("[SpatialRefuge] Rolled back transaction: " .. args.transactionId)
            end
        elseif args and args.transactionType == "REFUGE_UPGRADE" and SpatialRefuge.RollbackUpgradeTransaction then
            -- Fallback: rollback by type if no transaction ID
            SpatialRefuge.RollbackUpgradeTransaction(player, nil)
            if getDebug() then
                print("[SpatialRefuge] Rolled back upgrade transaction by type")
            end
        end
        
        -- Legacy fallback: If error includes coreRefund and no transaction system used
        -- (for backwards compatibility or if transaction wasn't started)
        if args and args.coreRefund and args.coreRefund > 0 and not args.transactionId then
            local inv = player:getInventory()
            if inv then
                for i = 1, args.coreRefund do
                    inv:AddItem(SpatialRefugeConfig.CORE_ITEM)
                end
                player:Say("Cores refunded")
            end
        end
        
        if getDebug() then
            print("[SpatialRefuge] Error from server: " .. message)
        end
    end
end

-----------------------------------------------------------
-- Client Connection Handler
-----------------------------------------------------------

-- Track if we've requested ModData
local modDataRequested = false

-- Request ModData from server when connected (multiplayer only)
local function RequestModDataFromServer()
    if not isMultiplayerClient() then
        return  -- Not in MP client mode
    end
    
    if modDataRequested then
        return  -- Already requested
    end
    
    local player = getPlayer()
    if not player or not player:getUsername() then
        return  -- Player not ready yet
    end
    
    modDataRequested = true
    
    if getDebug() then
        print("[SpatialRefuge] Requesting ModData from server...")
    end
    
    sendClientCommand(SpatialRefugeConfig.COMMAND_NAMESPACE, 
        SpatialRefugeConfig.COMMANDS.REQUEST_MODDATA, {})
end

-- On game start in MP, request ModData with a small delay
local function OnGameStartMP()
    if not isMultiplayerClient() then
        return
    end
    
    -- Reset the flag in case of reconnect
    modDataRequested = false
    
    -- Small delay to ensure connection is stable
    local tickCount = 0
    local function requestAfterDelay()
        tickCount = tickCount + 1
        if tickCount < 60 then return end -- Wait ~1 second
        
        Events.OnTick.Remove(requestAfterDelay)
        RequestModDataFromServer()
        
        -- After ModData is received, check if player is in refuge and repair properties
        -- This handles the case where player reconnects while already inside refuge
        local repairTickCount = 0
        local function repairAfterModData()
            repairTickCount = repairTickCount + 1
            if repairTickCount < 120 then return end -- Wait ~2 seconds for ModData sync
            
            Events.OnTick.Remove(repairAfterModData)
            
            local player = getPlayer()
            if not player then return end
            
            -- Check if player is in refuge coordinates
            if SpatialRefugeData and SpatialRefugeData.IsPlayerInRefugeCoords and 
               SpatialRefugeData.IsPlayerInRefugeCoords(player) then
                -- Player reconnected while in refuge - repair properties
                local refugeData = SpatialRefuge.GetRefugeData and SpatialRefuge.GetRefugeData(player)
                if refugeData and SpatialRefugeShared and SpatialRefugeShared.RepairRefugeProperties then
                    local repaired = SpatialRefugeShared.RepairRefugeProperties(refugeData)
                    if getDebug() and repaired > 0 then
                        print("[SpatialRefuge] Repaired " .. repaired .. " refuge objects on reconnect")
                    end
                end
            end
        end
        
        Events.OnTick.Add(repairAfterModData)
    end
    
    Events.OnTick.Add(requestAfterDelay)
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

-- Register server command handler for multiplayer responses
Events.OnServerCommand.Add(OnServerCommand)

-- Request ModData when game starts in MP
Events.OnGameStart.Add(OnGameStartMP)

return SpatialRefuge
