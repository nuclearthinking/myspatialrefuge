-- MSR_VehicleTeleport.lua - Vehicle teleport logic (client-side)
-- Dedicated module for vehicle teleport upgrade functionality
-- Keeps MSR_Teleport.lua clean by isolating vehicle-specific logic

require "00_core/00_MSR"
require "00_core/04_Env"
require "00_core/05_Config"
require "MSR_PlayerMessage"

if MSR.VehicleTeleport and MSR.VehicleTeleport._loaded then
    return MSR.VehicleTeleport
end

MSR.VehicleTeleport = MSR.VehicleTeleport or {}
MSR.VehicleTeleport._loaded = true

local VT = MSR.VehicleTeleport
local PM = MSR.PlayerMessage
local Config = MSR.Config

-----------------------------------------------------------
-- Validation Helpers
-----------------------------------------------------------

--- Check if player has the vehicle teleport upgrade
---@param player IsoPlayer
---@return boolean hasUpgrade
function VT.HasUpgrade(player)
    if not player then return false end
    if not MSR.UpgradeData then return false end
    local level = MSR.UpgradeData.getPlayerUpgradeLevel(player, Config.UPGRADES.VEHICLE_TELEPORT)
    return level >= 1
end

--- Check if vehicle is currently moving
---@param vehicle BaseVehicle
---@return boolean isMoving
function VT.IsVehicleMoving(vehicle)
    if not vehicle then return false end
    local speed = vehicle:getCurrentSpeedKmHour()
    return speed ~= nil and math.abs(speed) > 0.1
end

-----------------------------------------------------------
-- Entry Flow (before entering refuge)
-----------------------------------------------------------

--- Get vehicle data for saving with return position
---@param player IsoPlayer
---@return table|nil vehicleData {vehicleId, vehicleSeat, vehicleX, vehicleY, vehicleZ}
function VT.GetVehicleDataForEntry(player)
    if not player then return nil end
    
    local vehicle = player:getVehicle()
    if not vehicle then return nil end
    
    return {
        vehicleId = vehicle:getId(),
        vehicleSeat = vehicle:getSeat(player),
        vehicleX = vehicle:getX(),
        vehicleY = vehicle:getY(),
        vehicleZ = vehicle:getZ()
    }
end

--- Exit vehicle before teleport (call after GetVehicleDataForEntry)
---@param player IsoPlayer
---@return boolean exited Whether player was in vehicle and exited
function VT.ExitVehicleForTeleport(player)
    if not player then return false end
    
    local vehicle = player:getVehicle()
    if vehicle then
        vehicle:exit(player)
        L.debug("VehicleTeleport", "Player exited vehicle before teleport")
        return true
    end
    return false
end

-----------------------------------------------------------
-- Exit Flow (after exiting refuge)
-----------------------------------------------------------

--- Attempt to re-enter vehicle after exiting refuge (async, waits for position stabilization)
---@param player IsoPlayer
---@param vehicleId number Vehicle SQL ID
---@param vehicleSeat number Seat index (0-based)
---@param vehicleX number|nil Saved vehicle X (falls back to player position)
---@param vehicleY number|nil Saved vehicle Y (falls back to player position)
---@param vehicleZ number|nil Saved vehicle Z (falls back to player position)
function VT.TryReenterVehicle(player, vehicleId, vehicleSeat, vehicleX, vehicleY, vehicleZ)
    if not player then return end
    if not vehicleId then return end
    
    L.debug("VehicleTeleport", string.format("Attempting to re-enter vehicle ID=%s seat=%s at %.1f,%.1f,%.1f", 
        tostring(vehicleId), tostring(vehicleSeat), vehicleX or 0, vehicleY or 0, vehicleZ or 0))
    
    local attempts = 0
    local maxAttempts = 300  -- 5 seconds at 60fps (increased for coop latency)
    local vehicleFound = false
    
    local function doReenter()
        attempts = attempts + 1
        
        -- Timeout: vehicle not found
        if attempts > maxAttempts then
            Events.OnPlayerUpdate.Remove(doReenter)
            if not vehicleFound then
                PM.Say(player, PM.VEHICLE_NOT_FOUND)
                L.debug("VehicleTeleport", "Vehicle not found after timeout")
            end
            return
        end
        
        -- Wait for position to stabilize after teleport
        if attempts < 10 then return end
        
        -- Wait until player's square is loaded (like RV Interior does)
        local playerSquare = player:getCurrentSquare()
        if not playerSquare then return end
        
        local cell = getCell()
        if not cell then return end
        
        -- Search around player's current position (not saved position)
        -- Player was teleported to vehicle location, so search around where they are now
        local searchX = player:getX()
        local searchY = player:getY()
        local searchZ = player:getZ()
        
        -- Search 5x5 grid around player position
        for dx = -2, 2 do
            for dy = -2, 2 do
                local sq = cell:getGridSquare(searchX + dx, searchY + dy, searchZ)
                if sq then
                    local vehicle = sq:getVehicleContainer()
                    if vehicle then
                        vehicleFound = true
                        L.debug("VehicleTeleport", string.format("Found vehicle at search offset %d,%d", dx, dy))
                        
                        -- Move player to vehicle position (required for enter() to work)
                        local vehX, vehY, vehZ = vehicle:getX(), vehicle:getY(), vehicle:getZ()
                        player:setX(vehX)
                        player:setLastX(vehX)
                        player:setY(vehY)
                        player:setLastY(vehY)
                        player:setZ(vehZ)
                        player:setLastZ(vehZ)
                        
                        -- enter() sends VehicleEnterPacket - do NOT also call sendSwitchSeat()
                        local enterSuccess = vehicle:enter(vehicleSeat, player)
                        
                        if enterSuccess and player:getVehicle() == vehicle then
                            vehicle:setCharacterPosition(player, vehicleSeat, "inside")
                            vehicle:transmitCharacterPosition(vehicleSeat, "inside")
                            vehicle:playPassengerAnim(vehicleSeat, "idle")
                            triggerEvent("OnEnterVehicle", player)
                            
                            PM.Say(player, PM.RETURNED_TO_VEHICLE)
                            L.debug("VehicleTeleport", "Successfully re-entered vehicle")
                        else
                            PM.Say(player, PM.VEHICLE_ENTRY_FAILED)
                            L.debug("VehicleTeleport", "Vehicle found but could not enter (seat may be occupied)")
                        end
                        
                        Events.OnPlayerUpdate.Remove(doReenter)
                        return
                    end
                end
            end
        end
    end
    
    Events.OnPlayerUpdate.Add(doReenter)
end

return MSR.VehicleTeleport
