require "shared/MSR_Config"
require "shared/MSR_Validation"
require "shared/MSR_Shared"
require "shared/MSR_Env"
require "shared/MSR_Integrity"
require "shared/MSR_RoomPersistence"
require "shared/MSR_PlayerMessage"
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
        return false, string.format(getText("IGUI_PortalCharging"), remaining)
    end
    
    local lastDamage = MSR.GetLastDamageTime and MSR.GetLastDamageTime(player) or 0
    local combatBlock = MSR.Config.getCombatBlockTime()
    local canCombat, _ = MSR.Validation.CheckCooldown(lastDamage, combatBlock, now)
    
    if not canCombat then
        return false, getText("IGUI_CannotTeleportCombat")
    end
    
    return true, nil
end

-- Recalculate visibility/lighting after teleportation
local function recalculateRefugeBuildings(centerX, centerY, centerZ, radius)
    local cell = getCell()
    if not cell then return false end
    
    local recalculated = 0
    for x = centerX - radius - 1, centerX + radius + 1 do
        for y = centerY - radius - 1, centerY + radius + 1 do
            local square = cell:getGridSquare(x, y, centerZ)
            if square and square:getChunk() then
                square:RecalcAllWithNeighbours(true)
                recalculated = recalculated + 1
            end
        end
    end
    
    if recalculated > 0 then
        L.debug("Teleport", "Recalculated " .. recalculated .. " squares for visibility")
    end
    
    return recalculated > 0
end

local function doSingleplayerEnter(player, refugeData)
    local teleportX = refugeData.centerX
    local teleportY = refugeData.centerY
    local teleportZ = refugeData.centerZ
    local teleportPlayer = player
    local refugeId = refugeData.refugeId
    local tier = refugeData.tier or 0
    local tierData = MSR.Config.TIERS[tier]
    local radius = tierData and tierData.radius or 1
    
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
        
        -- Wait for chunks to load, then recalculate buildings (120 ticks = 2 seconds)
        if not buildingsRecalculated and floorPrepared and relicCreated and wallsCreated and tickCount >= 120 then
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
                if MSR.RoomPersistence and MSR.RoomPersistence.Restore then
                    local restored = MSR.RoomPersistence.Restore(refugeData)
                    if restored > 0 then
                        L.debug("Teleport", string.format("Restored %d room IDs after enter", restored))
                    end
                end
                
                recalculateRefugeBuildings(teleportX, teleportY, teleportZ, radius)
                buildingsRecalculated = true
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
    
    MSR.ClearReturnPosition(player)
    -- Don't update cooldown on exit - preserve penalty from enter
    
    local teleportPlayer = player
    local teleportDone = false
    local tickCount = 0
    
    local function doExitTeleport()
        tickCount = tickCount + 1
        
        if not teleportDone then
            teleportPlayer:teleportTo(targetX, targetY, targetZ)
            teleportPlayer:setLastX(targetX)
            teleportPlayer:setLastY(targetY)
            teleportPlayer:setLastZ(targetZ)
            teleportDone = true
            addSound(teleportPlayer, targetX, targetY, targetZ, 10, 1)
            PM.Say(teleportPlayer, PM.EXITED_REFUGE)
            return
        end
        
        if tickCount == 2 and MSR.IsPlayerInRefuge(teleportPlayer) then
            teleportPlayer:teleportTo(targetX, targetY, targetZ)
        end
        
        if tickCount >= 3 then
            Events.OnTick.Remove(doExitTeleport)
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
    
    local returnX, returnY, returnZ = player:getX(), player:getY(), player:getZ()
    
    if MSR.Env.isMultiplayerClient() then
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_ENTER, {
            returnX = returnX, returnY = returnY, returnZ = returnZ
        })
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
    
    MSR.SaveReturnPosition(player, returnX, returnY, returnZ)
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
                            
                            -- Restore room IDs AFTER teleport in (saved before teleport out)
                            if MSR.RoomPersistence and MSR.RoomPersistence.Restore then
                                local restored = MSR.RoomPersistence.Restore(refugeData)
                                if restored > 0 then
                                    L.debug("Teleport", string.format("Restored %d room IDs after enter", restored))
                                end
                            end
                            
                            recalculateRefugeBuildings(
                                refugeData.centerX, 
                                refugeData.centerY, 
                                refugeData.centerZ, 
                                refugeData.radius or 1
                            )
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
        end
        
    elseif command == MSR.Config.COMMANDS.MOVE_RELIC_COMPLETE then
        if args and args.cornerName then
            require "refuge/MSR_Context"
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
            
            if args.upgradeId == "expand_refuge" then
                if MSR.InvalidateRelicContainerCache then MSR.InvalidateRelicContainerCache() end
            end
            
            MSR.UpgradeLogic.onUpgradeComplete(player, args.upgradeId, args.newLevel, args.transactionId)
            
            if args.upgradeId == "expand_refuge" and args.centerX and args.centerY and args.centerZ then
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

local function onPeriodicIntegrityCheck()
    local player = getPlayer()
    if not player then return end
    if not MSR.Data.IsPlayerInRefugeCoords(player) then return end
    
    local refugeData = MSR.GetRefugeData(player)
    if refugeData and MSR.Integrity.CheckNeedsRepair(refugeData) then
        L.debug("Teleport", "Periodic check detected issues, running repair")
        MSR.Integrity.ValidateAndRepair(refugeData, { source = "periodic", player = player })
    end
end

Events.OnServerCommand.Add(OnServerCommand)
Events.OnGameStart.Add(OnGameStartMP)
Events.EveryOneMinute.Add(onPeriodicIntegrityCheck)

return MSR
