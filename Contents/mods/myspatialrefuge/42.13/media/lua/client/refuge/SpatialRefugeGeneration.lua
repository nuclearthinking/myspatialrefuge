-- Spatial Refuge Generation Module
-- Handles programmatic world generation for refuge spaces

-- Assume SpatialRefuge and SpatialRefugeConfig are already loaded
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-- Buffer tiles around refuge to clear zombies
local ZOMBIE_CLEAR_BUFFER = 3

-- Clear all zombies and zombie corpses from an area
-- Called during refuge generation and when entering refuge
function SpatialRefuge.ClearZombiesFromArea(centerX, centerY, z, radius)
    local cell = getCell()
    if not cell then return 0 end
    
    local cleared = 0
    local totalRadius = radius + ZOMBIE_CLEAR_BUFFER
    
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
                -- Remove dead bodies
                local deadBodies = square:getDeadBodys()
                if deadBodies then
                    for i = deadBodies:size() - 1, 0, -1 do
                        local body = deadBodies:get(i)
                        if body then
                            square:removeCorpse(body, false)
                            cleared = cleared + 1
                        end
                    end
                end
                
                -- Also check for corpse items on the ground
                local objects = square:getObjects()
                if objects then
                    for i = objects:size() - 1, 0, -1 do
                        local obj = objects:get(i)
                        if obj and obj:getType() == IsoObjectType.deadBody then
                            square:transmitRemoveItemFromSquare(obj)
                            cleared = cleared + 1
                        end
                    end
                end
            end
        end
    end
    
    if cleared > 0 and getDebug() then
        print("[SpatialRefuge] Cleared " .. cleared .. " zombies/corpses from refuge area")
    end
    
    return cleared
end

-- Create a floor tile at specific coordinates
function SpatialRefuge.CreateFloorTile(x, y, z, sprite)
    local cell = getCell()
    if not cell then error("[SpatialRefuge] getCell() returned nil") end
    
    local square = cell:getOrCreateGridSquare(x, y, z)
    if not square then error("[SpatialRefuge] Failed to create grid square at " .. x .. "," .. y) end
    
    -- Check if chunk is loaded before modifying square
    local chunk = square:getChunk()
    if not chunk then
        -- Chunk not loaded yet, skip this tile for now
        if getDebug() then
            print("[SpatialRefuge] Chunk not loaded for square " .. x .. "," .. y .. " - skipping floor")
        end
        return false
    end
    
    -- Check if floor already exists
    if square:getFloor() then return true end
    
    -- Add floor
    local floorSprite = sprite or SpatialRefugeConfig.SPRITES.FLOOR
    local floor = IsoObject.new(square, floorSprite)
    if not floor then error("[SpatialRefuge] Failed to create floor object") end
    
    square:AddTileObject(floor)
    square:RecalcAllWithNeighbours(true)
    return true
end

-- Ensure a solid floor area exists for the refuge size
-- Returns: number of tiles attempted (for debug)
function SpatialRefuge.EnsureRefugeFloor(centerX, centerY, z, radius)
    local attempted = 0
    for dx = -radius, radius do
        for dy = -radius, radius do
            SpatialRefuge.CreateFloorTile(centerX + dx, centerY + dy, z)
            attempted = attempted + 1
        end
    end
    return attempted
end

-- Create the Sacred Relic at refuge center
-- Returns: IsoThumpable object or nil
local function resolveRelicSprite()
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


local function findRelicOnSquare(square, refugeId)
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
local function findRelicInRefuge(centerX, centerY, z, radius, refugeId)
    local cell = getCell()
    if not cell then return nil end
    
    -- Search the entire refuge area (center + radius in all directions)
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local relic = findRelicOnSquare(square, refugeId)
                if relic then
                    return relic
                end
            end
        end
    end
    return nil
end

