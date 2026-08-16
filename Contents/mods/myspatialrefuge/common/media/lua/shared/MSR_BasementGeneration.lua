require "00_core/00_MSR"
require "helpers/World"
require "MSR_RefugeGeometry"
require "MSR_BoundaryReconciler"

local Basement = MSR.register("BasementGeneration")
if not Basement then
    return MSR.BasementGeneration
end
local LOG = L.logger("BasementGeneration")

local FLOOR_SPRITE = MSR.Config.BASEMENT.FLOOR_SPRITE
local function isSquareClear(square)
    if not square then return false end
    if square:getTree() then return false end

    local objects = square:getObjects()
    if not K.isIterable(objects) then return true end

    for _, obj in K.iter(objects) do
        if obj then
            local objType = obj.getType and obj:getType() or nil
            local spriteName = (obj.getSpriteName and obj:getSpriteName()) or nil
            local textureName = (obj.getTextureName and obj:getTextureName()) or nil
            local md = obj.getModData and obj:getModData() or nil
            local name = spriteName or textureName
            local isOverlay = name and
            (string.find(name, "blends_natural") or string.find(name, "blends_grassoverlays") or string.find(name, "vegetation"))

            if not isOverlay then
                if md and md.isSacredRelic then return false end
                local props = obj.getProperties and obj:getProperties() or nil
                local isSolid = props and (props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans))
                local isRefugeObject = md and (md.isRefugeBoundary or md.isRefugeBasementObject)
                local isFloor = (objType == IsoObjectType.FloorTile) or (spriteName and spriteName == FLOOR_SPRITE)

                if isSolid and not isFloor and not isRefugeObject then return false end
            end
        end
    end

    return true
end

local function hasSolidBlockerOnSquare(square)
    if not square then return true end
    local objects = square:getObjects()
    if not K.isIterable(objects) then return false end

    for _, obj in K.iter(objects) do
        if obj then
            local spriteName = (obj.getSpriteName and obj:getSpriteName()) or nil
            local textureName = (obj.getTextureName and obj:getTextureName()) or nil
            local name = spriteName or textureName
            local isOverlay = name and
            (string.find(name, "blends_natural") or string.find(name, "blends_grassoverlays") or string.find(name, "vegetation"))
            if not isOverlay then
                local props = obj.getProperties and obj:getProperties() or nil
                local isSolid = props and (props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans))
                if isSolid then
                    local objType = obj.getType and obj:getType() or nil
                    local isFloor = (objType == IsoObjectType.FloorTile) or (spriteName and spriteName == FLOOR_SPRITE)
                    local md = obj.getModData and obj:getModData() or nil
                    local isRefugeObject = md and (md.isRefugeBoundary or md.isRefugeBasementObject)
                    if not isFloor and not isRefugeObject then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function ensureSquare(x, y, z)
    local cell = getCell()
    if not cell then return nil end

    local square = cell:getGridSquare(x, y, z)
    if square then return square end

    square = IsoGridSquare.new(cell, nil, x, y, z)
    cell:ConnectNewSquare(square, false)
    return square
end

local function getStairsFootprint(x, y, z, north)
    if north then
        return {
            { x, y,     z },
            { x, y - 1, z },
            { x, y - 2, z },
        }, { x, y - 1, z + 1 }
    end
    return {
        { x,     y, z },
        { x - 1, y, z },
        { x - 2, y, z },
    }, { x - 1, y, z + 1 }
end

local function isStairsFootprintClear(x, y, z, north)
    local squares, landing = getStairsFootprint(x, y, z, north)
    for _, pos in ipairs(squares) do
        local square = ensureSquare(pos[1], pos[2], pos[3])
        if not square then
            LOG.debug("Stairs footprint missing square: x=%d y=%d z=%d", pos[1], pos[2], pos[3])
            return false
        end
        if not isSquareClear(square) then return false end
    end
    if landing then
        local landingSquare = ensureSquare(landing[1], landing[2], landing[3])
        if landingSquare and not isSquareClear(landingSquare) then return false end
    end
    return true
