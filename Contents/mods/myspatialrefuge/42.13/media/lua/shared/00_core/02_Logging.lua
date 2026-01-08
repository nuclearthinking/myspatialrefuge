-- 02_Logging - Debug logging utility, creates global L table
-- L.log/debug(tag, msg) - only when getDebug() is true
-- L.error/warn(tag, msg) - always prints
-- L.isDebug() - check debug state

if L and L._loaded then
    return L
end

L = L or {}
L._loaded = true

-- Lazy-evaluated debug state
local _debugEnabled, _debugChecked = nil, false

local function checkDebugEnabled()
    if not _debugChecked then
        _debugEnabled = getDebug and getDebug() or false
        _debugChecked = true
    end
    return _debugEnabled
end

--- Check if debug mode is enabled
--- @return boolean True if debug mode is on
function L.isDebug()
    return checkDebugEnabled()
end

--- Log a debug message with a tag prefix (only prints when debug enabled)
--- @param tag string Module/component name (e.g., "Transaction", "Server")
--- @param message string The message to log
function L.log(tag, message)
    if checkDebugEnabled() then
        print("[MSR-DEBUG] [" .. tag .. "] " .. tostring(message))
    end
end

--- Alias for log - debug message with tag prefix
--- @param tag string Module/component name
--- @param message string The message to log
L.debug = L.log

--- Log an error message (ALWAYS prints, regardless of debug mode)
--- @param tag string Module/component name
--- @param message string The error message to log
function L.error(tag, message)
    print("[MSR-ERROR] [" .. tag .. "] " .. tostring(message))
end

--- Log a warning message (ALWAYS prints, regardless of debug mode)
--- @param tag string Module/component name
--- @param message string The warning message to log
function L.warn(tag, message)
    print("[MSR-WARN] [" .. tag .. "] " .. tostring(message))
end

if MSR then MSR.Logging = L end

return L
