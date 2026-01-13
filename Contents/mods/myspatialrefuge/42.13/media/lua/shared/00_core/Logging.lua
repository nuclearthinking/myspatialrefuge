-- 02_Logging - Optimized logging utility with minimal performance impact
-- Creates global L table
--
-- Output formats:
--   Normal:  [date][LEVEL][Tag] message
--   Debug:   [date][ms][f:frame][LEVEL][Tag] message
--
-- The [date] prefix is automatically added by writeLog() via ZLogger
--
-- API:
--   L.debug(tag, msg, ...)    - Debug message (only in debug mode)
--   L.info(tag, msg, ...)     - Info message  
--   L.warning(tag, msg, ...)  - Warning message
--   L.error(tag, msg, ...)    - Error message
--
-- Logger Builder (recommended):
--   local LOG = L.logger("MyModule")
--   LOG.debug("message")
--   LOG.info("Player %s at %d,%d", name, x, y)

if L and L._loaded then
    return L
end

L = L or {}
L._loaded = true

---------------------------------------------------------------------------
-- Cached Globals (avoid repeated global lookups)
---------------------------------------------------------------------------
local _getDebug = getDebug
local _getWorld = getWorld
local _getTimestampMs = getTimestampMs
local _writeLog = writeLog
local _log = log
local _DebugType_Mod = DebugType and DebugType.Mod
local _isClient = isClient
local _isServer = isServer

-- Lua stdlib caching
local _format = string.format
local _sub = string.sub
local _rep = string.rep
local _select = select
local _tostring = tostring

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local MOD_TAG = "MSR"
local LOG_FILE = "MySpatialRefuge"
local MAX_TAG_LEN = 12      -- Max tag length before truncation
local TAG_TOTAL_WIDTH = 14  -- Total width for [Tag] column (including brackets)

---------------------------------------------------------------------------
-- Cached State
---------------------------------------------------------------------------
local _debugEnabled = nil
local _origin = nil
local _tagCache = {}        -- Pre-formatted tag columns cache

---------------------------------------------------------------------------
-- Internal Helpers (optimized)
---------------------------------------------------------------------------

--- Get origin string (cached after first call)
local function getOrigin()
    if _origin then return _origin end
    
    if _isClient and _isClient() then
        _origin = "CLIENT"
    elseif _isServer and _isServer() then
        _origin = "SERVER"
    else
        _origin = "SHARED"
    end
    return _origin
end

--- Get current frame number (returns 0 if world not loaded)
local function getFrame()
    local world = _getWorld and _getWorld()
    return world and world:getFrameNo() or 0
end

--- Format tag with brackets and trailing padding: [Tag]     
--- @param tag string
--- @return string Formatted as [Tag] + trailing spaces to fixed width
local function formatTagColumn(tag)
    local cached = _tagCache[tag]
    if cached then return cached end
    
    -- Truncate if needed
    local truncated = tag
    if #tag > MAX_TAG_LEN then
        truncated = _sub(tag, 1, MAX_TAG_LEN - 2) .. ".."
    end
    
    -- Build [Tag] + trailing padding
    -- Total width = MAX_TAG_LEN + 2 (for brackets)
    local bracketed = "[" .. truncated .. "]"
    local padNeeded = TAG_TOTAL_WIDTH - #bracketed
    if padNeeded > 0 then
        bracketed = bracketed .. _rep(" ", padNeeded)
    end
    
    -- Cache for reuse
    _tagCache[tag] = bracketed
    return bracketed
end

