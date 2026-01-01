-- Spatial Refuge Migration Module
-- Alembic-like pattern: MIGRATIONS[version] = migrationFunction
-- Version 1: per-player ModData (spatialRefuge_* fields)
-- Version 2: global ModData (MySpatialRefuge.Refuges[username])
-- Version 3: Custom relic sprite (myspatialrefuge_0)
-- Version 4: Added upgrades table for feature upgrades (faster_reading, etc.)

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeData"
require "shared/SpatialRefugeEnv"

-- Prevent double-loading
if SpatialRefugeMigration and SpatialRefugeMigration._loaded then
    return SpatialRefugeMigration
end

SpatialRefugeMigration = SpatialRefugeMigration or {}
SpatialRefugeMigration._loaded = true

-- Use version from config to keep it in sync
SpatialRefugeMigration.CURRENT_VERSION = SpatialRefugeConfig.CURRENT_DATA_VERSION

-----------------------------------------------------------
-- Environment Helpers (delegated to SpatialRefugeEnv)
-----------------------------------------------------------

local function getCachedIsServer()
    return SpatialRefugeEnv.isServer()
end

local function canModifyData()
    return SpatialRefugeEnv.canModifyData()
end

-----------------------------------------------------------
-- Migration: v1 -> v2
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
    return true, "Migrated v1 -> v2"
end

-----------------------------------------------------------
-- Migration: v2 -> v3
-- Update Sacred Relic sprite from angel gravestone to custom sprite
-----------------------------------------------------------

local function migrate_2_to_3(player)
    local username = player:getUsername()
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    
    if not refugeData then
        return true, "No refuge data - nothing to migrate"
    end
    
    -- Get the new sprite name from config
    local newSpriteName = SpatialRefugeConfig.SPRITES.SACRED_RELIC
    local oldSpriteName = "location_community_cemetary_01_11"  -- Old angel gravestone
    
    -- Find the relic at the refuge center
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ or 0
    
    if not centerX or not centerY then
        return true, "No center coordinates - skipping sprite migration"
    end
    
    -- Try to find the square and relic
    local cell = getCell()
    if not cell then
        -- Cell not loaded yet - mark for later migration
        refugeData.pendingSpriteMigration = true
        refugeData.dataVersion = 3
        SpatialRefugeData.SaveRefugeData(refugeData)
        return true, "Cell not loaded - marked for deferred sprite migration"
    end
    
    local square = cell:getGridSquare(centerX, centerY, centerZ)
    if not square then
        -- Square not loaded - mark for later
        refugeData.pendingSpriteMigration = true
        refugeData.dataVersion = 3
        SpatialRefugeData.SaveRefugeData(refugeData)
        return true, "Square not loaded - marked for deferred sprite migration"
    end
    
    -- Find the relic on this square
    local objects = square:getObjects()
    local relicFound = false
    
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj then
            local md = obj:getModData()
            if md and md.isSacredRelic then
                -- Found the relic - update its sprite
                local currentSprite = obj:getSpriteName()
                
                if currentSprite == oldSpriteName or currentSprite ~= newSpriteName then
                    -- Update to new sprite
                    local newSprite = getSprite(newSpriteName)
                    if newSprite then
                        obj:setSprite(newSpriteName)
                        md.relicSprite = newSpriteName
                        
                        -- Transmit changes in MP
                        if getCachedIsServer() and obj.transmitModData then
                            obj:transmitModData()
                        end
                        if getCachedIsServer() and obj.transmitUpdatedSpriteToClients then
                            obj:transmitUpdatedSpriteToClients()
                        end
                        
                        print("[Migration] Updated relic sprite for " .. username .. ": " .. tostring(currentSprite) .. " -> " .. newSpriteName)
                    else
                        print("[Migration] Warning: New sprite '" .. newSpriteName .. "' not found - keeping old sprite")
                    end
                end
                
                relicFound = true
                break
            end
        end
    end
    
    if not relicFound then
        -- Relic might not exist yet or be on a different square
        refugeData.pendingSpriteMigration = true
    end
    
    -- Update data version
    refugeData.dataVersion = 3
    refugeData.pendingSpriteMigration = nil  -- Clear if we found and updated
    SpatialRefugeData.SaveRefugeData(refugeData)
    
    return true, relicFound and "Updated relic sprite" or "Relic not found - will update on next load"
end

-----------------------------------------------------------
-- Migration: v3 -> v4
-- Add upgrades table for feature upgrades (faster_reading, etc.)
-----------------------------------------------------------

local function migrate_3_to_4(player)
    local username = player:getUsername()
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    
    if not refugeData then
        return true, "No refuge data - nothing to migrate"
    end
    
    -- Add upgrades table if missing
    if not refugeData.upgrades then
        refugeData.upgrades = {}
        print("[Migration] Added upgrades table for " .. username)
    end
    
    -- Update data version (hardcoded - each migration sets its target version)
    refugeData.dataVersion = 4
    SpatialRefugeData.SaveRefugeData(refugeData)
    
    return true, "Migrated v3 -> v4 (added upgrades table)"
end

local MIGRATIONS = {
    [1] = migrate_1_to_2,
    [2] = migrate_2_to_3,
    [3] = migrate_3_to_4
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
    
    print("[Migration] " .. username .. ": v" .. startVersion .. " -> v" .. version)
    return true, "Migrated v" .. startVersion .. " -> v" .. version
end

-- Check and apply pending sprite migration when relic becomes accessible
-- Call this when player enters refuge or when relic is loaded
function SpatialRefugeMigration.CheckPendingSpriteMigration(username, square)
    if not username or not square then return false end
    
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    if not refugeData or not refugeData.pendingSpriteMigration then
        return false  -- No pending migration
    end
    
    local newSpriteName = SpatialRefugeConfig.SPRITES.SACRED_RELIC
    local objects = square:getObjects()
    
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj then
            local md = obj:getModData()
            if md and md.isSacredRelic then
                local newSprite = getSprite(newSpriteName)
                if newSprite then
                    obj:setSprite(newSpriteName)
                    md.relicSprite = newSpriteName
                    
                    if getCachedIsServer() and obj.transmitModData then
                        obj:transmitModData()
                    end
                    if getCachedIsServer() and obj.transmitUpdatedSpriteToClients then
                        obj:transmitUpdatedSpriteToClients()
                    end
                    
                    -- Clear pending flag
                    refugeData.pendingSpriteMigration = nil
                    SpatialRefugeData.SaveRefugeData(refugeData)
                    
                    print("[Migration] Deferred sprite update completed for " .. username)
                    return true
                end
            end
        end
    end
    
    return false
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
