if MSR._coreValidated then
    return
end

local LOG = (L and L.logger) and L.logger("Validate") or {
    info = function(msg) print("[MSR][Validate] " .. msg) end,
    warning = function(msg) print("[MSR][WARN][Validate] " .. msg) end,
    error = function(msg) print("[MSR][ERROR][Validate] " .. msg) end,
}

local validations = {
    { "MSR namespace",      MSR,        nil,                                                    false },
    { "K (KahluaCompat)",   K,          {"isEmpty", "count", "iter", "time"},                   false },
    { "L (Logging)",        L,          {"info", "warning", "error", "isDebug"},                false },
    { "D (Difficulty)",     D,          {"core", "cooldown", "positiveEffect", "negativeEffect"}, false },
    { "MSR.Env",            MSR and MSR.Env,    {"isServer", "isClient", "isSingleplayer", "canModifyData"}, true },
    { "MSR.Config",         MSR and MSR.Config, {"getCastTime", "getTeleportCooldown"},         true },
    { "MSR.Data",           MSR and MSR.Data,   {"GetRefugeData", "SaveRefugeData", "GetModData"}, true },
    { "MSR.Events",         MSR and MSR.Events, {"OnServerReady", "OnClientReady", "OnAnyReady"}, true },
}

local function validate(name, target, requiredFields, isModule)
    if not target then
        LOG.error("FAIL: " .. name .. " not loaded")
        return false
    end
    
    if isModule and not target._loaded then
        LOG.error("FAIL: " .. name .. " missing _loaded flag")
        return false
    end
    
    if requiredFields then
        for _, field in ipairs(requiredFields) do
            if target[field] == nil then
                LOG.error("FAIL: " .. name .. " missing: " .. field)
                return false
            end
        end
    end
    
    LOG.info("OK: " .. name)
    return true
end

local function runValidation()
    LOG.info("=== Core Module Validation v" .. (MSR.VERSION or "?") .. " ===")
    
    local passed, total = 0, #validations
    
    for _, v in ipairs(validations) do
        if validate(v[1], v[2], v[3], v[4]) then
            passed = passed + 1
        end
    end
    
    LOG.info("=== Validation: " .. passed .. "/" .. total .. " passed ===")
    
    local allPassed = (passed == total)
    if allPassed then
        LOG.info("My Spatial Refuge v" .. (MSR.VERSION or "?") .. " loaded successfully")
    else
        LOG.warning("Some core modules failed validation!")
        LOG.warning("Check mod load order and file integrity")
        LOG.warning("If you see this error, try re-subscribing to the mod on Steam Workshop")
    end
    
    return allPassed
end

MSR._coreValidated = true
MSR._coreValid = runValidation()

return MSR._coreValid
