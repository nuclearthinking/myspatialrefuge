require "00_core/00_MSR"
require "helpers/World"
require "MSR_Integrity"
require "MSR_PlayerMessage"

local LOG = L.logger("Shared")

if MSR and MSR.Shared and MSR.Shared._loaded then
    return MSR.Shared
end

MSR.Shared = MSR.Shared or {}
MSR.Shared._loaded = true

local Shared = MSR.Shared


local function addSpecialObjectToSquare(square, obj)
    return MSR.World.addObject(square, obj, true)
end

local function removeObjectFromSquare(square, obj)
    return MSR.World.removeObject(square, obj, true)
end

local TREE_CLEAR_BUFFER = 5

-- Utility Functions
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
        LOG.debug("Using fallback sprite: %s", fallback)
        return fallback
    end

    return nil
end

function Shared.FindRelicOnSquare(square, refugeId)
    if not square then return nil end

    local relics = MSR.World.findObjects(square, function(obj)
        local md = MSR.World.getModData(obj)
        return md and md.isSacredRelic and md.refugeId == refugeId
    end)

    return relics[1] -- Return first match or nil
end

-- Sprite cache (resolved once per session)
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

-- Fallback for old saves without ModData
local function findRelicOnSquareBySprite(square, relicSprite, resolvedSprite)
    local relics = MSR.World.findObjects(square, function(obj)
        if not obj.getSprite then return false end
        local sprite = obj:getSprite()
        if not sprite then return false end
        local spriteName = sprite:getName()
        return spriteName == relicSprite or spriteName == resolvedSprite
    end)

    return relics[1] -- Return first match or nil
end

function Shared.FindRelicInRefuge(centerX, centerY, z, radius, refugeId)
    local relicSprite, resolvedSprite = getCachedRelicSprites()
    local searchRadius = (radius or 1) + 1
    local foundRelic = nil

    -- Try ModData first (preferred)
    MSR.World.iterateArea(centerX, centerY, z, searchRadius, function(square)
        if foundRelic then return end
        local relic = Shared.FindRelicOnSquare(square, refugeId)
        if relic then foundRelic = relic end
    end)

    if foundRelic then return foundRelic end

    -- Fallback: sprite matching for old saves
    MSR.World.iterateArea(centerX, centerY, z, searchRadius, function(square)
        if foundRelic then return end
        local relic = findRelicOnSquareBySprite(square, relicSprite, resolvedSprite)
        if relic then foundRelic = relic end
    end)

    return foundRelic
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

local Err = MSR.PlayerMessage.MoveRelicError

function Shared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName, existingRelic)
    if not refugeData then return false, Err.NO_REFUGE_DATA end

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId

    local targetX = centerX + (cornerDx * radius)
    local targetY = centerY + (cornerDy * radius)
    local targetZ = centerZ

    local relic = existingRelic or Shared.FindRelicInRefuge(centerX, centerY, centerZ, radius, refugeId)
    if not relic then return false, Err.RELIC_NOT_FOUND end

    local currentSquare = relic:getSquare()
    if currentSquare and currentSquare:getX() == targetX and currentSquare:getY() == targetY then
        return false, Err.ALREADY_AT_POSITION
    end

    local cell = getCell()
    if not cell then return false, Err.WORLD_NOT_READY end

    local targetSquare = cell:getGridSquare(targetX, targetY, targetZ)
    if not targetSquare then return false, Err.DESTINATION_NOT_LOADED end

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
        LOG.debug("MoveRelic: Blocked - %s", tostring(blockingErrorCode))
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

    if MSR.Env.isServer() and relic.transmitModData then
        relic:transmitModData()
    end

    LOG.debug("Moved relic to %s (%s,%s)", cornerName, targetX, targetY)

    return true, Err.SUCCESS
end

-----------------------------------------------------------
-- Wall Generation
-----------------------------------------------------------

local function createWallObject(square, spriteName, isNorthWall)
    if not square or not square:getChunk() then return nil end

    local existingWalls = MSR.World.findObjects(square, function(obj)
        local md = MSR.World.getModData(obj)
        return md and md.isRefugeBoundary and md.refugeBoundarySprite == spriteName
    end)

    if #existingWalls > 0 then return existingWalls[1] end

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
        if MSR.Env.isServer() then
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
    local square = MSR.World.getSquareSafe(x, y, z)
    if not square then return nil end

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

