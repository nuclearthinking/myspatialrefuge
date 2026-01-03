-- MSR_Shared - Shared Module
-- Generation functions accessible by both client and server
-- For multiplayer persistence, server uses these functions to create objects that save to map

require "shared/MSR"
require "shared/MSR_Config"
require "shared/MSR_Env"
require "shared/MSR_Integrity"

-- Prevent double-loading
if MSR.Shared and MSR.Shared._loaded then
    return MSR.Shared
end

MSR.Shared = MSR.Shared or {}
MSR.Shared._loaded = true

-- Local alias
local Shared = MSR.Shared

-----------------------------------------------------------
-- Move Relic Error Codes (enum-like table)
-- Use these constants instead of hardcoded strings
-----------------------------------------------------------

Shared.MoveRelicError = {
    -- Success (not an error)
    SUCCESS = "SUCCESS",

    -- Input/data errors
    NO_REFUGE_DATA = "NO_REFUGE_DATA",
    RELIC_NOT_FOUND = "RELIC_NOT_FOUND",
    ALREADY_AT_POSITION = "ALREADY_AT_POSITION",

    -- World/loading errors
    WORLD_NOT_READY = "WORLD_NOT_READY",
    DESTINATION_NOT_LOADED = "DESTINATION_NOT_LOADED",
    CURRENT_LOCATION_NOT_LOADED = "CURRENT_LOCATION_NOT_LOADED",

    -- Blocking objects
    BLOCKED_BY_TREE = "BLOCKED_BY_TREE",
    BLOCKED_BY_WALL = "BLOCKED_BY_WALL",
    BLOCKED_BY_STAIRS = "BLOCKED_BY_STAIRS",
    BLOCKED_BY_FURNITURE = "BLOCKED_BY_FURNITURE",
    BLOCKED_BY_CONTAINER = "BLOCKED_BY_CONTAINER",
    BLOCKED_BY_ENTITY = "BLOCKED_BY_ENTITY",
    DESTINATION_BLOCKED = "DESTINATION_BLOCKED",
}

-- Mapping from error code to translation key
local MoveRelicErrorToTranslationKey = {
    [Shared.MoveRelicError.SUCCESS] = "IGUI_SacredRelicMovedTo",
    [Shared.MoveRelicError.NO_REFUGE_DATA] = "IGUI_MoveRelic_NoRefugeData",
    [Shared.MoveRelicError.RELIC_NOT_FOUND] = "IGUI_MoveRelic_RelicNotFound",
    [Shared.MoveRelicError.ALREADY_AT_POSITION] = "IGUI_MoveRelic_AlreadyAtPosition",
    [Shared.MoveRelicError.WORLD_NOT_READY] = "IGUI_MoveRelic_WorldNotReady",
    [Shared.MoveRelicError.DESTINATION_NOT_LOADED] = "IGUI_MoveRelic_DestinationNotLoaded",
    [Shared.MoveRelicError.CURRENT_LOCATION_NOT_LOADED] = "IGUI_MoveRelic_CurrentLocationNotLoaded",
    [Shared.MoveRelicError.BLOCKED_BY_TREE] = "IGUI_MoveRelic_BlockedByTree",
    [Shared.MoveRelicError.BLOCKED_BY_WALL] = "IGUI_MoveRelic_BlockedByWall",
    [Shared.MoveRelicError.BLOCKED_BY_STAIRS] = "IGUI_MoveRelic_BlockedByStairs",
    [Shared.MoveRelicError.BLOCKED_BY_FURNITURE] = "IGUI_MoveRelic_BlockedByFurniture",
    [Shared.MoveRelicError.BLOCKED_BY_CONTAINER] = "IGUI_MoveRelic_BlockedByContainer",
    [Shared.MoveRelicError.BLOCKED_BY_ENTITY] = "IGUI_MoveRelic_BlockedByEntity",
    [Shared.MoveRelicError.DESTINATION_BLOCKED] = "IGUI_MoveRelic_DestinationBlocked",
}

