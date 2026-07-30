-- MSR_Migration - Migration Module
-- Alembic-like pattern: MIGRATIONS[version] = migrationFunction
-- Version 1: per-player ModData (spatialRefuge_* fields)
-- Version 2: global ModData (MyMSR.Refuges[username])
-- Version 3: Custom relic sprite (myspatialrefuge_0)
-- Version 4: Added upgrades table for feature upgrades (faster_reading, etc.)
-- Version 5: Added roomIds table for room persistence (no breaking changes)
-- Version 6: Added lastActiveTime for refuge decay and reclamation

require "00_core/00_MSR"
require "helpers/World"

local Migration = MSR.register("Migration")
if not Migration then return MSR.Migration end


local Config = MSR.Config
local Data = MSR.Data
local Env = MSR.Env
local LOG = L.logger("Migration")

-- Use version from config to keep it in sync
Migration.CURRENT_VERSION = Config.CURRENT_DATA_VERSION

-----------------------------------------------------------
-- Migration: v1 -> v2
-- Old: per-player ModData (spatialRefuge_* fields)
-- New: global ModData (MyMSR.Refuges[username])
-----------------------------------------------------------

local function clearLegacyFields(pmd)
    pmd.spatialRefuge_id = nil
    pmd.spatialRefuge_centerX = nil
    pmd.spatialRefuge_centerY = nil
    pmd.spatialRefuge_centerZ = nil
    pmd.spatialRefuge_tier = nil
    pmd.spatialRefuge_radius = nil
    pmd.spatialRefuge_return = nil
    pmd.spatialRefuge_createdTime = nil
end

local function migrate_1_to_2(player)
    local username = player:getUsername()
    local pmd = player:getModData()
    if not pmd then return true, "No player ModData" end
    
    local existingData = Data.GetRefugeDataByUsername(username)
    if existingData then
        clearLegacyFields(pmd)
        return true, "Cleaned up legacy data (already migrated)"
    end
    
    local oldCenterX = pmd.spatialRefuge_centerX
    local oldCenterY = pmd.spatialRefuge_centerY
    
    if not oldCenterX or not oldCenterY then
        clearLegacyFields(pmd)
        return true, "No coordinates, cleaned up stale fields"
    end
    
    local oldCenterZ = pmd.spatialRefuge_centerZ or 0
    local oldTier = pmd.spatialRefuge_tier or 0
    local oldRadius = pmd.spatialRefuge_radius
    local oldReturn = pmd.spatialRefuge_return
    local oldCreatedTime = pmd.spatialRefuge_createdTime
    
    if not oldRadius then
        local tierConfig = Config.TIERS[oldTier]
        oldRadius = tierConfig and tierConfig.radius or 1
    end
    
    local newRefugeData = {
        refugeId = pmd.spatialRefuge_id or ("refuge_" .. username),
        username = username,
        centerX = oldCenterX,
        centerY = oldCenterY,
        centerZ = oldCenterZ,
        tier = oldTier,
        radius = oldRadius,
        createdTime = oldCreatedTime or K.time(),
        lastExpanded = K.time(),
        dataVersion = 2
    }
    
    local success = Data.SaveRefugeData(newRefugeData)
    if not success then
        return false, "Failed to save to global ModData"
    end
    
    if oldReturn and type(oldReturn) == "table" and oldReturn.x and oldReturn.y then
        Data.SaveReturnPositionByUsername(username, oldReturn.x, oldReturn.y, oldReturn.z or 0)
    end
    
    clearLegacyFields(pmd)
    return true, "Migrated v1 -> v2"
end

-----------------------------------------------------------
-- Migration: v2 -> v3
-- Update Sacred Relic sprite from angel gravestone to custom sprite
-----------------------------------------------------------

local function migrate_2_to_3(player)
    local username = player:getUsername()
    local refugeData = Data.GetRefugeDataByUsername(username)

    if not refugeData then
        return true, "No refuge data - nothing to migrate"
    end

    local newSpriteName = Config.SPRITES.SACRED_RELIC
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ or 0

    refugeData.dataVersion = 3
    refugeData.pendingSpriteMigration = nil

    if not centerX or not centerY then
        Data.SaveRefugeData(refugeData)
        return true, "No center coordinates - deferred to integrity repair"
    end

    local cell = getCell()
    if not cell then
        Data.SaveRefugeData(refugeData)
        return true, "Cell not loaded - deferred to integrity repair"
    end

    local square = cell:getGridSquare(centerX, centerY, centerZ)
    if not square then
        Data.SaveRefugeData(refugeData)
        return true, "Square not loaded - deferred to integrity repair"
    end

    local objects = square:getObjects()
    local relicFound = false

    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj then
            local md = obj:getModData()
            if md and md.isSacredRelic then
                relicFound = true
                if not MSR.World.hasCanonicalSprite(obj, newSpriteName) then
                    if MSR.World.bindSpriteByName(obj, newSpriteName) then
                        md.relicSprite = newSpriteName

                        if Env.needsClientSync() and obj.transmitModData then
                            obj:transmitModData()
                        end
                        if Env.needsClientSync() and obj.transmitUpdatedSpriteToClients then
                            obj:transmitUpdatedSpriteToClients()
                        end

                        LOG.info("Updated relic sprite for %s to %s", username, newSpriteName)
                    else
                        LOG.warning(
                            "Sprite '%s' is unavailable for %s - deferred to integrity repair",
                            newSpriteName,
                            username
                        )
                    end
                elseif md.relicSprite ~= newSpriteName then
                    md.relicSprite = newSpriteName
                end
                break
            end
        end
    end

    Data.SaveRefugeData(refugeData)

    return true, relicFound and "Checked relic sprite" or "Relic not found - deferred to integrity repair"
