require "00_core/00_MSR"
require "helpers/World"


local Integrity = MSR.register("Integrity")
if not Integrity then return MSR.Integrity end

local LOG = L.logger("Integrity")

local function removeObjectFromSquare(square, obj)
    return MSR.World.removeObject(square, obj, true)
end

local function findRelicOnSquareByModData(square, refugeId)
    if not square then return nil end
    local objects = square:getObjects()
    if not K.isIterable(objects) then return nil end

    for _, obj in K.iter(objects) do
        if obj then
            local md = obj:getModData()
            if md and md.isSacredRelic and md.refugeId == refugeId then
                return obj
            end
        end
    end
    return nil
end

local function findRelicOnSquareBySprite(square)
    if not square then return nil end
    local objects = square:getObjects()
    if not K.isIterable(objects) then return nil end

    local relicSprite = MSR.Config.SPRITES.SACRED_RELIC
    local fallbackSprite = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK

    for _, obj in K.iter(objects) do
        if obj and obj.getSprite then
            local sprite = obj:getSprite()
            if sprite then
                local spriteName = sprite:getName()
                if spriteName == relicSprite or spriteName == fallbackSprite then
                    return obj
                end
            end
        end
    end
    return nil
end

local function findRelicReadOnly(centerX, centerY, z, radius, refugeId)
    local searchRadius = (radius or 1) + 1
    local foundRelic, foundBy = nil, nil

    -- Try ModData first (preferred)
    MSR.World.iterateArea(centerX, centerY, z, searchRadius, function(square)
        if foundRelic then return end
        local relic = findRelicOnSquareByModData(square, refugeId)
        if relic then foundRelic, foundBy = relic, "moddata" end
    end)

    if foundRelic then return foundRelic, foundBy end

    -- Fallback: sprite matching for old saves
    MSR.World.iterateArea(centerX, centerY, z, searchRadius, function(square)
        if foundRelic then return end
        local relic = findRelicOnSquareBySprite(square)
        if relic then foundRelic, foundBy = relic, "sprite" end
    end)

    return foundRelic, foundBy
end

local function findAllRelicsInArea(centerX, centerY, z, radius, refugeId)
    local searchRadius = (radius or 1) + 2
    local foundRelics = {}
    local relicSprite = MSR.Config.SPRITES.SACRED_RELIC
    local fallbackSprite = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK

    MSR.World.iterateArea(centerX, centerY, z, searchRadius, function(square)
        MSR.World.iterateObjects(square, function(obj)
            local md = MSR.World.getModData(obj)
            local isRelic = false
            local foundBy = nil

            if md and md.isSacredRelic and md.refugeId == refugeId then
                isRelic = true
                foundBy = "moddata"
            elseif obj.getSprite then
                local sprite = obj:getSprite()
                if sprite then
                    local spriteName = sprite:getName()
                    if spriteName == relicSprite or spriteName == fallbackSprite then
                        isRelic = true
                        foundBy = "sprite"
                    end
                end
            end

            if isRelic then
                local itemCount = 0
                if obj.getContainer then
                    local container = obj:getContainer()
                    if container then
                        local items = container:getItems()
                        itemCount = items and K.size(items) or 0
                    end
                end

                table.insert(foundRelics, {
                    obj = obj,
                    square = square,
                    foundBy = foundBy,
                    itemCount = itemCount,
                    x = square:getX(),
                    y = square:getY(),
                    z = square:getZ()
                })
            end
        end)
    end)

    return foundRelics
end

local function validateRelicModData(relic, refugeId, report)
    if not relic then return false end

    local md = relic:getModData()
    local repaired = false

    if not md.isSacredRelic then
        md.isSacredRelic = true
        repaired = true
        report.relic.modDataRepaired = true
        LOG.info("Added isSacredRelic flag")
    end

    if not md.refugeId or md.refugeId ~= refugeId then
        md.refugeId = refugeId
        repaired = true
        report.relic.modDataRepaired = true
        LOG.info("Fixed refugeId: %s", tostring(refugeId))
    end

    if not md.isProtectedRefugeObject then
        md.isProtectedRefugeObject = true
        repaired = true
    end

    if md.canBeDisassembled ~= false then
        md.canBeDisassembled = false
        repaired = true
    end

    return repaired
end

