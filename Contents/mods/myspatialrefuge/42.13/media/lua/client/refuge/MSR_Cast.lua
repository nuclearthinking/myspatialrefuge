require "shared/MSR_Config"
require "shared/MSR_PlayerMessage"
require "shared/MSR_UpgradeData"

local Config = MSR.Config
local PM = MSR.PlayerMessage

local function getCastTimeTicksWithUpgrades(player)
    local baseTicks = Config.getCastTimeTicks()
    local mult = 1.0
    
    if MSR and MSR.UpgradeData and MSR.UpgradeData.getPlayerActiveEffects then
        local ok, effects = pcall(function()
            return MSR.UpgradeData.getPlayerActiveEffects(player)
        end)
        if ok and effects and effects.refugeCastTimeMultiplier ~= nil then
            mult = effects.refugeCastTimeMultiplier
        end
    end
    
    if type(mult) ~= "number" or mult <= 0 then
        mult = 1.0
    end
    
    local ticks = math.floor(baseTicks * mult + 0.5)
    if ticks < 1 then ticks = 1 end
    return ticks
end

function MSR.BeginTeleportCast(player)
    if not player then return end
    if not ISEnterRefugeAction or not ISTimedActionQueue then
        PM.Say(player, PM.REFUGE_ACTION_NOT_AVAILABLE)
        return
    end
    
    local action = ISEnterRefugeAction:new(player, getCastTimeTicksWithUpgrades(player))
    ISTimedActionQueue.add(action)
end

function MSR.BeginExitCast(player)
    if not player then return end
    if not ISExitRefugeAction or not ISTimedActionQueue then
        PM.Say(player, PM.REFUGE_EXIT_ACTION_NOT_AVAILABLE)
        return
    end
    
    ISTimedActionQueue.clear(player)
    local action = ISExitRefugeAction:new(player, getCastTimeTicksWithUpgrades(player))
    ISTimedActionQueue.add(action)
end

return MSR