end

local function placeFixtureStairsAt(x, y, z, north, sprites)
    if not sprites or #sprites < 3 then return false end

    local squares = getStairsFootprint(x, y, z, north)
    for i, pos in ipairs(squares) do
        local square = ensureSquare(pos[1], pos[2], pos[3])
        if not square then return false end
        local spriteName = sprites[i]
        if not spriteName then return false end
        local obj = IsoObject.new(getCell(), square, spriteName)
        if obj then
            local md = obj:getModData()
            md.isProtectedRefugeObject = true
            md.isRefugeBasementObject = true
            md.isRefugeBasementStairs = true
            if not MSR.World.addObject(square, obj, true) then
                return false
            end
        else
            return false
        end
    end
    return true
end

local function placeStairsAt(x, y, z, north, sprites)
    if not sprites or #sprites < 3 then return false end
    return placeFixtureStairsAt(x, y, z, north, sprites)
end

-- stairs markers removed (no teleportation)

local function getConfiguredStairwells(refugeData)
    if not MSR.Config then return nil end

    local wells = {}
    local areaCenterX, areaCenterY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
    if MSR.Config.BASEMENT_STAIRWELLS and #MSR.Config.BASEMENT_STAIRWELLS > 0 then
        for _, cfg in ipairs(MSR.Config.BASEMENT_STAIRWELLS) do
            if cfg.xOffset ~= nil and cfg.yOffset ~= nil then
                table.insert(wells, {
                    x = areaCenterX + cfg.xOffset,
                    y = areaCenterY + cfg.yOffset,
                    zTop = refugeData.centerZ,
                    zBottom = (refugeData.centerZ or 0) - 1,
                    north = cfg.north,
                    sprites = cfg.sprites
                })
            end
        end
    end

    return #wells > 0 and wells or nil
end

local function getRefugeStairsOnSquare(square)
    if not square then return {} end
    return MSR.World.findObjects(square, function(obj)
        local md = MSR.World.getModData(obj)
        return md ~= nil and md.isRefugeBasementStairs == true
    end)
end

local function hasCompleteStairwell(anchor)
    local footprint = getStairsFootprint(anchor.x, anchor.y, anchor.zBottom, anchor.north or false)
    for _, pos in ipairs(footprint) do
        local square = MSR.World.getSquareSafe(pos[1], pos[2], pos[3])
        if #getRefugeStairsOnSquare(square) == 0 then return false end
    end
    return true
end

local function reconcileExistingStairwell(anchor)
    local footprint = getStairsFootprint(anchor.x, anchor.y, anchor.zBottom, anchor.north or false)
    local complete = true
    for _, pos in ipairs(footprint) do
        local square = MSR.World.getSquareSafe(pos[1], pos[2], pos[3])
        local stairs = getRefugeStairsOnSquare(square)
        if #stairs == 0 then complete = false end
        if square then
            for index = 2, #stairs do
                local duplicate = stairs[index]
                if duplicate then MSR.World.removeObject(square, duplicate, true) end
            end
        end
    end
    if complete then return true end

    -- A failed fixture placement can leave one or two pieces behind. Remove
    -- only our marked pieces so the next idempotent attempt starts cleanly.
    for _, pos in ipairs(footprint) do
        local square = MSR.World.getSquareSafe(pos[1], pos[2], pos[3])
        if square then
            for _, stairs in ipairs(getRefugeStairsOnSquare(square)) do
                if stairs then MSR.World.removeObject(square, stairs, true) end
            end
        end
    end
    return false
end

