require "00_core/00_MSR"
require "00_core/Events"

require "MSR_PlayerMessage"
require "MSR_Integrity"
require "MSR_RoomPersistence"
require "MSR_UpgradeLogic"
require "MSR_VehicleTeleport"

require "helpers/TeleportCooldown"
require "helpers/TeleportFlow"
require "helpers/World"

local Router = MSR.register("ServerCommandRouter")
local LOG = L.logger("Teleport")
if not Router then
    return MSR.ServerCommandRouter
end

MSR.ServerCommandRouter = Router

local PM = MSR.PlayerMessage
local TC = MSR.TeleportCooldown
local Flow = MSR.TeleportFlow
local World = MSR.World
local EventsBus = MSR.Events

local function fireTeleportEvent(eventName, payload)
    EventsBus.Custom.Fire(eventName, payload)
end

local CommandHandlers = {}

local function handleModDataResponse(args, player)
    MSR.Data.HandleModDataResponse(args, player)
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

local function handleClearZombies(args, player)
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
            local removed = 0
            local modifiedSquares = {}
            World.iterateArea(c.centerX, c.centerY, c.centerZ, c.scanRadius, function(square, x, y)
                if not isOnNewPerimeter(c, x, y) then
                    local objects = square:getObjects()
                    if K.isIterable(objects) then
                        local toRemove = {}
                        for _, obj in K.iter(objects) do
                            local md = World.getModData(obj)
                            if md and md.isRefugeBoundary then
                                table.insert(toRemove, obj)
                            end
                        end
                        if #toRemove > 0 then
                            table.insert(modifiedSquares, square)
                            for _, obj in ipairs(toRemove) do
                                if World.removeObject(square, obj, false) then
                                    removed = removed + 1
                                end
                            end
                        end
                    end
                end
            end)

            for _, square in ipairs(modifiedSquares) do
                World.recalcSquare(square)
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

local function handleFeatureUpgradeError(args, player)
    if args then
        MSR.UpgradeLogic.onUpgradeError(player, args.transactionId, args.reason)
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
