-- 00_MSR - Global namespace for My Spatial Refuge mod
-- All modules register under MSR namespace to avoid conflicts
-- Creates globals: MSR, and helpers MSR.resolvePlayer, MSR.safePlayerCall
--
-- Load order (shared/00_core/): 00→01→02→03→04→05→06→99
-- Globals created: MSR (this), K (01), L (02), D (03)

if MSR and MSR._loaded then
    return MSR
end

MSR = MSR or {}
MSR._loaded = true

local function getModVersion()
    if not getModInfoByID then return "?" end
    
    local modInfo = getModInfoByID("myspatialrefuge") or getModInfoByID("\\myspatialrefuge")
    if modInfo and modInfo.getModVersion then
        local ok, version = pcall(function() return modInfo:getModVersion() end)
        if ok and version then return version end
    end
    
    return "?"
end

MSR.VERSION = getModVersion()

print("[MSR] My Spatial Refuge v" .. MSR.VERSION .. " initializing...")

-- K, L, D globals created by 01-03 modules after this file loads

-----------------------------------------------------------
-- Shared Utilities
-----------------------------------------------------------

--- Resolve a player reference to a live IsoPlayer object
--- Handles player index, IsoPlayer object, or stale references
--- @param player number|IsoPlayer Player index or IsoPlayer object
--- @return IsoPlayer|nil Resolved player object or nil if invalid
function MSR.resolvePlayer(player)
    if not player then return nil end
    
    -- If player is a number, get player by index
    if type(player) == "number" and getSpecificPlayer then
        return getSpecificPlayer(player)
    end
    
    -- If player is userdata/table with getPlayerNum, re-resolve to avoid stale refs
    if (type(player) == "userdata" or type(player) == "table") and player.getPlayerNum then
        local ok, num = pcall(function() return player:getPlayerNum() end)
        if ok and num ~= nil and getSpecificPlayer then
            local resolved = getSpecificPlayer(num)
            if resolved then return resolved end
        end
    end
    
    return player
end

--- Safely call a method on a player (guards against disconnected/null refs)
--- @param player any Player reference
--- @param methodName string Method name to call
--- @return any|nil Method result or nil if call fails
function MSR.safePlayerCall(player, methodName)
    local resolved = MSR.resolvePlayer(player)
    if not resolved then return nil end
    
    -- Use K.safeCall if available (loaded by MSR_00_KahluaCompat after this file)
    if K and K.safeCall then
        return K.safeCall(resolved, methodName)
    end
    
    -- Fallback: direct pcall
    local ok, method = pcall(function() return resolved[methodName] end)
    if not ok or not method then return nil end
    
    local callOk, result = pcall(function() return method(resolved) end)
    if not callOk then return nil end
    return result
end

return MSR
