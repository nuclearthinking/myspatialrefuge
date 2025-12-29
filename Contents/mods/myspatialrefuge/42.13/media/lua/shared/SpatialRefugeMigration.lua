-- Spatial Refuge Migration Module
-- Alembic-like pattern: MIGRATIONS[version] = migrationFunction
-- Version 1: per-player ModData (spatialRefuge_* fields)
-- Version 2: global ModData (MySpatialRefuge.Refuges[username])

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeData"

-- Prevent double-loading
if SpatialRefugeMigration and SpatialRefugeMigration._loaded then
    return SpatialRefugeMigration
end

SpatialRefugeMigration = SpatialRefugeMigration or {}
SpatialRefugeMigration._loaded = true

SpatialRefugeMigration.CURRENT_VERSION = 2

-----------------------------------------------------------
-- Environment Helpers
-----------------------------------------------------------

local _cachedIsServer = nil
local _cachedIsClient = nil
local _cachedCanModify = nil

local function getCachedIsServer()
    if _cachedIsServer == nil then
        _cachedIsServer = isServer()
    end
    return _cachedIsServer
end

local function getCachedIsClient()
    if _cachedIsClient == nil then
        _cachedIsClient = isClient()
    end
    return _cachedIsClient
end

local function canModifyData()
    if _cachedCanModify == nil then
        _cachedCanModify = getCachedIsServer() or (not getCachedIsClient())
    end
    return _cachedCanModify
end

-----------------------------------------------------------
-- Migration: v1 → v2
-- Old: per-player ModData (spatialRefuge_* fields)
-- New: global ModData (MySpatialRefuge.Refuges[username])
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
    
    local existingData = SpatialRefugeData.GetRefugeDataByUsername(username)
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
        local tierConfig = SpatialRefugeConfig.TIERS[oldTier]
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
        createdTime = oldCreatedTime or os.time(),
        lastExpanded = os.time(),
        dataVersion = 2
    }
    
    local success = SpatialRefugeData.SaveRefugeData(newRefugeData)
    if not success then
        return false, "Failed to save to global ModData"
    end
    
    if oldReturn and type(oldReturn) == "table" and oldReturn.x and oldReturn.y then
        SpatialRefugeData.SaveReturnPositionByUsername(username, oldReturn.x, oldReturn.y, oldReturn.z or 0)
    end
    
    clearLegacyFields(pmd)
    return true, "Migrated v1 → v2"
end

local MIGRATIONS = {
    [1] = migrate_1_to_2
}

-- Returns: 1 (legacy), 2+ (current), nil (new player)
function SpatialRefugeMigration.DetectVersion(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    local globalData = SpatialRefugeData.GetRefugeDataByUsername(username)
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

function SpatialRefugeMigration.NeedsMigration(player)
    local version = SpatialRefugeMigration.DetectVersion(player)
    if version == nil then return false end
    return version < SpatialRefugeMigration.CURRENT_VERSION
end

function SpatialRefugeMigration.MigratePlayer(player)
    if not player then 
        return false, "No player" 
    end
    
    if not canModifyData() then
        return false, "MP client - server handles migration"
    end
    
    local username = player:getUsername()
    if not username then 
        return false, "No username" 
    end
    
    local version = SpatialRefugeMigration.DetectVersion(player)
    if version == nil then
        return false, "No data to migrate"
    end
    
    if version >= SpatialRefugeMigration.CURRENT_VERSION then
        return false, "Already at current version"
    end
    
    local startVersion = version
    while version < SpatialRefugeMigration.CURRENT_VERSION do
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
    
    print("[Migration] " .. username .. ": v" .. startVersion .. " → v" .. version)
    return true, "Migrated v" .. startVersion .. " → v" .. version
end

function SpatialRefugeMigration.DebugPrintState(player)
    if not player then 
        print("[Migration] Debug: No player")
        return 
    end
    
    local username = player:getUsername() or "unknown"
    local pmd = player:getModData()
    local version = SpatialRefugeMigration.DetectVersion(player)
    
    print("[Migration] === " .. username .. " ===")
    print("  CURRENT_VERSION: " .. SpatialRefugeMigration.CURRENT_VERSION)
    print("  Detected version: " .. tostring(version))
    print("  Needs migration: " .. tostring(SpatialRefugeMigration.NeedsMigration(player)))
    
    if pmd then
        print("  Legacy v1: centerX=" .. tostring(pmd.spatialRefuge_centerX) .. ", tier=" .. tostring(pmd.spatialRefuge_tier))
    end
    
    local data = SpatialRefugeData.GetRefugeDataByUsername(username)
    if data then
        print("  Global v2: centerX=" .. tostring(data.centerX) .. ", tier=" .. tostring(data.tier) .. ", dataVersion=" .. tostring(data.dataVersion))
    else
        print("  Global: (none)")
    end
end

return SpatialRefugeMigration
