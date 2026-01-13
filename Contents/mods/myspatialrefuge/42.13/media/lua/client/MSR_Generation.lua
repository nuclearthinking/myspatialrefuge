-- Refuge generation (client-side wrappers for MSR.Shared)

require "MSR_Shared"
require "00_core/05_Config"
require "MSR_PlayerMessage"

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
    
    -- Inheritance message handled by MSR_Main.lua
    if not refugeData.inheritedFrom then
        MSR.PlayerMessage.Say(player, MSR.PlayerMessage.REFUGE_INITIALIZING)
    end
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

-- Deletes data only; structures persist for inheritance and to avoid chunk-loading issues
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
