-- MSR_Validation - Shared validation logic for client and server

require "shared/core/MSR"
require "shared/MSR_Config"
require "shared/MSR_Data"

if MSR.Validation and MSR.Validation._loaded then
    return MSR.Validation
end

MSR.Validation = MSR.Validation or {}
MSR.Validation._loaded = true

local Validation = MSR.Validation
local Config = MSR.Config
local Data = MSR.Data

-----------------------------------------------------------
-- Player State Validation
-----------------------------------------------------------

function Validation.IsValidPlayer(player)
    if not player then
        return false, "Invalid player"
    end
    
    if not player.getX or not player.getY or not player.getZ then
        return false, "Invalid player state"
    end
    
    return true, nil
end

function Validation.IsInVehicle(player)
    if not player then return false end
    return player:getVehicle() ~= nil
end

function Validation.IsClimbing(player)
    if not player then return false end
    return player.isClimbing and player:isClimbing()
end

function Validation.IsFalling(player)
    if not player then return false end
    return player.isFalling and player:isFalling()
end

--- Returns ratio (1.5 = 150% capacity), invWeight, maxWeight
function Validation.GetWeightRatio(player)
    if not player then return 0, 0, 0 end
    
    local invWeight, maxWeight
    
    -- Use getInventory():getCapacityWeight() - matches game's internal check (B42+)
    local inv = player:getInventory()
    if inv then invWeight = inv:getCapacityWeight() end
    
    maxWeight = player:getMaxWeight()
    
    L.debug("Validation", string.format("Weight: %.1f/%.1f (%s)", 
        invWeight or 0, maxWeight or 0, player:getUsername() or "?"))
    
    if invWeight and maxWeight and maxWeight > 0 then
        return invWeight / maxWeight, invWeight, maxWeight
    end
    return 0, invWeight or 0, maxWeight or 0
end

--- Manual check (isOverEncumbered() can desync in MP)
function Validation.IsOverEncumbered(player)
    local ratio = Validation.GetWeightRatio(player)
    return ratio > 1.0
end

--- Encumbrance penalty seconds. Scaled by D.negativeValue (lower on Easy)
function Validation.GetEncumbrancePenalty(player)
    if not player then return 0 end
    
    local ratio = Validation.GetWeightRatio(player)
    
    if ratio <= 1.0 then return 0 end
    
    local overloadFactor = ratio - 1.0
    local multiplier = Config.getEncumbrancePenaltyMultiplier()
    local cap = Config.getEncumbrancePenaltyCap()
    local penalty = math.floor(math.min(D.negativeValue(overloadFactor * multiplier), cap))
    
    L.debug("Validation", string.format("Encumbrance penalty: %ds (ratio=%.2f, difficulty=%s)", penalty, ratio, MSR.GetDifficultyName() or "?"))
    
    return penalty
end

function Validation.IsInRefugeCoords(player)
    if not player then return false end
    return Data.IsPlayerInRefugeCoords(player)
end

-----------------------------------------------------------
-- Composite Validation Functions
-----------------------------------------------------------

--- Does NOT check cooldowns. Encumbrance adds penalty instead of blocking.
function Validation.CanPlayerTeleport(player)
    local valid, reason = Validation.IsValidPlayer(player)
    if not valid then
        return false, reason
    end
    
    if Validation.IsInVehicle(player) then
        return false, "Cannot teleport while in vehicle"
    end
    
    if Validation.IsClimbing(player) then
        return false, "Cannot teleport while climbing"
    end
    
    if Validation.IsFalling(player) then
        return false, "Cannot teleport while falling"
    end
    
    return true, nil
end

function Validation.CanEnterRefuge(player)
    local canTeleport, reason = Validation.CanPlayerTeleport(player)
    if not canTeleport then
        return false, reason
    end
    
    if Validation.IsInRefugeCoords(player) then
        return false, "Already in refuge"
    end
    
    return true, nil
end

function Validation.CanExitRefuge(player)
    local canTeleport, reason = Validation.CanPlayerTeleport(player)
    if not canTeleport then
        return false, reason
    end
    
    if not Validation.IsInRefugeCoords(player) then
        return false, "Not in refuge"
    end
    
    return true, nil
end

-- Cooldown Helpers

function Validation.CheckCooldown(lastTime, cooldownDuration, currentTime)
    local now = currentTime or K.time()
    lastTime = lastTime or 0
    cooldownDuration = cooldownDuration or 0
    
    local elapsed = now - lastTime
    local remaining = cooldownDuration - elapsed
    
    if remaining > 0 then
        return false, math.ceil(remaining)
    end
    
    return true, 0
end

function Validation.FormatCooldownMessage(baseMessage, remainingSeconds)
    return baseMessage .. " (" .. remainingSeconds .. "s)"
end

-- Value Validation

function Validation.ValidateCornerOffset(cornerDx, cornerDy)
    if type(cornerDx) ~= "number" or type(cornerDy) ~= "number" then
        return false, 0, 0
    end
    
    local sanitizedDx = math.max(-1, math.min(1, math.floor(cornerDx)))
    local sanitizedDy = math.max(-1, math.min(1, math.floor(cornerDy)))
    
    return true, sanitizedDx, sanitizedDy
end

function Validation.ValidateTier(tier)
    if type(tier) ~= "number" then
        return false, "Invalid tier type"
    end
    
    if tier < 0 then
        return false, "Tier cannot be negative"
    end
    
    if tier > Config.MAX_TIER then
        return false, "Tier exceeds maximum"
    end
    
    if not Config.TIERS[tier] then
        return false, "Invalid tier configuration"
    end
    
    return true, nil
end

function Validation.ValidateRefugeAccess(player, refugeId)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    local expectedRefugeId = "refuge_" .. username
    return refugeId == expectedRefugeId
end

function Validation.ValidateWorldCoordinates(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then
        return false, "Invalid coordinate type"
    end
    
    if Data.IsInRefugeCoordinates(x, y) then
        return false, "Coordinates are in refuge space"
    end
    
    return true, nil
end

-- Upgrade Validation

function Validation.CanUpgradeRefuge(player, refugeData)
    local valid, reason = Validation.IsValidPlayer(player)
    if not valid then
        return false, reason, nil
    end
    
    if not refugeData then
        return false, "No refuge found", nil
    end
    
    if not Validation.IsInRefugeCoords(player) then
        return false, "Must be in refuge to upgrade", nil
    end
    
    local currentTier = refugeData.tier or 0
    local newTier = currentTier + 1
    
    if newTier > Config.MAX_TIER then
        return false, "Already at maximum tier", nil
    end
    
    local tierConfig = Config.TIERS[newTier]
    if not tierConfig then
        return false, "Invalid tier configuration", nil
    end
    
    return true, nil, tierConfig
end

return MSR.Validation
