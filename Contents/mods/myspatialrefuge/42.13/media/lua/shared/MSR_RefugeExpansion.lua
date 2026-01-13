-- MSR_RefugeExpansion - Unified expansion logic for SP and MP

require "00_core/00_MSR"
require "MSR_Shared"
require "MSR_Validation"
require "MSR_Integrity"

local LOG = L.logger("RefugeExpansion")

if MSR and MSR.RefugeExpansion and MSR.RefugeExpansion._loaded then
    return MSR.RefugeExpansion
end

MSR.RefugeExpansion = MSR.RefugeExpansion or {}
MSR.RefugeExpansion._loaded = true

local Expansion = MSR.RefugeExpansion

-----------------------------------------------------------
-- Chunk Validation
-----------------------------------------------------------

--- @param refugeData table
--- @param newRadius number
--- @return boolean success
--- @return string|nil errorMessage
function Expansion.ValidateChunksLoaded(refugeData, newRadius)
    if not refugeData then
        return false, "No refuge data"
    end
    
    local cell = getCell()
    if not cell then
        return false, "World not ready"
    end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    
    -- +1 to include perimeter walls
    local cornerOffsets = {
        {0, 0},
        {-newRadius - 1, -newRadius - 1},
        {newRadius + 1, -newRadius - 1},
        {-newRadius - 1, newRadius + 1},
        {newRadius + 1, newRadius + 1}
    }
    
    for _, offset in ipairs(cornerOffsets) do
        local x = centerX + offset[1]
        local y = centerY + offset[2]
        local square = cell:getGridSquare(x, y, centerZ)
        if not square or not square:getChunk() then
            return false, "Refuge area not fully loaded. Move around and try again."
        end
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Relic Repositioning
-----------------------------------------------------------

--- Uses OLD radius to find relic, moves to NEW radius corner
--- @param refugeData table Already updated with new radius
--- @param oldRadius number Radius BEFORE expansion
--- @return boolean success
--- @return string|nil errorMessage
function Expansion.RepositionRelic(refugeData, oldRadius)
    if not refugeData then
        return false, "No refuge data"
    end
    
    -- Search using OLD radius where relic currently is
    local relic = MSR.Shared.FindRelicInRefuge(
        refugeData.centerX, refugeData.centerY, refugeData.centerZ,
        oldRadius, refugeData.refugeId
    )
    
    if not relic then
        LOG.debug("Could not find relic to reposition")
        return false, "Relic not found"
    end
    
    local md = relic:getModData()
    if not md or not md.assignedCorner then
        LOG.debug("Relic has no assigned corner, not moving")
        return true, nil
    end
    
    local cornerDx = md.assignedCornerDx or 0
    local cornerDy = md.assignedCornerDy or 0
    local cornerName = md.assignedCorner
    
    local moveSuccess, moveMessage = MSR.Shared.MoveRelic(
        refugeData, cornerDx, cornerDy, cornerName, relic
    )
    
    if moveSuccess then
        local newRelicX = refugeData.centerX + (cornerDx * refugeData.radius)
        local newRelicY = refugeData.centerY + (cornerDy * refugeData.radius)
        refugeData.relicX = newRelicX
        refugeData.relicY = newRelicY
        refugeData.relicZ = refugeData.centerZ
        
        LOG.debug("Repositioned relic to %s at %s,%s", cornerName, newRelicX, newRelicY)
        return true, nil
    else
        LOG.debug("Failed to reposition relic: %s", tostring(moveMessage))
        return false, moveMessage
    end
end

-----------------------------------------------------------
-- Core Expansion
-----------------------------------------------------------

--- @param player IsoPlayer
--- @param refugeData table
--- @param options table|nil {skipChunkValidation=bool, skipSave=bool}
--- @return boolean success
--- @return string|nil errorMessage
--- @return table|nil resultData {oldRadius, newRadius, newTier, tierConfig}
function Expansion.Execute(player, refugeData, options)
    options = options or {}
    
    local canUpgrade, reason, tierConfig = MSR.Validation.CanUpgradeRefuge(player, refugeData)
    if not canUpgrade then
        return false, reason, nil
    end
    
    local currentTier = refugeData.tier or 0
    local newTier = currentTier + 1
    local oldRadius = refugeData.radius or 1
    local newRadius = tierConfig.radius
    
    LOG.debug("Execute: tier %d -> %d, radius %d -> %d", currentTier, newTier, oldRadius, newRadius)
    
    if not options.skipChunkValidation then
        local chunksOk, chunksErr = Expansion.ValidateChunksLoaded(refugeData, newRadius)
        if not chunksOk then
            return false, chunksErr, nil
        end
    end
    
    local expandSuccess = MSR.Shared.ExpandRefuge(refugeData, newTier, player)
    if not expandSuccess then
        return false, "Expansion failed", nil
    end
    
    local relicOk, relicErr = Expansion.RepositionRelic(refugeData, oldRadius)
    if not relicOk then
        -- Non-fatal: expansion succeeded, relic just didn't move
        LOG.debug("Warning: relic repositioning issue: %s", tostring(relicErr))
    end
    
    MSR.Integrity.ValidateAndRepair(refugeData, {
        source = "expansion",
        player = player
    })
    
    if not options.skipSave then
        MSR.Data.SaveRefugeData(refugeData)
    end
    
    if MSR.InvalidateBoundsCache then
        MSR.InvalidateBoundsCache(player)
    end
    if MSR.InvalidateRelicContainerCache then
        MSR.InvalidateRelicContainerCache()
    end
    
    local resultData = {
        oldRadius = oldRadius,
        newRadius = newRadius,
        newTier = newTier,
        tierConfig = tierConfig
    }
    
    L.debug("Expansion", "Execute complete: tier " .. newTier .. ", radius " .. newRadius)
    
    return true, nil, resultData
end

-----------------------------------------------------------
-- Convenience Functions
-----------------------------------------------------------

--- @param refugeData table
--- @return table|nil tierConfig
function Expansion.GetNextTierConfig(refugeData)
    if not refugeData then return nil end
    
    local currentTier = refugeData.tier or 0
    local nextTier = currentTier + 1
    
    if nextTier > MSR.Config.MAX_TIER then
        return nil
    end
    
    return MSR.Config.TIERS[nextTier]
end

--- @param refugeData table
--- @return boolean canExpand
--- @return string|nil reason
function Expansion.CanExpand(refugeData)
    if not refugeData then
        return false, "No refuge data"
    end
    
    local currentTier = refugeData.tier or 0
    if currentTier >= MSR.Config.MAX_TIER then
        return false, "Already at maximum tier"
    end
    
    local nextTierConfig = MSR.Config.TIERS[currentTier + 1]
    if not nextTierConfig then
        return false, "Invalid tier configuration"
    end
    
    return true, nil
end

return MSR.RefugeExpansion
