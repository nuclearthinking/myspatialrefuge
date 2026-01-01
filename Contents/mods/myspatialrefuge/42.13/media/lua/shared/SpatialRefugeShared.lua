-- Spatial Refuge Shared Module
-- Generation functions accessible by both client and server
-- For multiplayer persistence, server uses these functions to create objects that save to map

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeEnv"

-- Prevent double-loading
if SpatialRefugeShared and SpatialRefugeShared._loaded then
    return SpatialRefugeShared
end

SpatialRefugeShared = SpatialRefugeShared or {}
SpatialRefugeShared._loaded = true

-- Use shared environment helpers
local function getCachedIsServer()
    return SpatialRefugeEnv.isServer()
end

-----------------------------------------------------------
-- World Object Utilities
-----------------------------------------------------------

local function addSpecialObjectToSquare(square, obj)
    if not square or not obj or not square:getChunk() then return false end
    
    if getCachedIsServer() then
        square:transmitAddObjectToSquare(obj, -1)
    else
        square:AddSpecialObject(obj)
    end
    square:RecalcAllWithNeighbours(true)
    return true
end

local function removeObjectFromSquare(square, obj)
    if not square or not obj then return false end
    
    if getCachedIsServer() then
        square:transmitRemoveItemFromSquare(obj)
    else
        if square.RemoveWorldObject then pcall(function() square:RemoveWorldObject(obj) end) end
        if obj.removeFromSquare then pcall(function() obj:removeFromSquare() end) end
        if obj.removeFromWorld then pcall(function() obj:removeFromWorld() end) end
    end
    
    square:RecalcAllWithNeighbours(true)
    return true
end

-- Buffer tiles around refuge to clear zombies
local ZOMBIE_CLEAR_BUFFER = 3

-- Buffer tiles beyond refuge radius to clear trees (catches foliage extending into refuge)
local TREE_CLEAR_BUFFER = 4

-----------------------------------------------------------
-- Utility Functions
-----------------------------------------------------------

function SpatialRefugeShared.ResolveRelicSprite()
    local spriteName = SpatialRefugeConfig.SPRITES.SACRED_RELIC
    
    if getSprite and getSprite(spriteName) then return spriteName end
    
    local digits = spriteName:match("_(%d+)$")
    if digits then
        local padded2 = spriteName:gsub("_(%d+)$", "_0" .. digits)
        if getSprite and getSprite(padded2) then return padded2 end
        local padded3 = spriteName:gsub("_(%d+)$", "_00" .. digits)
        if getSprite and getSprite(padded3) then return padded3 end
    end
    
    local fallback = SpatialRefugeConfig.SPRITES.SACRED_RELIC_FALLBACK
    if fallback and getSprite and getSprite(fallback) then
        if getDebug() then
            print("[SpatialRefugeShared] Using fallback sprite: " .. fallback)
        end
        return fallback
    end
    
    return nil
end

-- Find relic on a specific square by ModData
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

-- Module-level sprite cache (resolved once per session)
local _cachedRelicSprite = nil
local _cachedResolvedSprite = nil
local _spritesCached = false

local function getCachedRelicSprites()
    if not _spritesCached then
        _cachedRelicSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC
        _cachedResolvedSprite = SpatialRefugeShared.ResolveRelicSprite()
        _spritesCached = true
    end
    return _cachedRelicSprite, _cachedResolvedSprite
end

-- Find relic on square by sprite (for old saves without ModData)
local function findRelicOnSquareBySprite(square, relicSprite, resolvedSprite)
    local objects = square:getObjects()
    if not objects then return nil end
    
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj and obj.getSprite then
            local sprite = obj:getSprite()
            if sprite then
                local spriteName = sprite:getName()
                if spriteName == relicSprite or spriteName == resolvedSprite then
                    return obj
                end
            end
        end
    end
    return nil
end