local function validateRelicSprite(relic, report)
    if not relic then return false end

    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC
    local fallbackSprite = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK
    local currentSprite = relic:getSpriteName()

    -- Check if current sprite is valid
    local spriteValid = false
    if currentSprite and relic.getSprite then
        local sprite = relic:getSprite()
        spriteValid = (sprite ~= nil and sprite:getName() == currentSprite)
    end

    -- Determine if repair needed
    local needsRepair = not spriteValid or
        (currentSprite ~= expectedSprite and currentSprite == fallbackSprite)

    if needsRepair then
        local newSprite = getSprite(expectedSprite)
        if newSprite then
            relic:setSprite(expectedSprite)
            relic:getModData().relicSprite = expectedSprite
            report.relic.spriteRepaired = true
            LOG.info("Repaired relic sprite: %s -> %s", tostring(currentSprite), expectedSprite)
            return true
        else
            report.relic.spriteLoadFailed = true
            LOG.warning("Cannot load sprite '%s' - texture pack may not be loaded", expectedSprite)
        end
    end

    return false
end

local function validateRelicProperties(relic)
    if not relic then return false end

    if relic.setIsThumpable then relic:setIsThumpable(false) end
    if relic.setIsHoppable then relic:setIsHoppable(false) end
    if relic.setIsDismantable then relic:setIsDismantable(false) end
    if relic.setCanBarricade then relic:setCanBarricade(false) end
    if relic.setCanBePlastered then relic:setCanBePlastered(false) end

    return true
end

