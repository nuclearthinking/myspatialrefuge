-- Spatial Refuge Shared Module
-- Generation functions accessible by both client and server
-- For multiplayer persistence, server uses these functions to create objects that save to map

require "shared/SpatialRefugeConfig"

-- Prevent double-loading
if SpatialRefugeShared and SpatialRefugeShared._loaded then
    return SpatialRefugeShared
end

SpatialRefugeShared = SpatialRefugeShared or {}
SpatialRefugeShared._loaded = true

-----------------------------------------------------------
-- Cached Environment Flags (cannot change during session)
-----------------------------------------------------------

local _cachedIsServer = nil

-- Cached isServer() check - only evaluated once
local function getCachedIsServer()
    if _cachedIsServer == nil then
        _cachedIsServer = isServer()
    end
    return _cachedIsServer
end

-----------------------------------------------------------
-- World Object Utilities
-----------------------------------------------------------
-- In the two-phase MP approach:
-- - Server generates objects after client teleports
-- - Server uses transmitAddObjectToSquare to broadcast to clients
-- - transmitCompleteItemToClients() is NOT deprecated (only client->server is)

-- Add object to square with proper MP sync
local function addObjectToSquare(square, obj)
    if not square or not obj then return false end
    local chunk = square:getChunk()
    if not chunk then return false end
    
    -- On server: use transmit to broadcast to clients
    -- On SP/client: use direct add
    if getCachedIsServer() then
        square:transmitAddObjectToSquare(obj, -1)
    else
        square:AddTileObject(obj)
    end
    square:RecalcAllWithNeighbours(true)
    return true
end

-- Add special object (walls, furniture) to square with proper MP sync
local function addSpecialObjectToSquare(square, obj)
    if not square or not obj then return false end
    local chunk = square:getChunk()
    if not chunk then return false end
    
    -- On server: use transmit to broadcast to clients
    -- On SP/client: use direct add
    if getCachedIsServer() then
        square:transmitAddObjectToSquare(obj, -1)
    else
        square:AddSpecialObject(obj)
    end
    square:RecalcAllWithNeighbours(true)
    return true
end

-- Remove object from square with proper MP sync
local function removeObjectFromSquare(square, obj)
    if not square or not obj then return false end
    
    -- For IsoThumpable objects, we need a comprehensive removal approach
    -- to ensure proper client sync in multiplayer
    
    -- Method 1: Use the standard transmit removal (broadcasts to clients)
    square:transmitRemoveItemFromSquare(obj)
    
    -- Method 2: Also try RemoveWorldObject if available (some PZ versions)
    if square.RemoveWorldObject then
        pcall(function() square:RemoveWorldObject(obj) end)
    end
    
    -- Method 3: Remove from the IsoObject's own references
    if obj.removeFromSquare then
        pcall(function() obj:removeFromSquare() end)
    end
    if obj.removeFromWorld then
        pcall(function() obj:removeFromWorld() end)
    end
    
    -- Force recalculation of square and neighbors for proper rendering
    square:RecalcAllWithNeighbours(true)
    
    return true
end

-- Buffer tiles around refuge to clear zombies
local ZOMBIE_CLEAR_BUFFER = 3

-----------------------------------------------------------
-- Utility Functions
-----------------------------------------------------------

-- Resolve the Sacred Relic sprite name (handles padding variants)
function SpatialRefugeShared.ResolveRelicSprite()
    local spriteName = SpatialRefugeConfig.SPRITES.SACRED_RELIC
    if getSprite and getSprite(spriteName) then
        return spriteName
    end
    -- Try padded variants
    local digits = spriteName:match("_(%d+)$")
    if digits then
        local padded2 = spriteName:gsub("_(%d+)$", "_0" .. digits)
        if getSprite and getSprite(padded2) then return padded2 end
        local padded3 = spriteName:gsub("_(%d+)$", "_00" .. digits)
        if getSprite and getSprite(padded3) then return padded3 end
    end
    return nil
end

-- Find relic on a specific square
function SpatialRefugeShared.FindRelicOnSquare(square, refugeId)
    if not square then return nil end
    local objects = square:getObjects()
    if not objects then return nil end
    
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj then
            local md = obj:getModData()
            if md and md.isSacredRelic and md.refugeId == refugeId then
                return obj
            end
        end
    end
    return nil
end

-- Search entire refuge area for an existing Sacred Relic
-- This handles cases where relic was moved from center to a corner
function SpatialRefugeShared.FindRelicInRefuge(centerX, centerY, z, radius, refugeId)
    local cell = getCell()
    if not cell then return nil end
    
    -- Search the entire refuge area (center + radius in all directions)
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local relic = SpatialRefugeShared.FindRelicOnSquare(square, refugeId)
                if relic then
                    return relic
                end
            end
        end
    end
    return nil
