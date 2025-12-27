-- Spatial Refuge Boundary Enforcement
-- Monitors player position and prevents them from leaving refuge boundaries
-- Uses soft boundaries that push players back to the edge (not center)

SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-- Track last boundary warning time per player to avoid spam
-- Uses weak keys to allow garbage collection when players disconnect
local lastBoundaryWarning = setmetatable({}, {__mode = "k"})

-- Cached bounds per player (cleared on refuge upgrade or exit)
local cachedBounds = setmetatable({}, {__mode = "k"})

-- Get refuge boundary limits for position checking
-- In PZ, a tile at (x,y) has player positions from x.0 to x.999...
-- So for tiles minX to maxX, valid positions are minX.0 to (maxX+1).0
function SpatialRefuge.GetRefugeBounds(refugeData)
    if not refugeData then return nil end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local radius = refugeData.radius
    
    -- Tile bounds (inclusive)
    local tileMinX = centerX - radius
    local tileMaxX = centerX + radius
    local tileMinY = centerY - radius
    local tileMaxY = centerY + radius
    
    -- Position bounds: player can be anywhere on tiles minX to maxX
    -- Position on tile X ranges from X.0 to (X+1).0
    -- So valid position range is [tileMinX, tileMaxX + 1)
    return {
        -- Position bounds for player coordinate checks
        posMinX = tileMinX,
        posMaxX = tileMaxX + 1,  -- Exclusive upper bound
        posMinY = tileMinY,
        posMaxY = tileMaxY + 1,  -- Exclusive upper bound
        -- Tile bounds for reference
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
function SpatialRefuge.InvalidateBoundsCache(player)
    if player then
        cachedBounds[player] = nil
    end
end

-- Check if player position is outside boundaries and calculate clamped position
-- Returns: isOutside, clampedX, clampedY, bounds
function SpatialRefuge.CheckBoundaryViolation(player)
    if not player then return false end
    
    -- Only check if player is in refuge area
    if not SpatialRefuge.IsPlayerInRefuge or not SpatialRefuge.IsPlayerInRefuge(player) then
        return false
    end
    
    -- Use cached bounds for performance
    local bounds = cachedBounds[player]
    if not bounds then
        if not SpatialRefuge.GetRefugeData then return false end
        local refugeData = SpatialRefuge.GetRefugeData(player)
        if not refugeData then return false end
        bounds = SpatialRefuge.GetRefugeBounds(refugeData)
        if not bounds then return false end
        cachedBounds[player] = bounds
    end
    
    local playerX = player:getX()
    local playerY = player:getY()
    
    local isOutside = false
    local clampedX = playerX
    local clampedY = playerY
    
    -- Check and clamp X position
    -- Valid range: [posMinX, posMaxX) 
    if playerX < bounds.posMinX then
        -- Too far west (outside west wall)
        clampedX = bounds.posMinX + 0.1
        isOutside = true
    elseif playerX >= bounds.posMaxX then
        -- Too far east (outside east wall)
        clampedX = bounds.posMaxX - 0.1
        isOutside = true
    end
    
    -- Check and clamp Y position
    -- Valid range: [posMinY, posMaxY)
    if playerY < bounds.posMinY then
        -- Too far north (outside north wall)
        clampedY = bounds.posMinY + 0.1
        isOutside = true
    elseif playerY >= bounds.posMaxY then
        -- Too far south (outside south wall)
        clampedY = bounds.posMaxY - 0.1
        isOutside = true
    end
    
    return isOutside, clampedX, clampedY, bounds
end

-- Legacy function for compatibility (returns center for teleport-back)
function SpatialRefuge.IsOutsideRefugeBoundary(player)
    local isOutside, clampedX, clampedY, bounds = SpatialRefuge.CheckBoundaryViolation(player)
    if isOutside and bounds then
        return true, bounds.centerX, bounds.centerY, clampedX, clampedY
    end
    return false
end

-- Monitor player position and enforce boundaries (smooth push-back)
local function OnPlayerUpdate(player)
    if not player then return end
    
    local isOutside, clampedX, clampedY = SpatialRefuge.CheckBoundaryViolation(player)
    
    if isOutside and clampedX and clampedY then
        -- Push player back to edge (not center) - much smoother experience
        player:setX(clampedX)
        player:setLastX(clampedX)
        player:setY(clampedY)
        player:setLastY(clampedY)
        
        -- Show warning message (throttled to avoid spam)
        local currentTime = getTimestamp and getTimestamp() or os.time()
        local lastWarning = lastBoundaryWarning[player] or 0
        
        if currentTime - lastWarning > 2 then
            lastBoundaryWarning[player] = currentTime
            player:Say("Cannot leave refuge boundary!")
        end
    end
end

-- Register event - check frequently for smooth boundary enforcement
local tickCounter = 0
local CHECK_INTERVAL = 2  -- Check every 2 ticks for responsive feel

local function OnPlayerUpdateThrottled(player)
    tickCounter = tickCounter + 1
    if tickCounter >= CHECK_INTERVAL then
        tickCounter = 0
        OnPlayerUpdate(player)
    end
end

Events.OnPlayerUpdate.Add(OnPlayerUpdateThrottled)

return SpatialRefuge