--- Get translation key for a MoveRelic error code
-- @param errorCode string - one of Shared.MoveRelicError constants
-- @return string - the translation key (e.g., "IGUI_MoveRelic_BlockedByTree")
function Shared.GetMoveRelicTranslationKey(errorCode)
    return MoveRelicErrorToTranslationKey[errorCode] or "IGUI_CannotMoveRelic"
end

-- Use shared environment helpers
local function getCachedIsServer()
    return MSR.Env.isServer()
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
    pcall(function() square:transmitRemoveItemFromSquare(obj) end)

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

function Shared.ResolveRelicSprite()
    local spriteName = MSR.Config.SPRITES.SACRED_RELIC

    if getSprite and getSprite(spriteName) then return spriteName end

    local digits = spriteName:match("_(%d+)$")
    if digits then
        local padded2 = spriteName:gsub("_(%d+)$", "_0" .. digits)
        if getSprite and getSprite(padded2) then return padded2 end
        local padded3 = spriteName:gsub("_(%d+)$", "_00" .. digits)
        if getSprite and getSprite(padded3) then return padded3 end
    end

    local fallback = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK
    if fallback and getSprite and getSprite(fallback) then
        L.debug("Shared", "Using fallback sprite: " .. fallback)
        return fallback
    end

    return nil
end

-- Find relic on a specific square by ModData
function Shared.FindRelicOnSquare(square, refugeId)
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
        _cachedRelicSprite = MSR.Config.SPRITES.SACRED_RELIC
        _cachedResolvedSprite = Shared.ResolveRelicSprite()
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

function Shared.FindRelicInRefuge(centerX, centerY, z, radius, refugeId)
    local cell = getCell()
    if not cell then return nil end

    local relicSprite, resolvedSprite = getCachedRelicSprites()
    local searchRadius = (radius or 1) + 1

    -- First pass: find by ModData (preferred)
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local relic = Shared.FindRelicOnSquare(square, refugeId)
                if relic then
                    return relic
                end
            end
        end
    end

    -- Second pass: find by sprite (fallback for old saves)
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local relic = findRelicOnSquareBySprite(square, relicSprite, resolvedSprite)
                if relic then
                    return relic
                end
            end
        end
    end

    return nil
end

function Shared.SyncRelicPositionToModData(refugeData)
    if not refugeData then return false end
    if not MSR.Data.CanModifyData() then return false end
    if refugeData.relicX ~= nil then return false end

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId

    local relic = Shared.FindRelicInRefuge(centerX, centerY, centerZ, radius, refugeId)

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

    MSR.Data.SaveRefugeData(refugeData)
    return true
end

-- Shorthand for error codes
local Err = Shared.MoveRelicError

