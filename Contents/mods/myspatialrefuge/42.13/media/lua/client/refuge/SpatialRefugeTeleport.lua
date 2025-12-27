-- Spatial Refuge Teleportation Module
-- Handles entry/exit teleportation with validation

-- Assume dependencies are already loaded
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-- Check if player can enter refuge
-- Returns: canEnter (boolean), reason (string)
function SpatialRefuge.CanEnterRefuge(player)
    if not player then
        return false, "Invalid player"
    end
    
    -- Check if already in refuge
    if SpatialRefuge.IsPlayerInRefuge and SpatialRefuge.IsPlayerInRefuge(player) then
        return false, "Already in refuge"
    end
    
    -- Check if in vehicle
    if player:getVehicle() then
        return false, "Cannot enter refuge while in vehicle"
    end
    
    -- Check if climbing or falling
    if (player.isClimbing and player:isClimbing()) or (player.isFalling and player:isFalling()) then
        return false, "Cannot enter refuge while climbing or falling"
    end
    
    -- Check if encumbered
    if player:isEncumbered() then
        return false, "Cannot teleport while encumbered"
    end
    
    -- Check cooldown (using game timestamp)
    local now = getTimestamp and getTimestamp() or 0
    local lastTeleport = SpatialRefuge.GetLastTeleportTime and SpatialRefuge.GetLastTeleportTime(player) or 0
    local cooldown = SpatialRefugeConfig.TELEPORT_COOLDOWN or 60
    
    if now - lastTeleport < cooldown then
        local remaining = math.ceil(cooldown - (now - lastTeleport))
        return false, "Refuge portal charging... (" .. remaining .. "s)"
    end
    
    -- Check combat teleport blocking (if recently damaged)
    local lastDamage = SpatialRefuge.GetLastDamageTime and SpatialRefuge.GetLastDamageTime(player) or 0
    local combatBlock = SpatialRefugeConfig.COMBAT_TELEPORT_BLOCK or 10
    
    if now - lastDamage < combatBlock then
        return false, "Cannot teleport during combat!"
    end
    
    return true, nil
end

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
    
    -- Save current world position for return (uses global ModData for reliability)
    local currentX = player:getX()
    local currentY = player:getY()
    local currentZ = player:getZ()
    SpatialRefuge.SaveReturnPosition(player, currentX, currentY, currentZ)
    
    -- Store teleport data
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
        
        -- Ensure floor tiles exist (only once) - requires loaded chunks
        if not floorPrepared and centerSquareExists and chunkLoaded and SpatialRefuge.EnsureRefugeFloor then
            SpatialRefuge.EnsureRefugeFloor(teleportX, teleportY, teleportZ, radius + 1)
            
            -- Clear any zombies and corpses from the refuge area
            if SpatialRefuge.ClearZombiesFromArea then
                SpatialRefuge.ClearZombiesFromArea(teleportX, teleportY, teleportZ, radius)
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

        -- Try to create Sacred Relic (only once) - requires loaded chunks
        -- Pass radius so we can search entire refuge area for existing relic (prevents duplication)
        if not relicCreated and centerSquareExists and chunkLoaded and SpatialRefuge.CreateSacredRelic then
            local relic = SpatialRefuge.CreateSacredRelic(teleportX, teleportY, teleportZ, refugeId, radius)
            if relic then
                relicCreated = true
            end
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

-- Teleport player back to world from refuge
function SpatialRefuge.ExitRefuge(player)
    if not player then return false end
    
    -- No location check needed - exit is only available from Sacred Relic context menu
    -- which is only accessible inside the refuge
    
    -- Get return position (uses global ModData)
    local returnPos = SpatialRefuge.GetReturnPosition(player)
    if not returnPos then
        -- No return position - player may have died or data was cleared
        -- Fall back to using refuge center offset
        player:Say("Return position lost - teleporting to default location")
        local refugeData = SpatialRefuge.GetRefugeData(player)
        if refugeData then
            -- Teleport to just outside the refuge area in the world
            returnPos = { x = 10000, y = 10000, z = 0 }
        else
            player:Say("Cannot exit - no refuge data found")
            return false
        end
    end
    
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
    
    -- Schedule teleport on next tick (critical - teleporting inside timed action callback doesn't work properly)
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

return SpatialRefuge