end

-- Move Sacred Relic to a new position within the refuge (server-authoritative)
-- Returns: success (boolean), message (string)
function SpatialRefugeShared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName)
    if not refugeData then return false, "No refuge data" end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    
    -- Calculate target position
    local targetX = centerX + (cornerDx * radius)
    local targetY = centerY + (cornerDy * radius)
    local targetZ = centerZ
    
    -- Find existing relic
    local relic = SpatialRefugeShared.FindRelicInRefuge(centerX, centerY, centerZ, radius, refugeId)
    if not relic then
        return false, "Sacred Relic not found"
    end
    
    -- Get current position
    local currentSquare = relic:getSquare()
    if currentSquare and currentSquare:getX() == targetX and currentSquare:getY() == targetY then
        return false, "Relic already at " .. cornerName
    end
    
    -- Get target square
    local cell = getCell()
    if not cell then return false, "World not ready" end
    
    -- Only use getGridSquare - don't create empty cells
    local targetSquare = cell:getGridSquare(targetX, targetY, targetZ)
    if not targetSquare then return false, "Destination not loaded" end
    
    -- Verify chunk is loaded
    local targetChunk = targetSquare:getChunk()
    if not targetChunk then return false, "Destination chunk not loaded" end
    
    -- Check if target is blocked by actual obstructions
    -- We allow placement on natural floor (grass/dirt) since floor tiles are not generated
    -- Only block for: trees, zombies/players, non-refuge walls, large objects
    local hasBlockingObject = false
    local blockingReason = nil
    
    -- Check for trees
    if targetSquare:getTree() then
        hasBlockingObject = true
        blockingReason = "Tree in the way"
    end
    
    -- Check for zombies/players on the square
    if not hasBlockingObject then
        local movingObjects = targetSquare:getMovingObjects()
        if movingObjects and movingObjects:size() > 0 then
            hasBlockingObject = true
            blockingReason = "Something is standing there"
        end
    end
    
    -- Check for actual blocking objects (not floor, not our refuge structures)
    if not hasBlockingObject then
        local objects = targetSquare:getObjects()
        if objects then
            for i = 0, objects:size() - 1 do
                local obj = objects:get(i)
                if obj then
                            -- Get object type
                            local objType = nil
                            if obj.getType then
                                objType = obj:getType()
                            end
                            
                            -- Skip floor tiles (any type - natural grass, dirt, etc.)
                            -- Note: IsoObjectType.floor doesn't exist in PZ, only FloorTile
                            local isFloor = (objType == IsoObjectType.FloorTile)
                    
                    -- Check ModData for refuge structures
                    local md = obj.getModData and obj:getModData() or nil
                    local isRefugeObject = md and (md.isRefugeBoundary or md.isSacredRelic or md.isProtectedRefugeObject)
                    
                    -- Only check for blocking if it's NOT floor and NOT our refuge structure
                    if not isFloor and not isRefugeObject then
                        -- At this point, it's a non-refuge, non-floor object
                        -- Check if it's actually blocking (walls, large furniture, vehicles)
                        if objType == IsoObjectType.wall then
                            hasBlockingObject = true
                            blockingReason = "Wall in the way"
                            break
                        elseif objType == IsoObjectType.tree then
                            hasBlockingObject = true
                            blockingReason = "Tree in the way"
                            break
                        elseif objType == IsoObjectType.stairsTW or objType == IsoObjectType.stairsMW or 
                               objType == IsoObjectType.stairsNW or objType == IsoObjectType.stairsBN then
                            hasBlockingObject = true
                            blockingReason = "Stairs in the way"
                            break
                        end
                        -- For other objects (grass, flowers, small decorations) - not blocking
                    end
                end
            end
        end
    end
    
    if hasBlockingObject then
        if getDebug() then
            print("[SpatialRefugeShared] MoveRelic: Blocked - " .. tostring(blockingReason))
        end
        return false, blockingReason or "Destination blocked"
    end
    
    -- Verify both source and target chunks are loaded
    if currentSquare then
        local sourceChunk = currentSquare:getChunk()
        if not sourceChunk then
            return false, "Current location not loaded"
        end
    end
    
    -- Re-verify target chunk is still loaded (already checked above, but be safe)
    if not targetChunk then
        return false, "Destination not loaded"
    end
    
    -- Perform the move - PRESERVE container and all object data
    -- Use PZ's built-in transmit methods which handle both local state AND network sync
    -- 
    -- IMPORTANT: transmitRemoveItemFromSquare removes from local list AND syncs to clients
    -- transmitAddObjectToSquare adds to local list AND syncs to clients
    -- We must set square reference between remove and add for transmitAddObjectToSquare to work
    
    if currentSquare then
        -- This removes from local list AND transmits removal to clients
        currentSquare:transmitRemoveItemFromSquare(relic)
    end
    
    -- Set new square reference (required for transmitAddObjectToSquare)
    relic:setSquare(targetSquare)
    
    -- This adds to local list AND transmits to clients
    -- Using index -1 means "add to end of list"
    targetSquare:transmitAddObjectToSquare(relic, -1)
    
    -- Recalc for proper rendering
    if currentSquare then
        currentSquare:RecalcAllWithNeighbours(true)
    end
    targetSquare:RecalcAllWithNeighbours(true)
    
    -- Store corner assignment in relic modData
    local md = relic:getModData()
    md.assignedCorner = cornerName
    md.assignedCornerDx = cornerDx
    md.assignedCornerDy = cornerDy
    
    -- Transmit ModData so assignment persists
    if getCachedIsServer() and relic.transmitModData then
        relic:transmitModData()
    end
    
    if getDebug() then
        print("[SpatialRefugeShared] Moved relic to " .. cornerName .. " (" .. targetX .. "," .. targetY .. ")")
    end
    
    return true, "Moved to " .. cornerName
