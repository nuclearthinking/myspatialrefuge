-- Authoritative, idempotent refuge boundary reconciliation.

require "00_core/00_MSR"
require "helpers/World"
require "MSR_RefugeGeometry"

local Reconciler = MSR.register("BoundaryReconciler")
if not Reconciler then return MSR.BoundaryReconciler end

local LOG = L.logger("BoundaryReconciler")

local function boundaryKey(x, y, z, spriteName, isNorth)
    return table.concat({ tostring(x), tostring(y), tostring(z), spriteName, isNorth and "N" or "W" }, "|")
end

local function addSpec(list, map, x, y, z, spriteName, isNorth, level)
    local key = boundaryKey(x, y, z, spriteName, isNorth)
    local spec = {
        key = key,
        x = x,
        y = y,
        z = z,
        spriteName = spriteName,
        isNorth = isNorth,
        level = level,
    }
    table.insert(list, spec)
    map[key] = spec
end

local function buildExpected(refugeData, z, level, sprites)
    local tiles = MSR.RefugeGeometry.GetTileBounds(refugeData)
    local list, map = {}, {}

    for x = tiles.minX, tiles.maxX do
        addSpec(list, map, x, tiles.minY, z, sprites.north, true, level)
        addSpec(list, map, x, tiles.maxY + 1, z, sprites.north, true, level)
    end
    for y = tiles.minY, tiles.maxY do
        addSpec(list, map, tiles.minX, y, z, sprites.west, false, level)
        addSpec(list, map, tiles.maxX + 1, y, z, sprites.west, false, level)
    end
    addSpec(list, map, tiles.minX, tiles.minY, z, sprites.cornerNW, false, level)
    addSpec(list, map, tiles.maxX + 1, tiles.maxY + 1, z, sprites.cornerSE, false, level)

    return list, map
end

local function getObjectSpriteName(obj)
    local md = MSR.World.getModData(obj)
    if md and md.refugeBoundarySprite then return md.refugeBoundarySprite end
    if obj and obj.getSpriteName then return obj:getSpriteName() end
    local sprite = obj and obj.getSprite and obj:getSprite()
    return sprite and sprite:getName() or nil
end

local function getObjectKey(obj, square)
    local md = MSR.World.getModData(obj)
    if md and md.refugeBoundaryKey then return md.refugeBoundaryKey end
    local spriteName = getObjectSpriteName(obj)
    if not spriteName then return nil end
    local isNorth = obj.getNorth and obj:getNorth() == true or false
    return boundaryKey(square:getX(), square:getY(), square:getZ(), spriteName, isNorth)
end

local function stampBoundary(obj, refugeData, spec, shouldSync)
    local md = obj:getModData()
    md.isRefugeBoundary = true
    md.isProtectedRefugeObject = true
    md.canBeDisassembled = false
    md.refugeBoundarySprite = spec.spriteName
    md.refugeBoundaryKey = spec.key
    md.refugeSlotKey = MSR.RefugeGeometry.GetSlotKey(refugeData)
    md.boundaryLevel = spec.level
    md.isRefugeBasementObject = spec.level == "basement" or nil
    if shouldSync and obj.transmitModData and MSR.Env.needsClientSync() then obj:transmitModData() end
end

local function configureBoundary(obj)
    obj:setMaxHealth(999999)
    obj:setHealth(999999)
    obj:setCanBarricade(false)
    obj:setIsThumpable(false)
    obj:setBreakSound("none")
    obj:setIsDismantable(false)
    obj:setCanBePlastered(false)
    obj:setIsHoppable(false)
    if obj.setDestroyed then obj:setDestroyed(false) end
end

local function createBoundary(refugeData, spec)
    local square = MSR.World.getSquareSafe(spec.x, spec.y, spec.z)
    local cell = getCell()
    if not square or not square:getChunk() or not cell then return nil end

    local wall = IsoThumpable.new(cell, square, spec.spriteName, spec.isNorth, {})
    if not wall then return nil end
    configureBoundary(wall)
    stampBoundary(wall, refugeData, spec, false)
    if not MSR.World.addObject(square, wall, true) then return nil end
    if wall.transmitModData and MSR.Env.needsClientSync() then wall:transmitModData() end
    return wall
end

