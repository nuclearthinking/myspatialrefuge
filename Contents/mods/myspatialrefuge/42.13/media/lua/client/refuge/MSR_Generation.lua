-- Spatial Refuge Generation Module (Client)

require "shared/MSR_Shared"
require "shared/MSR_Config"
require "shared/MSR_PlayerMessage"
-- Uses global L for logging (loaded early by MSR.lua)

function MSR.ClearZombiesFromArea(centerX, centerY, z, radius, forceClean, player)
    return MSR.Shared.ClearZombiesFromArea(centerX, centerY, z, radius, forceClean, player)
end

function MSR.CreateSacredRelic(x, y, z, refugeId, searchRadius)
    return MSR.Shared.CreateSacredRelic(x, y, z, refugeId, searchRadius)
end

function MSR.CreateWall(x, y, z, addNorth, addWest, cornerSprite)
    return MSR.Shared.CreateWall(x, y, z, addNorth, addWest, cornerSprite)
end

function MSR.CreateBoundaryWalls(centerX, centerY, z, radius)
    return MSR.Shared.CreateBoundaryWalls(centerX, centerY, z, radius)
end

function MSR.RemoveBoundaryWalls(centerX, centerY, z, radius)
    return MSR.Shared.RemoveBoundaryWalls(centerX, centerY, z, radius)
end

function MSR.GenerateNewRefuge(player)
    if not player or not MSR.worldReady then return nil end
    
    local refugeData = MSR.GetOrCreateRefugeData(player)
    if not refugeData then return nil end
    
    MSR.PlayerMessage.Say(player, MSR.PlayerMessage.REFUGE_INITIALIZING)
    return refugeData
end

function MSR.ExpandRefuge(refugeData, newTier)
    if not refugeData then return false end
    
    local success = MSR.Shared.ExpandRefuge(refugeData, newTier)
    if success then
        MSR.SaveRefugeData(refugeData)
    end
    return success
end

function MSR.DeleteRefuge(player)
    if isClient() and not isServer() then
        L.debug("Generation", "DeleteRefuge called on MP client - skipping (server handles this)")
        return
    end
    
    local refugeData = MSR.GetRefugeData(player)
    if not refugeData then return end
    
    local cell = getCell and getCell()
    if not cell then return end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    
    for level = 0, wallHeight - 1 do
        local currentZ = centerZ + level
        for x = -radius-2, radius+2 do
            for y = -radius-2, radius+2 do
                local square = cell:getGridSquare(centerX + x, centerY + y, currentZ)
                if square then
                    local objects = square:getObjects()
                    if objects then
                        for i = objects:size()-1, 0, -1 do
                            local obj = objects:get(i)
                            if obj then
                                square:transmitRemoveItemFromSquare(obj)
                            end
                        end
                    end
                end
            end
        end
    end
    
    MSR.DeleteRefugeData(player)
end

return MSR
