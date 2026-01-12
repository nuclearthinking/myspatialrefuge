-- Boundary enforcement: prevents players from leaving refuge area

require "shared/01_modules/MSR_PlayerMessage"

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
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local radius = refugeData.radius
    
    local tileMinX = centerX - radius
    local tileMaxX = centerX + radius
    local tileMinY = centerY - radius
    local tileMaxY = centerY + radius
    
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
        radius = radius
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
    
    -- Only check if player is in refuge area
    if not MSR.IsPlayerInRefuge or not MSR.IsPlayerInRefuge(player) then
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