-- Create Sacred Relic as a proper physical object (IsoThumpable with sprite)
local function createRelicObject(square, refugeId)
    if not square then error("[SpatialRefuge] No square provided for relic creation") end
    
    -- Check if chunk is loaded before creating objects
    local chunk = square:getChunk()
    if not chunk then
        error("[SpatialRefuge] Chunk not loaded for relic square - cannot create relic")
    end
    
    local cell = getCell()
    if not cell then error("[SpatialRefuge] getCell() returned nil when creating relic") end
    
    local spriteName = resolveRelicSprite()
    if not spriteName then error("[SpatialRefuge] Sacred Relic sprite not found: " .. tostring(SpatialRefugeConfig.SPRITES.SACRED_RELIC)) end

    -- Create IsoThumpable with the gravestone sprite
    local relic = IsoThumpable.new(cell, square, spriteName, false, nil)
    if not relic then error("[SpatialRefuge] Failed to create IsoThumpable for Sacred Relic") end
    
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
    md.isProtectedRefugeObject = true  -- Used by our sledgehammer hook
    
    -- Enable container for storage functionality
    relic:setIsContainer(true)
    local container = relic:getContainer()
    if container then
        container:setCapacity(SpatialRefugeConfig.RELIC_STORAGE_CAPACITY or 20)
    end
    
    -- Add to square
    square:AddSpecialObject(relic)
    square:RecalcAllWithNeighbours(true)
    
    return relic, spriteName
end

function SpatialRefuge.CreateSacredRelic(x, y, z, refugeId, searchRadius)
    local cell = getCell()
    if not cell then error("[SpatialRefuge] getCell() returned nil") end
    
    -- First, search the ENTIRE refuge area for an existing relic
    -- This prevents duplication when relic was moved from center to a corner
    local radius = searchRadius or 10  -- Default to max tier radius to be safe
    local existing = findRelicInRefuge(x, y, z, radius, refugeId)
    if existing then 
        return existing 
    end
    
    local square = cell:getGridSquare(x, y, z) or cell:getOrCreateGridSquare(x, y, z)
    if not square then error("[SpatialRefuge] Failed to get/create square at " .. x .. "," .. y) end
    
    -- Avoid placing on player's exact square (can hide object)
    local player = getPlayer()
    if player and player:getX() == x and player:getY() == y and player:getZ() == z then
        x = x + 1
        y = y + 1
        square = cell:getGridSquare(x, y, z) or cell:getOrCreateGridSquare(x, y, z)
        if not square then error("[SpatialRefuge] Failed to get offset square") end
    end

    return createRelicObject(square, refugeId)
end

-- Create a single solid wall segment (IsoThumpable)
local function createWallObject(square, spriteName, isNorthWall)
    if not square then return nil end
    
    -- Check if chunk is loaded before creating objects
    local chunk = square:getChunk()
    if not chunk then
        if getDebug() then
            print("[SpatialRefuge] Chunk not loaded for wall square - skipping")
        end
        return nil
    end
    
    local cell = getCell()
    if not cell then error("[SpatialRefuge] getCell() returned nil") end
    
    -- Create real solid wall using IsoThumpable
    local wall = IsoThumpable.new(cell, square, spriteName, isNorthWall, {})
    if not wall then error("[SpatialRefuge] Failed to create wall for " .. spriteName) end
    
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
    md.isProtectedRefugeObject = true  -- Used by our sledgehammer hook
    
    square:AddSpecialObject(wall)
    square:RecalcAllWithNeighbours(true)
    return wall
end

-- Create boundary wall at coordinates
-- addNorth: add north-facing wall segment
-- addWest: add west-facing wall segment
-- cornerSprite: optional corner sprite to add
function SpatialRefuge.CreateWall(x, y, z, addNorth, addWest, cornerSprite)
    local cell = getCell()
    if not cell then error("[SpatialRefuge] getCell() returned nil") end

    local square = cell:getGridSquare(x, y, z) or cell:getOrCreateGridSquare(x, y, z)
    if not square then error("[SpatialRefuge] Failed to get square for wall at " .. x .. "," .. y) end

    local created = false
    if addNorth then
        createWallObject(square, SpatialRefugeConfig.SPRITES.WALL_NORTH, true)
        created = true
    end
    if addWest then
        createWallObject(square, SpatialRefugeConfig.SPRITES.WALL_WEST, false)
        created = true
    end
    if cornerSprite then
        createWallObject(square, cornerSprite, false)
        created = true
    end

    return created and square or nil
end

