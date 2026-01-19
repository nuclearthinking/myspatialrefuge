-- MSR_TeleportCooldown - Shared cooldown/penalty helpers for teleport flow

require "00_core/00_MSR"
require "00_core/Config"
require "MSR_Validation"
require "MSR_PlayerMessage"

if MSR.TeleportCooldown and MSR.TeleportCooldown._loaded then
    return MSR.TeleportCooldown
end

MSR.TeleportCooldown = MSR.TeleportCooldown or {}
MSR.TeleportCooldown._loaded = true

local TC = MSR.TeleportCooldown
local PM = MSR.PlayerMessage

---Format seconds into "Mm:SS" or "Xs"
---@param seconds number
---@return string
function TC.formatPenaltyTime(seconds)
    if seconds >= 60 then
        local mins = math.floor(seconds / 60)
        local secs = seconds % 60
        return string.format("%d:%02d", mins, secs)
    end
    return tostring(seconds) .. "s"
end

---Apply encumbrance penalty after teleport. Penalty must be calculated BEFORE teleport.
---@param player IsoPlayer
---@param penaltySeconds number
function TC.applyEncumbrancePenalty(player, penaltySeconds)
    if not player or not penaltySeconds or penaltySeconds <= 0 then
        MSR.UpdateTeleportTime(player)
        return
    end

    MSR.UpdateTeleportTimeWithPenalty(player, penaltySeconds)

    local cooldown = MSR.Config.getTeleportCooldown()
    local totalWait = cooldown + penaltySeconds
    PM.Say(player, PM.ENCUMBRANCE_PENALTY, TC.formatPenaltyTime(totalWait))
end

---Check if player can enter refuge and return reason string
---@param player IsoPlayer
---@return boolean canEnter
---@return string|nil reason
function TC.canEnterRefuge(player)
    local canEnter, reason = MSR.Validation.CanEnterRefuge(player)
    if not canEnter then
        return false, reason
    end

    local now = K.time()

    local lastTeleport = MSR.GetLastTeleportTime and MSR.GetLastTeleportTime(player) or 0
    local cooldown = MSR.Config.getTeleportCooldown()
    local canTeleport, remaining = MSR.Validation.CheckCooldown(lastTeleport, cooldown, now)

    if not canTeleport then
        return false, PM.GetFormattedText(PM.COOLDOWN_REMAINING, remaining)
    end

    local lastDamage = MSR.GetLastDamageTime and MSR.GetLastDamageTime(player) or 0
    local combatBlock = MSR.Config.getCombatBlockTime()
    local canCombat = MSR.Validation.CheckCooldown(lastDamage, combatBlock, now)

    if not canCombat then
        return false, PM.GetText(PM.CANNOT_TELEPORT_COMBAT)
    end

    return true, nil
end

return MSR.TeleportCooldown