end

-----------------------------------------------------------
-- Wall Generation
-- NOTE: Floor generation removed - natural terrain should remain
-----------------------------------------------------------

-- Create a single solid wall segment (IsoThumpable)
local function createWallObject(square, spriteName, isNorthWall)
    if not square then return nil end
    
    -- Check if chunk is loaded before creating objects
    local chunk = square:getChunk()
    if not chunk then
        if getDebug() then
            print("[SpatialRefugeShared] Chunk not loaded for wall square - skipping")
        end
        return nil
    end
    
    -- Check if this exact wall type already exists (prevent duplicates)
    local objects = square:getObjects()
    if objects then
        for i = 0, objects:size() - 1 do
            local obj = objects:get(i)
            if obj and obj.getModData then
                local md = obj:getModData()
                if md and md.isRefugeBoundary and md.refugeBoundarySprite == spriteName then
                    -- Wall already exists at this position with this sprite
                    if getDebug() then
                        print("[SpatialRefugeShared] Wall already exists at " .. square:getX() .. "," .. square:getY() .. " - skipping duplicate")
                    end
                    return obj  -- Return existing wall
                end
            end
        end
    end
    
    local cell = getCell()
    if not cell then 
        if getDebug() then print("[SpatialRefugeShared] getCell() returned nil") end
        return nil 
    end
    
    -- Create real solid wall using IsoThumpable
    local wall = IsoThumpable.new(cell, square, spriteName, isNorthWall, {})
    if not wall then 
        if getDebug() then print("[SpatialRefugeShared] Failed to create wall for " .. spriteName) end
        return nil 
    end
    
    -- Make it completely indestructible and non-interactable
    wall:setMaxHealth(999999)
    wall:setHealth(999999)
    wall:setCanBarricade(false)
    wall:setIsThumpable(false)
    wall:setBreakSound("none")
    wall:setIsDismantable(false)
    wall:setCanBePlastered(false)
    wall:setIsHoppable(false)
    
    -- Additional protection flags (if available in current PZ version)
    if wall.setDestroyed then wall:setDestroyed(false) end
    
    local md = wall:getModData()
    md.isRefugeBoundary = true
    md.refugeBoundarySprite = spriteName
    md.canBeDisassembled = false
    md.isProtectedRefugeObject = true  -- Used by sledgehammer hook
    
    -- Add to square with MP sync
    if addSpecialObjectToSquare(square, wall) then
        -- Transmit complete object state (properties + ModData) to clients
        -- This ensures isThumpable=false and other properties are synced
        if getCachedIsServer() then
            if wall.transmitCompleteItemToClients then
                wall:transmitCompleteItemToClients()
            elseif wall.transmitModData then
                wall:transmitModData()
            end
        end
        return wall
    end
    return nil
end

