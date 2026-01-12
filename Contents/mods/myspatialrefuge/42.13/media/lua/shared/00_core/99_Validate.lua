-- 99_Validate - Core Module Validation
-- Runs after all core modules load to verify initialization
-- Always prints to log (no debug check) for troubleshooting

require "shared/00_core/00_MSR"
require "shared/00_core/01_KahluaCompat"
require "shared/00_core/02_Logging"
require "shared/00_core/03_Difficulty"
require "shared/00_core/04_Env"
require "shared/00_core/05_Config"
require "shared/00_core/06_Data"
require "shared/00_core/07_Events"

if MSR._coreValidated then
    return
end

local function log(msg)
    print("[MSR] " .. msg)
end

-- { name, target, requiredFields, isModule } - isModule checks _loaded flag
local validations = {
    { "MSR namespace",      MSR,        nil,                                                    false },
    { "K (KahluaCompat)",   K,          {"isEmpty", "count", "iter", "time"},                   false },
    { "L (Logging)",        L,          {"log", "warn", "error", "isDebug"},                    false },
    { "D (Difficulty)",     D,          {"core", "cooldown", "positiveEffect", "negativeEffect"}, false },
    { "MSR.Env",            MSR and MSR.Env,    {"isServer", "isClient", "isSingleplayer", "canModifyData"}, true },
    { "MSR.Config",         MSR and MSR.Config, {"getCastTime", "getTeleportCooldown"},         true },
    { "MSR.Data",           MSR and MSR.Data,   {"GetRefugeData", "SaveRefugeData", "GetModData"}, true },
    { "MSR.Events",         MSR and MSR.Events, {"OnServerReady", "OnClientReady", "OnAnyReady"}, true },
}

local function validate(name, target, requiredFields, isModule)
    if not target then
        log("FAIL: " .. name .. " not loaded")
        return false
    end
    
    if isModule and not target._loaded then
        log("FAIL: " .. name .. " missing _loaded flag")
        return false
    end
    
    if requiredFields then
        for _, field in ipairs(requiredFields) do
            if target[field] == nil then
                log("FAIL: " .. name .. " missing: " .. field)
                return false
            end
        end
    end
    
    log("OK: " .. name)
    return true
end

local function runValidation()
    log("=== Core Module Validation v" .. (MSR.VERSION or "?") .. " ===")
    
    local passed, total = 0, #validations
    
    for _, v in ipairs(validations) do
        if validate(v[1], v[2], v[3], v[4]) then
            passed = passed + 1
        end
    end
    
    log("=== Validation: " .. passed .. "/" .. total .. " passed ===")
    
    local allPassed = (passed == total)
    if allPassed then
        log("My Spatial Refuge v" .. (MSR.VERSION or "?") .. " loaded successfully")
    else
        log("WARNING: Some core modules failed validation!")
        log("Check mod load order and file integrity")
        log("If you see this error, try re-subscribing to the mod on Steam Workshop")
    end
    
    return allPassed
end

MSR._coreValidated = true
MSR._coreValid = runValidation()

return MSR._coreValid
