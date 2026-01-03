-- Spatial Refuge Teleportation Module

require "shared/MSR_Config"
require "shared/MSR_Validation"
require "shared/MSR_Shared"
require "shared/MSR_Env"
require "shared/MSR_Integrity"

function MSR.CanEnterRefuge(player)
    local canEnter, reason = MSR.Validation.CanEnterRefuge(player)
    if not canEnter then
        return false, reason
    end
    
    local now = K.time()
    
    local lastTeleport = MSR.GetLastTeleportTime and MSR.GetLastTeleportTime(player) or 0
    local cooldown = MSR.Config.TELEPORT_COOLDOWN or 60
    local canTeleport, remaining = MSR.Validation.CheckCooldown(lastTeleport, cooldown, now)
    
    if not canTeleport then
        return false, string.format(getText("IGUI_PortalCharging"), remaining)
    end
    
    local lastDamage = MSR.GetLastDamageTime and MSR.GetLastDamageTime(player) or 0
    local combatBlock = MSR.Config.COMBAT_TELEPORT_BLOCK or 10
    local canCombat, _ = MSR.Validation.CheckCooldown(lastDamage, combatBlock, now)
    
    if not canCombat then
        return false, getText("IGUI_CannotTeleportCombat")
    end
    
    return true, nil
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
    
    local tickCount = 0
    local teleportDone = false
    local floorPrepared = false
    local relicCreated = false
    local wallsCreated = false
    local centerSquareSeen = false
    
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
                    if MSR.Shared and MSR.Shared.ClearTreesFromArea then
                        MSR.Shared.ClearTreesFromArea(teleportX, teleportY, teleportZ, radius, false)
                    end
                    
                    if MSR.CreateBoundaryWalls then
                        local wallsCount = MSR.CreateBoundaryWalls(teleportX, teleportY, teleportZ, radius)
                        if wallsCount > 0 then wallsCreated = true end
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
        else
            floorPrepared = true
            wallsCreated = true
            relicCreated = true
        end
        
        if (floorPrepared and relicCreated and wallsCreated) or tickCount >= 600 then
            if tickCount >= 600 and not centerSquareSeen then
                teleportPlayer:Say(getText("IGUI_RefugeAreaNotLoaded"))
            end
            Events.OnTick.Remove(doTeleport)
        end
    end
    
    Events.OnTick.Add(doTeleport)
    MSR.UpdateTeleportTime(player)
    addSound(player, refugeData.centerX, refugeData.centerY, refugeData.centerZ, 10, 1)
    player:Say(getText("IGUI_EnteredRefuge"))
    
    return true
end