function Basement.CheckStairwellAvailability(refugeData)
    if not refugeData then return false, 0 end
    local wells = getConfiguredStairwells(refugeData)
    if not wells or #wells == 0 then return false, 0 end

    local cell = getCell()
    if not cell then return false, 0 end

    local available = 0
    for _, well in ipairs(wells) do
        local blocked = false
        local footprint = getStairsFootprint(well.x, well.y, well.zTop, well.north or false)
        for _, pos in ipairs(footprint) do
            local square = cell:getGridSquare(pos[1], pos[2], well.zTop)
            if not square then
                blocked = true
                LOG.debug("Basement stairwell blocked: missing square at %d,%d,%d", pos[1], pos[2], well.zTop)
                break
            end
            if hasSolidBlockerOnSquare(square) then
                blocked = true
                LOG.debug("Basement stairwell blocked: solid object at %d,%d,%d", pos[1], pos[2], well.zTop)
                break
            end
        end
        if not blocked then
            available = available + 1
        end
    end

    return available > 0, available
end

local function ensureFloor(square)
    if not square then return false end
    local floor = square:getFloor()
    if floor and floor.getSprite then
        local sprite = floor:getSprite()
        if sprite and sprite:getName() == FLOOR_SPRITE then
            return true
        end
    end

    square:addFloor(FLOOR_SPRITE)
    floor = square:getFloor()
    if MSR.Env.isServer() and floor then
        square:transmitAddObjectToSquare(floor, -1)
    end
    square:RecalcAllWithNeighbours(true)
    if square.EnsureSurroundNotNull then square:EnsureSurroundNotNull() end
    if square.RecalcProperties then square:RecalcProperties() end
    return floor ~= nil
end

local function isBlockingUndergroundObject(obj, objType, spriteName, props)
    if not obj then return false end
    if spriteName and luautils and luautils.stringStarts(spriteName, "underground_") then
        return true
    end

    local isFloor = (objType == IsoObjectType.FloorTile) or (props and props:has(IsoFlagType.solidfloor))
    local isWall = (objType == IsoObjectType.wall)
    local isStairs = (objType == IsoObjectType.stairsTW or objType == IsoObjectType.stairsMW or
        objType == IsoObjectType.stairsNW or objType == IsoObjectType.stairsBN)

    if props and (props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans)) then
        return not (isFloor or isWall or isStairs)
    end

    return false
end

local function clearBasementSquare(square)
    if not square then return end
    local objects = square:getObjects()
    if not K.isIterable(objects) then return end
    local objList = K.toTable(objects)

    for _, obj in ipairs(objList) do
        if obj then
            local md = obj.getModData and obj:getModData() or nil
            if md and md.isRefugeBasementStairsMarker then
                MSR.World.removeObject(square, obj, false)
            elseif not (md and md.isRefugeBasementObject) then
                local objType = obj.getType and obj:getType() or nil
                local spriteName = (obj.getSpriteName and obj:getSpriteName()) or nil
                if not spriteName and obj.getSprite and obj:getSprite() then
                    local sprite = obj:getSprite()
                    spriteName = sprite and sprite:getName() or nil
                end
                local props = obj.getProperties and obj:getProperties() or nil

                if isBlockingUndergroundObject(obj, objType, spriteName, props) then
                    MSR.World.removeObject(square, obj, false)
                end
            end
        end
    end

    square:RecalcAllWithNeighbours(true)
    if square.EnsureSurroundNotNull then square:EnsureSurroundNotNull() end
    if square.RecalcProperties then square:RecalcProperties() end
end

local function removeFloorFromSquare(square)
    if not square then return end
    local objects = square:getObjects()
    if not K.isIterable(objects) then return end
    local objList = K.toTable(objects)

    for _, obj in ipairs(objList) do
        if obj then
            local isFloor = false
            if obj.getType and obj:getType() == IsoObjectType.FloorTile then
                isFloor = true
            elseif obj.isFloor then
                local ok, result = pcall(function() return obj:isFloor() end)
                isFloor = ok and result == true
            end
            if isFloor then
                MSR.World.removeObject(square, obj, false)
            end
        end
    end
end

