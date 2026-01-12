require "shared/00_core/05_Config"
require "shared/01_modules/MSR_Validation"
require "shared/01_modules/MSR_Shared"
require "shared/00_core/04_Env"
require "shared/01_modules/MSR_Integrity"
require "shared/01_modules/MSR_RoomPersistence"
require "shared/01_modules/MSR_PlayerMessage"
require "shared/01_modules/MSR_ZombieClear"
require "shared/01_modules/MSR_Death"
require "client/MSR_VehicleTeleport"

local PM = MSR.PlayerMessage

local function formatPenaltyTime(seconds)
    if seconds >= 60 then
        local mins = math.floor(seconds / 60)
        local secs = seconds % 60
        return string.format("%d:%02d", mins, secs)
    end
    return tostring(seconds) .. "s"
end

-- Apply encumbrance penalty after teleport. Penalty must be calculated BEFORE teleport.
local function applyEncumbrancePenalty(player, penaltySeconds)
    if not player or not penaltySeconds or penaltySeconds <= 0 then
        MSR.UpdateTeleportTime(player)
        return
    end
    
    MSR.UpdateTeleportTimeWithPenalty(player, penaltySeconds)
    
    local cooldown = MSR.Config.getTeleportCooldown()
    local totalWait = cooldown + penaltySeconds
    PM.Say(player, PM.ENCUMBRANCE_PENALTY, formatPenaltyTime(totalWait))
end

function MSR.CanEnterRefuge(player)
    local canEnter, reason = MSR.Validation.CanEnterRefuge(player)
    if not canEnter then
        return false, reason
    end
    
    local now = K.time()
    
    local lastTeleport = MSR.GetLastTeleportTime and MSR.GetLastTeleportTime(player) or 0
    local cooldown = MSR.Config.getTeleportCooldown()
    local canTeleport, remaining = MSR.Validation.CheckCooldown(lastTeleport, cooldown, now)
    
    if not canTeleport then
        return false, PM.GetFormattedText(PM.COOLDOWN_REMAINING, remaining)
    end
    
    local lastDamage = MSR.GetLastDamageTime and MSR.GetLastDamageTime(player) or 0
    local combatBlock = MSR.Config.getCombatBlockTime()
    local canCombat, _ = MSR.Validation.CheckCooldown(lastDamage, combatBlock, now)
    
    if not canCombat then
        return false, PM.GetText(PM.CANNOT_TELEPORT_COMBAT)
    end
    
    return true, nil
end

