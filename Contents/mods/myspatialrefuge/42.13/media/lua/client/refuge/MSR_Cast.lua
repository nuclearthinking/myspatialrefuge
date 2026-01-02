require "shared/MSR_Config"
require "shared/MSR_PlayerMessage"

local Config = MSR.Config
local PM = MSR.PlayerMessage

function MSR.BeginTeleportCast(player)
    if not player then return end
    if not ISEnterRefugeAction or not ISTimedActionQueue then
        PM.Say(player, PM.REFUGE_ACTION_NOT_AVAILABLE)
        return
    end
    
    local action = ISEnterRefugeAction:new(player, Config.getCastTimeTicks())
    ISTimedActionQueue.add(action)
end

function MSR.BeginExitCast(player)
    if not player then return end
    if not ISExitRefugeAction or not ISTimedActionQueue then
        PM.Say(player, PM.REFUGE_EXIT_ACTION_NOT_AVAILABLE)
        return
    end
    
    ISTimedActionQueue.clear(player)
    local action = ISExitRefugeAction:new(player, Config.getCastTimeTicks())
    ISTimedActionQueue.add(action)
end

return MSR
