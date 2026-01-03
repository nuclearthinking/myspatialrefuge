-- MSR_Logging - Centralized logging utility
-- Provides consistent debug logging across all MSR modules
--
-- This module has NO dependencies and can be loaded first (like MSR_KahluaCompat)
-- Creates global L table for logging, also exposed as MSR.Logging if MSR exists
--
-- USAGE: After this module loads, use `L` anywhere without require:
--   L.log("Tag", "message")     - Log with tag prefix (only when debug enabled)
--   L.debug("Tag", "message")   - Alias for log (clearer intent)
--   L.isDebug()                 - Check if debug mode is enabled

-- Return early if already loaded
if L and L._loaded then
    return L
end

-- Create global L table (no dependencies - can be loaded first)
L = L or {}
L._loaded = true

-- Lazy debug state - evaluated on first call
local _debugEnabled = nil
local _debugChecked = false

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

-- Also expose via MSR namespace for compatibility (if MSR exists)
if MSR then
    MSR.Logging = L
end

return L