local function doSingleplayerEnter(player, refugeData)
    local teleportX = refugeData.centerX
    local teleportY = refugeData.centerY
    local teleportZ = refugeData.centerZ
    local teleportPlayer = player
    local refugeId = refugeData.refugeId
    -- Use refugeData.radius directly (authoritative value) - tier lookup can be stale
    local radius = refugeData.radius or 1
    
    L.debug("Teleport", string.format("doSingleplayerEnter: center=%d,%d radius=%d tier=%s", 
        teleportX, teleportY, radius, tostring(refugeData.tier)))
    
    -- Penalty must be calculated before teleport (weight may change after)
    local encumbrancePenalty = MSR.Validation.GetEncumbrancePenalty(player)
    
    local tickCount = 0
    local teleportDone = false
    local floorPrepared = false
    local relicCreated = false
    local wallsCreated = false
    local centerSquareSeen = false
    local buildingsRecalculated = false
    local refugeInitialized = false
    
    local function doTeleport()
        tickCount = tickCount + 1
        
        if not teleportDone then
            teleportPlayer:teleportTo(teleportX, teleportY, teleportZ)
            teleportPlayer:setDir(0)
            teleportDone = true
            return
        end
        
        if tickCount >= 2 and tickCount <= 5 then
            teleportPlayer:setDir((tickCount - 1) % 4)
            return
        end
        
        if tickCount < 20 then return end
        
        local cell = getCell()
        if not cell then return end
        
        local centerSquare = cell:getGridSquare(teleportX, teleportY, teleportZ)
        local centerSquareExists = centerSquare ~= nil
        local chunkLoaded = centerSquareExists and centerSquare:getChunk() ~= nil
        
        if centerSquareExists and chunkLoaded then
            centerSquareSeen = true
        end
        
        if not MSR.Env.isMultiplayerClient() then
            -- Check if refuge already initialized
            if not refugeInitialized and centerSquareExists and chunkLoaded then
                local existingRelic = MSR.Shared.FindRelicInRefuge(teleportX, teleportY, teleportZ, radius, refugeId)
                local wallsExist = MSR.Shared.CheckBoundaryWallsExist(teleportX, teleportY, teleportZ, radius)
                
                if existingRelic and wallsExist then
                    refugeInitialized = true
                    floorPrepared = true
                    wallsCreated = true
                    relicCreated = true
                    L.debug("Teleport", "Refuge already initialized - skipping creation")
                end
            end
            
            if not refugeInitialized then
                if not floorPrepared and centerSquareExists and chunkLoaded then
                    if MSR.ClearZombiesFromArea then
                        MSR.ClearZombiesFromArea(teleportX, teleportY, teleportZ, radius, true)
                    end
                    floorPrepared = true
                end

                if not wallsCreated and centerSquareExists and chunkLoaded then
                    local boundarySquaresReady = true
                    for x = -radius-1, radius+1 do
                        for y = -radius-1, radius+1 do
                            local isPerimeter = (x == -radius-1 or x == radius+1) or (y == -radius-1 or y == radius+1)
                            if isPerimeter then
                                local sq = cell:getGridSquare(teleportX + x, teleportY + y, teleportZ)
                                if not sq or not sq:getChunk() then
                                    boundarySquaresReady = false
                                    break
                                end
                            end
                        end
                        if not boundarySquaresReady then break end
                    end
                    
                    if boundarySquaresReady then
                        MSR.Shared.ClearTreesFromArea(teleportX, teleportY, teleportZ, radius, false)
                        
                        if MSR.CreateBoundaryWalls then
                            local wallsCount = MSR.CreateBoundaryWalls(teleportX, teleportY, teleportZ, radius)
                            if wallsCount > 0 or MSR.Shared.CheckBoundaryWallsExist(teleportX, teleportY, teleportZ, radius) then
                                wallsCreated = true
                            end
                        end
                    end
                end

                if not relicCreated and centerSquareExists and chunkLoaded and MSR.CreateSacredRelic then
                    local relic = MSR.CreateSacredRelic(teleportX, teleportY, teleportZ, refugeId, radius)
                    if relic then
                        relicCreated = true
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
            end
        else
            floorPrepared = true
            wallsCreated = true
            relicCreated = true
        end
        
        -- Wait for chunks to load, then apply cutaway fix
        if not buildingsRecalculated and floorPrepared and relicCreated and wallsCreated then
            local allChunksReady = true
            for x = -radius-1, radius+1 do
                for y = -radius-1, radius+1 do
                    local sq = cell:getGridSquare(teleportX + x, teleportY + y, teleportZ)
                    if not sq or not sq:getChunk() then
                        allChunksReady = false
                        break
                    end
                end
                if not allChunksReady then break end
            end
            
            if allChunksReady then
                buildingsRecalculated = true
                
                -- Single integration point: Apply cutaway fix
                if MSR.RoomPersistence and MSR.RoomPersistence.ApplyCutaway then
                    MSR.RoomPersistence.ApplyCutaway(refugeData)
                end
            end
        end
        
        if (floorPrepared and relicCreated and wallsCreated and buildingsRecalculated) or tickCount >= 600 then
            if tickCount >= 600 and not centerSquareSeen then
                PM.Say(teleportPlayer, PM.AREA_NOT_LOADED)
            end
            Events.OnTick.Remove(doTeleport)
        end
    end
    
    Events.OnTick.Add(doTeleport)
    applyEncumbrancePenalty(player, encumbrancePenalty)
    addSound(player, refugeData.centerX, refugeData.centerY, refugeData.centerZ, 10, 1)
    PM.Say(player, PM.ENTERED_REFUGE)
    
    return true
end