function Shared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName, existingRelic)
    if not refugeData then return false, Err.NO_REFUGE_DATA end

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
        relic = Shared.FindRelicInRefuge(centerX, centerY, centerZ, radius, refugeId)
    end
    if not relic then
        return false, Err.RELIC_NOT_FOUND
    end

    -- Get current position
    local currentSquare = relic:getSquare()
    if currentSquare and currentSquare:getX() == targetX and currentSquare:getY() == targetY then
        return false, Err.ALREADY_AT_POSITION
    end

    -- Get target square
    local cell = getCell()
    if not cell then return false, Err.WORLD_NOT_READY end

    -- Only use getGridSquare - don't create empty cells
    local targetSquare = cell:getGridSquare(targetX, targetY, targetZ)
    if not targetSquare then return false, Err.DESTINATION_NOT_LOADED end

    -- Verify chunk is loaded
    local targetChunk = targetSquare:getChunk()
    if not targetChunk then return false, Err.DESTINATION_NOT_LOADED end

    local hasBlockingObject = false
    local blockingErrorCode = nil

    if targetSquare:getTree() then
        hasBlockingObject = true
        blockingErrorCode = Err.BLOCKED_BY_TREE
    end

    if not hasBlockingObject then
        local movingObjects = targetSquare:getMovingObjects()
        if movingObjects and movingObjects:size() > 0 then
            hasBlockingObject = true
            blockingErrorCode = Err.BLOCKED_BY_ENTITY
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
                            blockingErrorCode = Err.BLOCKED_BY_WALL
                            break
                        elseif objType == IsoObjectType.tree then
                            hasBlockingObject = true
                            blockingErrorCode = Err.BLOCKED_BY_TREE
                            break
                        elseif objType == IsoObjectType.stairsTW or objType == IsoObjectType.stairsMW or
                            objType == IsoObjectType.stairsNW or objType == IsoObjectType.stairsBN then
                            hasBlockingObject = true
                            blockingErrorCode = Err.BLOCKED_BY_STAIRS
                            break
                        else
                            local isFurniture = instanceof and instanceof(obj, "IsoThumpable") or false
                            local isContainer = obj.getContainer and obj:getContainer() ~= nil or false

                            if isContainer then
                                hasBlockingObject = true
                                blockingErrorCode = Err.BLOCKED_BY_CONTAINER
                                break
                            elseif isFurniture then
                                hasBlockingObject = true
                                blockingErrorCode = Err.BLOCKED_BY_FURNITURE
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    if hasBlockingObject then
        L.debug("Shared", "MoveRelic: Blocked - " .. tostring(blockingErrorCode))
        return false, blockingErrorCode or Err.DESTINATION_BLOCKED
    end

    if currentSquare and not currentSquare:getChunk() then
        return false, Err.CURRENT_LOCATION_NOT_LOADED
    end

    if not targetChunk then
        return false, Err.DESTINATION_NOT_LOADED
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

    L.debug("Shared", "Moved relic to " .. cornerName .. " (" .. targetX .. "," .. targetY .. ")")

    return true, Err.SUCCESS
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
                    L.debug("Shared", "Wall already exists at " .. square:getX() .. "," .. square:getY())
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

function Shared.CreateWall(x, y, z, addNorth, addWest, cornerSprite)
    local cell = getCell()
    if not cell then return nil end

    local square = cell:getGridSquare(x, y, z)
    if not square or not square:getChunk() then return nil end

    local created = false
    if addNorth and createWallObject(square, MSR.Config.SPRITES.WALL_NORTH, true) then
        created = true
    end
    if addWest and createWallObject(square, MSR.Config.SPRITES.WALL_WEST, false) then
        created = true
    end
    if cornerSprite and createWallObject(square, cornerSprite, false) then
        created = true
    end

    return created and square or nil
end

function Shared.CreateBoundaryWalls(centerX, centerY, z, radius)
    local wallsCreated = 0
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius

    for level = 0, wallHeight - 1 do
        local currentZ = z + level

        for x = minX, maxX do
            if Shared.CreateWall(x, minY, currentZ, true, false, nil) then wallsCreated = wallsCreated + 1 end
            if Shared.CreateWall(x, maxY + 1, currentZ, true, false, nil) then wallsCreated = wallsCreated +
                1 end
        end

        for y = minY, maxY do
            if Shared.CreateWall(minX, y, currentZ, false, true, nil) then wallsCreated = wallsCreated + 1 end
            if Shared.CreateWall(maxX + 1, y, currentZ, false, true, nil) then wallsCreated = wallsCreated +
                1 end
        end

        Shared.CreateWall(minX, minY, currentZ, false, false, MSR.Config.SPRITES.WALL_CORNER_NW)
        Shared.CreateWall(maxX + 1, maxY + 1, currentZ, false, false,
            MSR.Config.SPRITES.WALL_CORNER_SE)
    end

    L.debug("Shared", "Created " .. wallsCreated .. " wall segments")
    return wallsCreated
end

function Shared.RemoveAllRefugeWalls(centerX, centerY, z, maxRadius)
    local cell = getCell()
    if not cell then return 0 end

    local wallsRemoved = 0
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
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

    L.debug("Shared", "RemoveAllRefugeWalls: removed " .. wallsRemoved .. " wall segments")
    return wallsRemoved
end

function Shared.RemoveBoundaryWalls(centerX, centerY, z, radius)
    local cell = getCell()
    if not cell then return 0 end

    local wallsRemoved = 0
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius
    local perimeterCoords = {}

    for x = minX, maxX + 1 do
        table.insert(perimeterCoords, { x = x, y = minY })
        table.insert(perimeterCoords, { x = x, y = maxY + 1 })
    end

    for y = minY, maxY + 1 do
        table.insert(perimeterCoords, { x = minX, y = y })
        table.insert(perimeterCoords, { x = maxX + 1, y = y })
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

    L.debug("Shared", "Removed " .. wallsRemoved .. " wall segments")
    return wallsRemoved
