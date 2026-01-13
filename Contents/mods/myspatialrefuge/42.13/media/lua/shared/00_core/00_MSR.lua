-- 00_MSR - Global namespace for My Spatial Refuge
MSR = {
    VERSION = getModInfoByID("\\myspatialrefuge"):getModVersion(),
    GAME_VERSION = getCore():getVersionNumber(),
    _loaded = true,
    _modules = {}, -- Track registered modules
}

print("[MSR] My Spatial Refuge v" .. MSR.VERSION .. " initializing...")

-----------------------------------------------------------
-- Module Registration Helper
-----------------------------------------------------------

--- @param name string Module name
--- @return table|nil Module table, or nil if already fully loaded (skip init)
function MSR.register(name)
    if MSR[name] and MSR[name]._loaded then
        return nil
    end

    --- @type table
    local module = {}
    module._loaded = true
    module._loadTime = getTimestampMs()
    MSR[name] = module
    MSR._modules[name] = true

    return module
end

--- Check if a module is loaded
--- @param name string Module name
--- @return boolean
function MSR.isLoaded(name)
    return MSR[name] and MSR[name]._loaded == true
end

--- Get list of all registered modules
--- @return table Array of module names
function MSR.getModules()
    local result = {}
    for name in pairs(MSR._modules) do
        table.insert(result, name)
    end
    return result
end

-----------------------------------------------------------
-- Core Module Initialization
-----------------------------------------------------------

require "00_core/Utils"        -- MSR.Utils (delay, poll, player utils)
require "00_core/KahluaCompat" -- K global
require "00_core/Logging"      -- L global
require "00_core/Difficulty"   -- D global
require "00_core/Env"          -- MSR.Env
require "00_core/Config"       -- MSR.Config
require "00_core/Data"         -- MSR.Data
require "00_core/Events"       -- MSR.Events
require "00_core/Validate"     -- Core validation

return MSR