-- Create solid boundary walls around a refuge area
-- Returns: number of walls created
function SpatialRefuge.CreateBoundaryWalls(centerX, centerY, z, radius)
    local wallsCreated = 0
    local wallHeight = SpatialRefugeConfig.WALL_HEIGHT or 3

    -- Ensure wall squares have floors so wall sprites render correctly (all levels)
    for level = 0, wallHeight - 1 do
        SpatialRefuge.EnsureRefugeFloor(centerX, centerY, z + level, radius + 1)
    end

    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius

    -- Create walls at all z-levels
    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        
        -- North and South walls (horizontal edges)
        for x = minX, maxX do
            if SpatialRefuge.CreateWall(x, minY, currentZ, true, false, nil) then
                wallsCreated = wallsCreated + 1
            end
            if SpatialRefuge.CreateWall(x, maxY + 1, currentZ, true, false, nil) then
                wallsCreated = wallsCreated + 1
            end
        end

        -- West and East walls (vertical edges)
        for y = minY, maxY do
            if SpatialRefuge.CreateWall(minX, y, currentZ, false, true, nil) then
                wallsCreated = wallsCreated + 1
            end
            if SpatialRefuge.CreateWall(maxX + 1, y, currentZ, false, true, nil) then
                wallsCreated = wallsCreated + 1
            end
        end

        -- Corner pieces
        SpatialRefuge.CreateWall(minX, minY, currentZ, false, false, SpatialRefugeConfig.SPRITES.WALL_CORNER_NW)
        SpatialRefuge.CreateWall(maxX + 1, maxY + 1, currentZ, false, false, SpatialRefugeConfig.SPRITES.WALL_CORNER_SE)
    end

    return wallsCreated
end

-- Remove boundary walls (for expansion)
-- Scans exact perimeter where walls were placed
function SpatialRefuge.RemoveBoundaryWalls(centerX, centerY, z, radius)
    local cell = getCell()
    if not cell then return 0 end
    
    local wallsRemoved = 0
    local wallHeight = SpatialRefugeConfig.WALL_HEIGHT or 1
    
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius
    
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
                    for i = objects:size()-1, 0, -1 do
                        local obj = objects:get(i)
                        if obj then
                            local md = obj:getModData()
                            if md and md.isRefugeBoundary then
                                square:transmitRemoveItemFromSquare(obj)
                                wallsRemoved = wallsRemoved + 1
                            end
                        end
                    end
                end
            end
        end
    end
    
    return wallsRemoved
end

-- Generate a new refuge for a player
-- NOTE: We don't actually generate world tiles - we use existing map areas
-- This is a simpler approach that just allocates coordinates and creates the Sacred Relic
function SpatialRefuge.GenerateNewRefuge(player)
    if not player then return nil end
    
    -- Check if world is ready
    if not SpatialRefuge.worldReady then return nil end
    
    -- Get or create refuge data (allocates coordinates)
    local refugeData = SpatialRefuge.GetOrCreateRefugeData(player)
    if not refugeData then return nil end
    
    player:Say("Spatial Refuge initializing...")
    
    return refugeData
end

-- Expand an existing refuge to a new tier
function SpatialRefuge.ExpandRefuge(refugeData, newTier)
    if not refugeData then return false end
    
    local tierConfig = SpatialRefugeConfig.TIERS[newTier]
    if not tierConfig then return false end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local oldRadius = refugeData.radius
    local newRadius = tierConfig.radius
    
    -- Remove old boundary walls
    SpatialRefuge.RemoveBoundaryWalls(centerX, centerY, centerZ, oldRadius)

    -- Ensure floor exists for the new size (include wall perimeter)
    SpatialRefuge.EnsureRefugeFloor(centerX, centerY, centerZ, newRadius + 1)

    -- Create new boundary walls at new radius
    SpatialRefuge.CreateBoundaryWalls(centerX, centerY, centerZ, newRadius)
    
    -- Update refuge data
    refugeData.tier = newTier
    refugeData.radius = newRadius
    refugeData.lastExpanded = getTimestamp()
    SpatialRefuge.SaveRefugeData(refugeData)
    
    return true
end

-- Delete a refuge completely (for death penalty)
function SpatialRefuge.DeleteRefuge(player)
    local refugeData = SpatialRefuge.GetRefugeData(player)
    if not refugeData then return end
    
    local cell = getCell and getCell()
    if not cell then return end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius
    local wallHeight = SpatialRefugeConfig.WALL_HEIGHT or 3
    
    -- Remove all world objects in refuge area at all z-levels (including buffer zone)
    for level = 0, wallHeight - 1 do
        local currentZ = centerZ + level
        for x = -radius-2, radius+2 do
            for y = -radius-2, radius+2 do
                local square = cell:getGridSquare(centerX + x, centerY + y, currentZ)
                if square then
                    local objects = square:getObjects()
                    if objects then
                        for i = objects:size()-1, 0, -1 do
                            local obj = objects:get(i)
                            if obj then
                                square:transmitRemoveItemFromSquare(obj)
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Remove from ModData
    SpatialRefuge.DeleteRefugeData(player)
end

return SpatialRefuge
