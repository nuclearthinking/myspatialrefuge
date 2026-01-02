-- Spatial Refuge Teleportation Module
-- Handles entry/exit teleportation with validation
-- Supports both multiplayer (server-authoritative) and singleplayer (client-side) paths

require "shared/MSR_Config"
require "shared/MSR_Validation"
require "shared/MSR_Shared"
require "shared/MSR_Env"
require "shared/MSR_Integrity"

-- Assume dependencies are already loaded



-----------------------------------------------------------
-- Environment Detection (delegated to SpatialRefugeEnv)
-----------------------------------------------------------

local function isMultiplayerClient()
    return MSR.Env.isClient() and not MSR.Env.isServer()
end

local function isSinglePlayer()
    return MSR.Env.isSingleplayer()
end

-----------------------------------------------------------
-- Validation
-- Note: Core validation logic is in shared/MSR.Validation.lua
-- Client adds cooldown checks using client-side state
-----------------------------------------------------------

-- Check if player can enter refuge
-- Returns: canEnter (boolean), reason (string)
function MSR.CanEnterRefuge(player)
    -- Use shared validation for physical state checks
    local canEnter, reason = MSR.Validation.CanEnterRefuge(player)
    if not canEnter then
        return false, reason
    end
    
    -- Client-specific cooldown checks (using client-side state)
    -- Note: In MP, server also validates cooldowns with server-side state
    local now = getTimestamp and getTimestamp() or 0
    
    -- Check teleport cooldown
    local lastTeleport = MSR.GetLastTeleportTime and MSR.GetLastTeleportTime(player) or 0
    local cooldown = MSR.Config.TELEPORT_COOLDOWN or 60
    local canTeleport, remaining = MSR.Validation.CheckCooldown(lastTeleport, cooldown, now)
    
    if not canTeleport then
        return false, string.format(getText("IGUI_PortalCharging"), remaining)
    end
    
    -- Check combat teleport blocking (if recently damaged)
    local lastDamage = MSR.GetLastDamageTime and MSR.GetLastDamageTime(player) or 0
    local combatBlock = MSR.Config.COMBAT_TELEPORT_BLOCK or 10
    local canCombat, _ = MSR.Validation.CheckCooldown(lastDamage, combatBlock, now)
    
    if not canCombat then
        return false, getText("IGUI_CannotTeleportCombat")
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
    local tierData = MSR.Config.TIERS[tier]
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
                if MSR.ClearZombiesFromArea then
                    MSR.ClearZombiesFromArea(teleportX, teleportY, teleportZ, radius, true)
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
                
                if boundarySquaresReady then
                    -- Clear trees BEFORE creating walls (same as upgrade/MP paths)
                    if MSR.Shared and MSR.Shared.ClearTreesFromArea then
                        MSR.Shared.ClearTreesFromArea(teleportX, teleportY, teleportZ, radius, false)
                    end
                    
                    if MSR.CreateBoundaryWalls then
                        local wallsCount = MSR.CreateBoundaryWalls(teleportX, teleportY, teleportZ, radius)
                        if wallsCount > 0 then
                            wallsCreated = true
                        end
                    end
                end
            end

            if not relicCreated and centerSquareExists and chunkLoaded and MSR.CreateSacredRelic then
                local relic = MSR.CreateSacredRelic(teleportX, teleportY, teleportZ, refugeId, radius)
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
                        MSR.Data.SaveRefugeData(refugeData)
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
                teleportPlayer:Say(getText("IGUI_RefugeAreaNotLoaded"))
            end
            Events.OnTick.Remove(doTeleport)
        end
    end
    
    -- Schedule for next tick
    Events.OnTick.Add(doTeleport)
    
    -- Update teleport timestamp
    MSR.UpdateTeleportTime(player)
    
    -- Visual/audio feedback
    addSound(player, refugeData.centerX, refugeData.centerY, refugeData.centerZ, 10, 1)
    player:Say(getText("IGUI_EnteredRefuge"))
    
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
    MSR.ClearReturnPosition(player)
    
    -- Update teleport timestamp
    MSR.UpdateTeleportTime(player)
    
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
            teleportPlayer:Say(getText("IGUI_ExitedRefuge"))
            return
        end
        
        -- Verify teleport worked on subsequent tick - retry if still in refuge
        if tickCount == 2 and MSR.IsPlayerInRefuge(teleportPlayer) then
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
function MSR.EnterRefuge(player)
    if not player then return false end
    
    -- CRITICAL: Double-check we're not already in refuge
    -- This prevents overwriting return position if somehow called while inside
    if MSR.IsPlayerInRefuge and MSR.IsPlayerInRefuge(player) then
        player:Say(getText("IGUI_AlreadyInRefuge"))
        return false
    end
    
    -- Validate player state
    local canEnter, reason = MSR.CanEnterRefuge(player)
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
        
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_ENTER, args)
        -- Message will be shown when TeleportTo is received
        
        if getDebug() then
            print("[MSR] Sent RequestEnter to server")
        end
        
        return true
    else
        -- ========== SINGLEPLAYER PATH ==========
        -- Generate structures locally (existing behavior)
        
        -- Get or create refuge data
        local refugeData = MSR.GetRefugeData(player)
        
        -- If no refuge exists, generate it first
        if not refugeData then
            player:Say(getText("IGUI_GeneratingRefuge"))
            refugeData = MSR.GenerateNewRefuge(player)
            
            if not refugeData then
                player:Say(getText("IGUI_FailedToGenerateRefuge"))
                return false
            end
        end
        
        -- Save current world position for return
        MSR.SaveReturnPosition(player, returnX, returnY, returnZ)
        
        -- Execute singleplayer enter logic
        return doSingleplayerEnter(player, refugeData)
    end