-- Create boundary wall at coordinates
-- addNorth: add north-facing wall segment
-- addWest: add west-facing wall segment
-- cornerSprite: optional corner sprite to add
function SpatialRefugeShared.CreateWall(x, y, z, addNorth, addWest, cornerSprite)
    local cell = getCell()
    if not cell then 
        if getDebug() then print("[SpatialRefugeShared] getCell() returned nil") end
        return nil 
    end

    -- IMPORTANT: Only use getGridSquare, never getOrCreateGridSquare
    -- getOrCreate might create an empty cell before natural terrain is loaded
    -- We only want to modify existing cells that have proper terrain
    local square = cell:getGridSquare(x, y, z)
    if not square then 
        if getDebug() then print("[SpatialRefugeShared] Square not loaded at " .. x .. "," .. y .. " - skipping wall") end
        return nil 
    end
    
    -- Verify chunk is loaded
    local chunk = square:getChunk()
    if not chunk then
        if getDebug() then print("[SpatialRefugeShared] Chunk not loaded for wall at " .. x .. "," .. y .. " - skipping") end
        return nil
    end

    local created = false
    if addNorth then
        if createWallObject(square, SpatialRefugeConfig.SPRITES.WALL_NORTH, true) then
            created = true
        end
    end
    if addWest then
        if createWallObject(square, SpatialRefugeConfig.SPRITES.WALL_WEST, false) then
            created = true
        end
    end
    if cornerSprite then
        if createWallObject(square, cornerSprite, false) then
            created = true
        end
    end

    return created and square or nil
end

-- Create solid boundary walls around a refuge area
-- Returns: number of walls created
-- 
-- Wall placement in PZ isometric system:
-- - Interior usable area: from (minX, minY) to (maxX, maxY)
-- - Walls are placed on interior tiles but their sprites render at edges
-- - North-facing walls block entry from north (y-1)
-- - West-facing walls block entry from west (x-1)
function SpatialRefugeShared.CreateBoundaryWalls(centerX, centerY, z, radius)
    local wallsCreated = 0
    local wallHeight = SpatialRefugeConfig.WALL_HEIGHT or 1

    -- NOTE: No floor creation - we only modify existing cells with natural terrain
    -- Walls are added to existing squares, floor should already exist

    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius

    -- Create walls at all z-levels
    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        
        -- North and South walls (horizontal edges)
        for x = minX, maxX do
            if SpatialRefugeShared.CreateWall(x, minY, currentZ, true, false, nil) then
                wallsCreated = wallsCreated + 1
            end
            if SpatialRefugeShared.CreateWall(x, maxY + 1, currentZ, true, false, nil) then
                wallsCreated = wallsCreated + 1
            end
        end

        -- West and East walls (vertical edges)
        for y = minY, maxY do
            if SpatialRefugeShared.CreateWall(minX, y, currentZ, false, true, nil) then
                wallsCreated = wallsCreated + 1
            end
            if SpatialRefugeShared.CreateWall(maxX + 1, y, currentZ, false, true, nil) then
                wallsCreated = wallsCreated + 1
            end
        end

        -- Corner pieces
        SpatialRefugeShared.CreateWall(minX, minY, currentZ, false, false, SpatialRefugeConfig.SPRITES.WALL_CORNER_NW)
        SpatialRefugeShared.CreateWall(maxX + 1, maxY + 1, currentZ, false, false, SpatialRefugeConfig.SPRITES.WALL_CORNER_SE)
    end

    if getDebug() then
        print("[SpatialRefugeShared] Created " .. wallsCreated .. " wall segments")
    end
    return wallsCreated
end

