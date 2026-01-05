require "shared/core/MSR"

-- Guard against double-loading: another file may create empty MSR.Config table
if MSR.Config and MSR.Config._loaded then
    return MSR.Config
end

MSR.Config = {
    _loaded = true,
    
    -- Refuge coordinates: far northwest corner, away from all PZ map areas
    -- (Muldraugh ~10500,9500 | West Point ~12000,7000 | Riverside ~6000,5500)
    REFUGE_BASE_X = 1000,
    REFUGE_BASE_Y = 1000,
    REFUGE_BASE_Z = 0,
    REFUGE_SPACING = 50,
    
    -- size = radius * 2 + 1
    TIERS = {
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
    
    -- Encumbrance penalty: allows teleporting while overloaded, but adds cooldown
    -- Formula: penalty = (weightRatio - 1.0) * MULTIPLIER, capped at CAP
    -- Example: 150% capacity = 0.5 * 300 = 150s = 2.5 min penalty
    ENCUMBRANCE_PENALTY_MULTIPLIER = 300,  -- seconds per 100% overload
    ENCUMBRANCE_PENALTY_CAP = 300,         -- max 5 minutes penalty
    
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
    
    -- v1: per-player | v2: global | v3: custom relic sprite | v4: upgrades table | v5: roomIds
    CURRENT_DATA_VERSION = 5,
    
    CORE_ITEM = "Base.MagicalCore",
    
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
        
        -- Client data sync (client -> server)
        -- Used for persisting client-discovered data (roomIds, etc.)
        -- Server stores in ModData; client can't write ModData directly in MP
        SYNC_CLIENT_DATA = "SyncClientData"
    }
}

local function getSandboxVar(key)
    return SandboxVars and SandboxVars.MySpatialRefuge and SandboxVars.MySpatialRefuge[key]
end

function MSR.Config.getCastTime()
    return getSandboxVar("CastTime") or MSR.Config.TELEPORT_CAST_TIME
end

function MSR.Config.getCastTimeTicks()
    return MSR.Config.getCastTime() * 60
end

function MSR.Config.getTeleportCooldown()
    return getSandboxVar("TeleportCooldown") or MSR.Config.TELEPORT_COOLDOWN
end

function MSR.Config.getCombatBlockTime()
    return getSandboxVar("CombatBlockTime") or MSR.Config.COMBAT_TELEPORT_BLOCK
end

function MSR.Config.isEncumbrancePenaltyEnabled()
    local val = getSandboxVar("EncumbrancePenaltyEnabled")
    if val == nil then return true end  -- Default enabled
    return val
end

function MSR.Config.getEncumbrancePenaltyMultiplier()
    return getSandboxVar("EncumbrancePenaltyMultiplier") or MSR.Config.ENCUMBRANCE_PENALTY_MULTIPLIER
end

function MSR.Config.getEncumbrancePenaltyCap()
    return getSandboxVar("EncumbrancePenaltyCap") or MSR.Config.ENCUMBRANCE_PENALTY_CAP
end

return MSR.Config