local function clearSurfaceOverlays(square)
    if not square then return end
    local objects = square:getObjects()
    if not K.isIterable(objects) then return end
    local objList = K.toTable(objects)

    for _, obj in ipairs(objList) do
        if obj then
            local md = obj.getModData and obj:getModData() or nil
            if not (md and md.isRefugeBasementObject) then
                local spriteName = (obj.getSpriteName and obj:getSpriteName()) or nil
                if not spriteName and obj.getSprite and obj:getSprite() then
                    local sprite = obj:getSprite()
                    spriteName = sprite and sprite:getName() or nil
                end
                local textureName = (obj.getTextureName and obj:getTextureName()) or nil

                local name = spriteName or textureName
                if name and (string.find(name, "blends_grassoverlays") or string.find(name, "vegetation") or string.find(name, "grass")) then
                    MSR.World.removeObject(square, obj, false)
                end
            end
        end
    end
end

local function createStairwellOpening(anchorX, anchorY, zTop, north)
    local footprint = getStairsFootprint(anchorX, anchorY, zTop, north)

    for _, pos in ipairs(footprint) do
        local x, y, z = pos[1], pos[2], pos[3]
        local square = ensureSquare(x, y, z)
        clearSurfaceOverlays(square)
        removeFloorFromSquare(square)
        if square then
            square:RecalcAllWithNeighbours(true)
            if square.EnsureSurroundNotNull then square:EnsureSurroundNotNull() end
            if square.RecalcProperties then square:RecalcProperties() end
        end
    end
end

local function createBasementFloors(refugeData)
    local centerX, centerY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
    local centerZ = refugeData.centerZ - 1
    local radius = refugeData.radius or 1
    local created = 0
    local withFloor = 0

    for dx = -radius, radius do
        for dy = -radius, radius do
            local x = centerX + dx
            local y = centerY + dy
            local square = ensureSquare(x, y, centerZ)
            clearBasementSquare(square)
            if ensureFloor(square) then
                created = created + 1
            end
            if square and square:getFloor() then
                withFloor = withFloor + 1
            end
            if square and square.has and not square:has(IsoFlagType.solidfloor) then
                LOG.debug("Basement square missing solidfloor: x=%d y=%d z=%d", x, y, centerZ)
            end
        end
    end

    MSR.World.recalcArea(centerX, centerY, centerZ, radius)
    LOG.debug("Basement floors: created=%d withFloor=%d", created, withFloor)

    return created
end

function Basement.IsBasementPresent(refugeData)
    if not refugeData then return false end
    local centerZ = refugeData.centerZ or 0
    local basementZ = centerZ - 1
    local centerX, centerY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
    local square = MSR.World.getSquareSafe(centerX, centerY, basementZ)
    if not square or not square:getFloor() then return false end
    local anchors = getConfiguredStairwells(refugeData)
    if not anchors then return false end
    for _, anchor in ipairs(anchors) do
        if hasCompleteStairwell(anchor) then return true end
    end
    return false
end

-- NOTE: stairs marker teleport removed; stairs should behave naturally

function Basement.GetBasementZ(refugeData)
    return refugeData and (refugeData.centerZ or 0) - 1 or -1
end

local function debugTeleportToBasement(key)
    if key ~= Keyboard.KEY_F9 then return end
    local player = getPlayer()
    if not player then return end
    if not MSR.Data or not MSR.Data.IsPlayerInRefugeCoords or not MSR.Data.IsPlayerInRefugeCoords(player) then
        return
    end
    local refugeData = MSR.Data.GetRefugeData(player)
    if not refugeData then return end

    local basementZ = Basement.GetBasementZ(refugeData)
    local targetZ = (player:getZ() == basementZ) and refugeData.centerZ or basementZ
    local centerX, centerY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
    player:teleportTo(centerX, centerY, targetZ)
end

if not MSR._basementDebugTeleportRegistered then
    Events.OnKeyPressed.Add(debugTeleportToBasement)
    MSR._basementDebugTeleportRegistered = true
end

