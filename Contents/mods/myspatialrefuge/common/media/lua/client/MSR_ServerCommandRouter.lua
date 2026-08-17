require "00_core/00_MSR"
require "00_core/Events"

require "MSR_PlayerMessage"
require "MSR_Integrity"
require "MSR_RoomPersistence"
require "MSR_UpgradeLogic"
require "MSR_VehicleTeleport"
require "MSR_SpatialWell"
require "MSR_Transaction"
require "MSR_UpgradeItemCache"
require "MSR_Echo"

require "helpers/TeleportCooldown"
require "helpers/TeleportFlow"

local Router = MSR.register("ServerCommandRouter")
local LOG = L.logger("Teleport")
if not Router then
    return MSR.ServerCommandRouter
end

MSR.ServerCommandRouter = Router

local PM = MSR.PlayerMessage
local TC = MSR.TeleportCooldown
local Flow = MSR.TeleportFlow
local EventsBus = MSR.Events

local function fireTeleportEvent(eventName, payload)
    EventsBus.Custom.Fire(eventName, payload)
end

local CommandHandlers = {}

local function getUpgradeWindow()
    return MSR_UpgradeWindow and MSR_UpgradeWindow.instance or nil
end

local function hasPendingTransaction(player, transactionType, transactionId)
    if not player or type(transactionId) ~= "string" then return false end
    local pending = MSR.Transaction.GetPending(player, transactionType)
    return pending ~= nil and pending.id == transactionId
end

local function shouldAcceptUpgradeResponse(args, player)
    if not args
        or type(args.operationId) ~= "string"
        or args.operationId ~= args.transactionId
        or not hasPendingTransaction(
            player,
            MSR.UpgradeLogic.TRANSACTION_TYPE,
            args.transactionId
        )
    then
        return false
    end
    local window = getUpgradeWindow()
    return not window
        or not window.isUpgradeResponseCurrent
        or window:isUpgradeResponseCurrent(args.operationId)
end

local function shouldAcceptEchoResponse(args, player)
    if not args
        or not hasPendingTransaction(player, "ECHO_ABSORB", args.transactionId)
    then
        return false
    end
    local window = getUpgradeWindow()
    local panel = window and window.echoPanel or nil
    return not panel
        or not panel.isResponseCurrent
        or panel:isResponseCurrent(args.transactionId)
end

local function handleModDataResponse(args, player)
    MSR.Data.HandleModDataResponse(args, player)
    local window = getUpgradeWindow()
    if not window then return end
    window:refreshUpgradeList()
    window:refreshCurrentUpgrade()
    if window.echoPanel and not window.echoPanel.pending then window.echoPanel:refresh() end
end

local function requestAuthoritativeRefresh()
    MSR.Data.RequestModDataFromServer(true)
end

local function handleTeleportTo(args, player)
    if not args or not args.centerX or not args.centerY or args.centerZ == nil then return end

    LOG.debug( "TeleportTo received: " .. args.centerX .. "," .. args.centerY)

    -- Use encumbrance penalty from server (server is authoritative for cooldown)
    local encumbrancePenalty = args.encumbrancePenalty or 0

    local teleportX, teleportY, teleportZ = args.centerX, args.centerY, args.centerZ
    local teleportPlayer = player

    player:teleportTo(teleportX, teleportY, teleportZ)
    fireTeleportEvent("MSR_TeleportEnterStarted", { player = player, args = args })

    Flow.waitForCenterChunk({
        player = teleportPlayer,
        centerX = teleportX,
        centerY = teleportY,
        centerZ = teleportZ,
        minTicks = 30,
        maxTicks = 300,
        rotateTicks = 5,
        onReady = function()
            LOG.debug( "Chunks loaded, sending ChunksReady")
            sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.CHUNKS_READY, {})
        end,
        onTimeout = function()
            PM.Say(teleportPlayer, PM.FAILED_TO_LOAD_AREA)
        end
    })
    TC.applyEncumbrancePenalty(player, encumbrancePenalty)
end