-- Remove ALL boundary walls from the entire refuge area + buffer
-- This is more aggressive than just perimeter scanning and catches any orphaned walls
function SpatialRefugeShared.RemoveAllRefugeWalls(centerX, centerY, z, maxRadius)
    local cell = getCell()
    if not cell then return 0 end
    
    local wallsRemoved = 0
    local wallHeight = SpatialRefugeConfig.WALL_HEIGHT or 1
    
    -- Scan the entire area + 2 tile buffer to catch any orphaned walls
    local scanRadius = maxRadius + 2
    
    if getDebug() then
        print("[SpatialRefugeShared] RemoveAllRefugeWalls: scanning " .. (scanRadius * 2 + 1) .. "x" .. (scanRadius * 2 + 1) .. " area around center")
    end
    
    -- Track all squares we modified for later recalc
    local modifiedSquares = {}
    
    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        for dx = -scanRadius, scanRadius do
            for dy = -scanRadius, scanRadius do
                local x = centerX + dx
                local y = centerY + dy
                local square = cell:getGridSquare(x, y, currentZ)
                if square then
                    local objects = square:getObjects()
                    if objects then
                        -- Collect walls to remove first
                        local toRemove = {}
                        for i = 0, objects:size() - 1 do
                            local obj = objects:get(i)
                            if obj then
                                local md = obj:getModData()
                                if md and md.isRefugeBoundary then
                                    table.insert(toRemove, obj)
                                end
                            end
                        end
                        -- Now remove them
                        for _, obj in ipairs(toRemove) do
                            removeObjectFromSquare(square, obj)
                            wallsRemoved = wallsRemoved + 1
                            table.insert(modifiedSquares, square)
                        end
                    end
                end
            end
        end
    end
    
    -- Force recalculation of all modified squares to ensure client sync
    for _, square in ipairs(modifiedSquares) do
        square:RecalcAllWithNeighbours(true)
        if square.RecalcProperties then
            square:RecalcProperties()
        end
    end
    
    if getDebug() then
        print("[SpatialRefugeShared] RemoveAllRefugeWalls: removed " .. wallsRemoved .. " wall segments from " .. #modifiedSquares .. " squares")
    end
    return wallsRemoved
end

-- Remove boundary walls (for expansion)
-- Scans exact perimeter where walls were placed
function SpatialRefugeShared.RemoveBoundaryWalls(centerX, centerY, z, radius)
    local cell = getCell()
    if not cell then return 0 end
    
    if getDebug() then
        print("[SpatialRefugeShared] RemoveBoundaryWalls: center=" .. centerX .. "," .. centerY .. " radius=" .. radius)
    end
    
    local wallsRemoved = 0
    local wallHeight = SpatialRefugeConfig.WALL_HEIGHT or 1
    
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius
    
    if getDebug() then
        print("[SpatialRefugeShared] RemoveBoundaryWalls: scanning perimeter minX=" .. minX .. " maxX=" .. maxX .. " minY=" .. minY .. " maxY=" .. maxY)
    end
    
    -- Scan exact perimeter where walls are placed (matching CreateBoundaryWalls)
    local perimeterCoords = {}
    
    -- North row (y = minY) and South row (y = maxY + 1)
    for x = minX, maxX + 1 do
        table.insert(perimeterCoords, {x = x, y = minY})
        table.insert(perimeterCoords, {x = x, y = maxY + 1})
    end
    
    -- West column (x = minX) and East column (x = maxX + 1)
    for y = minY, maxY + 1 do
        table.insert(perimeterCoords, {x = minX, y = y})
        table.insert(perimeterCoords, {x = maxX + 1, y = y})
    end
    
    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        for _, coord in ipairs(perimeterCoords) do
            local square = cell:getGridSquare(coord.x, coord.y, currentZ)
            if square then
                local objects = square:getObjects()
                if objects then
                    -- Collect walls to remove first (modifying while iterating can cause issues)
                    local toRemove = {}
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj then
                            local md = obj:getModData()
                            if md and md.isRefugeBoundary then
                                table.insert(toRemove, obj)
                            end
                        end
                    end
                    -- Now remove them
                    for _, obj in ipairs(toRemove) do
                        if getDebug() then
                            print("[SpatialRefugeShared] Removing wall at " .. coord.x .. "," .. coord.y)
                        end
                        removeObjectFromSquare(square, obj)
                        wallsRemoved = wallsRemoved + 1
                    end
                end
            else
                if getDebug() then
                    print("[SpatialRefugeShared] WARNING: Square not loaded at " .. coord.x .. "," .. coord.y)
                end
            end
        end
    end
    
    if getDebug() then
        print("[SpatialRefugeShared] Removed " .. wallsRemoved .. " wall segments")
    end
    return wallsRemoved
end

-----------------------------------------------------------
-- Sacred Relic Generation
-----------------------------------------------------------

-- Create Sacred Relic as a proper physical object (IsoThumpable with sprite)
local function createRelicObject(square, refugeId)
    if not square then 
        if getDebug() then print("[SpatialRefugeShared] No square provided for relic creation") end
        return nil 
    end
    
    -- Check if chunk is loaded before creating objects
    local chunk = square:getChunk()
    if not chunk then
        if getDebug() then print("[SpatialRefugeShared] Chunk not loaded for relic square - cannot create relic") end
        return nil
    end
    
    local cell = getCell()
    if not cell then 
        if getDebug() then print("[SpatialRefugeShared] getCell() returned nil when creating relic") end
        return nil 
    end
    
    local spriteName = SpatialRefugeShared.ResolveRelicSprite()
    if not spriteName then 
        if getDebug() then print("[SpatialRefugeShared] Sacred Relic sprite not found: " .. tostring(SpatialRefugeConfig.SPRITES.SACRED_RELIC)) end
        return nil 
    end

    -- Create IsoThumpable with the gravestone sprite
    local relic = IsoThumpable.new(cell, square, spriteName, false, nil)
    if not relic then 
        if getDebug() then print("[SpatialRefugeShared] Failed to create IsoThumpable for Sacred Relic") end
        return nil 
    end
    
    -- Configure relic properties - make it completely indestructible
    relic:setMaxHealth(999999)
    relic:setHealth(999999)
    relic:setCanBarricade(false)
    relic:setIsThumpable(false)
    relic:setBreakSound("none")
    relic:setSpecialTooltip(true)
    relic:setIsDismantable(false)
    relic:setCanBePlastered(false)
    relic:setIsHoppable(false)
    
    -- Additional protection flags (if available in current PZ version)
    if relic.setDestroyed then relic:setDestroyed(false) end
    
    -- Block disassembly via ModData flag
    local md = relic:getModData()
    md.isSacredRelic = true
    md.refugeId = refugeId
    md.relicSprite = spriteName
    md.canBeDisassembled = false
    md.isProtectedRefugeObject = true  -- Used by sledgehammer hook
    
    -- Enable container for storage functionality
    relic:setIsContainer(true)
    local container = relic:getContainer()
    if container then
        container:setCapacity(SpatialRefugeConfig.RELIC_STORAGE_CAPACITY or 20)
    end
    
    -- Add to square with MP sync
    if addSpecialObjectToSquare(square, relic) then
        -- Transmit ModData to clients so they see the isSacredRelic flag
        if getCachedIsServer() and relic.transmitModData then
            relic:transmitModData()
        end
        
        if getDebug() then
            print("[SpatialRefugeShared] Created Sacred Relic at " .. square:getX() .. "," .. square:getY())
        end
        return relic, spriteName
    end
    
    return nil, nil
end

-- Create or find Sacred Relic
-- Returns: existing relic if found, or newly created one
-- Note: Creates at the search position (x, y, z) if not found
function SpatialRefugeShared.CreateSacredRelic(x, y, z, refugeId, searchRadius)
    return SpatialRefugeShared.CreateSacredRelicAtPosition(x, y, z, x, y, z, refugeId, searchRadius)
end

-- Create or find Sacred Relic with separate search and creation positions
-- searchX/Y/Z: Center of the search area (typically refuge center)
-- createX/Y/Z: Position to create relic if not found (from ModData or default)
-- Returns: existing relic if found, or newly created one
function SpatialRefugeShared.CreateSacredRelicAtPosition(searchX, searchY, searchZ, createX, createY, createZ, refugeId, searchRadius)
    local cell = getCell()
    if not cell then 
        if getDebug() then print("[SpatialRefugeShared] getCell() returned nil") end
        return nil 
    end
    
    -- First, search the ENTIRE refuge area for an existing relic
    -- This prevents duplication when relic was moved from center to a corner
    local radius = searchRadius or 10  -- Default to max tier radius to be safe
    local existing = SpatialRefugeShared.FindRelicInRefuge(searchX, searchY, searchZ, radius, refugeId)
    if existing then 
        if getDebug() then
            print("[SpatialRefugeShared] Found existing Sacred Relic")
        end
        return existing 
    end
    
    -- Create at the specified position (stored position from ModData)
    -- Only use getGridSquare - don't create empty cells that could lose terrain
    local square = cell:getGridSquare(createX, createY, createZ)
    if not square then 
        if getDebug() then print("[SpatialRefugeShared] Failed to get/create square at " .. createX .. "," .. createY) end
        return nil 
    end
    
    if getDebug() then
        print("[SpatialRefugeShared] Creating Sacred Relic at stored position: " .. createX .. "," .. createY)
    end

    return createRelicObject(square, refugeId)
end

-----------------------------------------------------------
-- Zombie Clearing
-----------------------------------------------------------

-- Clear all zombies and zombie corpses from an area
-- In multiplayer, this runs on the server and sends zombie IDs to client for synced removal
-- @param forceClean: if true, clears zombies even in remote areas (useful for MP edge cases)
-- @param player: optional player to send sync command to (for MP)
function SpatialRefugeShared.ClearZombiesFromArea(centerX, centerY, z, radius, forceClean, player)
    -- OPTIMIZATION: Refuges at coordinates < 2000 are in remote areas with no natural zombie spawns
    -- Skip the expensive O(n) iteration over all zombies in the cell (unless forced)
    if not forceClean and centerX < 2000 and centerY < 2000 then
        if getDebug() then
            print("[SpatialRefugeShared] Skipping zombie clearing - remote refuge area (use forceClean to override)")
        end
        return 0
    end
    
    local cell = getCell()
    if not cell then return 0 end
    
    local cleared = 0
    local totalRadius = radius + ZOMBIE_CLEAR_BUFFER
    local isMP = isClient() or isServer()
    local isMPServer = isMP and isServer()
    
    -- Collect zombie online IDs for client sync (MP only)
    local zombieOnlineIDs = {}
    
    -- Get all zombies in the cell and check if they're in our area
    local zombieList = cell:getZombieList()
    
    if zombieList then
        for i = zombieList:size() - 1, 0, -1 do
            local zombie = zombieList:get(i)
            if zombie then
                local zx = zombie:getX()
                local zy = zombie:getY()
                local zz = zombie:getZ()
                
                -- Check if zombie is within the refuge area + buffer
                if zz == z and 
                   zx >= centerX - totalRadius and zx <= centerX + totalRadius and
                   zy >= centerY - totalRadius and zy <= centerY + totalRadius then
                    
                    -- Collect online ID for client sync (before removal)
                    if isMPServer and zombie.getOnlineID then
                        local onlineID = zombie:getOnlineID()
                        if onlineID and onlineID >= 0 then
                            table.insert(zombieOnlineIDs, onlineID)
                        end
                    end
                    
                    -- Remove the zombie
                    zombie:removeFromWorld()
                    zombie:removeFromSquare()
                    cleared = cleared + 1
                end
            end
        end
    end
    
    -- Also remove zombie corpses (dead bodies) from squares
    for dx = -totalRadius, totalRadius do
        for dy = -totalRadius, totalRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                -- Remove dead bodies (IsoDeadBody objects)
                local deadBodies = square:getDeadBodys()
                if deadBodies then
                    for i = deadBodies:size() - 1, 0, -1 do
                        local body = deadBodies:get(i)
                        if body then
                            -- Use transmit method for MP sync
                            if isMP and square.transmitRemoveItemFromSquare then
                                square:transmitRemoveItemFromSquare(body)
                            else
                                square:removeCorpse(body, false)
                            end
                            cleared = cleared + 1
                        end
                    end
                end
                
                -- Also check for corpse items on the ground (IsoObject with deadBody type)
                local objects = square:getObjects()
                if objects then
                    for i = objects:size() - 1, 0, -1 do
                        local obj = objects:get(i)
                        if obj and obj:getType() == IsoObjectType.deadBody then
                            -- Use transmit method for MP sync
                            if isMP and square.transmitRemoveItemFromSquare then
                                square:transmitRemoveItemFromSquare(obj)
                            else
                                square:RemoveWorldObject(obj)
                            end
                            cleared = cleared + 1
                        end
                    end
                end
            end
        end
    end
    
    -- Send zombie IDs to client for synced removal (MP server only)
    if isMPServer and player and #zombieOnlineIDs > 0 then
        sendServerCommand(player, SpatialRefugeConfig.COMMAND_NAMESPACE, 
            SpatialRefugeConfig.COMMANDS.CLEAR_ZOMBIES, {
                zombieIDs = zombieOnlineIDs
            })
        if getDebug() then
            print("[SpatialRefugeShared] Sent " .. #zombieOnlineIDs .. " zombie IDs to client for removal")
        end
    end
    
    if cleared > 0 and getDebug() then
        print("[SpatialRefugeShared] Cleared " .. cleared .. " zombies/corpses from refuge area")
    end
    
    return cleared
end

-----------------------------------------------------------
-- Refuge Expansion
-----------------------------------------------------------

-- Expand an existing refuge to a new tier
-- Note: refugeData must be saved by caller after this returns
-- @param player: optional player for MP zombie sync
function SpatialRefugeShared.ExpandRefuge(refugeData, newTier, player)
    if not refugeData then return false end
    
    local tierConfig = SpatialRefugeConfig.TIERS[newTier]
    if not tierConfig then return false end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local oldRadius = refugeData.radius
    local newRadius = tierConfig.radius
    
    if getDebug() then
        print("[SpatialRefugeShared] ExpandRefuge: tier " .. (refugeData.tier or 0) .. " -> " .. newTier)
        print("[SpatialRefugeShared] ExpandRefuge: oldRadius=" .. oldRadius .. " newRadius=" .. newRadius)
        print("[SpatialRefugeShared] ExpandRefuge: center=" .. centerX .. "," .. centerY .. "," .. centerZ)
    end
    
    -- Remove ALL refuge walls from the entire area (not just perimeter)
    -- This ensures no orphaned walls from previous upgrades remain
    -- Use newRadius as the scan area to ensure we cover where old walls might be
    local wallsRemoved = SpatialRefugeShared.RemoveAllRefugeWalls(centerX, centerY, centerZ, newRadius)
    
    if getDebug() then
        print("[SpatialRefugeShared] ExpandRefuge: removed " .. wallsRemoved .. " old walls from area")
    end

    -- NOTE: Floor generation disabled by user request
    -- Natural terrain remains
    -- SpatialRefugeShared.EnsureRefugeFloor(centerX, centerY, centerZ, newRadius + 1)

    -- Create new boundary walls at new radius
    local wallsCreated = SpatialRefugeShared.CreateBoundaryWalls(centerX, centerY, centerZ, newRadius)
    
    if getDebug() then
        print("[SpatialRefugeShared] ExpandRefuge: created " .. wallsCreated .. " new walls")
    end
    
    -- Update refuge data (caller should save this)
    refugeData.tier = newTier
    refugeData.radius = newRadius
    refugeData.lastExpanded = getTimestamp and getTimestamp() or os.time()
    
    -- Clear any zombies from the expanded area (force clean even in remote areas for MP)
    -- Use newRadius to cover the entire new area, pass player for MP sync
    SpatialRefugeShared.ClearZombiesFromArea(centerX, centerY, centerZ, newRadius, true, player)
    
    if getDebug() then
        print("[SpatialRefugeShared] Expanded refuge to tier " .. newTier .. " (radius " .. newRadius .. ")")
    end
    
    return true
end

-----------------------------------------------------------
-- Full Refuge Generation (convenience function)
-----------------------------------------------------------

-- Ensure all refuge structures exist (floor, walls, relic)
-- Used by server for initial generation and stranded player recovery
-- @param player: optional player for MP zombie sync
function SpatialRefugeShared.EnsureRefugeStructures(refugeData, player)
    if not refugeData then return false end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    
    -- Use stored relic position if available, otherwise default to center
    -- This ensures relic is placed at correct position even if chunks weren't loaded during search
    local relicX = refugeData.relicX or centerX
    local relicY = refugeData.relicY or centerY
    local relicZ = refugeData.relicZ or centerZ
    
    -- NOTE: Floor generation disabled by user request
    -- Natural terrain remains, only walls and relic are generated
    -- SpatialRefugeShared.EnsureRefugeFloor(centerX, centerY, centerZ, radius + 1)
    
    -- Generate walls
    SpatialRefugeShared.CreateBoundaryWalls(centerX, centerY, centerZ, radius)
    
    -- Generate or find Sacred Relic at stored position
    -- Search is centered on refuge center to find relic anywhere in refuge
    -- But creation happens at stored relicX/relicY position
    local relic = SpatialRefugeShared.CreateSacredRelicAtPosition(
        centerX, centerY, centerZ,  -- Search center
        relicX, relicY, relicZ,     -- Creation position (stored or default)
        refugeId, radius
    )
    
    -- Clear any zombies (force clean for MP to handle edge cases where zombies might exist)
    -- Pass player for MP sync of zombie removal
    SpatialRefugeShared.ClearZombiesFromArea(centerX, centerY, centerZ, radius, true, player)
    
    if getDebug() then
        print("[SpatialRefugeShared] Ensured refuge structures for " .. tostring(refugeId))
    end
    
    return relic ~= nil
end

-----------------------------------------------------------
-- Property Repair (for objects that lose properties on map load)
-----------------------------------------------------------

-- Re-apply protection properties to refuge walls and relic
-- Call this when player enters refuge to ensure properties are correct
-- (PZ map save may not preserve all IsoThumpable properties)
function SpatialRefugeShared.RepairRefugeProperties(refugeData)
    if not refugeData then return 0 end
    
    local cell = getCell()
    if not cell then return 0 end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local repaired = 0
    
    -- Scan the refuge area + 2 tiles buffer (for walls at maxX+1, maxY+1)
    for dx = -radius - 2, radius + 2 do
        for dy = -radius - 2, radius + 2 do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, centerZ)
            if square then
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj and obj.getModData then
                            local md = obj:getModData()
                            
                            -- Re-apply wall properties
                            if md and md.isRefugeBoundary then
                                if obj.setIsThumpable then obj:setIsThumpable(false) end
                                if obj.setIsHoppable then obj:setIsHoppable(false) end
                                if obj.setCanBarricade then obj:setCanBarricade(false) end
                                if obj.setIsDismantable then obj:setIsDismantable(false) end
                                if obj.setCanBePlastered then obj:setCanBePlastered(false) end
                                repaired = repaired + 1
                            end
                            
                            -- Re-apply relic properties
                            if md and md.isSacredRelic then
                                if obj.setIsThumpable then obj:setIsThumpable(false) end
                                if obj.setIsHoppable then obj:setIsHoppable(false) end
                                if obj.setIsDismantable then obj:setIsDismantable(false) end
                                repaired = repaired + 1
                            end
                        end
                    end
                end
            end
        end
    end
    
    if getDebug() and repaired > 0 then
        print("[SpatialRefugeShared] Repaired properties on " .. repaired .. " refuge objects")
    end
    
    return repaired
end

return SpatialRefugeShared