function Basement.Generate(refugeData, player)
    if not refugeData then return false, "Refuge data not found" end
    if MSR.Env.isMultiplayerClient() then
        return false, "Basement generation must run on server/host"
    end

    local centerX, centerY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local basementZ = centerZ - 1

    LOG.debug("Generate start: center=%d,%d z=%d basementZ=%d radius=%d player=%s",
        centerX, centerY, centerZ, basementZ, radius, player and player:getUsername() or "nil")

    local upperLoaded = MSR.World.areAreaChunksLoaded(centerX, centerY, centerZ, radius)
    LOG.debug("Surface chunk check: upperLoaded=%s", tostring(upperLoaded))
    if not upperLoaded then
        return false, "Refuge area not fully loaded. Move around and try again."
    end

    createBasementFloors(refugeData)

    local wallsOk = MSR.BoundaryReconciler.ReconcileBasement(refugeData)
    if not wallsOk then
        return false, "Basement boundary reconciliation deferred"
    end

    local anchors = getConfiguredStairwells(refugeData)

    if not anchors or #anchors == 0 then
        LOG.debug("No valid stairs anchor found for basement")
        return false, "No valid stairs location"
    end

    local placedAny = false
    for _, anchor in ipairs(anchors) do
        LOG.debug("Stairs anchor: x=%d y=%d topZ=%d bottomZ=%d north=%s",
            anchor.x, anchor.y, anchor.zTop, anchor.zBottom, tostring(anchor.north))

        if reconcileExistingStairwell(anchor) then
            createStairwellOpening(anchor.x, anchor.y, anchor.zTop, anchor.north or false)
            placedAny = true
        end

        local topSquare = MSR.World.getSquareSafe(anchor.x, anchor.y, anchor.zTop)
        local bottomSquare = ensureSquare(anchor.x, anchor.y, anchor.zBottom)
        if placedAny and hasCompleteStairwell(anchor) then
            LOG.debug("Basement stairs already complete at %d,%d", anchor.x, anchor.y)
        elseif not topSquare or not bottomSquare then
            LOG.debug("Stairs squares not loaded: topSquare=%s bottomSquare=%s",
                tostring(topSquare ~= nil), tostring(bottomSquare ~= nil))
        else
            ensureFloor(bottomSquare)

            local placedStairs = false
            local stairsNorth = false
            local north = anchor.north
            if north == nil then north = false end

            -- Check surface first; if blocked, skip this stairwell entirely (no opening).
            local topBlocked = false
            local topFootprint = getStairsFootprint(anchor.x, anchor.y, anchor.zTop, north)
            for _, pos in ipairs(topFootprint) do
                local square = getCell():getGridSquare(pos[1], pos[2], anchor.zTop)
                if not square or hasSolidBlockerOnSquare(square) then
                    topBlocked = true
                    LOG.debug("Basement stairwell skipped: surface blocked at %d,%d,%d", pos[1], pos[2], anchor.zTop)
                    break
                end
            end

            if not topBlocked then
                -- Check basement footprint, place stairs first, then cut opening.
                if isStairsFootprintClear(anchor.x, anchor.y, anchor.zBottom, north) then
                    placedStairs = placeStairsAt(anchor.x, anchor.y, anchor.zBottom, north, anchor.sprites)
                    stairsNorth = north
                end
                if placedStairs then
                    createStairwellOpening(anchor.x, anchor.y, anchor.zTop, stairsNorth)
                    LOG.debug("Basement stairs placed at %d,%d (north=%s)", anchor.x, anchor.y, tostring(stairsNorth))
                    placedAny = true
                elseif reconcileExistingStairwell(anchor) then
                    createStairwellOpening(anchor.x, anchor.y, anchor.zTop, north)
                    placedAny = true
                else
                    LOG.debug("Stairs placement failed at %d,%d", anchor.x, anchor.y)
                end
            end
        end
    end

    if placedAny then
        LOG.debug("Basement generated at z=%d with stairs", basementZ)
        return true, nil
    end

    return false, "Stairs placement failed"
end

return MSR.BasementGeneration
