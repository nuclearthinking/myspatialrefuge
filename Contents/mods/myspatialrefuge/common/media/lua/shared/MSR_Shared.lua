require "00_core/00_MSR"
require "helpers/World"
require "MSR_Integrity"
require "MSR_PlayerMessage"
require "MSR_RefugeGeometry"

local LOG = L.logger("Shared")

if MSR and MSR.Shared and MSR.Shared._loaded then
    return MSR.Shared
end

MSR.Shared = MSR.Shared or {}
MSR.Shared._loaded = true

local Shared = MSR.Shared


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
    return MSR.Integrity.FindRelicOnSquare(square, refugeId)
end

function Shared.FindRelicInRefuge(centerX, centerY, z, radius, refugeId)
    return MSR.Integrity.FindRelicInArea(centerX, centerY, z, radius, refugeId)
end

function Shared.SyncRelicPositionToModData(refugeData)
    if not refugeData then return false end
    if not MSR.Data.CanModifyData() then return false end
    if refugeData.relicX ~= nil then return false end

    local centerX, centerY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
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

    local centerX, centerY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId

    local validAnchor, anchor = MSR.RefugeGeometry.ValidateAnchor(cornerDx, cornerDy, cornerName)
    if not validAnchor then return false, Err.DESTINATION_BLOCKED end

    local targetX, targetY, targetZ = MSR.RefugeGeometry.GetRelicTarget(refugeData, anchor)

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
-- Deprecated (use MSR.Integrity.ValidateAndRepair)
-----------------------------------------------------------

--- @deprecated Delegates to MSR.Integrity.ValidateAndRepair
function Shared.RepairRefugeProperties(refugeData)
    if not refugeData then return 0 end
    local report = MSR.Integrity.ValidateAndRepair(refugeData, { source = "legacy_repair" })
    return report.walls.repaired + (report.relic.found and 1 or 0)
end

--- @deprecated Delegates to MSR.Integrity.DeduplicateRelics
function Shared.RemoveDuplicateRelics(_centerX, _centerY, _centerZ, _radius, _refugeId, refugeData)
    if not refugeData then return 0 end
    local report = MSR.Integrity.DeduplicateRelics(refugeData, { source = "legacy_duplicate_removal" })
    return report.relic.duplicatesRemoved
end

-- Room persistence moved to MSR_RoomPersistence.lua

return MSR.Shared