end

-----------------------------------------------------------
-- Migration: v3 -> v4
-- Add upgrades table for feature upgrades (faster_reading, etc.)
-----------------------------------------------------------

local function migrate_3_to_4(player)
    local username = player:getUsername()
    local refugeData = Data.GetRefugeDataByUsername(username)
    
    if not refugeData then
        return true, "No refuge data - nothing to migrate"
    end
    
    -- Add upgrades table if missing
    if not refugeData.upgrades then
        refugeData.upgrades = {}
        LOG.info("Added upgrades table for %s", username)
    end
    
    -- Update data version (hardcoded - each migration sets its target version)
    refugeData.dataVersion = 4
    Data.SaveRefugeData(refugeData)
    
    return true, "Migrated v3 -> v4 (added upgrades table)"
end

-----------------------------------------------------------
-- Migration: v4 -> v5
-- Added roomIds table for room persistence
-- No breaking changes - just version bump
-----------------------------------------------------------

local function migrate_4_to_5(player)
    local username = player:getUsername()
    local refugeData = Data.GetRefugeDataByUsername(username)
    
    if not refugeData then
        return true, "No refuge data - nothing to migrate"
    end
    
    -- roomIds will be populated automatically on first teleport exit
    -- No action needed here, just bump version
    
    refugeData.dataVersion = 5
    Data.SaveRefugeData(refugeData)
    
    return true, "Migrated v4 -> v5 (roomIds support)"
end

-----------------------------------------------------------
-- Migration: v5 -> v6
-- Add lastActiveTime for refuge decay and reclamation
-----------------------------------------------------------

local function migrate_5_to_6(player)
    local username = player:getUsername()
    local refugeData = Data.GetRefugeDataByUsername(username)

    if not refugeData then
        return true, "No refuge data - nothing to migrate"
    end

    refugeData.lastActiveTime = refugeData.lastActiveTime or refugeData.createdTime or K.time()
    refugeData.dataVersion = 6
    Data.SaveRefugeData(refugeData)

    return true, "Migrated v5 -> v6 (last active tracking)"
end

local MIGRATIONS = {
    [1] = migrate_1_to_2,
    [2] = migrate_2_to_3,
    [3] = migrate_3_to_4,
    [4] = migrate_4_to_5,
    [5] = migrate_5_to_6
}

-- Returns: 1 (legacy), 2+ (current), nil (new player)
function Migration.DetectVersion(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    local globalData = Data.GetRefugeDataByUsername(username)
    if globalData then
        -- Default 2: global data always has dataVersion since we stamp it on creation
        return globalData.dataVersion or 2
    end
    
    local pmd = player:getModData()
    if pmd then
        if pmd.spatialRefuge_id ~= nil or 
           pmd.spatialRefuge_centerX ~= nil or
           pmd.spatialRefuge_tier ~= nil then
            return 1
        end
    end
    
    return nil
end

function Migration.NeedsMigration(player)
    local version = Migration.DetectVersion(player)
    if version == nil then return false end
    return version < Migration.CURRENT_VERSION
end

function Migration.MigratePlayer(player)
    if not player then 
        return false, "No player" 
    end
    
    if not Env.canModifyData() then
        return false, "MP client - server handles migration"
    end
    
    local username = player:getUsername()
    if not username then 
        return false, "No username" 
    end
    
    local version = Migration.DetectVersion(player)
    if version == nil then
        return false, "No data to migrate"
    end
    
    if version >= Migration.CURRENT_VERSION then
        return false, "Already at current version"
    end
    
    local startVersion = version
    while version < Migration.CURRENT_VERSION do
        local migration = MIGRATIONS[version]
        if not migration then
            return false, "No migration for v" .. version
        end
        
        local success, msg = migration(player)
        if not success then
            return false, "Migration v" .. version .. " failed: " .. (msg or "unknown")
        end
        
        version = version + 1
    end
    
    LOG.info("%s: v%d -> v%d", username, startVersion, version)
    return true, "Migrated v" .. startVersion .. " -> v" .. version
end

function Migration.DebugPrintState(player)
    if not player then 
        LOG.debug("Debug: No player")
        return 
    end
    
    local username = player:getUsername() or "unknown"
    local pmd = player:getModData()
    local version = Migration.DetectVersion(player)
    
    LOG.debug("=== %s ===", username)
    LOG.debug("  CURRENT_VERSION: %d", Migration.CURRENT_VERSION)
    LOG.debug("  Detected version: %s", tostring(version))
    LOG.debug("  Needs migration: %s", tostring(Migration.NeedsMigration(player)))
    
    if pmd then
        LOG.debug("  Legacy v1: centerX=%s, tier=%s", tostring(pmd.spatialRefuge_centerX), tostring(pmd.spatialRefuge_tier))
    end
    
    local data = Data.GetRefugeDataByUsername(username)
    if data then
        LOG.debug("  Global v2: centerX=%s, tier=%s, dataVersion=%s", tostring(data.centerX), tostring(data.tier), tostring(data.dataVersion))
    else
        LOG.debug("  Global: (none)")
    end
end

return MSR.Migration
