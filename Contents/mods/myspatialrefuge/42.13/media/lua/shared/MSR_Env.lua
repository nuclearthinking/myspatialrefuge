-- MSR_Env - Environment Helpers
-- Cached environment detection for server/client/singleplayer
-- Use these instead of calling isServer()/isClient() directly for performance

require "shared/MSR"

-- Prevent double-loading
if MSR.Env and MSR.Env._loaded then
    return MSR.Env
end

MSR.Env = {}
MSR.Env._loaded = true

-- Local alias for internal use
local Env = MSR.Env

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
function Env.invalidateCache()
    _cachedIsServer = nil
    _cachedIsClient = nil
    _cachedCanModify = nil
    _cacheValid = false
end

-- Check if running on server (cached after game is ready)
function Env.isServer()
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
            
            print("[MSR.Env] Environment: " .. envType .. 
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
function Env.isClient()
    if not _cacheValid and isGameReady() then
        -- Trigger cache population via isServer()
        Env.isServer()
    end
    
    if _cacheValid then
        return _cachedIsClient
    end
    return isClient()
end

-- Check if this context can modify data (server or singleplayer)
-- In MP: only server should modify shared ModData
-- In SP: client can modify (there is no server)
function Env.canModifyData()
    if not _cacheValid and isGameReady() then
        -- Trigger cache population via isServer()
        Env.isServer()
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
function Env.isCoopHost()
    return Env.isServer() and Env.isClient()
end

-- Check if running in singleplayer
-- Singleplayer: isServer() = true, isClient() = false
function Env.isSingleplayer()
    return Env.isServer() and not Env.isClient()
end

-- Check if running as dedicated server (no local player)
-- Same signature as singleplayer, but we can't distinguish without checking for connected clients
function Env.isDedicatedServer()
    -- Note: This returns same as isSingleplayer() - both have isServer=true, isClient=false
    -- To truly distinguish, you'd need to check getOnlinePlayers() or similar
    return Env.isServer() and not Env.isClient()
end

-- Check if running as multiplayer client (NOT host/server)
function Env.isMultiplayerClient()
    return Env.isClient() and not Env.isServer()
end

-- Check if running in multiplayer (coop host or MP client)
function Env.isMultiplayer()
    return Env.isClient()
end

-- Check if this instance has server authority (can modify world/data authoritatively)
-- True for: Singleplayer, Dedicated Server, Coop Host
function Env.hasServerAuthority()
    return Env.isServer()
end

-- Check if this instance needs to sync to clients (MP server or coop host)
function Env.needsClientSync()
    -- Only need to sync if we're the server AND there are clients
    -- Coop host: isServer=true, isClient=true (needs sync)
    -- Dedicated: isServer=true, isClient=false (needs sync)
    -- SP: isServer=true, isClient=false (but no clients to sync to)
    -- The isMultiplayer() check handles this
    return Env.isServer() and Env.isMultiplayer()
end

-----------------------------------------------------------
-- Timestamp Helper
-----------------------------------------------------------

-- Get current timestamp with fallback
-- NOTE: os.time() does NOT exist in Kahlua, use PZ functions only
function Env.getTimestamp()
    if getTimestamp then
        return getTimestamp()
    elseif getTimestampMs then
        return math.floor(getTimestampMs() / 1000)
    end
    -- Fallback: return 0 (should never happen in PZ)
    return 0
end

return MSR.Env
