-- Spatial Refuge Environment Helpers
-- Cached environment detection for server/client/singleplayer
-- Use these instead of calling isServer()/isClient() directly for performance

-- Prevent double-loading
if SpatialRefugeEnv and SpatialRefugeEnv._loaded then
    return SpatialRefugeEnv
end

SpatialRefugeEnv = {}
SpatialRefugeEnv._loaded = true

-----------------------------------------------------------
-- Cached Environment Detection
-----------------------------------------------------------

local _cachedIsServer = nil
local _cachedIsClient = nil
local _cachedCanModify = nil
local _cacheValid = false

-- Check if game is ready for environment detection
local function isGameReady()
    -- getPlayer() returns nil during loading/menu
    return getPlayer and getPlayer() ~= nil
end

-- Invalidate cache (for testing or if game state changes)
function SpatialRefugeEnv.invalidateCache()
    _cachedIsServer = nil
    _cachedIsClient = nil
    _cachedCanModify = nil
    _cacheValid = false
end

-- Check if running on server (cached after game is ready)
function SpatialRefugeEnv.isServer()
    -- Only cache once game is ready, otherwise return fresh value
    if not _cacheValid and isGameReady() then
        _cachedIsServer = isServer()
        _cachedIsClient = isClient()
        _cachedCanModify = _cachedIsServer or (not _cachedIsClient)
        _cacheValid = true
        
        if getDebug and getDebug() then
            -- Determine environment type for logging
            local envType = "unknown"
            if _cachedIsServer and _cachedIsClient then
                envType = "coop_host"
            elseif _cachedIsServer and not _cachedIsClient then
                envType = "singleplayer_or_dedicated"
            elseif not _cachedIsServer and _cachedIsClient then
                envType = "mp_client"
            end
            
            print("[SpatialRefugeEnv] Environment: " .. envType .. 
                  " (isServer=" .. tostring(_cachedIsServer) .. 
                  ", isClient=" .. tostring(_cachedIsClient) .. 
                  ", canModify=" .. tostring(_cachedCanModify) .. ")")
        end
    end
    
    if _cacheValid then
        return _cachedIsServer
    end
    -- Fallback to direct call if game not ready
    return isServer()
end

-- Check if running on client (cached after game is ready)
function SpatialRefugeEnv.isClient()
    if not _cacheValid and isGameReady() then
        -- Trigger cache population via isServer()
        SpatialRefugeEnv.isServer()
    end
    
    if _cacheValid then
        return _cachedIsClient
    end
    return isClient()
end

-- Check if this context can modify data (server or singleplayer)
-- In MP: only server should modify shared ModData
-- In SP: client can modify (there is no server)
function SpatialRefugeEnv.canModifyData()
    if not _cacheValid and isGameReady() then
        -- Trigger cache population via isServer()
        SpatialRefugeEnv.isServer()
    end
    
    if _cacheValid then
        return _cachedCanModify
    end
    -- Fallback: compute directly
    return isServer() or (not isClient())
end

-- Environment types in Project Zomboid:
-- ┌─────────────────┬───────────┬───────────┐
-- │ Mode            │ isServer  │ isClient  │
-- ├─────────────────┼───────────┼───────────┤
-- │ Singleplayer    │ true      │ false     │
-- │ Dedicated Server│ true      │ false     │
-- │ Coop Host       │ true      │ true      │
-- │ MP Client       │ false     │ true      │
-- └─────────────────┴───────────┴───────────┘

-- Check if running as coop host (self-hosted multiplayer)
-- Coop host is unique: both isServer() AND isClient() are true
function SpatialRefugeEnv.isCoopHost()
    return SpatialRefugeEnv.isServer() and SpatialRefugeEnv.isClient()
end

-- Check if running in singleplayer
-- Singleplayer: isServer() = true, isClient() = false
function SpatialRefugeEnv.isSingleplayer()
    return SpatialRefugeEnv.isServer() and not SpatialRefugeEnv.isClient()
end

-- Check if running as dedicated server (no local player)
-- Same signature as singleplayer, but we can't distinguish without checking for connected clients
function SpatialRefugeEnv.isDedicatedServer()
    -- Note: This returns same as isSingleplayer() - both have isServer=true, isClient=false
    -- To truly distinguish, you'd need to check getOnlinePlayers() or similar
    return SpatialRefugeEnv.isServer() and not SpatialRefugeEnv.isClient()
end

-- Check if running as multiplayer client (NOT host/server)
function SpatialRefugeEnv.isMultiplayerClient()
    return SpatialRefugeEnv.isClient() and not SpatialRefugeEnv.isServer()
end

-- Check if running in multiplayer (coop host or MP client)
function SpatialRefugeEnv.isMultiplayer()
    return SpatialRefugeEnv.isClient()
end

-- Check if this instance has server authority (can modify world/data authoritatively)
-- True for: Singleplayer, Dedicated Server, Coop Host
function SpatialRefugeEnv.hasServerAuthority()
    return SpatialRefugeEnv.isServer()
end

-- Check if this instance needs to sync to clients (MP server or coop host)
function SpatialRefugeEnv.needsClientSync()
    -- Only need to sync if we're the server AND there are clients
    -- Coop host: isServer=true, isClient=true (needs sync)
    -- Dedicated: isServer=true, isClient=false (needs sync)
    -- SP: isServer=true, isClient=false (but no clients to sync to)
    -- The isMultiplayer() check handles this
    return SpatialRefugeEnv.isServer() and SpatialRefugeEnv.isMultiplayer()
end

-----------------------------------------------------------
-- Timestamp Helper
-----------------------------------------------------------

-- Get current timestamp with fallback
-- NOTE: os.time() does NOT exist in Kahlua, use PZ functions only
function SpatialRefugeEnv.getTimestamp()
    if getTimestamp then
        return getTimestamp()
    elseif getTimestampMs then
        return math.floor(getTimestampMs() / 1000)
    end
    -- Fallback: return 0 (should never happen in PZ)
    return 0
end

return SpatialRefugeEnv

