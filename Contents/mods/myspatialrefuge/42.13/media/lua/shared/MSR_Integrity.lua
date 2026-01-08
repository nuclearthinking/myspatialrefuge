-- MSR_Integrity - Integrity Module
-- Unified validation and repair system for refuge structures
-- Consolidates all repair logic into a single, idempotent mechanism

require "shared/00_core/00_MSR"
require "shared/00_core/05_Config"
require "shared/00_core/04_Env"
require "shared/helpers/World"
require "shared/00_core/06_Data"

if MSR.Integrity and MSR.Integrity._loaded then
    return MSR.Integrity
end

MSR.Integrity = MSR.Integrity or {}
MSR.Integrity._loaded = true

local Integrity = MSR.Integrity

local _cachedRelicSprite = nil
local _cachedResolvedSprite = nil
local _cachedOldFallbackSprite = nil
local _spritesCached = false

local function getCachedRelicSprites()
    if not _spritesCached then
        _cachedRelicSprite = MSR.Config.SPRITES.SACRED_RELIC
        _cachedOldFallbackSprite = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK

        local spriteName = _cachedRelicSprite
        if getSprite and getSprite(spriteName) then
            _cachedResolvedSprite = spriteName
        else
            local digits = spriteName:match("_(%d+)$")
            if digits then
                local padded2 = spriteName:gsub("_(%d+)$", "_0" .. digits)
                if getSprite and getSprite(padded2) then
                    _cachedResolvedSprite = padded2
                else
                    local padded3 = spriteName:gsub("_(%d+)$", "_00" .. digits)
                    if getSprite and getSprite(padded3) then
                        _cachedResolvedSprite = padded3
                    end
                end
            end
            if not _cachedResolvedSprite then
                if _cachedOldFallbackSprite and getSprite and getSprite(_cachedOldFallbackSprite) then
                    _cachedResolvedSprite = _cachedOldFallbackSprite
                end
            end
        end
        _spritesCached = true
    end
    return _cachedRelicSprite, _cachedResolvedSprite, _cachedOldFallbackSprite
end

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

local function findRelicOnSquareBySprite(square, relicSprite, resolvedSprite, oldFallbackSprite)
    if not square then return nil end
    local objects = square:getObjects()
    if not K.isIterable(objects) then return nil end

    for _, obj in K.iter(objects) do
        if obj and obj.getSprite then
            local sprite = obj:getSprite()
            if sprite then
                local spriteName = sprite:getName()
                if spriteName == relicSprite or spriteName == resolvedSprite or
                    (oldFallbackSprite and spriteName == oldFallbackSprite) then
                    return obj
                end
            end
        end
    end
    return nil
end

local function findRelicReadOnly(centerX, centerY, z, radius, refugeId)
    local relicSprite, resolvedSprite, oldFallbackSprite = getCachedRelicSprites()
    local searchRadius = (radius or 1) + 1
    local foundRelic, foundBy = nil, nil

    -- Try ModData first
    MSR.World.iterateArea(centerX, centerY, z, searchRadius, function(square)
        if foundRelic then return end
        local relic = findRelicOnSquareByModData(square, refugeId)
        if relic then foundRelic, foundBy = relic, "moddata" end
    end)
    
    if foundRelic then return foundRelic, foundBy end

    -- Fallback: sprite matching for old saves
    MSR.World.iterateArea(centerX, centerY, z, searchRadius, function(square)
        if foundRelic then return end
        local relic = findRelicOnSquareBySprite(square, relicSprite, resolvedSprite, oldFallbackSprite)
        if relic then foundRelic, foundBy = relic, "sprite" end
    end)

    return foundRelic, foundBy
end

