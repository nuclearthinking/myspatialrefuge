-- Spatial Refuge Generation Module (Client)

require "shared/MSR_Shared"
require "shared/00_core/05_Config"
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

-- Delete refuge data only (physical structures persist in world save)
-- Physical removal is disabled because:
-- 1. Chunks may not be loaded when player dies
-- 2. In SP, we want the refuge to persist for inheritance
-- 3. Structures don't harm anything if they persist
function MSR.DeleteRefuge(player)
    if isClient() and not isServer() then
        L.debug("Generation", "DeleteRefuge called on MP client - skipping (server handles this)")
        return
    end
    
    local refugeData = MSR.GetRefugeData(player)
    if not refugeData then return end
    
    L.debug("Generation", "DeleteRefuge: removing data only, physical structures persist")
    MSR.DeleteRefugeData(player)
end

return MSR