function Shared.CheckBoundaryWallsExist(centerX, centerY, z, radius)
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius
    local sampleCount = 0
    local foundCount = 0

    for level = 0, wallHeight - 1 do
        local currentZ = z + level

        -- Check a few sample positions on each side
        local samplePositions = {
            { minX, minY }, { centerX, minY }, { maxX, minY },             -- South wall samples
            { minX, maxY + 1 }, { centerX, maxY + 1 }, { maxX, maxY + 1 }, -- North wall samples
            { minX,     minY }, { minX, centerY }, { minX, maxY },         -- West wall samples
            { maxX + 1, minY }, { maxX + 1, centerY }, { maxX + 1, maxY }  -- East wall samples
        }

        for _, pos in ipairs(samplePositions) do
            local square = MSR.World.getSquareSafe(pos[1], pos[2], currentZ)
            if square then
                sampleCount = sampleCount + 1
                local walls = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
                if #walls > 0 then
                    foundCount = foundCount + 1
                end
            end
        end
    end

    -- If we found walls at most sample positions, assume walls exist
    return sampleCount > 0 and foundCount >= (sampleCount * 0.7) -- 70% threshold
end

function Shared.CreateBoundaryWalls(centerX, centerY, z, radius)
    if Shared.CheckBoundaryWallsExist(centerX, centerY, z, radius) then
        return 0 -- Already exist
    end

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
            if Shared.CreateWall(x, maxY + 1, currentZ, true, false, nil) then
                wallsCreated = wallsCreated +
                    1
            end
        end

        for y = minY, maxY do
            if Shared.CreateWall(minX, y, currentZ, false, true, nil) then wallsCreated = wallsCreated + 1 end
            if Shared.CreateWall(maxX + 1, y, currentZ, false, true, nil) then
                wallsCreated = wallsCreated +
                    1
            end
        end

        Shared.CreateWall(minX, minY, currentZ, false, false, MSR.Config.SPRITES.WALL_CORNER_NW)
        Shared.CreateWall(maxX + 1, maxY + 1, currentZ, false, false,
            MSR.Config.SPRITES.WALL_CORNER_SE)
    end

    if wallsCreated > 0 then
        LOG.debug("Created %d wall segments", wallsCreated)
    end
    return wallsCreated
end

function Shared.RemoveAllRefugeWalls(centerX, centerY, z, maxRadius)
    local wallsRemoved = 0
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    local scanRadius = maxRadius + 2
    local modifiedSquares = {}

    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        MSR.World.iterateArea(centerX, centerY, currentZ, scanRadius, function(square)
            local walls = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
            for _, obj in ipairs(walls) do
                MSR.World.removeObject(square, obj, false)
                wallsRemoved = wallsRemoved + 1
                table.insert(modifiedSquares, square)
            end
        end)
    end

    for _, square in ipairs(modifiedSquares) do
        MSR.World.recalcSquare(square)
        if square.RecalcProperties then square:RecalcProperties() end
    end

    LOG.debug("RemoveAllRefugeWalls: removed %d wall segments", wallsRemoved)
    return wallsRemoved
end

function Shared.RemoveBoundaryWalls(centerX, centerY, z, radius)
    local wallsRemoved = 0
    local wallHeight = MSR.Config.WALL_HEIGHT or 1

    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        MSR.World.iteratePerimeter(centerX, centerY, currentZ, radius, function(square)
            local walls = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
            for _, obj in ipairs(walls) do
                MSR.World.removeObject(square, obj, true)
                wallsRemoved = wallsRemoved + 1
            end
        end)
    end

    LOG.debug("Removed %d wall segments", wallsRemoved)
    return wallsRemoved
end