local function handleGenerationComplete(args, player)
    LOG.debug( "GENERATION_COMPLETE received")
    if not args or not args.centerX then return end

    PM.Say(player, PM.ENTERED_REFUGE)
    fireTeleportEvent("MSR_TeleportEnterCompleted", { player = player, args = args })

    if MSR.Env.isMultiplayerClient() then
        local refugeData = MSR.GetRefugeData(player)
        if refugeData then
            -- Merge roomIds from server (server stores what client synced earlier)
            if args.roomIds then
                refugeData.roomIds = args.roomIds
                LOG.debug( string.format("Received %d roomIds from server", K.count(args.roomIds)))
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
                    MSR.RoomPersistence.ApplyCutaway(refugeData)
                end
                Events.OnTick.Add(delayedBuildingRecalc)
            end
            Events.OnTick.Add(delayedIntegrityCheck)
        end
    end

    addSound(player, args.centerX, args.centerY, args.centerZ, 10, 1)
end

local function handleExitReady(args, player)
    if not args or not args.returnX or not args.returnY or args.returnZ == nil then return end

    -- Save room IDs BEFORE teleport out (will restore after teleport in)
    local refugeData = MSR.GetRefugeData(player)
    if refugeData then
        local saved = MSR.RoomPersistence.Save(refugeData)
        if saved > 0 then
            LOG.debug( string.format("Saved %d room IDs before exit", saved))
        end
        if MSR.Env.isMultiplayerClient() and refugeData.roomIds then
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

    LOG.debug( "ExitReady: teleported to " .. args.returnX .. "," .. args.returnY)
    fireTeleportEvent("MSR_TeleportExitCompleted", { player = player, args = args })

    -- Attempt to re-enter vehicle if teleported from one
    if args.fromVehicle and args.vehicleId then
        LOG.debug( string.format("Attempting vehicle re-entry: id=%s seat=%s pos=%.1f,%.1f,%.1f",
            tostring(args.vehicleId), tostring(args.vehicleSeat),
            args.vehicleX or 0, args.vehicleY or 0, args.vehicleZ or 0))
        MSR.VehicleTeleport.TryReenterVehicle(player, args.vehicleId, args.vehicleSeat,
            args.vehicleX, args.vehicleY, args.vehicleZ)
    end
end

local function handleMoveRelicComplete(args, player)
    if not args or not args.cornerName then return end
    require "MSR_Context"
    local translatedCornerName = MSR.TranslateCornerName(args.cornerName)
    PM.Say(player, PM.RELIC_MOVED_TO, translatedCornerName)

    if MSR.InvalidateRelicContainerCache then MSR.InvalidateRelicContainerCache() end
    MSR.UpdateRelicMoveTime(player)

    if args.refugeData then
        local username = player:getUsername()
        if username and args.refugeData.username == username then
            local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
            if modData[MSR.Config.REFUGES_KEY] then
                modData[MSR.Config.REFUGES_KEY][username] = args.refugeData
            end
        end
    end

    LOG.debug( "MoveRelicComplete: " .. args.cornerName)
end

local function buildZombieIdLookup(ids)
    if not K.isIterable(ids) then return nil end
    local idLookup = {}
    if type(ids) == "table" then
        for _, id in ipairs(ids) do
            idLookup[id] = true
        end
    else
        for _, id in K.iter(ids) do
            idLookup[id] = true
        end
    end
    return idLookup
end

local function handleClearZombies(args, _player)
    if not args or not K.isIterable(args.zombieIDs) or K.size(args.zombieIDs) == 0 then return end

    local cell = getCell()
    if not cell then return end

    local zombieList = cell:getZombieList()
    local removed = 0

    if K.isIterable(zombieList) then
        local idLookup = buildZombieIdLookup(args.zombieIDs)
        if idLookup then
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
    end

    LOG.debug( "Client cleared " .. removed .. " zombies")
end

