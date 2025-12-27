-- Spatial Refuge Cast Time System
-- Uses native ISTimedAction for professional progress bar

SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-- Cast time in ticks (60 ticks = 1 second)
local CAST_TIME_TICKS = 180  -- 3 seconds

-- Begin teleport casting using ISTimedAction (with progress bar)
function SpatialRefuge.BeginTeleportCast(player)
    if not player then return end
    if not ISEnterRefugeAction or not ISTimedActionQueue then
        player:Say("Error: Refuge action not available")
        return
    end
    
    local action = ISEnterRefugeAction:new(player, CAST_TIME_TICKS)
    ISTimedActionQueue.add(action)
end

-- Begin exit casting using ISTimedAction
function SpatialRefuge.BeginExitCast(player, relicObj)
    if not player then return end
    if not ISExitRefugeAction or not ISTimedActionQueue then
        player:Say("Error: Refuge exit action not available")
        return
    end
    
    -- Clear any existing actions first
    ISTimedActionQueue.clear(player)
    
    -- Walk to relic if needed using standard PZ approach
    if relicObj and relicObj.getSquare then
        local relicSquare = relicObj:getSquare()
        if relicSquare and luautils and luautils.walkAdj then
            luautils.walkAdj(player, relicSquare, true)
        end
    end
    
    -- Queue exit action (will run after walk completes)
    local action = ISExitRefugeAction:new(player, CAST_TIME_TICKS)
    ISTimedActionQueue.add(action)
end

return SpatialRefuge
