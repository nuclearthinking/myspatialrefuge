-- Relic-anchored expansion planning and roll-forward world reconciliation.

require "00_core/00_MSR"
require "MSR_Validation"
require "MSR_Integrity"
require "MSR_RefugeGeometry"
require "MSR_BoundaryReconciler"
require "MSR_RefugeGeneration"
require "MSR_BasementGeneration"
require "MSR_RoomPersistence"

local Expansion = MSR.register("RefugeExpansion")
if not Expansion then return MSR.RefugeExpansion end

local LOG = L.logger("RefugeExpansion")

local function validateSlotChunks(refugeData)
    local extent = MSR.RefugeGeometry.GetMaximumDirectionalExtent()
    if not MSR.World.areAreaChunksLoaded(refugeData.centerX, refugeData.centerY, refugeData.centerZ, extent) then
        return false, "Refuge area not fully loaded. Move around and try again."
    end
    return true, nil
end

function Expansion.ValidateChunksLoaded(refugeData)
    if not refugeData then return false, "No refuge data" end
    if not getCell() then return false, "World not ready" end
    return validateSlotChunks(refugeData)
end

function Expansion.InferCurrentAnchor(refugeData)
    if not refugeData then return nil, nil, "No refuge data" end
    local relic = MSR.Integrity.FindRelic(refugeData)
    if not relic then return nil, nil, "Relic not found" end
    local square = relic:getSquare()
    if not square or not square:getChunk() then return nil, nil, "Relic location not loaded" end

    local anchor = MSR.RefugeGeometry.InferAnchor(refugeData, square:getX(), square:getY())
    if not anchor then
        return nil, relic, "Move the relic to the center or a refuge corner before expanding"
    end
    return anchor, relic, nil
end

function Expansion.Prepare(player, refugeData)
    local canUpgrade, reason, tierConfig = MSR.Validation.CanUpgradeRefuge(player, refugeData)
    if not canUpgrade then return nil, reason end

    local anchor, relic, anchorError = Expansion.InferCurrentAnchor(refugeData)
    if not anchor then return nil, anchorError end

    local currentTier = tonumber(refugeData.tier) or 0
    local newTier = currentTier + 1
    local plan, planError = MSR.RefugeGeometry.PlanExpansion(refugeData, tierConfig.radius, anchor)
    if not plan then return nil, planError end

    local square = relic:getSquare()
    local candidate = plan.candidate
    candidate.tier = newTier
    candidate.lastExpanded = K.time()
    candidate.dataVersion = MSR.Config.CURRENT_DATA_VERSION
    candidate.relicX = square:getX()
    candidate.relicY = square:getY()
    candidate.relicZ = square:getZ()

    if not MSR.RefugeGeometry.IsInsideSlotEnvelope(candidate) then
        return nil, "Expansion exceeds the refuge slot envelope"
    end

    local chunksOk, chunksError = validateSlotChunks(candidate)
    if not chunksOk then return nil, chunksError end

    return {
        candidate = candidate,
        anchor = anchor,
        oldRadius = plan.oldRadius,
        newRadius = plan.newRadius,
        newTier = newTier,
        tierConfig = tierConfig,
    }, nil
end

function Expansion.Commit(_player, operation)
    if not operation or not operation.candidate then return false, "Missing expansion candidate" end
    if not MSR.Data.SaveRefugeData(operation.candidate) then
        return false, "Failed to save refuge expansion"
    end
    return true, operation
end

local function reconcileWorld(player, operation)
    local refugeData = operation and operation.candidate
    if not refugeData then return false, "Missing committed refuge data" end

    local wallsOk = MSR.BoundaryReconciler.ReconcileUpper(refugeData)
    if not wallsOk then return false, "Upper boundary reconciliation deferred" end

    local centerX, centerY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
    MSR.RefugeGeneration.ClearTreesFromArea(
        centerX, centerY, refugeData.centerZ, refugeData.radius or 1, false
    )
    MSR.ZombieClear.ClearZombiesFromArea(
        centerX, centerY, refugeData.centerZ, refugeData.radius or 1, true, player
    )

    local upgrades = refugeData.upgrades or {}
    if (upgrades[MSR.Config.UPGRADES.REFUGE_BASEMENT] or 0) > 0 then
        local basementOk, basementError = MSR.BasementGeneration.Generate(refugeData, player)
        if not basementOk then return false, basementError end
    end

    MSR.RoomPersistence.ApplyCutaway(refugeData)
    MSR.Integrity.ValidateAndRepair(refugeData, { source = "expansion", player = player })
    return true, nil
end

function Expansion.Reconcile(player, operation)
    local success, errorMessage = reconcileWorld(player, operation)
    if not success then
        local playerRef = player
        local operationRef = operation
        MSR.delay(30, function()
            local retryPlayer = playerRef
            if retryPlayer and MSR.isPlayerValid and not MSR.isPlayerValid(retryPlayer) then
                retryPlayer = nil
            end
            local retryOk, retryError = reconcileWorld(retryPlayer, operationRef)
            if not retryOk then
                LOG.warning("Deferred expansion reconciliation remains incomplete: %s", tostring(retryError))
            end
        end)
    end
    return success, errorMessage
end

-- Compatibility entry point for callers that do not use the upgrade coordinator.
function Expansion.Execute(player, refugeData)
    local operation, prepareError = Expansion.Prepare(player, refugeData)
    if not operation then return false, prepareError, nil end
    local committed, commitResult = Expansion.Commit(player, operation)
    if not committed then return false, commitResult, nil end
    Expansion.Reconcile(player, operation)
    return true, nil, operation
end

function Expansion.GetNextTierConfig(refugeData)
    if not refugeData then return nil end
    return MSR.Config.TIERS[(tonumber(refugeData.tier) or 0) + 1]
end

function Expansion.CanExpand(refugeData)
    if not refugeData then return false, "No refuge data" end
    local tier = tonumber(refugeData.tier) or 0
    if tier >= MSR.Config.MAX_TIER then return false, "Already at maximum tier" end
    if not MSR.Config.TIERS[tier + 1] then return false, "Invalid tier configuration" end
    return true, nil
end

return Expansion
