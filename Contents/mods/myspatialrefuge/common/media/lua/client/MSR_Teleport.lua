-- MSR_Teleport - Client-side teleport and refuge flow orchestration
-- Responsibilities (current):
-- Public API (exposed on MSR):
-- 1) MSR.CanEnterRefuge: gatekeeper for entry (cooldowns/combat/validation).
-- 2) MSR.EnterRefuge: SP/MP entry orchestration + vehicle handling + return pos.
-- 3) MSR.ExitRefuge: SP/MP exit orchestration + return pos recovery.
--
-- Internal orchestration:
-- 4) SP enter flow: teleport into refuge, prepare area (zombie clear, trees/walls),
--    create relic, apply cutaway, and apply encumbrance penalty.
-- 5) SP exit flow: save room IDs, clear return position, teleport out, re-enter
--    vehicle if applicable, and fire local teleport events.
-- 6) MP client enter/exit: send request commands to server (responses handled
--    by MSR_ServerCommandRouter).
-- 7) Teleport events: fire local events for enter/exit lifecycle hooks.
-- 8) Utility helpers: shared tick sequencing, chunk readiness checks, and
--    world iteration via MSR.TeleportFlow / MSR.Utils / MSR.World.
--
-- Out-of-module responsibilities:
-- - Server command dispatch + response handling: MSR_ServerCommandRouter
-- - ModData sync on MP (request/response/ready): MSR.Data
-- - One-time post-join integrity sync: MSR.Data (via Events)

require "00_core/00_MSR"
require "00_core/Events"

require "MSR_PlayerMessage"
require "MSR_Validation"
require "MSR_VehicleTeleport"
require "MSR_RefugeGeneration"
require "MSR_ServerCommandRouter"
require "helpers/TeleportCooldown"
require "helpers/World"
require "helpers/TeleportFlow"

local PM = MSR.PlayerMessage
local LOG = L.logger("Teleport")
local TC = MSR.TeleportCooldown
local EventsBus = MSR.Events
local Utils = MSR.Utils

local function fireTeleportEvent(eventName, payload)
    EventsBus.Custom.Fire(eventName, payload)
end

function MSR.CanEnterRefuge(player)
    return TC.canEnterRefuge(player)
end

local doSingleplayerExit

local function doSingleplayerEnter(player, refugeData)
    local teleportX = refugeData.centerX
    local teleportY = refugeData.centerY
    local teleportZ = refugeData.centerZ
    local teleportPlayer = player
    -- Use refugeData.radius directly (authoritative value) - tier lookup can be stale
    local radius = refugeData.radius or 1
    
    LOG.debug( string.format("doSingleplayerEnter: center=%d,%d radius=%d tier=%s", 
        teleportX, teleportY, radius, tostring(refugeData.tier)))
    
    -- Penalty must be calculated before teleport (weight may change after)
    local encumbrancePenalty = MSR.Validation.GetEncumbrancePenalty(player)
    
    local tickCount = 0
    local teleportDone = false
    local enterCtx = MSR.RefugeGeneration.CreateEnterContext(refugeData, player)
    
    local function stepTeleport()
        tickCount = tickCount + 1
        
        if not teleportDone then
            teleportPlayer:teleportTo(teleportX, teleportY, teleportZ)
            teleportPlayer:setDir(0)
            teleportDone = true
            return false
        end
        
        if tickCount >= 2 and tickCount <= 5 then
            teleportPlayer:setDir((tickCount - 1) % 4)
            return false
        end
        
        if tickCount < 20 then return false end
        
        if MSR.RefugeGeneration.StepEnterPreparation(enterCtx) then
            return true
        end

        return false
    end
    
    Utils.poll({
        maxTicks = 600,
        tag = "teleport_enter_sp",
        condition = stepTeleport,
        onSuccess = function()
            -- Enter flow completed by stepTeleport
        end,
        onTimeout = function()
            if not enterCtx.centerSquareSeen then
                PM.Say(teleportPlayer, PM.AREA_NOT_LOADED)
                local returnPos = MSR.GetReturnPosition(teleportPlayer)
                if returnPos then
                    LOG.debug( "Area not loaded, returning player to last position")
                    doSingleplayerExit(teleportPlayer, returnPos)
                end
            end
        end
    })
    TC.applyEncumbrancePenalty(player, encumbrancePenalty)
    addSound(player, refugeData.centerX, refugeData.centerY, refugeData.centerZ, 10, 1)
    PM.Say(player, PM.ENTERED_REFUGE)
    fireTeleportEvent("MSR_TeleportEnterCompleted", { player = player, refugeData = refugeData })
    
    return true