function SpatialRefugeShared.FindRelicInRefuge(centerX, centerY, z, radius, refugeId)
    local cell = getCell()
    if not cell then return nil end
    
    local relicSprite, resolvedSprite = getCachedRelicSprites()
    local searchRadius = (radius or 1) + 1
    
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local relic = SpatialRefugeShared.FindRelicOnSquare(square, refugeId)
                if relic then 
                    if relic.getSprite then
                        local sprite = relic:getSprite()
                        if not sprite or not sprite:getName() then
                            local expectedSprite = SpatialRefugeShared.ResolveRelicSprite()
                            if expectedSprite then
                                relic:setSprite(expectedSprite)
                                local md = relic:getModData()
                                if md then md.relicSprite = expectedSprite end
                                if getDebug() then
                                    print("[SpatialRefugeShared] Repaired corrupted relic sprite")
                                end
                            end
                        end
                    end
                    return relic 
                end
                
                relic = findRelicOnSquareBySprite(square, relicSprite, resolvedSprite)
                if relic then
                    local md = relic:getModData()
                    md.isSacredRelic = true
                    md.refugeId = refugeId
                    md.isProtectedRefugeObject = true
                    return relic
                end
            end
        end
    end
    
    return nil
end

function SpatialRefugeShared.SyncRelicPositionToModData(refugeData)
    if not refugeData then return false end
    if not SpatialRefugeData.CanModifyData() then return false end
    if refugeData.relicX ~= nil then return false end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    
    local relic = SpatialRefugeShared.FindRelicInRefuge(centerX, centerY, centerZ, radius, refugeId)
    
    if relic then
        local square = relic:getSquare()
        if square then
            refugeData.relicX = square:getX()
            refugeData.relicY = square:getY()
            refugeData.relicZ = square:getZ()
        else
            refugeData.relicX = centerX
            refugeData.relicY = centerY
            refugeData.relicZ = centerZ
        end
    else
        refugeData.relicX = centerX
        refugeData.relicY = centerY
        refugeData.relicZ = centerZ
    end
    
    SpatialRefugeData.SaveRefugeData(refugeData)
    return true
end

function SpatialRefugeShared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName, existingRelic)
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
    
    -- Use provided relic or search for it
    local relic = existingRelic
    if not relic then
        relic = SpatialRefugeShared.FindRelicInRefuge(centerX, centerY, centerZ, radius, refugeId)
    end
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
    
    local hasBlockingObject = false
    local blockingReason = nil
    
    if targetSquare:getTree() then
        hasBlockingObject = true
        blockingReason = "Tree in the way"
    end
    
    if not hasBlockingObject then
        local movingObjects = targetSquare:getMovingObjects()
        if movingObjects and movingObjects:size() > 0 then
            hasBlockingObject = true
            blockingReason = "Something is standing there"
        end
    end
    
    if not hasBlockingObject then
        local objects = targetSquare:getObjects()
        if objects then
            for i = 0, objects:size() - 1 do
                local obj = objects:get(i)
                if obj then
                    local objType = obj.getType and obj:getType() or nil
                    local isFloor = (objType == IsoObjectType.FloorTile)
                    local md = obj.getModData and obj:getModData() or nil
                    local isRefugeObject = md and (md.isRefugeBoundary or md.isSacredRelic or md.isProtectedRefugeObject)
                    
                    if not isFloor and not isRefugeObject then
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
                        else
                            local isFurniture = instanceof and instanceof(obj, "IsoThumpable") or false
                            local isContainer = obj.getContainer and obj:getContainer() ~= nil or false
                            
                            if isFurniture or isContainer then
                                hasBlockingObject = true
                                blockingReason = isContainer and "Container in the way" or "Furniture in the way"
                                break
                            end
                        end
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
    
    if currentSquare and not currentSquare:getChunk() then
        return false, "Current location not loaded"
    end
    
    if not targetChunk then
        return false, "Destination not loaded"
    end
    
    if currentSquare then
        currentSquare:transmitRemoveItemFromSquare(relic)
    end
    
    relic:setSquare(targetSquare)
    targetSquare:transmitAddObjectToSquare(relic, -1)
    
    if currentSquare then currentSquare:RecalcAllWithNeighbours(true) end
    targetSquare:RecalcAllWithNeighbours(true)
    
    local md = relic:getModData()
    md.assignedCorner = cornerName
    md.assignedCornerDx = cornerDx
    md.assignedCornerDy = cornerDy
    
    if getCachedIsServer() and relic.transmitModData then
        relic:transmitModData()
    end
    
    if getDebug() then
        print("[SpatialRefugeShared] Moved relic to " .. cornerName .. " (" .. targetX .. "," .. targetY .. ")")
    end
    
    return true, "Moved to " .. cornerName
