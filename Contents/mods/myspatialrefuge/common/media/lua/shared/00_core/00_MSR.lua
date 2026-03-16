local function resolveModInfo(modId)
    local variants = { modId }
    if modId:sub(1, 1) ~= "\\" then
        table.insert(variants, "\\" .. modId)
    end

    for _, candidate in ipairs(variants) do
        local ok, modInfo = pcall(function()
            return getModInfoByID(candidate)
        end)
        if ok and modInfo then
            return modInfo
        end
    end

    error("[MSR] Failed to resolve mod info for " .. modId)
end

local modInfo = resolveModInfo("myspatialrefuge")
MSR = {
    ---@diagnostic disable-next-line: undefined-field
    VERSION = modInfo:getModVersion(),
    ---@diagnostic disable-next-line: undefined-field
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

require "00_core/KahluaCompat" -- K global
require "00_core/Logging"      -- L global
require "00_core/Env"          -- MSR.Env
require "00_core/Config"       -- MSR.Config
require "00_core/Data"         -- MSR.Data (load early)
require "00_core/Utils"        -- MSR.Utils (delay, poll, player utils)
require "00_core/Difficulty"   -- D global
require "00_core/Events"       -- MSR.Events
require "00_core/Validate"     -- Core validation

return MSR
