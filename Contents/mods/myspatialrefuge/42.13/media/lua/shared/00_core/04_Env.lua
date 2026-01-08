-- 04_Env - Cached environment detection (server/client/singleplayer)
-- Use Env.isServer() etc. instead of raw isServer() for performance

require "shared/00_core/00_MSR"
require "shared/00_core/02_Logging"

if MSR.Env and MSR.Env._loaded then
    return MSR.Env
end

MSR.Env = {}
MSR.Env._loaded = true

local Env = MSR.Env

local _cachedIsServer = nil
local _cachedIsClient = nil
local _cachedCanModify = nil
local _cacheValid = false

local function isGameReady()
    return getPlayer and getPlayer() ~= nil
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
            elseif _cachedIsServer and _cachedIsClient then
                envType = "coop_host"
            elseif _cachedIsServer and not _cachedIsClient then
                envType = "dedicated_server"
            else -- not _cachedIsServer and _cachedIsClient
                envType = "mp_client"
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

-- Environment types in Project Zomboid (verified from vanilla code):
-- ┌─────────────────┬───────────┬───────────┐
-- │ Mode            │ isServer  │ isClient  │
-- ├─────────────────┼───────────┼───────────┤
-- │ Singleplayer    │ false     │ false     │
-- │ Dedicated Server│ true      │ false     │
-- │ Coop Host       │ true      │ true      │
-- │ MP Client       │ false     │ true      │
-- └─────────────────┴───────────┴───────────┘

function Env.isCoopHost()
    return Env.isServer() and Env.isClient()
end

function Env.isSingleplayer()
    return not Env.isServer() and not Env.isClient()
end

function Env.isDedicatedServer()
    return Env.isServer() and not Env.isClient()
end

function Env.isMultiplayerClient()
    return Env.isClient() and not Env.isServer()
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
