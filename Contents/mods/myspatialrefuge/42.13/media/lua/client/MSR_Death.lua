-- Spatial Refuge Death Handling

require "MSR_Generation"
require "shared/00_core/04_Env"
-- Uses global L for logging (loaded early by MSR.lua)

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
    
    local username = player:getUsername()
    local refugeData = MSR.GetRefugeData(player)
    if not refugeData then return end
    
    if MSR.Env.isMultiplayerClient() then
        clearPlayerModData(player)
        return
    end
    
    -- Singleplayer: preserve refuge for inheritance
    if MSR.Env.isSingleplayer() then
        MSR.Data.MarkRefugeOrphaned(username)
        MSR.ClearReturnPosition(player)
        clearPlayerModData(player)
        return
    end
    
    -- Multiplayer server: delete refuge data
    MSR.DeleteRefugeData(player)
    MSR.ClearReturnPosition(player)
    clearPlayerModData(player)
end

-- Register death event handler
Events.OnPlayerDeath.Add(OnPlayerDeath)

return MSR