local function findAllRelicsInArea(centerX, centerY, z, radius, refugeId)
    local relicSprite, resolvedSprite, oldFallbackSprite = getCachedRelicSprites()
    local searchRadius = (radius or 1) + 2
    local foundRelics = {}

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
                    if spriteName == relicSprite or spriteName == resolvedSprite or
                        (oldFallbackSprite and spriteName == oldFallbackSprite) then
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
        L.log("Integrity", "Added isSacredRelic flag")
    end

    if not md.refugeId or md.refugeId ~= refugeId then
        md.refugeId = refugeId
        repaired = true
        report.relic.modDataRepaired = true
        L.log("Integrity", "Fixed refugeId: " .. tostring(refugeId))
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
    local oldFallbackSprite = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK
    local currentSprite = relic:getSpriteName()
    local repaired = false

    local spriteValid = false
    if currentSprite and relic.getSprite then
        local sprite = relic:getSprite()
        spriteValid = (sprite ~= nil and sprite:getName() == currentSprite)
    end

    local needsRepair = false
    local isOldFallback = false

    if not spriteValid then
        needsRepair = true
    elseif currentSprite ~= expectedSprite then
        if oldFallbackSprite and currentSprite == oldFallbackSprite then
            needsRepair = true
            isOldFallback = true
        else
            needsRepair = true
        end
    end

    if needsRepair then
        local newSprite = getSprite(expectedSprite)
        if newSprite then
            relic:setSprite(expectedSprite)
            local md = relic:getModData()
            md.relicSprite = expectedSprite
            repaired = true
            report.relic.spriteRepaired = true

            if not spriteValid then
                L.log("Integrity", "Repaired corrupted relic sprite")
            elseif isOldFallback then
                L.log("Integrity", "Migrated old fallback sprite to new: " ..
                    tostring(currentSprite) .. " -> " .. expectedSprite)
            else
                L.log("Integrity", "Migrated relic sprite: " ..
                    tostring(currentSprite) .. " -> " .. expectedSprite)
            end
        end
    end

    return repaired
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

    L.log("Integrity", "Found " .. #allRelics .. " relics - removing duplicates")

    local storedX = refugeData.relicX
    local storedY = refugeData.relicY
    local storedZ = refugeData.relicZ

    local keepIndex = 1
    local keepRelic = allRelics[1]
    local foundStoredPosition = false

    if storedX and storedY and storedZ then
        for i, relicData in ipairs(allRelics) do
            if relicData.x == storedX and relicData.y == storedY and relicData.z == storedZ then
                keepIndex = i
                keepRelic = relicData
                foundStoredPosition = true
                L.log("Integrity", "Keeping relic at stored position")
                break
            end
        end
    end

    if not foundStoredPosition then
        local maxItems = -1
        for i, relicData in ipairs(allRelics) do
            if relicData.itemCount > maxItems then
                maxItems = relicData.itemCount
                keepIndex = i
                keepRelic = relicData
            end
        end

        if maxItems > 0 then
            L.log("Integrity", "Keeping relic with " .. maxItems .. " items")
        end
    end

    local removed = 0
    for i, relicData in ipairs(allRelics) do
        if i ~= keepIndex then
            L.log("Integrity", "Removing duplicate at " .. relicData.x .. "," .. relicData.y)
            removeObjectFromSquare(relicData.square, relicData.obj)
            removed = removed + 1
        end
    end

    report.relic.duplicatesRemoved = removed

    if keepRelic and keepRelic.x and keepRelic.y then
        if refugeData.relicX ~= keepRelic.x or refugeData.relicY ~= keepRelic.y then
            refugeData.relicX = keepRelic.x
            refugeData.relicY = keepRelic.y
            refugeData.relicZ = keepRelic.z
            table.insert(report.modData.fieldsRepaired, "relicX")
            table.insert(report.modData.fieldsRepaired, "relicY")
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
    local scanRadius = radius + 2

    MSR.World.iterateArea(centerX, centerY, centerZ, scanRadius, function(square)
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

local function syncAll(refugeData, relic, context, report)
    if not MSR.Env.canModifyData() then
        report.modData.synced = false
        return false
    end

    if refugeData then
        MSR.Data.SaveRefugeData(refugeData)
    end

    if MSR.Env.needsClientSync() then
        if relic then
            if relic.transmitModData then
                relic:transmitModData()
            end
            if relic.transmitUpdatedSpriteToClients then
                relic:transmitUpdatedSpriteToClients()
            end
        end

        local envType = "server"
        if MSR.Env.isCoopHost() then
            envType = "coop_host"
        end
        L.log("Integrity", "Synced ModData (" .. envType .. ")")
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
            created = false,
            spriteRepaired = false,
            modDataRepaired = false,
            duplicatesRemoved = 0,
            position = nil
        },
        walls = {
            repaired = 0,
            created = 0
        },
        modData = {
            synced = false,
            fieldsRepaired = {}
        },
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

    L.log("Integrity", "ValidateAndRepair triggered by: " .. source)

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    local canRepair = MSR.Env.canModifyData()

    local relic
    if canRepair then
        relic = ensureSingleRelic(refugeData, report)
    end

    if not relic then
        local relicX = refugeData.relicX or centerX
        local relicY = refugeData.relicY or centerY
        local relicZ = refugeData.relicZ or centerZ
        relic = findRelicReadOnly(relicX, relicY, relicZ, radius, refugeId)

        if not relic and (relicX ~= centerX or relicY ~= centerY) then
            relic = findRelicReadOnly(centerX, centerY, centerZ, radius, refugeId)
        end
    end

    if relic then
        report.relic.found = true
        local square = relic:getSquare()
        if square then
            report.relic.position = {
                x = square:getX(),
                y = square:getY(),
                z = square:getZ()
            }
        end

        if canRepair then
            validateRelicModData(relic, refugeId, report)
            validateRelicSprite(relic, report)
            validateRelicProperties(relic)
        end
    else
        report.relic.found = false
        L.log("Integrity", "WARNING: No relic found in refuge")
    end

    if canRepair then
        validateWalls(refugeData, report)
    end

    if canRepair and (report.relic.modDataRepaired or report.relic.spriteRepaired or
            report.relic.duplicatesRemoved > 0 or #report.modData.fieldsRepaired > 0) then
        syncAll(refugeData, relic, context, report)
    end

    L.log("Integrity", "Complete: relic=" .. tostring(report.relic.found) ..
        " duplicates=" .. report.relic.duplicatesRemoved ..
        " walls=" .. report.walls.repaired ..
        " synced=" .. tostring(report.modData.synced))

    return report
end

function Integrity.CheckNeedSpriteRepair(obj)
    if not obj then return false end

    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC
    local oldFallbackSprite = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK

    local currentSprite = nil
    if obj.getSpriteName then
        currentSprite = obj:getSpriteName()
    elseif obj.getSprite and obj:getSprite() and obj:getSprite().getName then
        currentSprite = obj:getSprite():getName()
    end

    if not currentSprite then
        return true
    end

    if oldFallbackSprite and currentSprite == oldFallbackSprite then
        return true
    end

    if currentSprite ~= expectedSprite then
        return true
    end

    return false
end



function Integrity.CheckNeedsRepair(refugeData)
    if not refugeData then return true end

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId

    local relic, foundBy = findRelicReadOnly(centerX, centerY, centerZ, radius, refugeId)

    if not relic then
        return true
    end

    if foundBy == "sprite" then
        return true
    end

    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC
    local oldFallbackSprite = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK
    local currentSprite = relic:getSpriteName()
    if not currentSprite or currentSprite ~= expectedSprite then
        local sprite = relic:getSprite()
        if not sprite or not sprite:getName() then
            return true
        end
        if oldFallbackSprite and currentSprite == oldFallbackSprite then
            return true
        end
    end

    local allRelics = findAllRelicsInArea(centerX, centerY, centerZ, radius, refugeId)
    if #allRelics > 1 then
        return true
    end

    return false
end

function Integrity.ClientSpriteRepair(relic)
    if not relic then return false end
    if isServer() then return false end

    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC
    local oldFallbackSprite = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK
    local currentSprite = relic:getSpriteName()

    local spriteValid = false
    if currentSprite and relic.getSprite then
        local sprite = relic:getSprite()
        spriteValid = (sprite ~= nil and sprite:getName() == currentSprite)
    end

    local needsRepair = false
    local isOldFallback = false

    if not spriteValid then
        needsRepair = true
    elseif currentSprite ~= expectedSprite then
        needsRepair = true
        if oldFallbackSprite and currentSprite == oldFallbackSprite then
            isOldFallback = true
        end
    end

    if needsRepair then
        local newSprite = getSprite(expectedSprite)
        if newSprite then
            relic:setSprite(expectedSprite)

            local md = relic:getModData()
            if not md.isSacredRelic then
                md.isSacredRelic = true
            end
            md.relicSprite = expectedSprite

            if isOldFallback then
                L.log("Integrity", "Client sprite repair: migrated old fallback sprite")
            else
                L.log("Integrity", "Client sprite repair applied")
            end
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
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId

    local relic, foundBy = findRelicReadOnly(relicX, relicY, relicZ, radius, refugeId)

    if not relic then
        relic, foundBy = findRelicReadOnly(refugeData.centerX, refugeData.centerY, refugeData.centerZ, radius, refugeId)
    end

    return relic, foundBy
end

return MSR.Integrity