local function doSingleplayerExit(player, returnPos)
    local targetX, targetY, targetZ = returnPos.x, returnPos.y, returnPos.z
    
    MSR.ClearReturnPosition(player)
    MSR.UpdateTeleportTime(player)
    
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
            teleportPlayer:Say(getText("IGUI_ExitedRefuge"))
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
        player:Say(getText("IGUI_AlreadyInRefuge"))
        return false
    end
    
    local canEnter, reason = MSR.CanEnterRefuge(player)
    if not canEnter then
        player:Say(reason)
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
        player:Say(getText("IGUI_GeneratingRefuge"))
        refugeData = MSR.GenerateNewRefuge(player)
        if not refugeData then
            player:Say(getText("IGUI_FailedToGenerateRefuge"))
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
        player:Say(getText("IGUI_ExitingRefuge"))
        L.debug("Teleport", "Sent RequestExit to server")
        return true
    end
    
    local returnPos = MSR.GetReturnPosition(player)
    if not returnPos then
        player:Say(getText("IGUI_ReturnPositionLost"))
        local refugeData = MSR.GetRefugeData(player)
        if refugeData then
            returnPos = { x = 10000, y = 10000, z = 0 }
        else
            player:Say(getText("IGUI_CannotExitNoData"))
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
            
            local teleportX, teleportY, teleportZ = args.centerX, args.centerY, args.centerZ
            local teleportPlayer = player
            
            player:teleportTo(teleportX, teleportY, teleportZ)
            player:Say(getText("IGUI_EnteringRefuge"))
            
            local tickCount = 0
            local chunksSent = false
            
            local function waitForChunks()
                tickCount = tickCount + 1
                
                if tickCount <= 5 then
                    teleportPlayer:setDir(tickCount % 4)
                    return
                end
                
                if tickCount < 30 then return end
                
                local cell = getCell()
                if not cell then return end
                
                local centerSquare = cell:getGridSquare(teleportX, teleportY, teleportZ)
                if not centerSquare or not centerSquare:getChunk() then return end
                
                if not chunksSent then
                    chunksSent = true
                    Events.OnTick.Remove(waitForChunks)
                    L.debug("Teleport", "Chunks loaded, sending ChunksReady")
                    sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.CHUNKS_READY, {})
                end
                
                if tickCount >= 300 and not chunksSent then
                    Events.OnTick.Remove(waitForChunks)
                    teleportPlayer:Say(getText("IGUI_FailedToLoadRefugeArea"))
                end
            end
            
            Events.OnTick.Add(waitForChunks)
            MSR.UpdateTeleportTime(player)
        end
        
    elseif command == MSR.Config.COMMANDS.GENERATION_COMPLETE then
        L.debug("Teleport", "GENERATION_COMPLETE received")
        if args and args.centerX then
            player:Say(getText("IGUI_EnteredRefuge"))
            
            if MSR.Env.isMultiplayerClient() then
                local refugeData = MSR.GetRefugeData and MSR.GetRefugeData(player)
                if refugeData and MSR.Integrity then
                    local repairTicks = 0
                    local function delayedIntegrityCheck()
                        repairTicks = repairTicks + 1
                        if repairTicks < 30 then return end
                        Events.OnTick.Remove(delayedIntegrityCheck)
                        MSR.Integrity.ValidateAndRepair(refugeData, {
                            source = "enter_client",
                            player = player
                        })
                    end
                    Events.OnTick.Add(delayedIntegrityCheck)
                end
            end
            
            addSound(player, args.centerX, args.centerY, args.centerZ, 10, 1)
        end
        
    elseif command == MSR.Config.COMMANDS.EXIT_READY then
        if args and args.returnX and args.returnY and args.returnZ then
            player:teleportTo(args.returnX, args.returnY, args.returnZ)
            player:setLastX(args.returnX)
            player:setLastY(args.returnY)
            player:setLastZ(args.returnZ)
            player:Say(getText("IGUI_ExitedRefuge"))
            MSR.UpdateTeleportTime(player)
            addSound(player, args.returnX, args.returnY, args.returnZ, 10, 1)
            
            L.debug("Teleport", "ExitReady: teleported to " .. args.returnX .. "," .. args.returnY)
        end
        
    elseif command == MSR.Config.COMMANDS.MOVE_RELIC_COMPLETE then
        if args and args.cornerName then
            require "refuge/MSR_Context"
            local translatedCornerName = MSR.TranslateCornerName(args.cornerName)
            player:Say(string.format(getText("IGUI_SacredRelicMovedTo"), translatedCornerName))
            
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
                
                -- Use K.isIterable() and K.size() for safe Java ArrayList handling
                if K.isIterable(zombieList) then
                    local idLookup = {}
                    for _, id in ipairs(args.zombieIDs) do
                        idLookup[id] = true
                    end
                    
                    -- Reverse iteration for removal - must use manual loop
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
            if args.upgradeId == "expand_refuge" and args.refugeData then
                local username = player:getUsername()
                if username and args.refugeData.username == username then
                    local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
                    if modData[MSR.Config.REFUGES_KEY] then
                        modData[MSR.Config.REFUGES_KEY][username] = args.refugeData
                    end
                end
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
                                -- Use K.isIterable() for safe Java ArrayList check
                                if K.isIterable(objects) and not isOnNewPerimeter(c, x, y) then
                                    local toRemove = {}
                                    -- Use K.iter() for safe Java ArrayList iteration
                                    for _, obj in K.iter(objects) do
                                        if obj and obj.getModData then
                                            local md = obj:getModData()
                                            if md and md.isRefugeBoundary then
                                                table.insert(toRemove, obj)
                                            end
                                        end
                                    end
                                    for _, obj in ipairs(toRemove) do
                                        -- Use transmitRemoveItemFromSquare for proper MP sync
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
                        if p then p:Say(getText("IGUI_RefugeWallsSynced")) end
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
        elseif args and args.message then
            message = args.message
        else
            message = getText("IGUI_RefugeError")
        end
        player:Say(message)
        
        L.debug("Teleport", "Error from server: " .. message)
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
    if not MSR.Data or not MSR.Data.IsPlayerInRefugeCoords then return end
    if not MSR.Data.IsPlayerInRefugeCoords(player) then return end
    
    local refugeData = MSR.GetRefugeData and MSR.GetRefugeData(player)
    if refugeData and MSR.Integrity and MSR.Integrity.CheckNeedsRepair then
        if MSR.Integrity.CheckNeedsRepair(refugeData) then
            L.debug("Teleport", "Periodic check detected issues, running repair")
            MSR.Integrity.ValidateAndRepair(refugeData, { source = "periodic", player = player })
        end
    end
end

Events.OnServerCommand.Add(OnServerCommand)
Events.OnGameStart.Add(OnGameStartMP)
Events.EveryOneMinute.Add(onPeriodicIntegrityCheck)

return MSR
