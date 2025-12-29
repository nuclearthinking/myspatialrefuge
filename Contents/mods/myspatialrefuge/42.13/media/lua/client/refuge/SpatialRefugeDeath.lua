-- Spatial Refuge Death Handling
-- Handles player death in refuge: corpse relocation and refuge deletion
-- 
-- MULTIPLAYER NOTE: In MP, the SERVER handles authoritative death processing
-- via OnPlayerDeathServer in SpatialRefugeServer.lua
-- This client-side handler only does local cleanup

require "refuge/SpatialRefugeGeneration"

-- Assume dependencies are already loaded
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-- Cached MP check
local _cachedIsMPClient = nil
local function isMultiplayerClient()
    if _cachedIsMPClient == nil then
        _cachedIsMPClient = isClient() and not isServer()
    end
    return _cachedIsMPClient
end

-- Handle player death (client-side)
local function OnPlayerDeath(player)
    if not player then return end
    
    -- Check if player died inside their refuge
    if not SpatialRefuge.IsPlayerInRefuge(player) then return end
    
    if isMultiplayerClient() then
        -- MULTIPLAYER: Server handles corpse movement, ModData cleanup, etc.
        -- We only do local player ModData cleanup here
        local pmd = player:getModData()
        pmd.spatialRefuge_id = nil
        pmd.spatialRefuge_return = nil
        pmd.spatialRefuge_lastTeleport = nil
        pmd.spatialRefuge_lastDamage = nil
        pmd.spatialRefuge_lastRelicMove = nil
        
        if getDebug() then
            print("[SpatialRefuge] Player died in refuge (MP client) - server handles cleanup")
        end
        return
    end
    
    -- SINGLEPLAYER: Full local handling
    
    -- Get return position (now uses global ModData)
    local returnPos = SpatialRefuge.GetReturnPosition(player)
    
    -- Move corpse to last world position (where they entered from)
    if returnPos then
        local corpse = player:getCorpse()
        if corpse then
            corpse:setX(returnPos.x)
            corpse:setY(returnPos.y)
            corpse:setZ(returnPos.z)
        end
    end
    
    -- Delete refuge completely (singleplayer only - MP check is inside DeleteRefuge)
    SpatialRefuge.DeleteRefuge(player)
    
    -- Clear return position
    SpatialRefuge.ClearReturnPosition(player)
    
    -- Clear player-specific modData (legacy cleanup)
    local pmd = player:getModData()
    pmd.spatialRefuge_id = nil
    pmd.spatialRefuge_return = nil
    pmd.spatialRefuge_lastTeleport = nil
    pmd.spatialRefuge_lastDamage = nil
    pmd.spatialRefuge_lastRelicMove = nil
end

-- Register death event handler
Events.OnPlayerDeath.Add(OnPlayerDeath)

return SpatialRefuge

