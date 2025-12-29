-- Spatial Refuge Validation Module (Shared)
-- Centralized validation logic for both client and server
-- Eliminates code duplication and ensures consistent validation rules

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeData"

-- Prevent double-loading
if SpatialRefugeValidation and SpatialRefugeValidation._loaded then
    return SpatialRefugeValidation
end

SpatialRefugeValidation = SpatialRefugeValidation or {}
SpatialRefugeValidation._loaded = true

-----------------------------------------------------------
-- Player State Validation
-- These checks are environment-agnostic (work on both client and server)
-----------------------------------------------------------

-- Check if player object is valid
function SpatialRefugeValidation.IsValidPlayer(player)
    if not player then
        return false, "Invalid player"
    end
    
    -- Check for essential player methods
    if not player.getX or not player.getY or not player.getZ then
        return false, "Invalid player state"
    end
    
    return true, nil
end

-- Check if player is in a vehicle
function SpatialRefugeValidation.IsInVehicle(player)
    if not player then return false end
    return player:getVehicle() ~= nil
end

-- Check if player is climbing
function SpatialRefugeValidation.IsClimbing(player)
    if not player then return false end
    return player.isClimbing and player:isClimbing()
end

-- Check if player is falling
function SpatialRefugeValidation.IsFalling(player)
    if not player then return false end
    return player.isFalling and player:isFalling()
end

-- Check if player is over-encumbered
function SpatialRefugeValidation.IsOverEncumbered(player)
    if not player then return false end
    return player.isOverEncumbered and player:isOverEncumbered()
end

-- Check if player is in refuge coordinates
function SpatialRefugeValidation.IsInRefugeCoords(player)
    if not player then return false end
    return SpatialRefugeData.IsPlayerInRefugeCoords(player)
end

-----------------------------------------------------------
-- Composite Validation Functions
-- These combine multiple checks into common validation scenarios
-----------------------------------------------------------

-- Validate player can teleport (basic physical state checks)
-- Returns: canTeleport (boolean), reason (string or nil)
-- Note: Does NOT check cooldowns - those are context-specific (client vs server)
function SpatialRefugeValidation.CanPlayerTeleport(player)
    -- Check player validity
    local valid, reason = SpatialRefugeValidation.IsValidPlayer(player)
    if not valid then
        return false, reason
    end
    
    -- Check if in vehicle
    if SpatialRefugeValidation.IsInVehicle(player) then
        return false, "Cannot teleport while in vehicle"
    end
    
    -- Check if climbing or falling
    if SpatialRefugeValidation.IsClimbing(player) then
        return false, "Cannot teleport while climbing"
    end
    
    if SpatialRefugeValidation.IsFalling(player) then
        return false, "Cannot teleport while falling"
    end
    
    -- Check if over-encumbered
    if SpatialRefugeValidation.IsOverEncumbered(player) then
        return false, "Cannot teleport while encumbered"
    end
    
    return true, nil
end

-- Validate player can enter refuge (physical + location checks)
-- Returns: canEnter (boolean), reason (string or nil)
-- Note: Does NOT check cooldowns - those are context-specific
function SpatialRefugeValidation.CanEnterRefuge(player)
    -- First check basic teleport ability
    local canTeleport, reason = SpatialRefugeValidation.CanPlayerTeleport(player)
    if not canTeleport then
        return false, reason
    end
    
    -- Check if already in refuge
    if SpatialRefugeValidation.IsInRefugeCoords(player) then
        return false, "Already in refuge"
    end
    
    return true, nil
end

-- Validate player can exit refuge (physical + location checks)
-- Returns: canExit (boolean), reason (string or nil)
function SpatialRefugeValidation.CanExitRefuge(player)
    -- First check basic teleport ability
    local canTeleport, reason = SpatialRefugeValidation.CanPlayerTeleport(player)
    if not canTeleport then
        return false, reason
    end
    
    -- Check if actually in refuge (should be, but validate)
    if not SpatialRefugeValidation.IsInRefugeCoords(player) then
        return false, "Not in refuge"
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Cooldown Validation Helpers
-- These are helpers that can be used by both client and server
-- Actual cooldown state is managed by caller (client-side or server-side)
-----------------------------------------------------------

-- Check if a cooldown has expired
-- @param lastTime: timestamp of last action
-- @param cooldownDuration: required cooldown in seconds
-- @param currentTime: current timestamp (optional, uses getTimestamp() if nil)
-- Returns: canProceed (boolean), remainingSeconds (number)
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

-- Format cooldown message
function SpatialRefugeValidation.FormatCooldownMessage(baseMessage, remainingSeconds)
    return baseMessage .. " (" .. remainingSeconds .. "s)"
end

-----------------------------------------------------------
-- Value Validation
-- Input sanitization and validation
-----------------------------------------------------------

-- Validate corner offset values (for relic movement)
-- @param cornerDx: x offset (-1, 0, or 1)
-- @param cornerDy: y offset (-1, 0, or 1)
-- Returns: isValid (boolean), sanitizedDx (number), sanitizedDy (number)
function SpatialRefugeValidation.ValidateCornerOffset(cornerDx, cornerDy)
    -- Type check
    if type(cornerDx) ~= "number" or type(cornerDy) ~= "number" then
        return false, 0, 0
    end
    
    -- Clamp to valid range (-1, 0, 1)
    local sanitizedDx = math.max(-1, math.min(1, math.floor(cornerDx)))
    local sanitizedDy = math.max(-1, math.min(1, math.floor(cornerDy)))
    
    return true, sanitizedDx, sanitizedDy
end

-- Validate tier value
-- @param tier: tier number to validate
-- Returns: isValid (boolean), reason (string or nil)
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

-- Validate refuge access (player owns this refuge)
-- @param player: player object
-- @param refugeId: refuge ID to check
-- Returns: hasAccess (boolean)
function SpatialRefugeValidation.ValidateRefugeAccess(player, refugeId)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    local expectedRefugeId = "refuge_" .. username
    return refugeId == expectedRefugeId
end

-- Validate coordinates are not in refuge space (for return position)
-- @param x, y: coordinates to check
-- Returns: isValid (boolean), reason (string or nil)
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

-- Validate upgrade prerequisites (not cooldowns, just state)
-- @param player: player object
-- @param refugeData: current refuge data
-- Returns: canUpgrade (boolean), reason (string or nil), tierConfig (table or nil)
function SpatialRefugeValidation.CanUpgradeRefuge(player, refugeData)
    -- Check player validity
    local valid, reason = SpatialRefugeValidation.IsValidPlayer(player)
    if not valid then
        return false, reason, nil
    end
    
    -- Check refuge data exists
    if not refugeData then
        return false, "No refuge found", nil
    end
    
    -- Check player is in their refuge
    if not SpatialRefugeValidation.IsInRefugeCoords(player) then
        return false, "Must be in refuge to upgrade", nil
    end
    
    -- Check max tier
    local currentTier = refugeData.tier or 0
    local newTier = currentTier + 1
    
    if newTier > SpatialRefugeConfig.MAX_TIER then
        return false, "Already at maximum tier", nil
    end
    
    -- Get tier config
    local tierConfig = SpatialRefugeConfig.TIERS[newTier]
    if not tierConfig then
        return false, "Invalid tier configuration", nil
    end
    
    return true, nil, tierConfig
end

return SpatialRefugeValidation