end

-----------------------------------------------------------
-- Main Entry Point - ExitRefuge
-----------------------------------------------------------

-- Teleport player back to world from refuge
function MSR.ExitRefuge(player)
    if not player then return false end
    
    if isMultiplayerClient() then
        -- ========== MULTIPLAYER PATH ==========
        -- Send request to server, server validates and sends return coords
        
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_EXIT, {})
        player:Say(getText("IGUI_ExitingRefuge"))
        
        if getDebug() then
            print("[MSR] Sent RequestExit to server")
        end
        
        return true
    else
        -- ========== SINGLEPLAYER PATH ==========
        -- Handle exit locally
        
        -- Get return position (uses global ModData)
        local returnPos = MSR.GetReturnPosition(player)
        if not returnPos then
            -- No return position - player may have died or data was cleared
            -- Fall back to default location
            player:Say(getText("IGUI_ReturnPositionLost"))
            local refugeData = MSR.GetRefugeData(player)
            if refugeData then
                -- Teleport to a default safe location in the world
                returnPos = { x = 10000, y = 10000, z = 0 }
            else
                player:Say(getText("IGUI_CannotExitNoData"))
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
    if module ~= MSR.Config.COMMAND_NAMESPACE then return end
    
    local player = getPlayer()
    if not player then return end
    
    if command == MSR.Config.COMMANDS.MODDATA_RESPONSE then
        -- Server sent our refuge data - store it locally
        if args and args.refugeData then
            local username = player:getUsername()
            if username and args.refugeData.username == username then
                -- Store in local ModData for context menus
                local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
                if not modData[MSR.Config.REFUGES_KEY] then
                    modData[MSR.Config.REFUGES_KEY] = {}
                end
                modData[MSR.Config.REFUGES_KEY][username] = args.refugeData
                
                -- Store return position if provided
                if args.returnPosition then
                    if not modData.ReturnPositions then
                        modData.ReturnPositions = {}
                    end
                    modData.ReturnPositions[username] = args.returnPosition
                end
                
                if getDebug() then
                    print("[MSR] Received ModData from server: refuge at " .. 
                          args.refugeData.centerX .. "," .. args.refugeData.centerY .. 
                          " tier " .. args.refugeData.tier)
                end
            end
        end
        
    elseif command == MSR.Config.COMMANDS.TELEPORT_TO then
        -- Phase 1: Server sent coordinates, client teleports and waits for chunks
        -- Then client tells server chunks are ready for server-side generation
        if args and args.centerX and args.centerY and args.centerZ then
            
            if getDebug() then
                print("[MSR] TeleportTo received, teleporting to " .. args.centerX .. "," .. args.centerY)
            end
            
            local teleportX = args.centerX
            local teleportY = args.centerY
            local teleportZ = args.centerZ
            local teleportPlayer = player
            
            -- Teleport immediately
            player:teleportTo(teleportX, teleportY, teleportZ)
            player:Say(getText("IGUI_EnteringRefuge"))
            
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
                        print("[MSR] Chunks loaded, sending ChunksReady to server")
                    end
                    
                    -- Tell server chunks are ready - server will generate structures
                    sendClientCommand(MSR.Config.COMMAND_NAMESPACE, 
                        MSR.Config.COMMANDS.CHUNKS_READY, {})
                end
                
                -- Timeout
                if tickCount >= maxTicks and not chunksSent then
                    Events.OnTick.Remove(waitForChunks)
                    teleportPlayer:Say(getText("IGUI_FailedToLoadRefugeArea"))
                end
            end
            
            Events.OnTick.Add(waitForChunks)
            MSR.UpdateTeleportTime(player)
        end
        
    elseif command == MSR.Config.COMMANDS.GENERATION_COMPLETE then
        -- Phase 2 complete: Server finished generating/validating structures
        if getDebug() then
            print("[MSR] GENERATION_COMPLETE received")
        end
        if args and args.centerX then
            player:Say(getText("IGUI_EnteredRefuge"))
            
            -- For MP clients (not coop host), run a lightweight integrity check
            -- Coop host and SP already ran the check server-side, so skip
            if MSR.Env and MSR.Env.isMultiplayerClient and MSR.Env.isMultiplayerClient() then
                local refugeData = MSR.GetRefugeData and MSR.GetRefugeData(player)
                if refugeData and MSR.Integrity then
                    -- Delay slightly to ensure chunks are fully synced from server
                    local repairTicks = 0
                    local function delayedIntegrityCheck()
                        repairTicks = repairTicks + 1
                        if repairTicks < 30 then return end -- ~0.5 sec delay
                        Events.OnTick.Remove(delayedIntegrityCheck)
                        MSR.Integrity.ValidateAndRepair(refugeData, {
                            source = "enter_client",
                            player = player
                        })
                    end
                    Events.OnTick.Add(delayedIntegrityCheck)
                end
            elseif getDebug() then
                print("[MSR] Skipping client-side integrity check (server already handled)")
            end
            
            -- Visual/audio feedback
            addSound(player, args.centerX, args.centerY, args.centerZ, 10, 1)
            
            if getDebug() then
                print("[MSR] GenerationComplete received, structures ready at " .. args.centerX .. "," .. args.centerY)
            end
        end
        
    elseif command == MSR.Config.COMMANDS.EXIT_READY then
        -- Server confirmed exit, teleport to return position
        if args and args.returnX and args.returnY and args.returnZ then
            player:teleportTo(args.returnX, args.returnY, args.returnZ)
            player:setLastX(args.returnX)
            player:setLastY(args.returnY)
            player:setLastZ(args.returnZ)
            player:Say(getText("IGUI_ExitedRefuge"))
            MSR.UpdateTeleportTime(player)
            
            -- Visual/audio feedback
            addSound(player, args.returnX, args.returnY, args.returnZ, 10, 1)
            
            if getDebug() then
                print("[MSR] ExitReady received, teleported to " .. args.returnX .. "," .. args.returnY)
            end
        end
        
    elseif command == MSR.Config.COMMANDS.MOVE_RELIC_COMPLETE then
        -- Server confirmed relic move
        if args and args.cornerName then
            -- Translate canonical corner name for display (cornerName is canonical from server)
            -- Ensure SpatialRefugeContext is loaded to get TranslateCornerName function
            require "refuge/MSR_Context"
            local translatedCornerName = MSR.TranslateCornerName(args.cornerName)
            local message = string.format(getText("IGUI_SacredRelicMovedTo"), translatedCornerName)
            player:Say(message)
            
            -- Invalidate relic container cache (relic moved to new position)
            if MSR.InvalidateRelicContainerCache then
                MSR.InvalidateRelicContainerCache()
            end
            
            -- Update local cooldown
            if MSR.UpdateRelicMoveTime then
                MSR.UpdateRelicMoveTime(player)
            end
            
            -- Update local ModData with new relic position from server
            if args.refugeData then
                local username = player:getUsername()
                if username and args.refugeData.username == username then
                    local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
                    if modData[MSR.Config.REFUGES_KEY] then
                        modData[MSR.Config.REFUGES_KEY][username] = args.refugeData
                        
                        if getDebug() then
                            print("[MSR] Updated local ModData: relicX=" .. 
                                  tostring(args.refugeData.relicX) .. " relicY=" .. tostring(args.refugeData.relicY))
                        end
                    end
                end
            end
            
            if getDebug() then
                print("[MSR] MoveRelicComplete received, corner: " .. args.cornerName)
            end
        end
        
    elseif command == MSR.Config.COMMANDS.CLEAR_ZOMBIES then
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
                    print("[MSR] Client cleared " .. removed .. " zombies by ID (received " .. #args.zombieIDs .. " IDs)")
                end
            end
        end
        
    elseif command == MSR.Config.COMMANDS.FEATURE_UPGRADE_COMPLETE then
        -- Server confirmed feature upgrade
        if args then
            -- IMPORTANT: Update local ModData FIRST, before calling onUpgradeComplete
            -- This ensures the UI refresh sees the updated tier/data
            if args.upgradeId == "expand_refuge" and args.refugeData then
                local username = player:getUsername()
                if username and args.refugeData.username == username then
                    local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
                    if modData[MSR.Config.REFUGES_KEY] then
                        modData[MSR.Config.REFUGES_KEY][username] = args.refugeData
                        
                        if getDebug() then
                            print("[MSR] FeatureUpgrade: Updated local ModData BEFORE UI refresh: tier=" .. args.refugeData.tier .. 
                                  " radius=" .. args.refugeData.radius)
                        end
                    end
                end
                
                -- Invalidate relic container cache (refuge expanded, relic may have moved)
                if MSR.InvalidateRelicContainerCache then
                    MSR.InvalidateRelicContainerCache()
                end
            end
            
            -- Now call onUpgradeComplete which will refresh the UI with updated data
            local UpgradeLogic = require "refuge/MSR_UpgradeLogic"
            UpgradeLogic.onUpgradeComplete(
                player,
                args.upgradeId,
                args.newLevel,
                args.transactionId
            )
            
            -- Special handling for expand_refuge: client-side wall cleanup
            -- Server has removed old walls, but client may have stale cached objects
            if args.upgradeId == "expand_refuge" and args.centerX and args.centerY and args.centerZ then
                
                -- Create cleanup context to avoid race conditions with multiple upgrades
                -- Each upgrade gets its own context, so concurrent cleanups don't interfere
                local cleanupContext = {
                    oldRadius = args.oldRadius or 5,
                    newRadius = args.newRadius or 3,
                    centerX = args.centerX,
                    centerY = args.centerY,
                    centerZ = args.centerZ,
                    ticks = 0,
                    cleanupId = tostring(args.transactionId or getTimestampMs())
                }
                cleanupContext.scanRadius = math.max(cleanupContext.oldRadius, cleanupContext.newRadius) + 2
                
                -- Calculate new perimeter bounds once
                cleanupContext.newMinX = cleanupContext.centerX - cleanupContext.newRadius
                cleanupContext.newMaxX = cleanupContext.centerX + cleanupContext.newRadius
                cleanupContext.newMinY = cleanupContext.centerY - cleanupContext.newRadius
                cleanupContext.newMaxY = cleanupContext.centerY + cleanupContext.newRadius
                
                -- Helper function to check if position is on new perimeter
                local function isOnNewPerimeter(ctx, x, y)
                    -- North/South rows
                    if y == ctx.newMinY or y == ctx.newMaxY + 1 then
                        if x >= ctx.newMinX and x <= ctx.newMaxX + 1 then
                            return true
                        end
                    end
                    -- West/East columns
                    if x == ctx.newMinX or x == ctx.newMaxX + 1 then
                        if y >= ctx.newMinY and y <= ctx.newMaxY + 1 then
                            return true
                        end
                    end
                    return false
                end
                
                -- Cleanup function for stale wall objects (uses context)
                local function doFeatureUpgradeCleanup(ctx, phase)
                    local cell = getCell()
                    if not cell then return 0 end
                    
                    local removedClient = 0
                    
                    for dx = -ctx.scanRadius, ctx.scanRadius do
                        for dy = -ctx.scanRadius, ctx.scanRadius do
                            local x = ctx.centerX + dx
                            local y = ctx.centerY + dy
                            local square = cell:getGridSquare(x, y, ctx.centerZ)
                            if square then
                                local objects = square:getObjects()
                                if objects and not isOnNewPerimeter(ctx, x, y) then
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
                        print("[MSR] FeatureUpgrade cleanup [" .. ctx.cleanupId .. "] (" .. phase .. "): removed " .. removedClient .. " stale walls")
                    end
                    
                    return removedClient
                end
                
                -- PHASE 1: Immediate cleanup
                if getDebug() then
                    print("[MSR] FeatureUpgrade Phase 1: Immediate client cleanup [" .. cleanupContext.cleanupId .. "]")
                end
                doFeatureUpgradeCleanup(cleanupContext, "immediate")
                
                -- PHASE 2: Delayed cleanup (fallback for any stragglers)
                -- Capture context in closure to ensure each cleanup is independent
                local ctx = cleanupContext
                local function delayedFeatureCleanup()
                    ctx.ticks = ctx.ticks + 1
                    if ctx.ticks < 30 then return end  -- ~0.5 second delay
                    
                    Events.OnTick.Remove(delayedFeatureCleanup)
                    
                    if getDebug() then
                        print("[MSR] FeatureUpgrade Phase 2: Delayed client cleanup [" .. ctx.cleanupId .. "]")
                    end
                    local delayedRemoved = doFeatureUpgradeCleanup(ctx, "delayed")
                    
                    if delayedRemoved > 0 then
                        local playerObj = getPlayer()
                        if playerObj then
                            playerObj:Say(getText("IGUI_RefugeWallsSynced"))
                        end
                    end
                end
                
                Events.OnTick.Add(delayedFeatureCleanup)
                
                -- Invalidate cached boundary bounds so new size is used
                if MSR.InvalidateBoundsCache then
                    MSR.InvalidateBoundsCache(player)
                end
                
                if getDebug() then
                    print("[MSR] FeatureUpgradeComplete: expand_refuge processed, new tier: " .. tostring(args.newTier))
                end
            end
        end
        
    elseif command == MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR then
        -- Server reported feature upgrade error
        if args then
            local UpgradeLogic = require "refuge/MSR_UpgradeLogic"
            UpgradeLogic.onUpgradeError(
                player,
                args.transactionId,
                args.reason
            )
        end
        
    elseif command == MSR.Config.COMMANDS.ERROR then
        -- Server reported an error
        local message
        if args and args.messageKey then
            -- New format: translation key with optional args
            local translatedText = getText(args.messageKey)
            if args.messageArgs and #args.messageArgs > 0 then
                message = string.format(translatedText, unpack(args.messageArgs))
            else
                message = translatedText
            end
        elseif args and args.message then
            -- Legacy format: raw message string
            message = args.message
        else
            message = getText("IGUI_RefugeError")
        end
        player:Say(message)
        
        if getDebug() then
            print("[MSR] Error from server: " .. message)
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
        print("[MSR] Requesting ModData from server...")
    end
    
    sendClientCommand(MSR.Config.COMMAND_NAMESPACE, 
        MSR.Config.COMMANDS.REQUEST_MODDATA, {})
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
        
        -- After ModData is received, check if player is in refuge and validate integrity
        -- This handles the case where player reconnects while already inside refuge
        local integrityTickCount = 0
        local function integrityCheckAfterModData()
            integrityTickCount = integrityTickCount + 1
            if integrityTickCount < 120 then return end -- Wait ~2 seconds for ModData sync
            
            Events.OnTick.Remove(integrityCheckAfterModData)
            
            local player = getPlayer()
            if not player then return end
            
            -- Check if player is in refuge coordinates
            if MSR.Data and MSR.Data.IsPlayerInRefugeCoords and 
               MSR.Data.IsPlayerInRefugeCoords(player) then
                -- Player reconnected while in refuge - check if repair needed first
                local refugeData = MSR.GetRefugeData and MSR.GetRefugeData(player)
                if refugeData and MSR.Integrity then
                    -- Only run full repair if lightweight check detects issues
                    if MSR.Integrity.CheckNeedsRepair(refugeData) then
                        local report = MSR.Integrity.ValidateAndRepair(refugeData, {
                            source = "reconnect",
                            player = player
                        })
                        if getDebug() then
                            print("[MSR] Reconnect repair: relic=" .. tostring(report.relic.found) ..
                                  " walls=" .. report.walls.repaired .. " synced=" .. tostring(report.modData.synced))
                        end
                    elseif getDebug() then
                        print("[MSR] Reconnect: refuge intact, no repair needed")
                    end
                end
            end
        end
        
        Events.OnTick.Add(integrityCheckAfterModData)
    end
    
    Events.OnTick.Add(requestAfterDelay)
end

-----------------------------------------------------------
-- Periodic Integrity Check (runs every in-game minute)
-----------------------------------------------------------

-- Lightweight periodic check runs while player is in refuge
-- Only triggers full repair if CheckNeedsRepair() returns true
local function onPeriodicIntegrityCheck()
    local player = getPlayer()
    if not player then return end
    
    -- Only check if player is in refuge
    if not MSR.Data or not MSR.Data.IsPlayerInRefugeCoords then
        return
    end
    
    if not MSR.Data.IsPlayerInRefugeCoords(player) then
        return
    end
    
    -- Lightweight check first
    local refugeData = MSR.GetRefugeData and MSR.GetRefugeData(player)
    if refugeData and MSR.Integrity and MSR.Integrity.CheckNeedsRepair then
        if MSR.Integrity.CheckNeedsRepair(refugeData) then
            if getDebug() then
                print("[MSR] Periodic check detected issues, running integrity repair")
            end
            MSR.Integrity.ValidateAndRepair(refugeData, {
                source = "periodic",
                player = player
            })
        end
    end
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

-- Register server command handler for multiplayer responses
Events.OnServerCommand.Add(OnServerCommand)

-- Request ModData when game starts in MP
Events.OnGameStart.Add(OnGameStartMP)

-- Periodic integrity check while in refuge (every in-game minute)
Events.EveryOneMinute.Add(onPeriodicIntegrityCheck)

return MSR