end

-----------------------------------------------------------
-- Sacred Relic Generation
-----------------------------------------------------------

local function createRelicObject(square, refugeId)
    if not square or not square:getChunk() then return nil end

    local cell = getCell()
    if not cell then return nil end

    local spriteName = Shared.ResolveRelicSprite()
    if not spriteName then return nil end

    local sprite = getSprite(spriteName)
    if not sprite then
        L.debug("Shared", "ERROR: Sprite object is nil: " .. tostring(spriteName))
        return nil
    end

    local relic = IsoThumpable.new(cell, square, spriteName, false, nil)
    if not relic then return nil end

    local createdSprite = relic:getSprite()
    if not createdSprite or not createdSprite:getName() then
        relic:setSprite(spriteName)
        createdSprite = relic:getSprite()
        if not createdSprite or not createdSprite:getName() then
            L.debug("Shared", "ERROR: Failed to repair relic sprite - removing invalid relic")
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
        container:setCapacity(MSR.Config.RELIC_STORAGE_CAPACITY or 20)
    end

    if addSpecialObjectToSquare(square, relic) then
        if getCachedIsServer() and relic.transmitModData then
            relic:transmitModData()
        end

        L.debug("Shared", "Created Sacred Relic at " .. square:getX() .. "," .. square:getY())
        return relic, spriteName
    end

    return nil, nil
end

function Shared.CreateSacredRelic(x, y, z, refugeId, searchRadius)
    return MSR.Shared.CreateSacredRelicAtPosition(x, y, z, x, y, z, refugeId, searchRadius)
end

function Shared.CreateSacredRelicAtPosition(searchX, searchY, searchZ, createX, createY, createZ, refugeId,
                                                         searchRadius)
    local cell = getCell()
    if not cell then return nil end

    local radius = (searchRadius or 10) + 1

    -- Check for existing relic (no inline repairs - let integrity system handle that)
    local existing = Shared.FindRelicInRefuge(searchX, searchY, searchZ, radius, refugeId)
    if existing then
        L.debug("Shared", "Found existing Sacred Relic")
        return existing
    end

    -- Final duplicate check with wider radius
    local finalCheckRadius = radius + 2
    local duplicateCheck = Shared.FindRelicInRefuge(searchX, searchY, searchZ, finalCheckRadius, refugeId)
    if duplicateCheck then
        L.debug("Shared", "Found relic in extended search")
        return duplicateCheck
    end

    -- Create new relic
    local square = cell:getGridSquare(createX, createY, createZ)
    if not square or not square:getChunk() then return nil end

    L.debug("Shared", "Creating Sacred Relic at stored position: " .. createX .. "," .. createY)

    return createRelicObject(square, refugeId)
end

-----------------------------------------------------------
-- Zombie Clearing
-----------------------------------------------------------

