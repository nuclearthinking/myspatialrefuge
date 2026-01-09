-- 05_Config - Static configuration values and difficulty-scaled getters
-- All constants for refuge dimensions, timers, sprites, commands

require "shared/00_core/00_MSR"
require "shared/00_core/03_Difficulty"

if MSR.Config and MSR.Config._loaded then
    return MSR.Config
end

MSR.Config = {
    _loaded = true,
    
    -- Refuge coords: far NW corner, away from PZ map areas
    REFUGE_BASE_X = 1000,
    REFUGE_BASE_Y = 1000,
    REFUGE_BASE_Z = 0,
    REFUGE_SPACING = 50,
    
    TIERS = { -- size = radius * 2 + 1
        [0] = { radius = 1, size = 3, cores = 0, displayName = "3x3" },
        [1] = { radius = 2, size = 5, cores = 5, displayName = "5x5" },
        [2] = { radius = 3, size = 7, cores = 10, displayName = "7x7" },
        [3] = { radius = 4, size = 9, cores = 20, displayName = "9x9" },
        [4] = { radius = 5, size = 11, cores = 35, displayName = "11x11" },
        [5] = { radius = 6, size = 13, cores = 50, displayName = "13x13" },
        [6] = { radius = 7, size = 15, cores = 75, displayName = "15x15" },
        [7] = { radius = 8, size = 17, cores = 100, displayName = "17x17" },
        [8] = { radius = 9, size = 19, cores = 150, displayName = "19x19" }
    },
    MAX_TIER = 8,
    
    TELEPORT_COOLDOWN = 10,
    COMBAT_TELEPORT_BLOCK = 10,
    TELEPORT_CAST_TIME = 3,
    
    -- Encumbrance: penalty = (weightRatio - 1.0) * MULTIPLIER, capped at CAP
    ENCUMBRANCE_PENALTY_MULTIPLIER = 300,  -- seconds per 100% overload
    ENCUMBRANCE_PENALTY_CAP = 300,         -- max 5 min
    
    SPRITES = {
        WALL_WEST = "walls_exterior_house_01_0",
        WALL_NORTH = "walls_exterior_house_01_1",
        WALL_CORNER_NW = "walls_exterior_house_01_2",
        WALL_CORNER_SE = "walls_exterior_house_01_3",
        SACRED_RELIC = "myspatialrefuge_0",
        SACRED_RELIC_FALLBACK = "location_community_cemetary_01_11",
    },
    
    RELIC_STORAGE_CAPACITY = 20,
    RELIC_MOVE_COOLDOWN = 30,
    WALL_HEIGHT = 1,
    
    TRANSACTION_TIMEOUT_TICKS = 300,
    
    MODDATA_KEY = "MySpatialRefuge",
    REFUGES_KEY = "Refuges",
    
    CURRENT_DATA_VERSION = 5, -- v1:per-player v2:global v3:relic v4:upgrades v5:roomIds
    
    CORE_ITEM = "Base.MagicalCore",
    
    -- Upgrade IDs (must match upgrades.yaml and MSR_UpgradeData.lua)
    UPGRADES = {
        EXPAND_REFUGE = "expand_refuge",          -- hardcoded in MSR_UpgradeData
        CORE_STORAGE = "refuge_core_storage",     -- from upgrades.yaml
        FASTER_READING = "faster_reading",        -- from upgrades.yaml
        FASTER_CAST = "faster_refuge_cast",       -- from upgrades.yaml
        VEHICLE_TELEPORT = "vehicle_teleport",    -- from upgrades.yaml
    },
    
    COMMAND_NAMESPACE = "SpatialRefuge",
    COMMANDS = {
        REQUEST_MODDATA = "RequestModData",
        REQUEST_ENTER = "RequestEnter",
        REQUEST_EXIT = "RequestExit",
        REQUEST_MOVE_RELIC = "RequestMoveRelic",
        CHUNKS_READY = "ChunksReady",
        
        MODDATA_RESPONSE = "ModDataResponse",
        TELEPORT_TO = "TeleportTo",
        GENERATION_COMPLETE = "GenerationComplete",
        EXIT_READY = "ExitReady",
        MOVE_RELIC_COMPLETE = "MoveRelicComplete",
        CLEAR_ZOMBIES = "ClearZombies",
        ERROR = "Error",
        
        REQUEST_FEATURE_UPGRADE = "RequestFeatureUpgrade",
        FEATURE_UPGRADE_COMPLETE = "FeatureUpgradeComplete",
        FEATURE_UPGRADE_ERROR = "FeatureUpgradeError",
        SYNC_CLIENT_DATA = "SyncClientData" -- client→server for roomIds (client can't write ModData in MP)
    }
}

-- Dynamic getters (scaled by global D)

function MSR.Config.getCastTime()
    return D.cooldown(MSR.Config.TELEPORT_CAST_TIME)
end

function MSR.Config.getCastTimeTicks()
    return MSR.Config.getCastTime() * 60
end

function MSR.Config.getTeleportCooldown()
    return D.cooldown(MSR.Config.TELEPORT_COOLDOWN)
end

function MSR.Config.getCombatBlockTime()
    return D.cooldown(MSR.Config.COMBAT_TELEPORT_BLOCK)
end

function MSR.Config.getEncumbrancePenaltyMultiplier()
    return MSR.Config.ENCUMBRANCE_PENALTY_MULTIPLIER -- D.negativeValue applied in Validation
end

function MSR.Config.getEncumbrancePenaltyCap()
    return D.negativeValue(MSR.Config.ENCUMBRANCE_PENALTY_CAP)
end

function MSR.Config.getRelicStorageCapacity(refugeData)
    local baseCapacity = MSR.Config.RELIC_STORAGE_CAPACITY
    
    if not refugeData then return baseCapacity end
    
    local upgrades = refugeData.upgrades
    if not upgrades then return baseCapacity end
    
    local storageLevel = upgrades[MSR.Config.UPGRADES.CORE_STORAGE] or 0
    if storageLevel <= 0 then return baseCapacity end
    
    -- Get capacity from upgrade data if available
    if MSR.UpgradeData and MSR.UpgradeData.getLevelEffects then
        local effects = MSR.UpgradeData.getLevelEffects(MSR.Config.UPGRADES.CORE_STORAGE, storageLevel)
        if effects and effects.relicStorageCapacity then
            return effects.relicStorageCapacity
        end
    end
    
    return baseCapacity
end

return MSR.Config