end

function SpatialRefugeShared.RemoveDuplicateRelics(centerX, centerY, centerZ, radius, refugeId, refugeData)
    local cell = getCell()
    if not cell then return 0 end
    
    local relicSprite, resolvedSprite = getCachedRelicSprites()
    local searchRadius = (radius or 1) + 2
    local foundRelics = {}
    local duplicatesRemoved = 0
    
    local function countRelicItems(relic)
        if not relic or not relic.getContainer then return 0 end
        local container = relic:getContainer()
        if not container then return 0 end
        local items = container:getItems()
        return items and items:size() or 0
    end
    
    -- First pass: find all relics in the area and count their items
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, centerZ)
            if square then
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj then
                            local md = obj:getModData()
                            local isRelic = false
                            
                            if md and md.isSacredRelic and md.refugeId == refugeId then
                                isRelic = true
                            elseif obj.getSprite then
                                local sprite = obj:getSprite()
                                if sprite then
                                    local spriteName = sprite:getName()
                                    if spriteName == relicSprite or spriteName == resolvedSprite then
                                        isRelic = true
                                        if not md then md = obj:getModData() end
                                        md.isSacredRelic = true
                                        md.refugeId = refugeId
                                    end
                                end
                            end
                            
                            if isRelic then
                                local itemCount = countRelicItems(obj)
                                table.insert(foundRelics, {
                                    obj = obj, 
                                    square = square,
                                    itemCount = itemCount,
                                    x = square:getX(),
                                    y = square:getY(),
                                    z = square:getZ()
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    
    if #foundRelics > 1 then
        if getDebug() then
            print("[SpatialRefugeShared] Found " .. #foundRelics .. " relics - removing " .. (#foundRelics - 1) .. " duplicates")
        end
        
        local storedX = refugeData and refugeData.relicX or nil
        local storedY = refugeData and refugeData.relicY or nil
        local storedZ = refugeData and refugeData.relicZ or nil
        
        local maxItems = -1
        local relicWithItems = nil
        local relicWithItemsIndex = nil
        
        for i = 1, #foundRelics do
            local itemCount = foundRelics[i].itemCount or 0
            if itemCount > maxItems then
                maxItems = itemCount
                relicWithItems = foundRelics[i]
                relicWithItemsIndex = i
            end
        end
        
        local keepIndex = 1
        local keepRelic = foundRelics[1]
        
        if not keepRelic then
            if getDebug() then
                print("[SpatialRefugeShared] ERROR: No relics found to keep")
            end
            return 0
        end
        
        if maxItems > 0 then
            local hasRelicsWithoutItems = false
            for i = 1, #foundRelics do
                if (foundRelics[i].itemCount or 0) == 0 then
                    hasRelicsWithoutItems = true
                    break
                end
            end
            
            if hasRelicsWithoutItems and relicWithItems then
                keepIndex = relicWithItemsIndex
                keepRelic = relicWithItems
                
                if getDebug() then
                    print("[SpatialRefugeShared] Keeping relic with " .. maxItems .. " items at " .. (keepRelic.x or 0) .. "," .. (keepRelic.y or 0))
                end
                
                if refugeData and keepRelic.x and keepRelic.y and keepRelic.z then
                    refugeData.relicX = keepRelic.x
                    refugeData.relicY = keepRelic.y
                    refugeData.relicZ = keepRelic.z
                    
                    if SpatialRefugeData and SpatialRefugeData.SaveRefugeData then
                        SpatialRefugeData.SaveRefugeData(refugeData)
                    end
                    
                    if getDebug() then
                        print("[SpatialRefugeShared] Updated stored relic position to " .. keepRelic.x .. "," .. keepRelic.y)
                    end
                end
            elseif storedX and storedY and storedZ then
                for i = 1, #foundRelics do
                    local relic = foundRelics[i]
                    if relic.x == storedX and relic.y == storedY and relic.z == storedZ then
                        keepIndex = i
                        keepRelic = relic
                        if getDebug() then
                            print("[SpatialRefugeShared] All relics have items - keeping relic at stored position " .. storedX .. "," .. storedY)
                        end
                        break
                    end
                end
            end
        elseif storedX and storedY and storedZ then
            for i = 1, #foundRelics do
                local relic = foundRelics[i]
                if relic.x == storedX and relic.y == storedY and relic.z == storedZ then
                    keepIndex = i
                    keepRelic = relic
                    if getDebug() then
                        print("[SpatialRefugeShared] No relics have items - keeping relic at stored position " .. storedX .. "," .. storedY)
                    end
                    break
                end
            end
        end
        
        for i = 1, #foundRelics do
            if i ~= keepIndex then
                local relicData = foundRelics[i]
                if relicData and relicData.obj and relicData.square then
                    if getDebug() then
                        print("[SpatialRefugeShared] Removing duplicate relic at " .. (relicData.x or 0) .. "," .. (relicData.y or 0) .. " (items: " .. (relicData.itemCount or 0) .. ")")
                    end
                    removeObjectFromSquare(relicData.square, relicData.obj)
                    duplicatesRemoved = duplicatesRemoved + 1
                end
            end
        end
    end
    
    return duplicatesRemoved
end

-----------------------------------------------------------
-- Wall Generation
-----------------------------------------------------------

local function createWallObject(square, spriteName, isNorthWall)
    if not square or not square:getChunk() then return nil end
    
    local objects = square:getObjects()
    if objects then
        for i = 0, objects:size() - 1 do
            local obj = objects:get(i)
            if obj and obj.getModData then
                local md = obj:getModData()
                if md and md.isRefugeBoundary and md.refugeBoundarySprite == spriteName then
                    if getDebug() then
                        print("[SpatialRefugeShared] Wall already exists at " .. square:getX() .. "," .. square:getY())
                    end
                    return obj
                end
            end
        end
    end
    
    local cell = getCell()
    if not cell then return nil end
    
    local wall = IsoThumpable.new(cell, square, spriteName, isNorthWall, {})
    if not wall then return nil end
    
    wall:setMaxHealth(999999)
    wall:setHealth(999999)
    wall:setCanBarricade(false)
    wall:setIsThumpable(false)
    wall:setBreakSound("none")
    wall:setIsDismantable(false)
    wall:setCanBePlastered(false)
    wall:setIsHoppable(false)
    if wall.setDestroyed then wall:setDestroyed(false) end
    
    local md = wall:getModData()
    md.isRefugeBoundary = true
    md.refugeBoundarySprite = spriteName
    md.canBeDisassembled = false
    md.isProtectedRefugeObject = true
    
    if addSpecialObjectToSquare(square, wall) then
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

function SpatialRefugeShared.CreateWall(x, y, z, addNorth, addWest, cornerSprite)
    local cell = getCell()
    if not cell then return nil end

    local square = cell:getGridSquare(x, y, z)
    if not square or not square:getChunk() then return nil end

    local created = false
    if addNorth and createWallObject(square, SpatialRefugeConfig.SPRITES.WALL_NORTH, true) then
        created = true
    end
    if addWest and createWallObject(square, SpatialRefugeConfig.SPRITES.WALL_WEST, false) then
        created = true
    end
    if cornerSprite and createWallObject(square, cornerSprite, false) then
        created = true
    end

    return created and square or nil
end

function SpatialRefugeShared.CreateBoundaryWalls(centerX, centerY, z, radius)
    local wallsCreated = 0
    local wallHeight = SpatialRefugeConfig.WALL_HEIGHT or 1
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius

    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        
        for x = minX, maxX do
            if SpatialRefugeShared.CreateWall(x, minY, currentZ, true, false, nil) then wallsCreated = wallsCreated + 1 end
            if SpatialRefugeShared.CreateWall(x, maxY + 1, currentZ, true, false, nil) then wallsCreated = wallsCreated + 1 end
        end

        for y = minY, maxY do
            if SpatialRefugeShared.CreateWall(minX, y, currentZ, false, true, nil) then wallsCreated = wallsCreated + 1 end
            if SpatialRefugeShared.CreateWall(maxX + 1, y, currentZ, false, true, nil) then wallsCreated = wallsCreated + 1 end
        end

        SpatialRefugeShared.CreateWall(minX, minY, currentZ, false, false, SpatialRefugeConfig.SPRITES.WALL_CORNER_NW)
        SpatialRefugeShared.CreateWall(maxX + 1, maxY + 1, currentZ, false, false, SpatialRefugeConfig.SPRITES.WALL_CORNER_SE)
    end

    if getDebug() then
        print("[SpatialRefugeShared] Created " .. wallsCreated .. " wall segments")
    end
    return wallsCreated
end

function SpatialRefugeShared.RemoveAllRefugeWalls(centerX, centerY, z, maxRadius)
    local cell = getCell()
    if not cell then return 0 end
    
    local wallsRemoved = 0
    local wallHeight = SpatialRefugeConfig.WALL_HEIGHT or 1
    local scanRadius = maxRadius + 2
    local modifiedSquares = {}
    
    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        for dx = -scanRadius, scanRadius do
            for dy = -scanRadius, scanRadius do
                local square = cell:getGridSquare(centerX + dx, centerY + dy, currentZ)
                if square then
                    local objects = square:getObjects()
                    if objects then
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
    
    for _, square in ipairs(modifiedSquares) do
        square:RecalcAllWithNeighbours(true)
        if square.RecalcProperties then square:RecalcProperties() end
    end
    
    if getDebug() then
        print("[SpatialRefugeShared] RemoveAllRefugeWalls: removed " .. wallsRemoved .. " wall segments")
    end
    return wallsRemoved
end

function SpatialRefugeShared.RemoveBoundaryWalls(centerX, centerY, z, radius)
    local cell = getCell()
    if not cell then return 0 end
    
    local wallsRemoved = 0
    local wallHeight = SpatialRefugeConfig.WALL_HEIGHT or 1
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius
    local perimeterCoords = {}
    
    for x = minX, maxX + 1 do
        table.insert(perimeterCoords, {x = x, y = minY})
        table.insert(perimeterCoords, {x = x, y = maxY + 1})
    end
    
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
                    for _, obj in ipairs(toRemove) do
                        removeObjectFromSquare(square, obj)
                        wallsRemoved = wallsRemoved + 1
                    end
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

local function createRelicObject(square, refugeId)
    if not square or not square:getChunk() then return nil end
    
    local cell = getCell()
    if not cell then return nil end
    
    local spriteName = SpatialRefugeShared.ResolveRelicSprite()
    if not spriteName then return nil end
    
    local sprite = getSprite(spriteName)
    if not sprite then
        if getDebug() then
            print("[SpatialRefugeShared] ERROR: Sprite object is nil: " .. tostring(spriteName))
        end
        return nil
    end

    local relic = IsoThumpable.new(cell, square, spriteName, false, nil)
    if not relic then return nil end
    
    local createdSprite = relic:getSprite()
    if not createdSprite or not createdSprite:getName() then
        relic:setSprite(spriteName)
        createdSprite = relic:getSprite()
        if not createdSprite or not createdSprite:getName() then
            if getDebug() then
                print("[SpatialRefugeShared] ERROR: Failed to repair relic sprite - removing invalid relic")
            end
            removeObjectFromSquare(square, relic)
            return nil
        end
    end
    
    relic:setMaxHealth(999999)
    relic:setHealth(999999)
    relic:setCanBarricade(false)
    relic:setIsThumpable(false)
    relic:setBreakSound("none")
    relic:setSpecialTooltip(true)
    relic:setIsDismantable(false)
    relic:setCanBePlastered(false)
    relic:setIsHoppable(false)
    relic:setCanPassThrough(false)
    relic:setBlockAllTheSquare(true)
    if relic.setDestroyed then relic:setDestroyed(false) end
    
    local md = relic:getModData()
    md.isSacredRelic = true
    md.refugeId = refugeId
    md.relicSprite = spriteName
    md.canBeDisassembled = false
    md.isProtectedRefugeObject = true
    
    relic:setIsContainer(true)
    local container = relic:getContainer()
    if container then
        container:setCapacity(SpatialRefugeConfig.RELIC_STORAGE_CAPACITY or 20)
    end
    
    if addSpecialObjectToSquare(square, relic) then
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

function SpatialRefugeShared.CreateSacredRelic(x, y, z, refugeId, searchRadius)
    return SpatialRefugeShared.CreateSacredRelicAtPosition(x, y, z, x, y, z, refugeId, searchRadius)
end

function SpatialRefugeShared.CreateSacredRelicAtPosition(searchX, searchY, searchZ, createX, createY, createZ, refugeId, searchRadius)
    local cell = getCell()
    if not cell then return nil end
    
    local radius = (searchRadius or 10) + 1
    local existing = SpatialRefugeShared.FindRelicInRefuge(searchX, searchY, searchZ, radius, refugeId)
    if existing then 
        if getDebug() then
            print("[SpatialRefugeShared] Found existing Sacred Relic")
        end
        
        local expectedSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC
        local currentSprite = existing:getSpriteName()
        local spriteValid = false
        
        if currentSprite then
            local sprite = existing:getSprite()
            spriteValid = (sprite ~= nil and sprite:getName() == currentSprite)
        end
        
        if not spriteValid or (currentSprite and currentSprite ~= expectedSprite) then
            local newSprite = getSprite(expectedSprite)
            if newSprite then
                existing:setSprite(expectedSprite)
                local md = existing:getModData()
                if md then
                    md.relicSprite = expectedSprite
                    if not md.isSacredRelic then
                        md.isSacredRelic = true
                        md.refugeId = refugeId
                    end
                end
                if getDebug() then
                    if not spriteValid then
                        print("[SpatialRefugeShared] Repaired corrupted relic sprite")
                    else
                        print("[SpatialRefugeShared] Migrated relic sprite: " .. tostring(currentSprite) .. " -> " .. expectedSprite)
                    end
                end
                
                if isServer() and existing.transmitModData then
                    existing:transmitModData()
                end
                if isServer() and existing.transmitUpdatedSpriteToClients then
                    existing:transmitUpdatedSpriteToClients()
                end
            end
        end
        
        return existing 
    end
    
    local finalCheckRadius = radius + 2
    local duplicateCheck = SpatialRefugeShared.FindRelicInRefuge(searchX, searchY, searchZ, finalCheckRadius, refugeId)
    if duplicateCheck and duplicateCheck ~= existing then
        if getDebug() then
            print("[SpatialRefugeShared] WARNING: Found duplicate relic during creation check")
        end
        return duplicateCheck
    end
    
    local square = cell:getGridSquare(createX, createY, createZ)
    if not square or not square:getChunk() then return nil end
    
    if getDebug() then
        print("[SpatialRefugeShared] Creating Sacred Relic at stored position: " .. createX .. "," .. createY)
    end

    return createRelicObject(square, refugeId)
end

-----------------------------------------------------------
-- Zombie Clearing
-----------------------------------------------------------

function SpatialRefugeShared.ClearZombiesFromArea(centerX, centerY, z, radius, forceClean, player)
    if not forceClean and centerX < 2000 and centerY < 2000 then
        if getDebug() then
            print("[SpatialRefugeShared] Skipping zombie clearing - remote refuge area")
        end
        return 0
    end
    
    local cell = getCell()
    if not cell then return 0 end
    
    local cleared = 0
    local totalRadius = radius + ZOMBIE_CLEAR_BUFFER
    local isMP = isClient() or isServer()
    local isMPServer = isMP and isServer()
    local zombieOnlineIDs = {}
    
    local zombieList = cell:getZombieList()
    if zombieList then
        for i = zombieList:size() - 1, 0, -1 do
            local zombie = zombieList:get(i)
            if zombie then
                local zx, zy, zz = zombie:getX(), zombie:getY(), zombie:getZ()
                if zz == z and 
                   zx >= centerX - totalRadius and zx <= centerX + totalRadius and
                   zy >= centerY - totalRadius and zy <= centerY + totalRadius then
                    if isMPServer and zombie.getOnlineID then
                        local onlineID = zombie:getOnlineID()
                        if onlineID and onlineID >= 0 then
                            table.insert(zombieOnlineIDs, onlineID)
                        end
                    end
                    zombie:removeFromWorld()
                    zombie:removeFromSquare()
                    cleared = cleared + 1
                end
            end
        end
    end
    
    for dx = -totalRadius, totalRadius do
        for dy = -totalRadius, totalRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local deadBodies = square:getDeadBodys()
                if deadBodies then
                    for i = deadBodies:size() - 1, 0, -1 do
                        local body = deadBodies:get(i)
                        if body then
                            if isMP and square.transmitRemoveItemFromSquare then
                                square:transmitRemoveItemFromSquare(body)
                            else
                                square:removeCorpse(body, false)
                            end
                            cleared = cleared + 1
                        end
                    end
                end
                
                local objects = square:getObjects()
                if objects then
                    for i = objects:size() - 1, 0, -1 do
                        local obj = objects:get(i)
                        if obj and obj:getType() == IsoObjectType.deadBody then
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
-- Tree Clearing
-----------------------------------------------------------

function SpatialRefugeShared.ClearTreesFromArea(centerX, centerY, z, radius, dropLoot)
    local cell = getCell()
    if not cell then return 0 end
    
    local isMP = isClient() or isServer()
    if isMP and not getCachedIsServer() then
        if getDebug() then
            print("[SpatialRefugeShared] ClearTreesFromArea: Skipping on client")
        end
        return 0
    end
    
    local cleared = 0
    local totalRadius = radius + TREE_CLEAR_BUFFER
    
    for dx = -totalRadius, totalRadius do
        for dy = -totalRadius, totalRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local tree = square:getTree()
                if tree then
                    if dropLoot then
                        if tree.toppleTree then tree:toppleTree() end
                    else
                        if getCachedIsServer() then
                            square:transmitRemoveItemFromSquare(tree)
                        else
                            if square.RemoveWorldObject then pcall(function() square:RemoveWorldObject(tree) end) end
                            if tree.removeFromSquare then pcall(function() tree:removeFromSquare() end) end
                            if tree.removeFromWorld then pcall(function() tree:removeFromWorld() end) end
                        end
                        square:RecalcAllWithNeighbours(true)
                    end
                    cleared = cleared + 1
                end
            end
        end
    end
    
    if getDebug() and cleared > 0 then
        print("[SpatialRefugeShared] Cleared " .. cleared .. " trees from refuge area" .. (isMP and " (MP server)" or " (SP)"))
    end
    
    return cleared
end

-----------------------------------------------------------
-- Refuge Expansion
-----------------------------------------------------------

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
        print("[SpatialRefugeShared] ExpandRefuge: tier " .. (refugeData.tier or 0) .. " -> " .. newTier .. " radius " .. oldRadius .. " -> " .. newRadius)
    end
    
    SpatialRefugeShared.RemoveAllRefugeWalls(centerX, centerY, centerZ, newRadius)
    SpatialRefugeShared.CreateBoundaryWalls(centerX, centerY, centerZ, newRadius)
    SpatialRefugeShared.ClearTreesFromArea(centerX, centerY, centerZ, newRadius, false)
    
    refugeData.tier = newTier
    refugeData.radius = newRadius
    refugeData.lastExpanded = getTimestamp and getTimestamp() or os.time()
    
    SpatialRefugeShared.ClearZombiesFromArea(centerX, centerY, centerZ, newRadius, true, player)
    
    return true
end

-----------------------------------------------------------
-- Full Refuge Generation
-----------------------------------------------------------

function SpatialRefugeShared.EnsureRefugeStructures(refugeData, player)
    if not refugeData then return false end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    local relicX = refugeData.relicX or centerX
    local relicY = refugeData.relicY or centerY
    local relicZ = refugeData.relicZ or centerZ
    
    SpatialRefugeShared.CreateBoundaryWalls(centerX, centerY, centerZ, radius)
    SpatialRefugeShared.ClearTreesFromArea(centerX, centerY, centerZ, radius, false)
    SpatialRefugeShared.RemoveDuplicateRelics(centerX, centerY, centerZ, radius, refugeId, refugeData)
    
    local relic = SpatialRefugeShared.CreateSacredRelicAtPosition(
        centerX, centerY, centerZ,
        relicX, relicY, relicZ,
        refugeId, radius
    )
    
    SpatialRefugeShared.SyncRelicPositionToModData(refugeData)
    SpatialRefugeShared.ClearZombiesFromArea(centerX, centerY, centerZ, radius, true, player)
    
    if getDebug() then
        print("[SpatialRefugeShared] Ensured refuge structures for " .. tostring(refugeId))
    end
    
    return relic ~= nil
end

-----------------------------------------------------------
-- Property Repair
-----------------------------------------------------------

function SpatialRefugeShared.RepairRefugeProperties(refugeData)
    if not refugeData then return 0 end
    
    local cell = getCell()
    if not cell then return 0 end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local repaired = 0
    
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
                            
                            if md and md.isRefugeBoundary then
                                if obj.setIsThumpable then obj:setIsThumpable(false) end
                                if obj.setIsHoppable then obj:setIsHoppable(false) end
                                if obj.setCanBarricade then obj:setCanBarricade(false) end
                                if obj.setIsDismantable then obj:setIsDismantable(false) end
                                if obj.setCanBePlastered then obj:setCanBePlastered(false) end
                                repaired = repaired + 1
                            end
                            
                            local spriteName = obj:getSpriteName()
                            local isOldRelicSprite = spriteName == "location_community_cemetary_01_11"
                            local isRelic = (md and md.isSacredRelic) or isOldRelicSprite
                            
                            if isRelic then
                                if not md.isSacredRelic then
                                    md.isSacredRelic = true
                                    md.refugeId = refugeData.refugeId
                                    print("[SpatialRefugeShared] Added isSacredRelic flag to old relic")
                                end
                                if obj.setIsThumpable then obj:setIsThumpable(false) end
                                if obj.setIsHoppable then obj:setIsHoppable(false) end
                                if obj.setIsDismantable then obj:setIsDismantable(false) end
                                
                                local expectedSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC
                                local currentSprite = obj:getSpriteName()
                                local spriteValid = false
                                
                                if currentSprite and obj.getSprite then
                                    local sprite = obj:getSprite()
                                    spriteValid = (sprite ~= nil and sprite:getName() == currentSprite)
                                end
                                
                                if not spriteValid or (currentSprite and currentSprite ~= expectedSprite) then
                                    local newSprite = getSprite(expectedSprite)
                                    if newSprite then
                                        obj:setSprite(expectedSprite)
                                        md.relicSprite = expectedSprite
                                        if getDebug() then
                                            if not spriteValid then
                                                print("[SpatialRefugeShared] Repaired corrupted relic sprite via repair function")
                                            else
                                                print("[SpatialRefugeShared] Migrated relic sprite via repair: " .. tostring(currentSprite) .. " -> " .. expectedSprite)
                                            end
                                        end
                                        
                                        if getCachedIsServer() then
                                            if obj.transmitModData then obj:transmitModData() end
                                            if obj.transmitUpdatedSpriteToClients then obj:transmitUpdatedSpriteToClients() end
                                        end
                                    end
                                end
                                
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
