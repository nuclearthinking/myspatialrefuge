-- 05_Config - Static configuration and difficulty-scaled getters
-- Assumes: MSR, MSR.Difficulty exist (loaded by 00_MSR.lua)

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
    REFUGE_GRID_SIZE = 20,
    REFUGE_DECAY_TRIGGER_PERCENT = 95,
    
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
    
    CURRENT_DATA_VERSION = 6, -- v1:per-player v2:global v3:relic v4:upgrades v5:roomIds v6:lastActiveTime
    
    CORE_ITEM = "Base.MagicalCore",
    
    -- XP Essence System
    ESSENCE_ENABLED = true,
    ESSENCE_RETENTION_PERCENT = 75,  -- % of earned XP recovered when absorbing essence
    ESSENCE_ITEM = "Base.MSR_ExperienceEssence",

    -- Refuge decay
    DECAY_ENABLED = true,
    DECAY_MIN_DAYS = 14,

    -- Upgrade IDs (must match upgrades.yaml)
    UPGRADES = {
        EXPAND_REFUGE = "expand_refuge",
        CORE_STORAGE = "refuge_core_storage",
        REFUGE_BASEMENT = "refuge_basement",
        FASTER_READING = "faster_reading",
        FASTER_CAST = "faster_refuge_cast",
        VEHICLE_TELEPORT = "vehicle_teleport",
        SANCTUARY_HEALING = "sanctuary_healing",
        RESTFUL_SLUMBER = "restful_slumber",
        INNER_PEACE = "inner_peace",
        MUSCLE_RECOVERY = "muscle_recovery",
        DEBUG_FAIL_UPGRADE = "debug_fail_upgrade",
    },
    
    COMMAND_NAMESPACE = "SpatialRefuge",
    COMMANDS = {
        REQUEST_MODDATA = "RequestModData",
        REQUEST_ENTER = "RequestEnter",
        REQUEST_EXIT = "RequestExit",
        REQUEST_MOVE_RELIC = "RequestMoveRelic",
        CHUNKS_READY = "ChunksReady",
        DEBUG_ADD_CORES = "DebugAddCores",
        
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
        SYNC_CLIENT_DATA = "SyncClientData", -- client→server for roomIds (client can't write ModData in MP)
        ADMIN_COMMAND = "AdminCommand",
        ADMIN_RESPONSE = "AdminResponse",

        -- XP Essence commands
        XP_ESSENCE_ABSORB = "XPEssenceAbsorb",
        XP_ESSENCE_APPLY = "XPEssenceApply"  -- Server→Client: apply XP locally
        
        -- Note: Death handling uses MSR.Events.Server system
        -- No separate death command needed
    },

    EVENTS = {
        PLAYER_DEATH = "MSR_PlayerDeath",
        PLAYER_DIED_IN_REFUGE = "MSR_PlayerDiedInRefuge",
        CORPSE_FOUND = "MSR_CorpseFound",
        CORPSE_PROTECTED = "MSR_CorpseProtected",
        ESSENCE_CREATED = "MSR_EssenceCreated",
        MODDATA_READY = "MSR_ModDataReady"
    },

    BASEMENT = {
        FLOOR_SPRITE = "floors_exterior_street_01_17",
        WALL_NORTH = "walls_commercial_03_49",
        WALL_WEST = "walls_commercial_03_48",
        WALL_CORNER_NW = "walls_commercial_03_51",
        WALL_CORNER_SE = "walls_commercial_03_51"
    },

    BASEMENT_STAIRWELLS = {
        {
            xOffset = -9,
            yOffset = -5,
            north = true,
            sprites = {
                "fixtures_stairs_01_8",
                "fixtures_stairs_01_9",
                "fixtures_stairs_01_10"
            }
        },
        {
            xOffset = -5,
            yOffset = -9,
            north = false,
            sprites = {
                "fixtures_stairs_01_0",
                "fixtures_stairs_01_1",
                "fixtures_stairs_01_2"
            }
        }
    }
}

-- Dynamic getters (difficulty-scaled via D)

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

function MSR.Config.getEssenceEnabled()
    local sandbox = SandboxVars and SandboxVars.MySpatialRefuge
    if sandbox and sandbox.EssenceEnabled ~= nil then
        return sandbox.EssenceEnabled
    end
    
    return MSR.Config.ESSENCE_ENABLED
end

function MSR.Config.getEssenceRetentionPercent()
    local baseValue = MSR.Config.ESSENCE_RETENTION_PERCENT
    local sandbox = SandboxVars and SandboxVars.MySpatialRefuge
    
    if sandbox and type(sandbox.EssenceRetentionPercent) == "number" then
        baseValue = sandbox.EssenceRetentionPercent
    end
    
    return math.min(100, D.positiveValue(math.max(0, baseValue)))
end

function MSR.Config.getRefugeGridSize()
    return math.max(1, tonumber(MSR.Config.REFUGE_GRID_SIZE) or 20)
end

function MSR.Config.getRefugeSlotCount()
    local gridSize = MSR.Config.getRefugeGridSize()
    return gridSize * gridSize
end

function MSR.Config.getDecayEnabled()
    local sandbox = SandboxVars and SandboxVars.MySpatialRefuge
    if sandbox and sandbox.DecayEnabled ~= nil then
        return sandbox.DecayEnabled
    end

    return MSR.Config.DECAY_ENABLED
end

function MSR.Config.getDecayMinDays()
    local sandbox = SandboxVars and SandboxVars.MySpatialRefuge
    local value = MSR.Config.DECAY_MIN_DAYS

    if sandbox and type(sandbox.DecayMinDays) == "number" then
        value = sandbox.DecayMinDays
    end

    value = math.floor(value)
    if value < 1 then
        value = 1
    end

    return value
end

function MSR.Config.getDecayTriggerPercent()
    local percent = tonumber(MSR.Config.REFUGE_DECAY_TRIGGER_PERCENT) or 95
    if percent < 1 then
        percent = 1
    elseif percent > 100 then
        percent = 100
    end
    return percent
end

function MSR.Config.getDecayTriggerSlotCount()
    local slotCount = MSR.Config.getRefugeSlotCount()
    local triggerSlots = math.floor(slotCount * (MSR.Config.getDecayTriggerPercent() / 100))
    if triggerSlots < 1 then
        triggerSlots = 1
    elseif triggerSlots > slotCount then
        triggerSlots = slotCount
    end
    return triggerSlots
end

function MSR.Config.getRelicStorageCapacity(refugeData)
    local baseCapacity = MSR.Config.RELIC_STORAGE_CAPACITY
    
    if not refugeData then return baseCapacity end
    
    local upgrades = refugeData.upgrades
    if not upgrades then return baseCapacity end
    
    local storageLevel = upgrades[MSR.Config.UPGRADES.CORE_STORAGE] or 0
    if storageLevel <= 0 then return baseCapacity end

    if MSR.UpgradeData and MSR.UpgradeData.getLevelEffects then
        local effects = MSR.UpgradeData.getLevelEffects(MSR.Config.UPGRADES.CORE_STORAGE, storageLevel)
        if effects and effects.relicStorageCapacity then
            return effects.relicStorageCapacity
        end
    end
    
    return baseCapacity
end

return MSR.Config