local function handleFeatureUpgradeComplete(args, player)
    if not args then return end
    if not shouldAcceptUpgradeResponse(args, player) then
        LOG.debug("Ignoring stale upgrade completion: %s", tostring(args.operationId))
        requestAuthoritativeRefresh()
        return
    end

    if args.refugeData then
        local username = player:getUsername()
        if username and args.refugeData.username == username then
            local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
            if modData[MSR.Config.REFUGES_KEY] then
                modData[MSR.Config.REFUGES_KEY][username] = args.refugeData
                LOG.debug( "Updated client ModData with server refugeData for " .. tostring(args.upgradeId))
            end
        end
    end

    -- onUpgradeComplete handles cache invalidation based on handler config
    MSR.UpgradeLogic.onUpgradeComplete(
        player,
        args.upgradeId,
        args.newLevel,
        args.transactionId,
        args.operationId
    )

    -- Boundary objects are authoritative server state. The client only accepts
    -- the refuge snapshot and invalidates derived caches in onUpgradeComplete.
end

local function handleFeatureUpgradeError(args, player)
    if not args or not shouldAcceptUpgradeResponse(args, player) then
        LOG.debug("Ignoring stale upgrade error: %s", tostring(args and args.operationId))
        requestAuthoritativeRefresh()
        return
    end
    MSR.UpgradeLogic.onUpgradeError(player, args.transactionId, args.reason, args.operationId)
end

local function updateClientRefugeData(player, refugeData)
    if not player or not refugeData then return end
    local username = player:getUsername()
    if not username or refugeData.username ~= username then return end

    local modData = ModData.getOrCreate(MSR.Config.MODDATA_KEY)
    modData[MSR.Config.REFUGES_KEY] = modData[MSR.Config.REFUGES_KEY] or {}
    modData[MSR.Config.REFUGES_KEY][username] = refugeData
end

local function refreshEchoPanel(success, operationId)
    local window = getUpgradeWindow()
    local panel = window and window.echoPanel or nil
    if not panel then return end
    if success then panel:onServerComplete(operationId) else panel:onServerError(operationId) end
end

local function handleEchoAbsorbComplete(args, player)
    if not args or not shouldAcceptEchoResponse(args, player) then
        LOG.debug("Ignoring stale Echo completion: %s", tostring(args and args.transactionId))
        requestAuthoritativeRefresh()
        return
    end
    updateClientRefugeData(player, args.refugeData)
    if args.transactionId then MSR.Transaction.Finalize(player, args.transactionId) end
    MSR.UpgradeItemCache.invalidate(player)
    refreshEchoPanel(true, args.transactionId)
    if not args.duplicate then
        PM.SayRaw(player, getText("UI_Echo_AbsorbSuccess"))
    end
end

local function handleEchoAbsorbError(args, player)
    if not args or not shouldAcceptEchoResponse(args, player) then
        LOG.debug("Ignoring stale Echo error: %s", tostring(args and args.transactionId))
        requestAuthoritativeRefresh()
        return
    end
    updateClientRefugeData(player, args.refugeData)
    if args.transactionId then MSR.Transaction.Rollback(player, args.transactionId) end
    MSR.UpgradeItemCache.invalidate(player)
    refreshEchoPanel(false, args.transactionId)
    local reason = args.rateLimited and getText("UI_Echo_Error")
        or args.reason
        or getText("UI_Echo_Error")
    PM.SayRaw(player, tostring(reason))
end

local function handleTransactionTimeout(player, transaction)
    if not player or not transaction then return end
    requestAuthoritativeRefresh()
    local window = getUpgradeWindow()
    if not window then return end

    if transaction.type == MSR.UpgradeLogic.TRANSACTION_TYPE
        and window.onUpgradeTransactionTimeout
    then
        window:onUpgradeTransactionTimeout(transaction.id)
    elseif transaction.type == "ECHO_ABSORB" then
        local panel = window.echoPanel
        if panel and panel.onTransactionTimeout then panel:onTransactionTimeout(transaction.id) end
    end
end

EventsBus.Custom.Add(MSR.Transaction.EVENT_TIMEOUT, handleTransactionTimeout)

local function handleSpatialWellComplete(args, player)
    if not args or not hasPendingTransaction(
        player,
        MSR.SpatialWell.TRANSACTION_TYPE,
        args.transactionId
    ) then
        LOG.debug("Ignoring stale Spatial Well completion: %s", tostring(args and args.transactionId))
        requestAuthoritativeRefresh()
        return
    end
    updateClientRefugeData(player, args.refugeData)
    if args.transactionId then
        MSR.Transaction.Finalize(player, args.transactionId)
    end
    MSR.UpgradeItemCache.invalidate(player)
    PM.Say(player, PM.SPATIAL_WELL_BUILT)
