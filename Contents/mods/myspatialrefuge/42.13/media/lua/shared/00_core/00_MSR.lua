-- 00_MSR - Global namespace for My Spatial Refuge
-- Load order: 00→01→02→03→04→05→06→99 | Globals: MSR, K, L, D

MSR = MSR or {} -- Must be first line to prevent cascade failures

if MSR._loaded then
    return MSR
end

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

--- Resolve player reference to live IsoPlayer (handles index, object, or stale refs)
--- @param player number|IsoPlayer
--- @return IsoPlayer|nil
function MSR.resolvePlayer(player)
    if not player then return nil end
    
    if type(player) == "number" and getSpecificPlayer then
        return getSpecificPlayer(player)
    end
    
    -- Re-resolve to avoid stale references in MP
    if (type(player) == "userdata" or type(player) == "table") and player.getPlayerNum then
        local ok, num = pcall(function() return player:getPlayerNum() end)
        if ok and num ~= nil and getSpecificPlayer then
            local resolved = getSpecificPlayer(num)
            if resolved then return resolved end
        end
    end
    
    return player
end

--- Safely call method on player (guards against disconnected/null refs)
--- @param player any
--- @param methodName string
--- @return any|nil
function MSR.safePlayerCall(player, methodName)
    local resolved = MSR.resolvePlayer(player)
    if not resolved then return nil end
    
    if K and K.safeCall then
        return K.safeCall(resolved, methodName)
    end
    
    local ok, method = pcall(function() return resolved[methodName] end)
    if not ok or not method then return nil end
    
    local callOk, result = pcall(function() return method(resolved) end)
    if not callOk then return nil end
    return result
end

return MSR