-- Sacred Relic Generation
local function createRelicObject(square, refugeId)
    if not square or not square:getChunk() then return nil end

    local cell = getCell()
    if not cell then return nil end

    local spriteName = Shared.ResolveRelicSprite()
    if not spriteName then return nil end

    local sprite = getSprite(spriteName)
    if not sprite then
        LOG.error("Sprite object is nil: %s", tostring(spriteName))
        return nil
    end

    local relic = IsoThumpable.new(cell, square, spriteName, false, nil)
    if not relic then return nil end

    local createdSprite = relic:getSprite()
    if not createdSprite or not createdSprite:getName() then
        relic:setSprite(spriteName)
        createdSprite = relic:getSprite()
        if not createdSprite or not createdSprite:getName() then
            LOG.error("Failed to repair relic sprite - removing invalid relic")
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
        -- Get capacity based on upgrade level (refugeId is the username)
        local refugeData = MSR.Data.GetRefugeDataByUsername(refugeId)
        local capacity = MSR.Config.getRelicStorageCapacity(refugeData)
        container:setCapacity(capacity)
    end

    if addSpecialObjectToSquare(square, relic) then
        if MSR.Env.isServer() and relic.transmitModData then
            relic:transmitModData()
        end

        LOG.debug("Created Sacred Relic at %s,%s", square:getX(), square:getY())
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

    -- Check for existing relic (integrity system handles repairs)
    local existing = Shared.FindRelicInRefuge(searchX, searchY, searchZ, radius, refugeId)
    if existing then return existing end

    -- Extended search for duplicates
    local duplicateCheck = Shared.FindRelicInRefuge(searchX, searchY, searchZ, radius + 2, refugeId)
    if duplicateCheck then return duplicateCheck end

    local square = cell:getGridSquare(createX, createY, createZ)
    if not square or not square:getChunk() then return nil end

    LOG.debug("Creating Sacred Relic at %s,%s", createX, createY)
    return createRelicObject(square, refugeId)
end

-----------------------------------------------------------
-- Tree Clearing
-----------------------------------------------------------

function Shared.ClearTreesFromArea(centerX, centerY, z, radius, dropLoot)
    if MSR.Env.isClient() then
        LOG.debug("ClearTreesFromArea: Skipping on client")
        return 0
    end

    local cleared = 0
    local totalRadius = radius + TREE_CLEAR_BUFFER

    MSR.World.iterateArea(centerX, centerY, z, totalRadius, function(square)
        local tree = square:getTree()
        if tree then
            if dropLoot then
                if tree.toppleTree then tree:toppleTree() end
            else
                MSR.World.removeObject(square, tree, true)
            end
            cleared = cleared + 1
        end
    end)

    if cleared > 0 then
        LOG.debug("Cleared %d trees from refuge area", cleared)
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

    LOG.debug("ExpandRefuge: tier %d -> %d radius %d -> %d", (refugeData.tier or 0), newTier, oldRadius, newRadius)

    Shared.RemoveAllRefugeWalls(centerX, centerY, centerZ, newRadius)
    Shared.CreateBoundaryWalls(centerX, centerY, centerZ, newRadius)
    Shared.ClearTreesFromArea(centerX, centerY, centerZ, newRadius, false)

    refugeData.tier = newTier
    refugeData.radius = newRadius
    refugeData.lastExpanded = K.time()

    require "MSR_ZombieClear"
    MSR.ZombieClear.ClearZombiesFromArea(centerX, centerY, centerZ, newRadius, true, player)

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

    Shared.CreateBoundaryWalls(centerX, centerY, centerZ, radius)
    Shared.ClearTreesFromArea(centerX, centerY, centerZ, radius, false)

    local relic = Shared.CreateSacredRelicAtPosition(
        centerX, centerY, centerZ,
        relicX, relicY, relicZ,
        refugeId, radius
    )

    local report = MSR.Integrity.ValidateAndRepair(refugeData, {
        source = "generation",
        player = player
    })

    Shared.SyncRelicPositionToModData(refugeData)
    require "MSR_ZombieClear"
    MSR.ZombieClear.ClearZombiesFromArea(centerX, centerY, centerZ, radius, true, player)

    LOG.debug("Ensured refuge structures for %s", tostring(refugeId))

    return report.relic.found or relic ~= nil
end

-----------------------------------------------------------
-- Deprecated (use MSR.Integrity.ValidateAndRepair)
-----------------------------------------------------------

--- @deprecated Delegates to MSR.Integrity.ValidateAndRepair
function Shared.RepairRefugeProperties(refugeData)
    if not refugeData then return 0 end
    local report = MSR.Integrity.ValidateAndRepair(refugeData, { source = "legacy_repair" })
    return report.walls.repaired + (report.relic.found and 1 or 0)
end

--- @deprecated Delegates to MSR.Integrity.ValidateAndRepair
function Shared.RemoveDuplicateRelics(centerX, centerY, centerZ, radius, refugeId, refugeData)
    if not refugeData then return 0 end
    local report = MSR.Integrity.ValidateAndRepair(refugeData, { source = "legacy_duplicate_removal" })
    return report.relic.duplicatesRemoved
end

-- Room persistence moved to MSR_RoomPersistence.lua

return MSR.Shared