local function ensureSingleRelic(refugeData, report)
    if not refugeData then return nil end
    if not MSR.Env.canModifyData() then return nil end

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId

    local allRelics = findAllRelicsInArea(centerX, centerY, centerZ, radius, refugeId)

    if #allRelics == 0 then
        return nil
    end

    if #allRelics == 1 then
        return allRelics[1].obj
    end

    LOG.info("Found %d relics - removing duplicates", #allRelics)

    -- Find which relic to keep (prefer stored position, then most items)
    local keepIndex = 1
    local keepRelic = allRelics[1]

    if refugeData.relicX and refugeData.relicY then
        for i, relicData in ipairs(allRelics) do
            if relicData.x == refugeData.relicX and relicData.y == refugeData.relicY then
                keepIndex = i
                keepRelic = relicData
                break
            end
        end
    else
        local maxItems = -1
        for i, relicData in ipairs(allRelics) do
            if relicData.itemCount > maxItems then
                maxItems = relicData.itemCount
                keepIndex = i
                keepRelic = relicData
            end
        end
    end

    -- Remove duplicates
    local removed = 0
    for i, relicData in ipairs(allRelics) do
        if i ~= keepIndex then
            removeObjectFromSquare(relicData.square, relicData.obj)
            removed = removed + 1
        end
    end

    report.relic.duplicatesRemoved = removed

    -- Update stored position
    if keepRelic and keepRelic.x and keepRelic.y then
        if refugeData.relicX ~= keepRelic.x or refugeData.relicY ~= keepRelic.y then
            refugeData.relicX = keepRelic.x
            refugeData.relicY = keepRelic.y
            refugeData.relicZ = keepRelic.z
            table.insert(report.modData.fieldsRepaired, "relicPosition")
        end
    end

    return keepRelic.obj
end

local function validateWalls(refugeData, report)
    if not refugeData then return 0 end

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local repaired = 0

    MSR.World.iterateArea(centerX, centerY, centerZ, radius + 2, function(square)
        local walls = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
        for _, obj in ipairs(walls) do
            if obj.setIsThumpable then obj:setIsThumpable(false) end
            if obj.setIsHoppable then obj:setIsHoppable(false) end
            if obj.setCanBarricade then obj:setCanBarricade(false) end
            if obj.setIsDismantable then obj:setIsDismantable(false) end
            if obj.setCanBePlastered then obj:setCanBePlastered(false) end
            repaired = repaired + 1
        end
    end)

    report.walls.repaired = repaired
    return repaired
end

local function syncAll(refugeData, relic, report)
    if not MSR.Env.canModifyData() then
        report.modData.synced = false
        return false
    end

    if refugeData then
        MSR.Data.SaveRefugeData(refugeData)
    end

    if MSR.Env.needsClientSync() and relic then
        if relic.transmitModData then
            relic:transmitModData()
        end
        if relic.transmitUpdatedSpriteToClients then
            relic:transmitUpdatedSpriteToClients()
        end
    end

    report.modData.synced = true
    return true
end

local function createReport(source)
    return {
        success = true,
        source = source or "unknown",
        timestamp = K.time(),
        relic = {
            found = false,
            spriteRepaired = false,
            modDataRepaired = false,
            duplicatesRemoved = 0,
            spriteLoadFailed = false
        },
        walls = { repaired = 0 },
        modData = { synced = false, fieldsRepaired = {} },
        errors = {}
    }
end

function Integrity.ValidateAndRepair(refugeData, context)
    context = context or {}
    local source = context.source or "unknown"
    local report = createReport(source)

    if not refugeData then
        table.insert(report.errors, "No refuge data provided")
        report.success = false
        return report
    end

    LOG.debug("ValidateAndRepair triggered by: %s", source)

    local canRepair = MSR.Env.canModifyData()

    -- Find or deduplicate relics
    local relic
    if canRepair then
        relic = ensureSingleRelic(refugeData, report)
    end

    if not relic then
        local relicX = refugeData.relicX or refugeData.centerX
        local relicY = refugeData.relicY or refugeData.centerY
        local relicZ = refugeData.relicZ or refugeData.centerZ
        relic = findRelicReadOnly(relicX, relicY, relicZ, refugeData.radius or 1, refugeData.refugeId)

        if not relic and (relicX ~= refugeData.centerX or relicY ~= refugeData.centerY) then
            relic = findRelicReadOnly(refugeData.centerX, refugeData.centerY, refugeData.centerZ,
                refugeData.radius or 1, refugeData.refugeId)
        end
    end

    if relic then
        report.relic.found = true
        if canRepair then
            validateRelicModData(relic, refugeData.refugeId, report)
            validateRelicSprite(relic, report)
            validateRelicProperties(relic)
        end
    else
        report.relic.found = false
        LOG.warning("No relic found in refuge")
    end

    if canRepair then
        validateWalls(refugeData, report)
    end

    -- Sync if anything was repaired
    if canRepair and (report.relic.modDataRepaired or report.relic.spriteRepaired or
            report.relic.duplicatesRemoved > 0 or #report.modData.fieldsRepaired > 0) then
        syncAll(refugeData, relic, report)
    end

    LOG.debug("Complete: relic=%s sprite=%s synced=%s",
        tostring(report.relic.found), tostring(report.relic.spriteRepaired), tostring(report.modData.synced))

    return report
end

function Integrity.CheckNeedsRepair(refugeData)
    if not refugeData then return true end

    local relic, foundBy = findRelicReadOnly(
        refugeData.centerX, refugeData.centerY, refugeData.centerZ,
        refugeData.radius or 1, refugeData.refugeId)

    if not relic then return true end
    if foundBy == "sprite" then return true end -- Found by sprite = missing ModData

    -- Check sprite is correct
    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC
    local currentSprite = relic:getSpriteName()

    if not currentSprite or currentSprite ~= expectedSprite then
        -- Allow fallback sprite only if it has valid sprite object
        if currentSprite == MSR.Config.SPRITES.SACRED_RELIC_FALLBACK then
            return true -- Needs migration to new sprite
        end
        local sprite = relic:getSprite()
        if not sprite or not sprite:getName() then
            return true
        end
    end

    -- Check for duplicate relics
    local allRelics = findAllRelicsInArea(
        refugeData.centerX, refugeData.centerY, refugeData.centerZ,
        refugeData.radius or 1, refugeData.refugeId)
    if #allRelics > 1 then return true end

    return false
end

function Integrity.ClientSpriteRepair(relic)
    if not relic then return false end
    if isServer() then return false end

    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC
    local currentSprite = relic:getSpriteName()

    -- Check if repair needed
    local spriteValid = false
    if currentSprite and relic.getSprite then
        local sprite = relic:getSprite()
        spriteValid = (sprite ~= nil and sprite:getName() == currentSprite)
    end

    if not spriteValid or currentSprite ~= expectedSprite then
        local newSprite = getSprite(expectedSprite)
        if newSprite then
            relic:setSprite(expectedSprite)
            relic:getModData().isSacredRelic = true
            relic:getModData().relicSprite = expectedSprite
            LOG.info("Client sprite repair applied")
            return true
        end
    end

    return false
end

function Integrity.FindRelic(refugeData)
    if not refugeData then return nil, nil end

    local relicX = refugeData.relicX or refugeData.centerX
    local relicY = refugeData.relicY or refugeData.centerY
    local relicZ = refugeData.relicZ or refugeData.centerZ

    local relic, foundBy = findRelicReadOnly(relicX, relicY, relicZ, refugeData.radius or 1, refugeData.refugeId)

    if not relic then
        relic, foundBy = findRelicReadOnly(refugeData.centerX, refugeData.centerY, refugeData.centerZ,
            refugeData.radius or 1, refugeData.refugeId)
    end

    return relic, foundBy
end

return MSR.Integrity