local function doSingleplayerExit(player, returnPos)
    local targetX, targetY, targetZ = returnPos.x, returnPos.y, returnPos.z
    
    -- Save room IDs BEFORE teleport out (will restore after teleport in)
    local refugeData = MSR.GetRefugeData(player)
    if refugeData and MSR.RoomPersistence then
        local saved = MSR.RoomPersistence.Save(refugeData)
        L.debug("Teleport", string.format("doSingleplayerExit: Saved %d room IDs before exit", saved))
    end
    
    -- Store vehicle data before clearing return position
    local fromVehicle = returnPos.fromVehicle
    local vehicleId = returnPos.vehicleId
    local vehicleSeat = returnPos.vehicleSeat
    local vehicleX = returnPos.vehicleX
    local vehicleY = returnPos.vehicleY
    local vehicleZ = returnPos.vehicleZ
    
    MSR.ClearReturnPosition(player)
    -- Don't update cooldown on exit - preserve penalty from enter
    
    local teleportPlayer = player
    local teleportDone = false
    local tickCount = 0
    
    -- Vehicle return: teleport to vehicle position for re-entry
    local actualTargetX = targetX
    local actualTargetY = targetY
    local actualTargetZ = targetZ
    if fromVehicle and vehicleX and vehicleY and vehicleZ then
        actualTargetX = vehicleX
        actualTargetY = vehicleY
        actualTargetZ = vehicleZ
        L.debug("Teleport", string.format("Vehicle return: teleporting to vehicle position %.1f,%.1f,%.1f instead of exit position", vehicleX, vehicleY, vehicleZ))
    end
    
    local function doExitTeleport()
        tickCount = tickCount + 1
        
        if not teleportDone then
            teleportPlayer:teleportTo(actualTargetX, actualTargetY, actualTargetZ)
            teleportPlayer:setLastX(actualTargetX)
            teleportPlayer:setLastY(actualTargetY)
            teleportPlayer:setLastZ(actualTargetZ)
            teleportDone = true
            addSound(teleportPlayer, actualTargetX, actualTargetY, actualTargetZ, 10, 1)
            PM.Say(teleportPlayer, PM.EXITED_REFUGE)
            return
        end
        
        if tickCount == 2 and MSR.IsPlayerInRefuge(teleportPlayer) then
            teleportPlayer:teleportTo(actualTargetX, actualTargetY, actualTargetZ)
        end
        
        if tickCount >= 3 then
            Events.OnTick.Remove(doExitTeleport)
            
            -- Attempt to re-enter vehicle if teleported from one
            if fromVehicle and vehicleId and MSR.VehicleTeleport then
                MSR.VehicleTeleport.TryReenterVehicle(teleportPlayer, vehicleId, vehicleSeat, vehicleX, vehicleY, vehicleZ)
            end
        end
    end
    
    Events.OnTick.Add(doExitTeleport)
    return true
end

function MSR.EnterRefuge(player)
    if not player then return false end
    
    if MSR.IsPlayerInRefuge and MSR.IsPlayerInRefuge(player) then
        PM.Say(player, PM.ALREADY_IN_REFUGE)
        return false
    end
    
    local canEnter, reason = MSR.CanEnterRefuge(player)
    if not canEnter then
        PM.SayRaw(player, reason)
        return false
    end
    
    -- Get vehicle data before exiting
    local vehicleData = nil
    if player:getVehicle() and MSR.VehicleTeleport then
        vehicleData = MSR.VehicleTeleport.GetVehicleDataForEntry(player)
        MSR.VehicleTeleport.ExitVehicleForTeleport(player)
    end
    
    local returnX, returnY, returnZ = player:getX(), player:getY(), player:getZ()
    
    if MSR.Env.isMultiplayerClient() then
        local requestArgs = {
            returnX = returnX, returnY = returnY, returnZ = returnZ
        }
        -- Include vehicle data if teleporting from vehicle
        if vehicleData then
            requestArgs.fromVehicle = true
            requestArgs.vehicleId = vehicleData.vehicleId
            requestArgs.vehicleSeat = vehicleData.vehicleSeat
            requestArgs.vehicleX = vehicleData.vehicleX
            requestArgs.vehicleY = vehicleData.vehicleY
            requestArgs.vehicleZ = vehicleData.vehicleZ
            L.debug("Teleport", string.format("Including vehicle data: id=%s seat=%s pos=%.1f,%.1f,%.1f", 
                tostring(vehicleData.vehicleId), tostring(vehicleData.vehicleSeat),
                vehicleData.vehicleX or 0, vehicleData.vehicleY or 0, vehicleData.vehicleZ or 0))
        end
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_ENTER, requestArgs)
        L.debug("Teleport", "Sent RequestEnter to server")
        return true
    end
    
    local refugeData = MSR.GetRefugeData(player)
    if not refugeData then
        PM.Say(player, PM.GENERATING_REFUGE)
        refugeData = MSR.GenerateNewRefuge(player)
        if not refugeData then
            PM.Say(player, PM.FAILED_TO_GENERATE)
            return false
        end
    end
    
    -- Save return position (with or without vehicle data)
    local username = player:getUsername()
    if vehicleData then
        MSR.Data.SaveReturnPositionWithVehicle(username, returnX, returnY, returnZ, 
            vehicleData.vehicleId, vehicleData.vehicleSeat,
            vehicleData.vehicleX, vehicleData.vehicleY, vehicleData.vehicleZ)
    else
        MSR.SaveReturnPosition(player, returnX, returnY, returnZ)
    end
    
    return doSingleplayerEnter(player, refugeData)
