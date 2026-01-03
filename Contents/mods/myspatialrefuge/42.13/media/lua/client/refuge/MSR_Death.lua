-- Spatial Refuge Death Handling

require "refuge/MSR_Generation"
-- Uses global L for logging (loaded early by MSR.lua)

local _cachedIsMPClient = nil
local function isMultiplayerClient()
    if _cachedIsMPClient == nil then
        _cachedIsMPClient = isClient() and not isServer()
    end
    return _cachedIsMPClient
end

local function clearPlayerModData(player)
    local pmd = player:getModData()
    pmd.spatialRefuge_id = nil
    pmd.spatialRefuge_return = nil
    pmd.spatialRefuge_lastTeleport = nil
    pmd.spatialRefuge_lastDamage = nil
    pmd.spatialRefuge_lastRelicMove = nil
end

local function OnPlayerDeath(player)
    if not player then return end
    if not MSR.IsPlayerInRefuge(player) then return end
    
    if isMultiplayerClient() then
        clearPlayerModData(player)
        L.debug("Death", "Player died in refuge (MP client) - server handles cleanup")
        return
    end
    
    local returnPos = MSR.GetReturnPosition(player)
    if returnPos then
        local corpse = player:getCorpse()
        if corpse then
            corpse:setX(returnPos.x)
            corpse:setY(returnPos.y)
            corpse:setZ(returnPos.z)
        end
    end
    
    MSR.DeleteRefuge(player)
    MSR.ClearReturnPosition(player)
    clearPlayerModData(player)
end

-- Register death event handler
Events.OnPlayerDeath.Add(OnPlayerDeath)

return MSR

