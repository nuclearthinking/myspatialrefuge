-- Spatial Refuge Death Handling
-- Handles player death in refuge: corpse relocation and refuge deletion

-- Assume dependencies are already loaded
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-- Handle player death
local function OnPlayerDeath(player)
    if not player then return end
    
    -- Check if player died inside their refuge
    if not SpatialRefuge.IsPlayerInRefuge(player) then return end
    
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
    
    -- Delete refuge completely
    SpatialRefuge.DeleteRefuge(player)
    
    -- Clear return position
    SpatialRefuge.ClearReturnPosition(player)
    
    -- Clear player-specific modData (legacy cleanup)
    local pmd = player:getModData()
    pmd.spatialRefuge_id = nil
    pmd.spatialRefuge_return = nil
    pmd.spatialRefuge_lastTeleport = nil
    pmd.spatialRefuge_lastDamage = nil
end

-- Register death event handler
Events.OnPlayerDeath.Add(OnPlayerDeath)

return SpatialRefuge

