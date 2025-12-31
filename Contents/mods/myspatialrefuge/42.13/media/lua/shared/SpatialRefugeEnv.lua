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

-- Check if running on server (cached after first call)
function SpatialRefugeEnv.isServer()
    if _cachedIsServer == nil then
        _cachedIsServer = isServer()
    end
    return _cachedIsServer
end

-- Check if running on client (cached after first call)
function SpatialRefugeEnv.isClient()
    if _cachedIsClient == nil then
        _cachedIsClient = isClient()
    end
    return _cachedIsClient
end

-- Check if this context can modify data (server or singleplayer)
-- In MP: only server should modify shared ModData
-- In SP: client can modify (there is no server)
function SpatialRefugeEnv.canModifyData()
    if _cachedCanModify == nil then
        _cachedCanModify = SpatialRefugeEnv.isServer() or (not SpatialRefugeEnv.isClient())
    end
    return _cachedCanModify
end

-- Check if running in singleplayer
-- In PZ singleplayer: isServer() returns true, isClient() returns false
-- In MP dedicated server: isServer() = true, isClient() = false (but with connected clients)
-- In MP client: isServer() = false, isClient() = true
function SpatialRefugeEnv.isSingleplayer()
    -- Singleplayer: isServer() is true but isClient() is false
    -- This is the same as dedicated server, but in SP there's no network layer
    -- We detect SP by checking if isServer() is true AND isClient() is false
    -- Note: This means SP and dedicated server are treated similarly for data modification
    -- which is correct - both can modify GlobalModData
    return SpatialRefugeEnv.isServer() and not SpatialRefugeEnv.isClient()
end

-- Check if running as multiplayer client (NOT host/server)
function SpatialRefugeEnv.isMultiplayerClient()
    return SpatialRefugeEnv.isClient() and not SpatialRefugeEnv.isServer()
end

-- Check if running in multiplayer (either as server or client)
function SpatialRefugeEnv.isMultiplayer()
    -- True MP: there are connected clients (isClient somewhere returns true)
    -- For the purpose of this check, we consider it MP if isClient() is true
    -- Note: isServer() alone could be SP or dedicated server
    return SpatialRefugeEnv.isClient()
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