function Shared.ClearZombiesFromArea(centerX, centerY, z, radius, forceClean, player)
    if not forceClean and centerX < 2000 and centerY < 2000 then
        L.debug("Shared", "Skipping zombie clearing - remote refuge area")
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
                            pcall(function() square:transmitRemoveItemFromSquare(obj) end)
                            cleared = cleared + 1
                        end
                    end
                end
            end
        end
    end

    if isMPServer and player and #zombieOnlineIDs > 0 then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE,
            MSR.Config.COMMANDS.CLEAR_ZOMBIES, {
                zombieIDs = zombieOnlineIDs
            })
        L.debug("Shared", "Sent " .. #zombieOnlineIDs .. " zombie IDs to client for removal")
    end

    if cleared > 0 then
        L.debug("Shared", "Cleared " .. cleared .. " zombies/corpses from refuge area")
    end

    return cleared
end

-----------------------------------------------------------
-- Tree Clearing
-----------------------------------------------------------

function Shared.ClearTreesFromArea(centerX, centerY, z, radius, dropLoot)
    local cell = getCell()
    if not cell then return 0 end

    local isMP = isClient() or isServer()
    if isMP and not getCachedIsServer() then
        L.debug("Shared", "ClearTreesFromArea: Skipping on client")
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
                        pcall(function() square:transmitRemoveItemFromSquare(tree) end)
                        square:RecalcAllWithNeighbours(true)
                    end
                    cleared = cleared + 1
                end
            end
        end
    end

    if cleared > 0 then
        L.debug("Shared", "Cleared " ..
        cleared .. " trees from refuge area" .. (isMP and " (MP server)" or " (SP)"))
    end

    return cleared
end

-----------------------------------------------------------
-- Refuge Expansion
-----------------------------------------------------------

function Shared.ExpandRefuge(refugeData, newTier, player)
    if not refugeData then return false end

    local tierConfig = MSR.Config.TIERS[newTier]
    if not tierConfig then return false end

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local oldRadius = refugeData.radius
    local newRadius = tierConfig.radius

    L.debug("Shared", "ExpandRefuge: tier " ..
        (refugeData.tier or 0) .. " -> " .. newTier .. " radius " .. oldRadius .. " -> " .. newRadius)

    Shared.RemoveAllRefugeWalls(centerX, centerY, centerZ, newRadius)
    Shared.CreateBoundaryWalls(centerX, centerY, centerZ, newRadius)
    Shared.ClearTreesFromArea(centerX, centerY, centerZ, newRadius, false)

    refugeData.tier = newTier
    refugeData.radius = newRadius
    refugeData.lastExpanded = getTimestamp and getTimestamp() or os.time()

    Shared.ClearZombiesFromArea(centerX, centerY, centerZ, newRadius, true, player)

    return true
end

-----------------------------------------------------------
-- Full Refuge Generation
-----------------------------------------------------------

function Shared.EnsureRefugeStructures(refugeData, player)
    if not refugeData then return false end

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    local relicX = refugeData.relicX or centerX
    local relicY = refugeData.relicY or centerY
    local relicZ = refugeData.relicZ or centerZ

    -- Create/verify boundary walls
    Shared.CreateBoundaryWalls(centerX, centerY, centerZ, radius)
    Shared.ClearTreesFromArea(centerX, centerY, centerZ, radius, false)

    -- Create relic if needed
    local relic = Shared.CreateSacredRelicAtPosition(
        centerX, centerY, centerZ,
        relicX, relicY, relicZ,
        refugeId, radius
    )

    -- Use integrity system for validation and repair
    local report = MSR.Integrity.ValidateAndRepair(refugeData, {
        source = "generation",
        player = player
    })

    Shared.SyncRelicPositionToModData(refugeData)
    Shared.ClearZombiesFromArea(centerX, centerY, centerZ, radius, true, player)

    L.debug("Shared", "Ensured refuge structures for " .. tostring(refugeId))

    return report.relic.found or relic ~= nil
end

-----------------------------------------------------------
-- Property Repair (DEPRECATED - use MSR.Integrity.ValidateAndRepair)
-----------------------------------------------------------

-- @deprecated Use MSR.Integrity.ValidateAndRepair() instead
-- This function is kept for backwards compatibility but delegates to the new system
function Shared.RepairRefugeProperties(refugeData)
    if not refugeData then return 0 end

    local report = MSR.Integrity.ValidateAndRepair(refugeData, {
        source = "legacy_repair"
    })

    -- Return approximate count for backwards compatibility
    local repaired = report.walls.repaired
    if report.relic.found then repaired = repaired + 1 end

    return repaired
end

-- @deprecated Use MSR.Integrity.ValidateAndRepair() instead
-- Duplicate removal is now handled internally by the integrity system
function Shared.RemoveDuplicateRelics(centerX, centerY, centerZ, radius, refugeId, refugeData)
    if not refugeData then return 0 end

    local report = MSR.Integrity.ValidateAndRepair(refugeData, {
        source = "legacy_duplicate_removal"
    })

    return report.relic.duplicatesRemoved
end

return MSR.Shared