end

function MSR.ExitRefuge(player)
    if not player then return false end
    
    if MSR.Env.isMultiplayerClient() then
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_EXIT, {})
        L.debug("Teleport", "Sent RequestExit to server")
        return true
    end
    
    local returnPos = MSR.GetReturnPosition(player)
    if not returnPos then
        PM.Say(player, PM.RETURN_POSITION_LOST)
        local refugeData = MSR.GetRefugeData(player)
        if refugeData then
            returnPos = { x = 10000, y = 10000, z = 0 }
        else
            PM.Say(player, PM.CANNOT_EXIT_NO_DATA)
            return false
        end
    end
    
    return doSingleplayerExit(player, returnPos)
end

local function OnServerCommand(module, command, args)
    if module ~= MSR.Config.COMMAND_NAMESPACE then return end
    
    local player = getPlayer()
    if not player then return end
    
    if command == MSR.Config.COMMANDS.MODDATA_RESPONSE then
        if args and args.refugeData then
            local username = player:getUsername()
            if username and args.refugeData.username == username then
                local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
                modData[MSR.Config.REFUGES_KEY] = modData[MSR.Config.REFUGES_KEY] or {}
                modData[MSR.Config.REFUGES_KEY][username] = args.refugeData
                
                if args.returnPosition then
                    modData.ReturnPositions = modData.ReturnPositions or {}
                    modData.ReturnPositions[username] = args.returnPosition
                end
                
                -- Mark data as ready on client after receiving valid data from server
                MSR.Data.SetModDataReady(true)
                
                L.debug("Teleport", "Received ModData: refuge at " .. args.refugeData.centerX .. "," .. args.refugeData.centerY)
            end
        end
        
    elseif command == MSR.Config.COMMANDS.TELEPORT_TO then
        if args and args.centerX and args.centerY and args.centerZ then
            L.debug("Teleport", "TeleportTo received: " .. args.centerX .. "," .. args.centerY)
            
            -- Use encumbrance penalty from server (server is authoritative for cooldown)
            local encumbrancePenalty = args.encumbrancePenalty or 0
            
            local teleportX, teleportY, teleportZ = args.centerX, args.centerY, args.centerZ
            local teleportPlayer = player
            
            player:teleportTo(teleportX, teleportY, teleportZ)
            
            local tickCount = 0
            local chunksSent = false
            
            local function waitForChunks()
                tickCount = tickCount + 1
                
                if tickCount <= 5 then
                    teleportPlayer:setDir(tickCount % 4)
                    return
                end
                
                if tickCount < 30 then return end
                
                -- Timeout: area failed to load
                if tickCount >= 300 then
                    Events.OnTick.Remove(waitForChunks)
                    PM.Say(teleportPlayer, PM.FAILED_TO_LOAD_AREA)
                    return
                end
                
                local cell = getCell()
                if not cell then return end
                
                local centerSquare = cell:getGridSquare(teleportX, teleportY, teleportZ)
                if not centerSquare or not centerSquare:getChunk() then return end
                
                chunksSent = true
                Events.OnTick.Remove(waitForChunks)
                L.debug("Teleport", "Chunks loaded, sending ChunksReady")
                sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.CHUNKS_READY, {})
            end
            
            Events.OnTick.Add(waitForChunks)
            applyEncumbrancePenalty(player, encumbrancePenalty)
        end
        
    elseif command == MSR.Config.COMMANDS.GENERATION_COMPLETE then
        L.debug("Teleport", "GENERATION_COMPLETE received")
        if args and args.centerX then
            PM.Say(player, PM.ENTERED_REFUGE)
            
            if MSR.Env.isMultiplayerClient() then
                local refugeData = MSR.GetRefugeData(player)
                if refugeData then
                    -- Merge roomIds from server (server stores what client synced earlier)
                    if args.roomIds then
                        refugeData.roomIds = args.roomIds
                        L.debug("Teleport", string.format("Received %d roomIds from server", K.count(args.roomIds)))
                    end
                    
                    local repairTicks = 0
                    local function delayedIntegrityCheck()
                        repairTicks = repairTicks + 1
                        if repairTicks < 30 then return end
                        Events.OnTick.Remove(delayedIntegrityCheck)
                        MSR.Integrity.ValidateAndRepair(refugeData, {
                            source = "enter_client",
                            player = player
                        })
                        
                        -- After integrity check, restore rooms and recalculate building recognition
                        local recalcTicks = 0
                        local function delayedBuildingRecalc()
                            recalcTicks = recalcTicks + 1
                            if recalcTicks < 60 then return end  -- Wait 1 second after integrity check
                            
                            Events.OnTick.Remove(delayedBuildingRecalc)
                            
                            -- Apply cutaway fix
                            if MSR.RoomPersistence and MSR.RoomPersistence.ApplyCutaway then
                                MSR.RoomPersistence.ApplyCutaway(refugeData)
                            end
                        end
                        Events.OnTick.Add(delayedBuildingRecalc)
                    end
                    Events.OnTick.Add(delayedIntegrityCheck)
                end
            end
            
            addSound(player, args.centerX, args.centerY, args.centerZ, 10, 1)
        end
        
    elseif command == MSR.Config.COMMANDS.EXIT_READY then
        if args and args.returnX and args.returnY and args.returnZ then
            -- Save room IDs BEFORE teleport out (will restore after teleport in)
            local refugeData = MSR.GetRefugeData(player)
            if refugeData and MSR.RoomPersistence then
                local saved = MSR.RoomPersistence.Save(refugeData)
                if saved > 0 then
                    L.debug("Teleport", string.format("Saved %d room IDs before exit", saved))
                end
                if MSR.Env.isMultiplayerClient() and refugeData.roomIds and MSR.RoomPersistence.SyncToServer then
                    MSR.RoomPersistence.SyncToServer(refugeData)
                end
            end
            
            player:teleportTo(args.returnX, args.returnY, args.returnZ)
            player:setLastX(args.returnX)
            player:setLastY(args.returnY)
            player:setLastZ(args.returnZ)
            PM.Say(player, PM.EXITED_REFUGE)
            -- Don't update cooldown on exit - preserve penalty from enter
            addSound(player, args.returnX, args.returnY, args.returnZ, 10, 1)
            
            L.debug("Teleport", "ExitReady: teleported to " .. args.returnX .. "," .. args.returnY)
            
            -- Attempt to re-enter vehicle if teleported from one
            if args.fromVehicle and args.vehicleId and MSR.VehicleTeleport then
                L.debug("Teleport", string.format("Attempting vehicle re-entry: id=%s seat=%s pos=%.1f,%.1f,%.1f", 
                    tostring(args.vehicleId), tostring(args.vehicleSeat),
                    args.vehicleX or 0, args.vehicleY or 0, args.vehicleZ or 0))
                MSR.VehicleTeleport.TryReenterVehicle(player, args.vehicleId, args.vehicleSeat, 
                    args.vehicleX, args.vehicleY, args.vehicleZ)
            end
        end
        
    elseif command == MSR.Config.COMMANDS.MOVE_RELIC_COMPLETE then
        if args and args.cornerName then
            require "MSR_Context"
            local translatedCornerName = MSR.TranslateCornerName(args.cornerName)
            PM.Say(player, PM.RELIC_MOVED_TO, translatedCornerName)
            
            if MSR.InvalidateRelicContainerCache then MSR.InvalidateRelicContainerCache() end
            if MSR.UpdateRelicMoveTime then MSR.UpdateRelicMoveTime(player) end
            
            if args.refugeData then
                local username = player:getUsername()
                if username and args.refugeData.username == username then
                    local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
                    if modData[MSR.Config.REFUGES_KEY] then
                        modData[MSR.Config.REFUGES_KEY][username] = args.refugeData
                    end
                end
            end
            
            L.debug("Teleport", "MoveRelicComplete: " .. args.cornerName)
        end
        
    elseif command == MSR.Config.COMMANDS.CLEAR_ZOMBIES then
        if args and args.zombieIDs and #args.zombieIDs > 0 then
            local cell = getCell()
            if cell then
                local zombieList = cell:getZombieList()
                local removed = 0
                
                if K.isIterable(zombieList) then
                    local idLookup = {}
                    for _, id in ipairs(args.zombieIDs) do
                        idLookup[id] = true
                    end
                    
                    -- Reverse iteration for removal
                    for i = K.size(zombieList) - 1, 0, -1 do
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
                
                L.debug("Teleport", "Client cleared " .. removed .. " zombies")
            end
        end
        
    elseif command == MSR.Config.COMMANDS.FEATURE_UPGRADE_COMPLETE then
        if args then
            if args.refugeData then
                local username = player:getUsername()
                if username and args.refugeData.username == username then
                    local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
                    if modData[MSR.Config.REFUGES_KEY] then
                        modData[MSR.Config.REFUGES_KEY][username] = args.refugeData
                        L.debug("Teleport", "Updated client ModData with server refugeData for " .. tostring(args.upgradeId))
                    end
                end
            end
            
            -- onUpgradeComplete handles cache invalidation based on handler config
            MSR.UpgradeLogic.onUpgradeComplete(player, args.upgradeId, args.newLevel, args.transactionId)
            
            if args.upgradeId == MSR.Config.UPGRADES.EXPAND_REFUGE and args.centerX and args.centerY and args.centerZ then
                local ctx = {
                    oldRadius = args.oldRadius or 5,
                    newRadius = args.newRadius or 3,
                    centerX = args.centerX,
                    centerY = args.centerY,
                    centerZ = args.centerZ,
                    ticks = 0,
                    cleanupId = tostring(args.transactionId or K.timeMs())
                }
                ctx.scanRadius = math.max(ctx.oldRadius, ctx.newRadius) + 2
                ctx.newMinX = ctx.centerX - ctx.newRadius
                ctx.newMaxX = ctx.centerX + ctx.newRadius
                ctx.newMinY = ctx.centerY - ctx.newRadius
                ctx.newMaxY = ctx.centerY + ctx.newRadius
                
                local function isOnNewPerimeter(c, x, y)
                    if y == c.newMinY or y == c.newMaxY + 1 then
                        if x >= c.newMinX and x <= c.newMaxX + 1 then return true end
                    end
                    if x == c.newMinX or x == c.newMaxX + 1 then
                        if y >= c.newMinY and y <= c.newMaxY + 1 then return true end
                    end
                    return false
                end
                
                local function doCleanup(c)
                    local cell = getCell()
                    if not cell then return 0 end
                    
                    local removed = 0
                    for dx = -c.scanRadius, c.scanRadius do
                        for dy = -c.scanRadius, c.scanRadius do
                            local x, y = c.centerX + dx, c.centerY + dy
                            local square = cell:getGridSquare(x, y, c.centerZ)
                            if square then
                                local objects = square:getObjects()
                                if K.isIterable(objects) and not isOnNewPerimeter(c, x, y) then
                                    local toRemove = {}
                                    for _, obj in K.iter(objects) do
                                        if obj and obj.getModData then
                                            local md = obj:getModData()
                                            if md and md.isRefugeBoundary then
                                                table.insert(toRemove, obj)
                                            end
                                        end
                                    end
                                    for _, obj in ipairs(toRemove) do
                                        local success = pcall(function()
                                            square:transmitRemoveItemFromSquare(obj)
                                        end)
                                        if success then
                                            removed = removed + 1
                                        end
                                    end
                                end
                                square:RecalcAllWithNeighbours(true)
                            end
                        end
                    end
                    return removed
                end
                
                doCleanup(ctx)
                
                local function delayedCleanup()
                    ctx.ticks = ctx.ticks + 1
                    if ctx.ticks < 30 then return end
                    Events.OnTick.Remove(delayedCleanup)
                    local removed = doCleanup(ctx)
                    if removed > 0 then
                        local p = getPlayer()
                        if p then PM.Say(p, PM.WALLS_SYNCED) end
                    end
                end
                
                Events.OnTick.Add(delayedCleanup)
                if MSR.InvalidateBoundsCache then MSR.InvalidateBoundsCache(player) end
            end
        end
        
    elseif command == MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR then
        if args then
            MSR.UpgradeLogic.onUpgradeError(player, args.transactionId, args.reason)
        end
        
    elseif command == MSR.Config.COMMANDS.ERROR then
        local message
        if args and args.messageKey then
            local translatedText = getText(args.messageKey)
            if args.messageArgs and #args.messageArgs > 0 then
                message = string.format(translatedText, unpack(args.messageArgs))
            else
                message = translatedText
            end
            PM.SayRaw(player, message)
        elseif args and args.message then
            PM.SayRaw(player, args.message)
        else
            PM.Say(player, PM.REFUGE_ERROR)
        end
        
        L.debug("Teleport", "Error from server: " .. (message or "unknown"))
    end