local function reconcileLevel(refugeData, z, level, sprites)
    if not refugeData or not MSR.Env.hasServerAuthority() then return false, nil end
    local slotKey = MSR.RefugeGeometry.GetSlotKey(refugeData)
    local extent = MSR.RefugeGeometry.GetMaximumDirectionalExtent()
    -- Chunks are addressed by X/Y. Sparse generated levels (notably the
    -- basement at z - 1) must not be required to contain every square before
    -- reconciliation can create their boundaries.
    if not MSR.World.areAreaChunksLoaded(refugeData.centerX, refugeData.centerY, refugeData.centerZ, extent) then
        return false, { deferred = true, created = 0, removed = 0, adopted = 0 }
    end

    local expectedList, expectedMap = buildExpected(refugeData, z, level, sprites)
    local retained = {}
    local report = { deferred = false, created = 0, removed = 0, adopted = 0 }

    MSR.World.iterateArea(refugeData.centerX, refugeData.centerY, z, extent, function(square)
        local boundaries = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
        for _, obj in ipairs(boundaries) do
            local md = MSR.World.getModData(obj)
            local owner = md and md.refugeSlotKey or nil
            if owner == nil or owner == slotKey then
                local key = getObjectKey(obj, square)
                local spec = key and expectedMap[key] or nil
                if spec and not retained[key] then
                    retained[key] = obj
                    configureBoundary(obj)
                    stampBoundary(obj, refugeData, spec, true)
                    if owner == nil then report.adopted = report.adopted + 1 end
                    if not MSR.World.hasCanonicalSprite(obj, spec.spriteName) then
                        MSR.World.bindSpriteByName(obj, spec.spriteName)
                        ---@diagnostic disable-next-line: undefined-field
                        if obj.transmitUpdatedSpriteToClients and MSR.Env.needsClientSync() then
                            ---@diagnostic disable-next-line: undefined-field
                            obj:transmitUpdatedSpriteToClients()
                        end
                    end
                elseif MSR.World.removeObject(square, obj, true) then
                    report.removed = report.removed + 1
                end
            end
        end
    end)

    for _, spec in ipairs(expectedList) do
        if not retained[spec.key] then
            local created = createBoundary(refugeData, spec)
            if not created then
                LOG.warning("Failed to create expected %s boundary at %d,%d,%d", level, spec.x, spec.y, spec.z)
                return false, report
            end
            retained[spec.key] = created
            report.created = report.created + 1
        end
    end

    return true, report
end

function Reconciler.ReconcileUpper(refugeData)
    local sprites = {
        north = MSR.Config.SPRITES.WALL_NORTH,
        west = MSR.Config.SPRITES.WALL_WEST,
        cornerNW = MSR.Config.SPRITES.WALL_CORNER_NW,
        cornerSE = MSR.Config.SPRITES.WALL_CORNER_SE,
    }
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    local combined = { deferred = false, created = 0, removed = 0, adopted = 0 }
    for level = 0, wallHeight - 1 do
        local success, report = reconcileLevel(refugeData, refugeData.centerZ + level, "upper", sprites)
        report = report or {}
        combined.deferred = combined.deferred or report.deferred == true
        combined.created = combined.created + (report.created or 0)
        combined.removed = combined.removed + (report.removed or 0)
        combined.adopted = combined.adopted + (report.adopted or 0)
        if not success then return false, combined end
    end
    return true, combined
end

function Reconciler.ReconcileBasement(refugeData)
    local sprites = {
        north = MSR.Config.BASEMENT.WALL_NORTH,
        west = MSR.Config.BASEMENT.WALL_WEST,
        cornerNW = MSR.Config.BASEMENT.WALL_CORNER_NW,
        cornerSE = MSR.Config.BASEMENT.WALL_CORNER_SE,
    }
    return reconcileLevel(refugeData, refugeData.centerZ - 1, "basement", sprites)
end

function Reconciler.RemoveSlotBoundaries(refugeData)
    if not refugeData or not MSR.Env.hasServerAuthority() then return false, 0 end
    local extent = MSR.RefugeGeometry.GetMaximumDirectionalExtent()
    local slotKey = MSR.RefugeGeometry.GetSlotKey(refugeData)
    local zLevels = { refugeData.centerZ, refugeData.centerZ - 1 }
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    for level = 1, wallHeight - 1 do table.insert(zLevels, refugeData.centerZ + level) end

    if not MSR.World.areAreaChunksLoaded(refugeData.centerX, refugeData.centerY, refugeData.centerZ, extent) then
        return false, 0
    end

    local removed = 0
    for _, z in ipairs(zLevels) do
        MSR.World.iterateArea(refugeData.centerX, refugeData.centerY, z, extent, function(square)
            local boundaries = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
            for _, obj in ipairs(boundaries) do
                local md = MSR.World.getModData(obj)
                if md and (md.refugeSlotKey == nil or md.refugeSlotKey == slotKey) then
                    if MSR.World.removeObject(square, obj, true) then removed = removed + 1 end
                end
            end
        end)
    end
    return true, removed
end

return Reconciler
