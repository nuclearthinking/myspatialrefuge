-- Spatial Refuge Validation Module (Shared)
-- Centralized validation logic for both client and server
-- Eliminates code duplication and ensures consistent validation rules

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeData"

if SpatialRefugeValidation and SpatialRefugeValidation._loaded then
    return SpatialRefugeValidation
end

SpatialRefugeValidation = SpatialRefugeValidation or {}
SpatialRefugeValidation._loaded = true

-----------------------------------------------------------
-- Player State Validation
-----------------------------------------------------------

function SpatialRefugeValidation.IsValidPlayer(player)
    if not player then
        return false, "Invalid player"
    end
    
    if not player.getX or not player.getY or not player.getZ then
        return false, "Invalid player state"
    end
    
    return true, nil
end

function SpatialRefugeValidation.IsInVehicle(player)
    if not player then return false end
    return player:getVehicle() ~= nil
end

function SpatialRefugeValidation.IsClimbing(player)
    if not player then return false end
    return player.isClimbing and player:isClimbing()
end

function SpatialRefugeValidation.IsFalling(player)
    if not player then return false end
    return player.isFalling and player:isFalling()
end

function SpatialRefugeValidation.IsOverEncumbered(player)
    if not player then return false end
    
    if player.isOverEncumbered then
        local ok, res = pcall(function() return player:isOverEncumbered() end)
        if ok then
            return res == true
        end
    end
    
    -- Fallback: compare carried weight vs max carry capacity.
    -- Different PZ builds/mod stacks may not expose isOverEncumbered() to Lua consistently.
    local invWeight = nil
    if player.getInventoryWeight then
        local ok, w = pcall(function() return player:getInventoryWeight() end)
        if ok then invWeight = w end
    end
    
    local maxWeight = nil
    if player.getMaxWeight then
        local ok, w = pcall(function() return player:getMaxWeight() end)
        if ok then maxWeight = w end
    end
    
    if invWeight ~= nil and maxWeight ~= nil then
        return invWeight > maxWeight
    end
    
    return false
end

function SpatialRefugeValidation.IsInRefugeCoords(player)
    if not player then return false end
    return SpatialRefugeData.IsPlayerInRefugeCoords(player)
end

-----------------------------------------------------------
-- Composite Validation Functions
-----------------------------------------------------------

-- Does NOT check cooldowns - those are context-specific (client vs server)
function SpatialRefugeValidation.CanPlayerTeleport(player)
    local valid, reason = SpatialRefugeValidation.IsValidPlayer(player)
    if not valid then
        return false, reason
    end
    
    if SpatialRefugeValidation.IsInVehicle(player) then
        return false, "Cannot teleport while in vehicle"
    end
    
    if SpatialRefugeValidation.IsClimbing(player) then
        return false, "Cannot teleport while climbing"
    end
    
    if SpatialRefugeValidation.IsFalling(player) then
        return false, "Cannot teleport while falling"
    end
    
    if SpatialRefugeValidation.IsOverEncumbered(player) then
        return false, "Cannot teleport while encumbered"
    end
    
    return true, nil
end

-- Does NOT check cooldowns - those are context-specific
function SpatialRefugeValidation.CanEnterRefuge(player)
    local canTeleport, reason = SpatialRefugeValidation.CanPlayerTeleport(player)
    if not canTeleport then
        return false, reason
    end
    
    if SpatialRefugeValidation.IsInRefugeCoords(player) then
        return false, "Already in refuge"
    end
    
    return true, nil
end

function SpatialRefugeValidation.CanExitRefuge(player)
    local canTeleport, reason = SpatialRefugeValidation.CanPlayerTeleport(player)
    if not canTeleport then
        return false, reason
    end
    
    if not SpatialRefugeValidation.IsInRefugeCoords(player) then
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
function SpatialRefugeValidation.CheckCooldown(lastTime, cooldownDuration, currentTime)
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

function SpatialRefugeValidation.FormatCooldownMessage(baseMessage, remainingSeconds)
    return baseMessage .. " (" .. remainingSeconds .. "s)"
end

-----------------------------------------------------------
-- Value Validation
-----------------------------------------------------------

-- @param cornerDx: x offset (-1, 0, or 1)
-- @param cornerDy: y offset (-1, 0, or 1)
function SpatialRefugeValidation.ValidateCornerOffset(cornerDx, cornerDy)
    if type(cornerDx) ~= "number" or type(cornerDy) ~= "number" then
        return false, 0, 0
    end
    
    local sanitizedDx = math.max(-1, math.min(1, math.floor(cornerDx)))
    local sanitizedDy = math.max(-1, math.min(1, math.floor(cornerDy)))
    
    return true, sanitizedDx, sanitizedDy
end

-- @param tier: tier number to validate
function SpatialRefugeValidation.ValidateTier(tier)
    if type(tier) ~= "number" then
        return false, "Invalid tier type"
    end
    
    if tier < 0 then
        return false, "Tier cannot be negative"
    end
    
    if tier > SpatialRefugeConfig.MAX_TIER then
        return false, "Tier exceeds maximum"
    end
    
    if not SpatialRefugeConfig.TIERS[tier] then
        return false, "Invalid tier configuration"
    end
    
    return true, nil
end

-- @param player: player object
-- @param refugeId: refuge ID to check
function SpatialRefugeValidation.ValidateRefugeAccess(player, refugeId)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    local expectedRefugeId = "refuge_" .. username
    return refugeId == expectedRefugeId
end

-- @param x, y: coordinates to check
function SpatialRefugeValidation.ValidateWorldCoordinates(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then
        return false, "Invalid coordinate type"
    end
    
    if SpatialRefugeData.IsInRefugeCoordinates(x, y) then
        return false, "Coordinates are in refuge space"
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Upgrade Validation
-----------------------------------------------------------

-- @param player: player object
-- @param refugeData: current refuge data
function SpatialRefugeValidation.CanUpgradeRefuge(player, refugeData)
    local valid, reason = SpatialRefugeValidation.IsValidPlayer(player)
    if not valid then
        return false, reason, nil
    end
    
    if not refugeData then
        return false, "No refuge found", nil
    end
    
    if not SpatialRefugeValidation.IsInRefugeCoords(player) then
        return false, "Must be in refuge to upgrade", nil
    end
    
    local currentTier = refugeData.tier or 0
    local newTier = currentTier + 1
    
    if newTier > SpatialRefugeConfig.MAX_TIER then
        return false, "Already at maximum tier", nil
    end
    
    local tierConfig = SpatialRefugeConfig.TIERS[newTier]
    if not tierConfig then
        return false, "Invalid tier configuration", nil
    end
    
    return true, nil, tierConfig
end

return SpatialRefugeValidation

