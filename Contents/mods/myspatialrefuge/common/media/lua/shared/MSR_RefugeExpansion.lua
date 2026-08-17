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
    local bounds = MSR.RefugeGeometry.GetLoadBounds(refugeData)
    if not bounds or not MSR.World.areBoundsChunksLoaded(
        bounds.minX,
        bounds.minY,
        bounds.maxX,
        bounds.maxY,
        refugeData.centerZ
    ) then
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
    MSR.RefugeGeometry.WarnIfTierConfigurationChanged("refuge expansion")
    if refugeData and refugeData.pendingExpansionRepair then
        return nil, "Previous expansion repair is still pending"
    end
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
        previous = refugeData,
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
    return reconcileWorld(player, operation)
end

--- Restore the authoritative pre-expansion refuge state. World boundaries are
--- reconciled immediately against that state so a failed purchase cannot be
--- applied later after its resources have been refunded.
function Expansion.Rollback(player, operation)
    local previous = operation and operation.previous
    if not previous then return false, "Missing pre-expansion refuge data" end
    if not MSR.Data.SaveRefugeData(previous) then
        return false, "Failed to restore pre-expansion refuge data"
    end

    local upperOk = MSR.BoundaryReconciler.ReconcileUpper(previous, operation.candidate)

    local upgrades = previous.upgrades or {}
    local basementOk = true
    local basementError = nil
    if (upgrades[MSR.Config.UPGRADES.REFUGE_BASEMENT] or 0) > 0 then
        basementOk, basementError = MSR.BasementGeneration.Generate(previous, player, operation.candidate)
    end

    MSR.RoomPersistence.ApplyCutaway(previous)
    local integrityReport = MSR.Integrity.ValidateAndRepair(
        previous,
        { source = "expansion_rollback", player = player }
    )
    local wallsRestored = integrityReport
        and integrityReport.walls
        and integrityReport.walls.reconciled == true
    if not upperOk and not wallsRestored then
        return false, "Failed to restore upper refuge boundary"
    end
    if not basementOk then
        return false, basementError or "Failed to restore basement"
    end
    return true, nil
end

--- If compensation cannot restore the old world, keep the paid candidate tier
--- authoritative and persist a repair marker. This prevents a refunded/free
--- expansion while allowing the loaded-chunk entry path to finish reconciliation.
function Expansion.PreserveCandidateForRepair(_player, operation, reason)
    local candidate = operation and operation.candidate
    if not candidate then return false, "Missing expansion candidate" end
    candidate.pendingExpansionRepair = {
        createdTime = K.time(),
        lastError = tostring(reason or "Expansion rollback failed"),
        attempts = 0,
    }
    if not MSR.Data.SaveRefugeData(candidate) then
        return false, "Failed to preserve expansion candidate"
    end
    LOG.warning("Preserved paid expansion candidate for deferred repair: %s", tostring(reason))
    operation.repairPending = true
    return true, operation
end

function Expansion.RepairPending(player, refugeData)
    local pending = refugeData and refugeData.pendingExpansionRepair or nil
    if not pending then return true, nil end

    local operation = { candidate = refugeData }
    local repaired, repairError = reconcileWorld(player, operation)
    if not repaired then
        pending.attempts = (tonumber(pending.attempts) or 0) + 1
        pending.lastAttemptTime = K.time()
        pending.lastError = tostring(repairError or "Expansion repair failed")
        MSR.Data.SaveRefugeData(refugeData)
        return false, repairError
    end

    refugeData.pendingExpansionRepair = nil
    if not MSR.Data.SaveRefugeData(refugeData) then
        return false, "Failed to clear expansion repair marker"
    end
    LOG.info("Completed pending expansion repair for %s", tostring(refugeData.username))
    return true, nil
end

-- Compatibility entry point for callers that do not use the upgrade coordinator.
function Expansion.Execute(player, refugeData)
    local operation, prepareError = Expansion.Prepare(player, refugeData)
    if not operation then return false, prepareError, nil end
    local committed, commitResult = Expansion.Commit(player, operation)
    if not committed then return false, commitResult, nil end
    local reconciled, reconcileError = Expansion.Reconcile(player, operation)
    if not reconciled then
        local rolledBack, rollbackError = Expansion.Rollback(player, operation)
        if not rolledBack then
            return false, rollbackError or reconcileError or "Expansion rollback failed", nil
        end
        return false, reconcileError or "Expansion reconciliation failed", nil
    end
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
