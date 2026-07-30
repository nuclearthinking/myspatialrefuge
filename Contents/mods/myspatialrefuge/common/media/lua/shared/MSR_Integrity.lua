require "00_core/00_MSR"
require "helpers/World"
require "MSR_BasementGeneration"


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

local function findRelicOnSquareBySprite(square, includeVanillaFallback)
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
                if spriteName == relicSprite or
                    (includeVanillaFallback and spriteName == fallbackSprite) then
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

    -- The custom sprite is unique to this mod and is safe to locate in the
    -- wider refuge area even when old ModData is incomplete.
    MSR.World.iterateArea(centerX, centerY, z, searchRadius, function(square)
        if foundRelic then return end
        local relic = findRelicOnSquareBySprite(square, false)
        if relic then foundRelic, foundBy = relic, "sprite" end
    end)

    if foundRelic then return foundRelic, foundBy end

    -- The fallback gravestone is a vanilla sprite players can place
    -- themselves. Only trust it at the expected relic square.
    local expectedSquare = MSR.World.getSquare(centerX, centerY, z)
    local fallbackRelic = findRelicOnSquareBySprite(expectedSquare, true)
    if fallbackRelic then return fallbackRelic, "sprite" end

    return foundRelic, foundBy
end

local function getContainerItemCount(obj)
    if not obj or not obj.getContainer then return 0 end
    local container = obj:getContainer()
    if not container then return 0 end
    local items = container:getItems()
    return items and K.size(items) or 0
end

