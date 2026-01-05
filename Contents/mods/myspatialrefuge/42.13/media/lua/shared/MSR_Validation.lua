-- MSR_Validation - Validation Module (Shared)
-- Centralized validation logic for both client and server
-- Eliminates code duplication and ensures consistent validation rules

require "shared/MSR"
require "shared/MSR_Config"
require "shared/MSR_Data"

if MSR.Validation and MSR.Validation._loaded then
    return MSR.Validation
end

MSR.Validation = MSR.Validation or {}
MSR.Validation._loaded = true

-- Local aliases
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

-- Get weight ratio for encumbrance calculations
-- Returns: ratio (e.g., 1.5 = 150% of max capacity), invWeight, maxWeight
function Validation.GetWeightRatio(player)
    if not player then return 0, 0, 0 end
    
    local invWeight, maxWeight
    
    -- Use getInventory():getCapacityWeight() - matches game's internal check (B42+)
    local inv = player:getInventory()
    if inv then
        invWeight = inv:getCapacityWeight()
    end
    
    maxWeight = player:getMaxWeight()
    
    L.debug("Validation", string.format("Weight: %.1f/%.1f (%s)", 
        invWeight or 0, maxWeight or 0, player:getUsername() or "?"))
    
    if invWeight and maxWeight and maxWeight > 0 then
        return invWeight / maxWeight, invWeight, maxWeight
    end
    
    -- Cannot determine weight
    return 0, invWeight or 0, maxWeight or 0
end

-- Manual weight check for MP consistency (isOverEncumbered() can desync between client/server)
function Validation.IsOverEncumbered(player)
    local ratio = Validation.GetWeightRatio(player)
    return ratio > 1.0
end

-- Calculate encumbrance penalty in seconds for teleportation
-- Returns 0 if disabled, not encumbered, or below threshold
-- Example: 150% capacity with 300 multiplier = 0.5 * 300 = 150 seconds
function Validation.GetEncumbrancePenalty(player)
    if not player then return 0 end
    
    -- Check if feature is disabled
    if not Config.isEncumbrancePenaltyEnabled() then
        return 0
    end
    
    local ratio = Validation.GetWeightRatio(player)
    
    -- No penalty if at or below capacity
    if ratio <= 1.0 then
        return 0
    end
    
    local overloadFactor = ratio - 1.0  -- e.g., 1.5 -> 0.5
    local multiplier = Config.getEncumbrancePenaltyMultiplier()
    local cap = Config.getEncumbrancePenaltyCap()
    
    local penalty = overloadFactor * multiplier
    penalty = math.min(penalty, cap)  -- Cap at maximum
    penalty = math.floor(penalty)     -- Round down to whole seconds
    
    L.debug("Validation", string.format("Encumbrance penalty: %ds (ratio=%.2f)", penalty, ratio))
    
    return penalty
end

function Validation.IsInRefugeCoords(player)
    if not player then return false end
    return Data.IsPlayerInRefugeCoords(player)
end

-----------------------------------------------------------
-- Composite Validation Functions
-----------------------------------------------------------

-- Does NOT check cooldowns - those are context-specific (client vs server)
-- NOTE: Encumbrance is no longer blocking - it adds a cooldown penalty instead
-- Use Validation.GetEncumbrancePenalty() after teleport to apply penalty
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
    
    -- Encumbrance no longer blocks teleport - penalty is applied after successful teleport
    -- This prevents abuse while still allowing emergency escapes
    
    return true, nil
end

-- Does NOT check cooldowns - those are context-specific
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

-----------------------------------------------------------
-- Cooldown Validation Helpers
-----------------------------------------------------------

-- @param lastTime: timestamp of last action
-- @param cooldownDuration: required cooldown in seconds
-- @param currentTime: current timestamp (optional, uses getTimestamp() if nil)
function Validation.CheckCooldown(lastTime, cooldownDuration, currentTime)
    local now = currentTime or (getTimestamp and getTimestamp() or os.time())
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

-----------------------------------------------------------
-- Value Validation
-----------------------------------------------------------

-- @param cornerDx: x offset (-1, 0, or 1)
-- @param cornerDy: y offset (-1, 0, or 1)
function Validation.ValidateCornerOffset(cornerDx, cornerDy)
    if type(cornerDx) ~= "number" or type(cornerDy) ~= "number" then
        return false, 0, 0
    end
    
    local sanitizedDx = math.max(-1, math.min(1, math.floor(cornerDx)))
    local sanitizedDy = math.max(-1, math.min(1, math.floor(cornerDy)))
    
    return true, sanitizedDx, sanitizedDy
end

-- @param tier: tier number to validate
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

-- @param player: player object
-- @param refugeId: refuge ID to check
function Validation.ValidateRefugeAccess(player, refugeId)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    local expectedRefugeId = "refuge_" .. username
    return refugeId == expectedRefugeId
end

-- @param x, y: coordinates to check
function Validation.ValidateWorldCoordinates(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then
        return false, "Invalid coordinate type"
    end
    
    if Data.IsInRefugeCoordinates(x, y) then
        return false, "Coordinates are in refuge space"
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Upgrade Validation
-----------------------------------------------------------

-- @param player: player object
-- @param refugeData: current refuge data
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
