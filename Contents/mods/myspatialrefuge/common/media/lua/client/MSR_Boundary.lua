-- Boundary enforcement: prevents players from leaving refuge area

require "MSR_PlayerMessage"
require "MSR_RefugeGeometry"

local lastBoundaryWarning = setmetatable({}, {__mode = "k"})  -- weak: last warning time per player
local boundaryCheckSuppressed = setmetatable({}, {__mode = "k"})  -- weak: suppressed during approach teleport
local cachedBounds = setmetatable({}, {__mode = "k"})  -- weak: bounds cache per player

-- Suppress boundary check during teleport (approach phase is outside refuge)
function MSR.SuppressBoundaryCheck(player, suppress)
    if player then
        boundaryCheckSuppressed[player] = suppress and true or nil
    end
end
function MSR.GetRefugeBounds(refugeData)
    if not refugeData then return nil end
    
    local tiles = MSR.RefugeGeometry.GetTileBounds(refugeData)
    if not tiles then return nil end
    local centerX, centerY, radius = tiles.centerX, tiles.centerY, tiles.radius
    local tileMinX, tileMaxX = tiles.minX, tiles.maxX
    local tileMinY, tileMaxY = tiles.minY, tiles.maxY
    
    return {
        posMinX = tileMinX,
        posMaxX = tileMaxX + 1,
        posMinY = tileMinY,
        posMaxY = tileMaxY + 1,
        tileMinX = tileMinX,
        tileMaxX = tileMaxX,
        tileMinY = tileMinY,
        tileMaxY = tileMaxY,
        centerX = centerX,
        centerY = centerY,
        radius = radius,
        slotCenterX = refugeData.centerX,
        slotCenterY = refugeData.centerY,
        slotHalfSpacing = MSR.Config.REFUGE_SPACING / 2
    }
end

-- Invalidate cached bounds for a player (call on upgrade or exit)
function MSR.InvalidateBoundsCache(player)
    if player then
        cachedBounds[player] = nil
    end
end

function MSR.CheckBoundaryViolation(player)
    if not player then return false end
    
    -- Skip during approach teleport phase
    if boundaryCheckSuppressed[player] then
        return false
    end
    
    local bounds = cachedBounds[player]
    if not bounds then
        -- ModData may not be available on MP client before server sync
        if not MSR.Data or not MSR.Data.HasRefugeData or not MSR.Data.HasRefugeData() then
            return false
        end
        
        if not MSR.GetRefugeData then return false end
        local refugeData = MSR.GetRefugeData(player)
        if not refugeData then return false end
        bounds = MSR.GetRefugeBounds(refugeData)
        if not bounds then return false end
        cachedBounds[player] = bounds
    end
    
    local playerX = player:getX()
    local playerY = player:getY()

    -- Keep enforcing just outside the effective wall, but never affect the
    -- player elsewhere in the world. The immutable slot envelope is the gate.
    if math.abs(playerX - bounds.slotCenterX) >= bounds.slotHalfSpacing
        or math.abs(playerY - bounds.slotCenterY) >= bounds.slotHalfSpacing
    then
        return false
    end
    
    local isOutside = false
    local clampedX = playerX
    local clampedY = playerY
    
    if playerX < bounds.posMinX then
        clampedX = bounds.posMinX + 0.1
        isOutside = true
    elseif playerX >= bounds.posMaxX then
        clampedX = bounds.posMaxX - 0.1
        isOutside = true
    end
    
    if playerY < bounds.posMinY then
        clampedY = bounds.posMinY + 0.1
        isOutside = true
    elseif playerY >= bounds.posMaxY then
        clampedY = bounds.posMaxY - 0.1
        isOutside = true
    end
    
    return isOutside, clampedX, clampedY, bounds
end


local tickCounter = 0

local function OnPlayerUpdateThrottled(player)
    tickCounter = tickCounter + 1
    if tickCounter < 2 then return end
    tickCounter = 0
    
    if not player then return end
    
    local isOutside, clampedX, clampedY = MSR.CheckBoundaryViolation(player)
    if not isOutside or not clampedX then return end
    
    player:setX(clampedX)
    player:setLastX(clampedX)
    player:setY(clampedY)
    player:setLastY(clampedY)
    
    local currentTime = K.time()
    local lastWarning = lastBoundaryWarning[player] or 0
    
    if currentTime - lastWarning > 2 then
        lastBoundaryWarning[player] = currentTime
        local PM = MSR.PlayerMessage
        PM.Say(player, PM.CANNOT_LEAVE_BOUNDARY)
    end
end

Events.OnPlayerUpdate.Add(OnPlayerUpdateThrottled)

return MSR