-- Destructive operations must only consider objects positively owned by this
-- refuge. Sprite-only matches are recovery candidates, never duplicates.
local function findConfirmedRelicsInArea(centerX, centerY, z, radius, refugeId)
    if not centerX or not centerY or z == nil or not refugeId then return {} end

    local searchRadius = (radius or 1) + 2
    local foundRelics = {}

    MSR.World.iterateArea(centerX, centerY, z, searchRadius, function(square)
        MSR.World.iterateObjects(square, function(obj)
            local md = MSR.World.getModData(obj)
            if md and md.isSacredRelic and md.refugeId == refugeId then
                table.insert(foundRelics, {
                    obj = obj,
                    square = square,
                    itemCount = getContainerItemCount(obj),
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
        LOG.info("Added isSacredRelic flag")
    end

    if not md.refugeId or md.refugeId ~= refugeId then
        md.refugeId = refugeId
        repaired = true
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

    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC
    if md.relicSprite ~= expectedSprite then
        md.relicSprite = expectedSprite
        repaired = true
    end

    if repaired then
        report.relic.modDataRepaired = true
    end
    return repaired
end

local function validateRelicSprite(relic, report)
    if not relic then return false end

    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC
    local currentSprite = relic:getSpriteName()

    if not MSR.World.hasCanonicalSprite(relic, expectedSprite) then
        if MSR.World.bindSpriteByName(relic, expectedSprite) then
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

local function selectRelicToKeep(allRelics, refugeData)
    local keepIndex = 1
    local keepRelic = allRelics[1]

    if refugeData.relicX and refugeData.relicY then
        for i, relicData in ipairs(allRelics) do
            if relicData.x == refugeData.relicX and
                relicData.y == refugeData.relicY and
                (refugeData.relicZ == nil or relicData.z == refugeData.relicZ) then
                return i, relicData
            end
        end
    end

    for i, relicData in ipairs(allRelics) do
        if relicData.itemCount > keepRelic.itemCount then
            keepIndex = i
            keepRelic = relicData
        end
    end

    return keepIndex, keepRelic
end

local function transferRelicContents(sourceRelic, targetRelic)
    local sourceContainer = sourceRelic and sourceRelic.getContainer and sourceRelic:getContainer()
    local targetContainer = targetRelic and targetRelic.getContainer and targetRelic:getContainer()
    local sourceItems = sourceContainer and sourceContainer:getItems()
    local sourceCount = sourceItems and K.size(sourceItems) or 0

    if sourceCount == 0 then return true, 0 end
    if not sourceContainer or not targetContainer or not sourceItems then return false, 0 end

    local moved = 0
    local complete = true
    while K.size(sourceItems) > 0 do
        local before = K.size(sourceItems)
        local item = sourceItems:get(0)
        if not item then
            complete = false
            break
        end

        -- AddItem(existingItem) removes the item from its current container.
        -- Verify the source count as well: a duplicate item ID can make
        -- AddItem return an existing target item without moving this one.
        local added = targetContainer:AddItem(item)
        if not added or K.size(sourceItems) >= before then
            complete = false
            break
        end
        moved = moved + 1
    end

    if moved > 0 and MSR.Env.needsClientSync() and targetRelic.sendObjectChange then
        targetRelic:sendObjectChange("containers")
    end
    if moved > 0 and not complete and MSR.Env.needsClientSync() and sourceRelic.sendObjectChange then
        sourceRelic:sendObjectChange("containers")
    end

    return complete, moved
end

local function updateStoredRelicPosition(refugeData, relicData, report)
    if not relicData or not relicData.x or not relicData.y then return end
    if refugeData.relicX == relicData.x and
        refugeData.relicY == relicData.y and
        refugeData.relicZ == relicData.z then
        return
    end

    refugeData.relicX = relicData.x
    refugeData.relicY = relicData.y
    refugeData.relicZ = relicData.z
    table.insert(report.modData.fieldsRepaired, "relicPosition")
end

local function deduplicateConfirmedRelics(refugeData, report)
    if not refugeData or not MSR.Env.canModifyData() then return nil end

    local allRelics = findConfirmedRelicsInArea(
        refugeData.centerX,
        refugeData.centerY,
        refugeData.centerZ,
        refugeData.radius or 1,
        refugeData.refugeId
    )

    if #allRelics == 0 then return nil end

    local keepIndex, keepRelic = selectRelicToKeep(allRelics, refugeData)
    if #allRelics == 1 then
        updateStoredRelicPosition(refugeData, keepRelic, report)
        return keepRelic.obj
    end

    LOG.info("Found %d confirmed relics for %s", #allRelics, tostring(refugeData.refugeId))

    for i, relicData in ipairs(allRelics) do
        if i ~= keepIndex then
            local transferred, moved = transferRelicContents(relicData.obj, keepRelic.obj)
            report.relic.duplicateItemsTransferred = report.relic.duplicateItemsTransferred + moved

            if not transferred then
                report.relic.duplicatesSkipped = report.relic.duplicatesSkipped + 1
                LOG.warning(
                    "Kept duplicate relic at %d,%d,%d because its contents could not be transferred safely",
                    relicData.x, relicData.y, relicData.z
                )
            elseif removeObjectFromSquare(relicData.square, relicData.obj) then
                report.relic.duplicatesRemoved = report.relic.duplicatesRemoved + 1
            else
                report.relic.duplicatesSkipped = report.relic.duplicatesSkipped + 1
                LOG.warning(
                    "Kept empty duplicate relic at %d,%d,%d because object removal failed",
                    relicData.x, relicData.y, relicData.z
                )
            end
        end
    end

    updateStoredRelicPosition(refugeData, keepRelic, report)
    return keepRelic.obj
end

local function isBasementEnabled(refugeData)
    if not refugeData or not refugeData.upgrades then return false end
    local level = refugeData.upgrades[MSR.Config.UPGRADES.REFUGE_BASEMENT] or 0
    return level > 0
end

local function getRefugeZLevels(refugeData)
    local zLevels = { refugeData.centerZ }
    if isBasementEnabled(refugeData) then
        table.insert(zLevels, refugeData.centerZ - 1)
    end
    return zLevels
end

local function visitBoundaryObjects(refugeData, visitor)
    if not refugeData then return false end
    local stopped = false
    for _, z in ipairs(getRefugeZLevels(refugeData)) do
        MSR.World.iterateArea(
            refugeData.centerX,
            refugeData.centerY,
            z,
            (refugeData.radius or 1) + 2,
            function(square)
                if stopped then return end
                local walls = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
                for _, obj in ipairs(walls) do
                    if visitor(obj) then
                        stopped = true
                        return
                    end
                end
            end
        )
        if stopped then return true end
    end

    return false
end

local function hasNonCanonicalBoundarySprite(refugeData)
    return visitBoundaryObjects(refugeData, function(obj)
        local md = MSR.World.getModData(obj)
        local expectedSprite = md and md.refugeBoundarySprite
        return expectedSprite and not MSR.World.hasCanonicalSprite(obj, expectedSprite)
    end)
end

local function validateWalls(refugeData, report)
    if not refugeData then return 0 end

    local repaired = 0

    visitBoundaryObjects(refugeData, function(obj)
        local md = MSR.World.getModData(obj)
        local expectedSprite = md and md.refugeBoundarySprite
        if expectedSprite and not MSR.World.hasCanonicalSprite(obj, expectedSprite) then
            if MSR.World.bindSpriteByName(obj, expectedSprite) then
                repaired = repaired + 1
                if MSR.Env.needsClientSync() and obj.transmitUpdatedSpriteToClients then
                    obj:transmitUpdatedSpriteToClients()
                end
            else
                LOG.warning("Cannot rebind boundary sprite '%s'", tostring(expectedSprite))
            end
        end

        if obj.setIsThumpable then obj:setIsThumpable(false) end
        if obj.setIsHoppable then obj:setIsHoppable(false) end
        if obj.setCanBarricade then obj:setCanBarricade(false) end
        if obj.setIsDismantable then obj:setIsDismantable(false) end
        if obj.setCanBePlastered then obj:setCanBePlastered(false) end
        return false
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
            duplicatesSkipped = 0,
            duplicateItemsTransferred = 0,
            spriteLoadFailed = false
        },
        walls = { repaired = 0 },
        modData = { synced = false, fieldsRepaired = {} },
        errors = {}
    }
end

local function findRelicForRefuge(refugeData)
    local relicX = refugeData.relicX or refugeData.centerX
    local relicY = refugeData.relicY or refugeData.centerY
    local relicZ = refugeData.relicZ or refugeData.centerZ
    local relic, foundBy = findRelicReadOnly(
        relicX,
        relicY,
        relicZ,
        refugeData.radius or 1,
        refugeData.refugeId
    )

    if not relic and (relicX ~= refugeData.centerX or relicY ~= refugeData.centerY) then
        relic, foundBy = findRelicReadOnly(
            refugeData.centerX,
            refugeData.centerY,
            refugeData.centerZ,
            refugeData.radius or 1,
            refugeData.refugeId
        )
    end

    return relic, foundBy
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
    local relic = findRelicForRefuge(refugeData)

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
        if refugeData.pendingSpriteMigration ~= nil then
            refugeData.pendingSpriteMigration = nil
            table.insert(report.modData.fieldsRepaired, "pendingSpriteMigration")
        end
        validateWalls(refugeData, report)
    end

    -- Sync if anything was repaired
    if canRepair and (report.relic.modDataRepaired or report.relic.spriteRepaired or
            report.walls.repaired > 0 or #report.modData.fieldsRepaired > 0) then
        syncAll(refugeData, relic, report)
    end

    LOG.debug("Complete: relic=%s sprite=%s synced=%s",
        tostring(report.relic.found), tostring(report.relic.spriteRepaired), tostring(report.modData.synced))

    return report
end

---Explicitly remove confirmed duplicate relics for one refuge.
---Routine repair never calls this: deletion is opt-in and sprite-only recovery
---candidates are excluded. Contents must transfer before an object is removed.
function Integrity.DeduplicateRelics(refugeData, context)
    context = context or {}
    local report = createReport(context.source or "explicit_deduplication")

    if not refugeData then
        table.insert(report.errors, "No refuge data provided")
        report.success = false
        return report
    end
    if not refugeData.refugeId then
        table.insert(report.errors, "No refuge ID provided")
        report.success = false
        return report
    end
    if not MSR.Env.canModifyData() then
        table.insert(report.errors, "No authority to deduplicate relics")
        report.success = false
        return report
    end

    local relic = deduplicateConfirmedRelics(refugeData, report)
    report.relic.found = relic ~= nil

    if report.relic.duplicatesRemoved > 0 or #report.modData.fieldsRepaired > 0 then
        syncAll(refugeData, relic, report)
    end

    LOG.debug(
        "Deduplication complete: removed=%d skipped=%d items=%d",
        report.relic.duplicatesRemoved,
        report.relic.duplicatesSkipped,
        report.relic.duplicateItemsTransferred
    )
    return report
end

function Integrity.CheckNeedsRepair(refugeData)
    if not refugeData then return true end

    local relic, foundBy = findRelicForRefuge(refugeData)

    if not relic then return true end
    if foundBy == "sprite" then return true end -- Found by sprite = missing ModData

    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC
    if not MSR.World.hasCanonicalSprite(relic, expectedSprite) then return true end

    if hasNonCanonicalBoundarySprite(refugeData) then return true end

    return false
end

function Integrity.ClientSpriteRepair(relic)
    if not relic then return false end
    if isServer() then return false end

    local expectedSprite = MSR.Config.SPRITES.SACRED_RELIC

    if not MSR.World.hasCanonicalSprite(relic, expectedSprite) then
        if MSR.World.bindSpriteByName(relic, expectedSprite) then
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
    return findRelicForRefuge(refugeData)
end

function Integrity.FindRelicOnSquare(square, refugeId)
    return findRelicOnSquareByModData(square, refugeId)
end

function Integrity.FindRelicInArea(centerX, centerY, z, radius, refugeId)
    return findRelicReadOnly(centerX, centerY, z, radius, refugeId)
end

-----------------------------------------------------------
-- ModData Ready Hook (MP Client)
-----------------------------------------------------------

local MODDATA_READY_EVENT = MSR.Events.Names.MODDATA_READY

local function onModDataReady(args)
    if not MSR.Env.isClientProcess() then return end
    local player = args and args.player or getPlayer()
    if not player then return end
    if not MSR.Data.IsPlayerInRefugeCoords(player) then return end

    local refugeData = MSR.GetRefugeData(player)
    if refugeData and Integrity.CheckNeedsRepair(refugeData) then
        Integrity.ValidateAndRepair(refugeData, { source = "reconnect", player = player })
    end
end

MSR.Events.Custom.Add(MODDATA_READY_EVENT, onModDataReady)

return MSR.Integrity
