-- 04_Env - Cached environment detection (server/client/singleplayer)
-- Use Env.isServer() etc. instead of raw isServer() for performance

require "00_core/00_MSR"
require "00_core/02_Logging"

if MSR and MSR.Env and MSR.Env._loaded then
    return MSR.Env
end

MSR.Env = {}
MSR.Env._loaded = true

local Env = MSR.Env

local _cachedIsServer = nil
local _cachedIsClient = nil
local _cachedCanModify = nil
local _cacheValid = false

-- Check if game has initialized enough to determine environment
-- On dedicated server, getPlayer() is always nil, so we check if isServer/isClient exist
local function isGameReady()
    -- If we have a player, we're definitely ready (client/SP)
    if getPlayer and getPlayer() ~= nil then
        return true
    end
    -- On dedicated server, check if isServer() returns true (no player exists)
    if isServer and isServer() then
        return true
    end
    return false
end

function Env.invalidateCache()
    _cachedIsServer = nil
    _cachedIsClient = nil
    _cachedCanModify = nil
    _cacheValid = false
end

function Env.isServer()
    if not _cacheValid and isGameReady() then
        _cachedIsServer = isServer()
        _cachedIsClient = isClient()
        -- In SP: both false, can modify. In MP client: only server modifies.
        _cachedCanModify = (not _cachedIsServer and not _cachedIsClient) or _cachedIsServer
        _cacheValid = true
        
        if L.isDebug() then
            local envType
            if not _cachedIsServer and not _cachedIsClient then
                envType = "singleplayer"
            elseif _cachedIsServer then
                -- Server process (dedicated or coop host's server)
                envType = "server"
            else
                -- Client process (MP client or coop host's client)
                envType = "client"
            end
            
            L.debug("Env", "Environment: " .. envType .. 
                  " (isServer=" .. tostring(_cachedIsServer) .. 
                  ", isClient=" .. tostring(_cachedIsClient) .. 
                  ", canModify=" .. tostring(_cachedCanModify) .. ")")
        end
    end
    
    if _cacheValid then
        return _cachedIsServer
    end
    return isServer()
end

function Env.isClient()
    if not _cacheValid and isGameReady() then
        Env.isServer() -- Populates cache
    end
    
    if _cacheValid then
        return _cachedIsClient
    end
    return isClient()
end

-- SP or server can modify; MP client cannot
function Env.canModifyData()
    if not _cacheValid and isGameReady() then
        Env.isServer()
    end
    
    if _cacheValid then
        return _cachedCanModify
    end
    return (not isServer() and not isClient()) or isServer()
end

-- Environment types in Project Zomboid (verified from actual runtime observations):
-- 
-- Key insight: Even coop mode runs as SEPARATE PROCESSES. The host machine runs
-- both a server process and a client process independently.
--
-- ┌─────────────────────────┬───────────┬───────────┐
-- │ Process Context         │ isServer  │ isClient  │
-- ├─────────────────────────┼───────────┼───────────┤
-- │ Singleplayer            │ false     │ false     │  <- Single process, full authority
-- │ Server (dedicated/coop) │ true      │ false     │  <- Server process
-- │ Client (MP/coop)        │ false     │ true      │  <- Client process
-- └─────────────────────────┴───────────┴───────────┘
--
-- NOTE: The combination (true, true) does NOT occur in practice.
-- Even on coop host machine, server and client are separate processes.

--- @deprecated Likely never returns true in practice. Use hasServerAuthority() instead.
function Env.isCoopHost()
    -- Kept for backwards compatibility, but this condition never occurs
    -- in observed PZ behavior (even coop runs as separate processes)
    return Env.isServer() and Env.isClient()
end

function Env.isSingleplayer()
    return not Env.isServer() and not Env.isClient()
end

--- @deprecated Use isServerProcess() instead - clearer naming
function Env.isDedicatedServer()
    return Env.isServer() and not Env.isClient()
end

--- Returns true if this is a server process (dedicated or coop host's server)
function Env.isServerProcess()
    return Env.isServer()
end

--- Returns true if this is a client process in multiplayer
--- @deprecated Use isClientProcess() instead - clearer naming
function Env.isMultiplayerClient()
    return Env.isClient() and not Env.isServer()
end

--- Returns true if this is a client process (MP client or coop host's client)
function Env.isClientProcess()
    return Env.isClient()
end

function Env.isMultiplayer()
    return Env.isClient() or Env.isServer()
end

function Env.hasServerAuthority()
    -- In SP: local player has authority. In MP: only server.
    return Env.isSingleplayer() or Env.isServer()
end

-- Returns true when we need to sync data to clients (MP server contexts only)
function Env.needsClientSync()
    return Env.isServer()
end

function Env.getTimestamp()
    if getTimestamp then
        return getTimestamp()
    elseif getTimestampMs then
        return math.floor(getTimestampMs() / 1000)
    end
    return 0
end

return MSR.Env