end

local function handleSpatialWellError(args, player)
    if not args or not hasPendingTransaction(
        player,
        MSR.SpatialWell.TRANSACTION_TYPE,
        args.transactionId
    ) then
        LOG.debug("Ignoring stale Spatial Well error: %s", tostring(args and args.transactionId))
        requestAuthoritativeRefresh()
        return
    end
    if args and args.transactionId then
        MSR.Transaction.Rollback(player, args.transactionId)
    end
    MSR.UpgradeItemCache.invalidate(player)
    PM.Say(player, args and args.reason or PM.SPATIAL_WELL_BUILD_FAILED)
end

local function handleSpatialWellMoveComplete(args, player)
    if not args then return end
    updateClientRefugeData(player, args.refugeData)
    MSR.SpatialWell.UpdateMoveTime(player)
    PM.Say(player, PM.SPATIAL_WELL_MOVED)
end

local function handleSpatialWellMoveError(args, player)
    local reason = args and args.reason or PM.SPATIAL_WELL_MOVE_FAILED
    if args and args.reasonArgs and #args.reasonArgs > 0 then
        PM.Say(player, reason, unpack(args.reasonArgs))
    else
        PM.Say(player, reason)
    end
end

local function handleServerError(args, player)
    if args and args.messageKey then
        if args.messageArgs and #args.messageArgs > 0 then
            PM.Say(player, args.messageKey, unpack(args.messageArgs))
        else
            PM.Say(player, args.messageKey)
        end
    elseif args and args.message then
        PM.SayRaw(player, args.message)
    else
        PM.Say(player, PM.REFUGE_ERROR)
    end

    LOG.debug( "Error from server: " .. (args and (args.messageKey or args.message) or "unknown"))
end

CommandHandlers[MSR.Config.COMMANDS.MODDATA_RESPONSE] = handleModDataResponse
CommandHandlers[MSR.Config.COMMANDS.TELEPORT_TO] = handleTeleportTo
CommandHandlers[MSR.Config.COMMANDS.GENERATION_COMPLETE] = handleGenerationComplete
CommandHandlers[MSR.Config.COMMANDS.EXIT_READY] = handleExitReady
CommandHandlers[MSR.Config.COMMANDS.MOVE_RELIC_COMPLETE] = handleMoveRelicComplete
CommandHandlers[MSR.Config.COMMANDS.CLEAR_ZOMBIES] = handleClearZombies
CommandHandlers[MSR.Config.COMMANDS.FEATURE_UPGRADE_COMPLETE] = handleFeatureUpgradeComplete
CommandHandlers[MSR.Config.COMMANDS.FEATURE_UPGRADE_ERROR] = handleFeatureUpgradeError
CommandHandlers[MSR.Config.COMMANDS.ECHO_ABSORB_COMPLETE] = handleEchoAbsorbComplete
CommandHandlers[MSR.Config.COMMANDS.ECHO_ABSORB_ERROR] = handleEchoAbsorbError
CommandHandlers[MSR.Config.COMMANDS.SPATIAL_WELL_COMPLETE] = handleSpatialWellComplete
CommandHandlers[MSR.Config.COMMANDS.SPATIAL_WELL_ERROR] = handleSpatialWellError
CommandHandlers[MSR.Config.COMMANDS.SPATIAL_WELL_MOVE_COMPLETE] = handleSpatialWellMoveComplete
CommandHandlers[MSR.Config.COMMANDS.SPATIAL_WELL_MOVE_ERROR] = handleSpatialWellMoveError
CommandHandlers[MSR.Config.COMMANDS.ERROR] = handleServerError

local function OnServerCommand(module, command, args)
    if module ~= MSR.Config.COMMAND_NAMESPACE then return end

    local player = getPlayer()
    if not player then return end

    local handler = CommandHandlers[command]
    if handler then
        handler(args, player)
    end
end

if not MSR._serverCommandRouterRegistered then
    Events.OnServerCommand.Add(OnServerCommand)
    MSR._serverCommandRouterRegistered = true
end

return MSR.ServerCommandRouter