end

doSingleplayerExit = function(player, returnPos)
    local targetX, targetY, targetZ = returnPos.x, returnPos.y, returnPos.z
    
    -- Save room IDs BEFORE teleport out (will restore after teleport in)
    local refugeData = MSR.GetRefugeData(player)
    if refugeData then
        local saved = MSR.RoomPersistence.Save(refugeData)
        LOG.debug( string.format("doSingleplayerExit: Saved %d room IDs before exit", saved))
    end
    
    fireTeleportEvent("MSR_TeleportExitStarted", { player = player, returnPos = returnPos })
    
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
        LOG.debug( string.format("Vehicle return: teleporting to vehicle position %.1f,%.1f,%.1f instead of exit position", vehicleX, vehicleY, vehicleZ))
    end
    
    local function stepExitTeleport()
        tickCount = tickCount + 1
        
        if not teleportDone then
            teleportPlayer:teleportTo(actualTargetX, actualTargetY, actualTargetZ)
            teleportPlayer:setLastX(actualTargetX)
            teleportPlayer:setLastY(actualTargetY)
            teleportPlayer:setLastZ(actualTargetZ)
            teleportDone = true
            addSound(teleportPlayer, actualTargetX, actualTargetY, actualTargetZ, 10, 1)
            PM.Say(teleportPlayer, PM.EXITED_REFUGE)
            fireTeleportEvent("MSR_TeleportExitCompleted", { player = teleportPlayer, returnPos = returnPos })
            return false
        end
        
        if tickCount == 2 and MSR.IsPlayerInRefuge(teleportPlayer) then
            teleportPlayer:teleportTo(actualTargetX, actualTargetY, actualTargetZ)
        end
        
        if tickCount >= 3 then
            -- Attempt to re-enter vehicle if teleported from one
            if fromVehicle and vehicleId then
                MSR.VehicleTeleport.TryReenterVehicle(teleportPlayer, vehicleId, vehicleSeat, vehicleX, vehicleY, vehicleZ)
            end
            return true
        end

        return false
    end
    
    Utils.poll({
        maxTicks = 5,
        tag = "teleport_exit_sp",
        condition = stepExitTeleport,
        onSuccess = function()
            -- Exit flow completed by stepExitTeleport
        end
    })
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
    
    fireTeleportEvent("MSR_TeleportEnterRequested", { player = player })
    
    -- Get vehicle data before exiting
    local vehicleData = nil
    if player:getVehicle() then
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
            LOG.debug( string.format("Including vehicle data: id=%s seat=%s pos=%.1f,%.1f,%.1f", 
                tostring(vehicleData.vehicleId), tostring(vehicleData.vehicleSeat),
                vehicleData.vehicleX or 0, vehicleData.vehicleY or 0, vehicleData.vehicleZ or 0))
        end
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_ENTER, requestArgs)
        LOG.debug( "Sent RequestEnter to server")
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
    
    fireTeleportEvent("MSR_TeleportEnterStarted", { player = player, refugeData = refugeData })
    return doSingleplayerEnter(player, refugeData)
end

function MSR.ExitRefuge(player)
    if not player then return false end
    
    if MSR.Env.isMultiplayerClient() then
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_EXIT, {})
        LOG.debug( "Sent RequestExit to server")
        fireTeleportEvent("MSR_TeleportExitRequested", { player = player })
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
    
    fireTeleportEvent("MSR_TeleportExitRequested", { player = player, returnPos = returnPos })
    return doSingleplayerExit(player, returnPos)
end


return MSR