end

local modDataRequested = false

local function RequestModDataFromServer()
    if not MSR.Env.isMultiplayerClient() or modDataRequested then return end
    
    local player = getPlayer()
    if not player or not player:getUsername() then return end
    
    modDataRequested = true
    L.debug("Teleport", "Requesting ModData from server")
    sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_MODDATA, {})
end

local function OnGameStartMP()
    if not MSR.Env.isMultiplayerClient() then return end
    
    modDataRequested = false
    
    local tickCount = 0
    local function requestAfterDelay()
        tickCount = tickCount + 1
        if tickCount < 60 then return end
        
        Events.OnTick.Remove(requestAfterDelay)
        RequestModDataFromServer()
        
        local integrityTickCount = 0
        local function integrityCheckAfterModData()
            integrityTickCount = integrityTickCount + 1
            if integrityTickCount < 120 then return end
            
            Events.OnTick.Remove(integrityCheckAfterModData)
            
            local player = getPlayer()
            if not player then return end
            
            if MSR.Data and MSR.Data.IsPlayerInRefugeCoords and MSR.Data.IsPlayerInRefugeCoords(player) then
                local refugeData = MSR.GetRefugeData and MSR.GetRefugeData(player)
                if refugeData and MSR.Integrity and MSR.Integrity.CheckNeedsRepair(refugeData) then
                    MSR.Integrity.ValidateAndRepair(refugeData, { source = "reconnect", player = player })
                end
            end
        end
        
        Events.OnTick.Add(integrityCheckAfterModData)
    end
    
    Events.OnTick.Add(requestAfterDelay)
