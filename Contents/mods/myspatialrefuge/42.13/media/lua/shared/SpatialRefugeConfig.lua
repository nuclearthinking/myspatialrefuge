-- Spatial Refuge System Configuration
-- Defines tier progression, coordinates, and gameplay constants

-- Prevent double-loading
if SpatialRefugeConfig then
    return SpatialRefugeConfig
end

SpatialRefugeConfig = {
    -- Global refuge coordinate space (far edge of world, isolated from all map content)
    -- PZ main areas: Muldraugh ~10500,9500 | West Point ~12000,7000 | Riverside ~6000,5500
    -- Using far northwest corner - well away from any mapped areas or expansion mods
    REFUGE_BASE_X = 1000,   -- Far west edge of world
    REFUGE_BASE_Y = 1000,   -- Far north edge of world
    REFUGE_BASE_Z = 0,
    REFUGE_SPACING = 50,    -- Tiles between refuges (increased for max tier size)
    
    -- Tier definitions: radius determines boundary, size is display name
    -- Starting size is 3x3 (tier 0), each tier adds +1 radius (+2 size)
    -- Core costs are high to make zombie hunting meaningful
    TIERS = {
        [0] = { radius = 1, size = 3, cores = 0, displayName = "3x3" },
        [1] = { radius = 2, size = 5, cores = 5, displayName = "5x5" },
        [2] = { radius = 3, size = 7, cores = 10, displayName = "7x7" },
        [3] = { radius = 4, size = 9, cores = 20, displayName = "9x9" },
        [4] = { radius = 5, size = 11, cores = 35, displayName = "11x11" },
        [5] = { radius = 6, size = 13, cores = 50, displayName = "13x13" },
        [6] = { radius = 7, size = 15, cores = 75, displayName = "15x15" }
    },
    
    -- Maximum tier (for validation)
    MAX_TIER = 6,
    
    -- Gameplay settings
    TELEPORT_COOLDOWN = 10,  -- seconds between teleports
    COMBAT_TELEPORT_BLOCK = 10,  -- seconds after damage before allowing teleport
    TELEPORT_CAST_TIME = 3,  -- seconds to cast teleport (interruptible)
    
    -- World generation sprites
    SPRITES = {
        FLOOR = "blends_natural_01_16",  -- Grass/dirt floor
        WALL_WEST = "walls_exterior_house_01_0",  -- West wall
        WALL_NORTH = "walls_exterior_house_01_1", -- North wall
        WALL_CORNER_NW = "walls_exterior_house_01_2",
        WALL_CORNER_SE = "walls_exterior_house_01_3",
        SACRED_RELIC = "location_community_cemetary_01_11"  -- Angel Gravestone (Sacred Relic) - note: game uses "cemetary" typo
    },
    
    -- Sacred Relic storage capacity (for future item teleportation feature)
    RELIC_STORAGE_CAPACITY = 20,
    
    -- Sacred Relic move cooldown in seconds
    RELIC_MOVE_COOLDOWN = 30,
    
    -- Wall height in z-levels
    WALL_HEIGHT = 1,
    
    -- ModData keys
    MODDATA_KEY = "MySpatialRefuge",
    REFUGES_KEY = "Refuges",
    
    -- Core item type
    CORE_ITEM = "Base.MagicalCore",
    
    -- Network command namespace (for multiplayer client-server communication)
    COMMAND_NAMESPACE = "SpatialRefuge",
    COMMANDS = {
        -- Client -> Server requests
        REQUEST_MODDATA = "RequestModData",   -- Client requests their refuge data on connect
        REQUEST_ENTER = "RequestEnter",       -- Client wants to enter refuge
        REQUEST_EXIT = "RequestExit",         -- Client wants to exit refuge
        REQUEST_UPGRADE = "RequestUpgrade",   -- Client wants to upgrade refuge
        REQUEST_MOVE_RELIC = "RequestMoveRelic", -- Client wants to move relic to corner
        CHUNKS_READY = "ChunksReady",         -- Client confirms chunks loaded after teleport
        
        -- Server -> Client responses (ModData)
        MODDATA_RESPONSE = "ModDataResponse", -- Server sends player's refuge data
        
        -- Server -> Client responses (Enter Flow)
        TELEPORT_TO = "TeleportTo",           -- Phase 1: Server tells client to teleport
        GENERATION_COMPLETE = "GenerationComplete",  -- Phase 2: Server finished creating structures
        
        -- Server -> Client responses (Other)
        EXIT_READY = "ExitReady",             -- Server confirms exit, provides return coords
        UPGRADE_COMPLETE = "UpgradeComplete", -- Server confirms upgrade done
        MOVE_RELIC_COMPLETE = "MoveRelicComplete", -- Server confirms relic moved
        CLEAR_ZOMBIES = "ClearZombies",       -- Server tells client to clear specific zombies by ID
        ERROR = "Error"                       -- Server reports an error
    }
}

return SpatialRefugeConfig