--- Write to file - uses cached functions, minimal string ops
--- @param level string Level name (DEBUG, INFO, WARN, ERROR)
--- @param tag string Component tag
--- @param msg string Message
--- @param isDebugMode boolean Whether to include frame/ms
local function toFile(level, tag, msg, isDebugMode)
    local tagCol = formatTagColumn(tag)
    
    if isDebugMode then
        -- Detailed format: [ms][f:frame][LEVEL][Tag]      message
        local ms = _getTimestampMs and _getTimestampMs() or 0
        local frame = getFrame()
        _writeLog(LOG_FILE, _format("[%d][f:%-6d][%-5s]%s%s", ms, frame, level, tagCol, msg))
    else
        -- Simple format: [LEVEL][Tag]      message  
        _writeLog(LOG_FILE, _format("[%-5s]%s%s", level, tagCol, msg))
    end
end

local function toConsole(prefix, tag, msg)
    -- Console gets clean format without padding: [ORIGIN][MSR:Tag] message
    local tagTrimmed = tag
    if #tag > MAX_TAG_LEN then
        tagTrimmed = _sub(tag, 1, MAX_TAG_LEN - 2) .. ".."
    end
    local formatted = _format("[%s][%s:%s] %s", getOrigin(), MOD_TAG, tagTrimmed, msg)
    if prefix then
        formatted = prefix .. formatted
    end
    _log(_DebugType_Mod, formatted)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Check if debug mode is enabled (cached)
function L.isDebug()
    if _debugEnabled == nil then
        _debugEnabled = _getDebug and _getDebug() or false
    end
    return _debugEnabled
end

--- Debug message (only in debug mode)
--- @param tag string Component tag
--- @param msg string Message or format string
--- @param ... any Optional format arguments
function L.debug(tag, msg, ...)
    if not L.isDebug() then return end
    
    if _select("#", ...) > 0 then
        msg = _format(msg, ...)
    else
        msg = _tostring(msg)
    end
    
    toConsole(nil, tag, msg)
    toFile("DEBUG", tag, msg, true)  -- Debug always gets detailed format
end

--- Info message
--- @param tag string Component tag
--- @param msg string Message or format string
--- @param ... any Optional format arguments
function L.info(tag, msg, ...)
    if _select("#", ...) > 0 then
        msg = _format(msg, ...)
    else
        msg = _tostring(msg)
    end
    
    toConsole(nil, tag, msg)
    toFile("INFO", tag, msg, L.isDebug())
end

--- Warning message
--- @param tag string Component tag
--- @param msg string Message or format string
--- @param ... any Optional format arguments
function L.warning(tag, msg, ...)
    if _select("#", ...) > 0 then
        msg = _format(msg, ...)
    else
        msg = _tostring(msg)
    end
    
    toConsole("[WARN] ", tag, msg)
    toFile("WARN", tag, msg, L.isDebug())
end

--- Error message
--- @param tag string Component tag
--- @param msg string Message or format string
--- @param ... any Optional format arguments
function L.error(tag, msg, ...)
    if _select("#", ...) > 0 then
        msg = _format(msg, ...)
    else
        msg = _tostring(msg)
    end
    
    toConsole("[ERROR] ", tag, msg)
    toFile("ERROR", tag, msg, L.isDebug())
end

---------------------------------------------------------------------------
-- Logger Builder
---------------------------------------------------------------------------

--- Create a logger for a specific module (pre-caches tag)
--- @param tag string Module name
--- @return table Logger with debug/info/warning/error methods
function L.logger(tag)
    -- Pre-cache the tag for this logger
    formatTagColumn(tag)
    
    return {
        debug = function(msg, ...) L.debug(tag, msg, ...) end,
        info = function(msg, ...) L.info(tag, msg, ...) end,
        warning = function(msg, ...) L.warning(tag, msg, ...) end,
        error = function(msg, ...) L.error(tag, msg, ...) end,
    }
end

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------

--- Reset cached state (useful for testing or hot-reload)
function L.resetCache()
    _debugEnabled = nil
    _origin = nil
    -- Don't clear _tagCache - tags don't change
end

--- Clear tag cache (if memory is a concern)
function L.clearTagCache()
    _tagCache = {}
end

---------------------------------------------------------------------------
-- Register
---------------------------------------------------------------------------
MSR.Logging = L

return L