end

-- Track repair attempts to avoid infinite loops
local _lastRepairAttempt = 0
local _repairCooldown = 60 -- seconds between repair attempts

local function onPeriodicIntegrityCheck()
    local player = getPlayer()
    if not player then return end
    if not MSR.Data.IsPlayerInRefugeCoords(player) then return end
    
    local refugeData = MSR.GetRefugeData(player)
    if not refugeData then return end
    
    -- Only run repairs on server/host (SP, coop host, dedicated server)
    -- Pure MP clients should not attempt repairs - server will handle it
    if MSR.Env.isMultiplayerClient() then
        -- MP client: only do local visual fixes, no authoritative repairs
        if MSR.Integrity.CheckNeedsRepair(refugeData) then
            local relic = MSR.Integrity.FindRelic(refugeData)
            if relic then
                MSR.Integrity.ClientSpriteRepair(relic)
            end
        end
        return
    end
    
    -- Server/host: do full repair but with cooldown to avoid spam
    local now = K.time()
    if now - _lastRepairAttempt < _repairCooldown then
        return
    end
    
    if MSR.Integrity.CheckNeedsRepair(refugeData) then
        _lastRepairAttempt = now
        L.debug("Teleport", "Periodic check detected issues, running repair")
        local report = MSR.Integrity.ValidateAndRepair(refugeData, { source = "periodic", player = player })
        
        -- If repair failed (sprite issue), extend cooldown to avoid spam
        if report and report.relic.found and not report.relic.spriteRepaired 
           and not report.modData.synced then
            -- Sprite repair failed - likely sprite not loaded. Extend cooldown.
            _repairCooldown = 300 -- 5 minutes
            L.log("Teleport", "Sprite repair failed (sprite may not be loaded), extending cooldown")
        else
            _repairCooldown = 60 -- Reset to normal
        end
    end
    
    -- NOTE: Periodic zombie clearing is handled by MSR.ZombieClear module
    -- It self-registers on EveryOneMinute for both client and server
end

Events.OnServerCommand.Add(OnServerCommand)
Events.OnGameStart.Add(OnGameStartMP)
Events.EveryOneMinute.Add(onPeriodicIntegrityCheck)

return MSR
