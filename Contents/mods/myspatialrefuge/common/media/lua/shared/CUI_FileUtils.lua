-- CUI_FileUtils - File Reading Utilities for Project Zomboid
-- Part of MySpatialCore framework
-- Handles B42+ mod ID backslash prefix and provides reliable file reading

-- Prevent double-loading
if CUI_FileUtils and CUI_FileUtils._loaded then
    return CUI_FileUtils
end

CUI_FileUtils = {
    _loaded = true,
    _debug = false  -- Set to true for verbose logging
}

-----------------------------------------------------------
-- Internal Helpers
-----------------------------------------------------------

local function log(msg)
    if CUI_FileUtils._debug then
        print("[CUI_FileUtils] " .. msg)
    end
end

-- Get mod ID variants (with and without B42+ backslash prefix)
local function getModIdVariants(modId)
    local variants = { modId }
    if modId:sub(1, 1) ~= "\\" then
        table.insert(variants, "\\" .. modId)
    end
    return variants
end

-----------------------------------------------------------
-- Public API
-----------------------------------------------------------

-- Enable/disable debug logging
function CUI_FileUtils.setDebug(enabled)
    CUI_FileUtils._debug = enabled
end

-- Get the correct mod ID (with B42+ backslash prefix if needed)
-- @param modId: The mod ID from mod.info (e.g., "myspatialrefuge")
-- @return: The correct mod ID to use with PZ API functions, or nil if not found
function CUI_FileUtils.resolveModId(modId)
    if not modId then return nil end
    if not getModInfoByID then return nil end
    
    local variants = getModIdVariants(modId)
    
    for _, tryId in ipairs(variants) do
        -- Wrap in pcall to handle any Java exceptions gracefully
        local ok, modInfo = pcall(function()
            return getModInfoByID(tryId)
        end)
        if ok and modInfo then
            log("Resolved mod ID: '" .. modId .. "' -> '" .. tryId .. "'")
            return tryId
        end
    end
    
    log("Could not resolve mod ID: " .. modId)
    return nil
end

-- Check if a mod is installed and activated
-- @param modId: The mod ID from mod.info
-- @return: true if mod is installed, false otherwise
function CUI_FileUtils.isModInstalled(modId)
    return CUI_FileUtils.resolveModId(modId) ~= nil
end

-- Get mod info, handling B42+ backslash prefix automatically
-- @param modId: The mod ID from mod.info
-- @return: ChooseGameInfo.Mod object or nil
function CUI_FileUtils.getModInfo(modId)
    if not modId then return nil end
    if not getModInfoByID then return nil end
    
    local variants = getModIdVariants(modId)
    
    for _, tryId in ipairs(variants) do
        -- Wrap in pcall to handle any Java exceptions gracefully
        local ok, modInfo = pcall(function()
            return getModInfoByID(tryId)
        end)
        if ok and modInfo then
            return modInfo
        end
    end
    
    return nil
end

-- Read a file from a mod's directory
-- Handles B42+ backslash prefix automatically
-- @param modId: The mod ID from mod.info (e.g., "myspatialrefuge")
-- @param filePath: Path relative to mod's version folder (e.g., "media/lua/shared/data.txt")
-- @return: Table of lines, or nil on failure
function CUI_FileUtils.readModFile(modId, filePath)
    if not modId or not filePath then
        log("ERROR: modId and filePath are required")
        return nil
    end
    
    if not getModFileReader then
        log("ERROR: getModFileReader not available")
        return nil
    end
    
    log("Reading file: " .. filePath .. " from mod: " .. modId)
    
    -- First, resolve the mod ID to one that actually exists
    -- IMPORTANT: getModFileReader throws a Java NPE (not catchable by pcall) 
    -- if the mod doesn't exist, so we MUST validate first using getModInfoByID
    local resolvedModId = CUI_FileUtils.resolveModId(modId)
    if not resolvedModId then
        log("FAILED: Mod not found: " .. modId)
        return nil
    end
    
    log("Trying getModFileReader('" .. resolvedModId .. "', '" .. filePath .. "', false)")
    local reader = nil
    local ok, result = pcall(function()
        return getModFileReader(resolvedModId, filePath, false)
    end)
    if ok and result then
        reader = result
        log("SUCCESS: Got reader using mod ID '" .. resolvedModId .. "'")
    end
    
    if not reader then
        log("FAILED: Could not open file: " .. filePath)
        return nil
    end
    
    -- Read all lines
    local lines = {}
    local ok, err = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            table.insert(lines, line)
            line = reader:readLine()
        end
        reader:close()
    end)
    
    if not ok then
        log("ERROR reading file: " .. tostring(err))
        return nil
    end
    
    log("Successfully read " .. #lines .. " lines")
    return lines
end

-- Read a file from a mod's directory as a single string
-- @param modId: The mod ID from mod.info
-- @param filePath: Path relative to mod's version folder
-- @return: File contents as string, or nil on failure
function CUI_FileUtils.readModFileAsString(modId, filePath)
    local lines = CUI_FileUtils.readModFile(modId, filePath)
    if not lines then
        return nil
    end
    return table.concat(lines, "\n")
end

-- Read a file from the Lua cache directory
-- @param filePath: Path relative to Lua cache root
-- @return: Table of lines, or nil on failure
function CUI_FileUtils.readCacheFile(filePath)
    if not filePath then
        log("ERROR: filePath is required")
        return nil
    end
    
    if not getFileReader then
        log("ERROR: getFileReader not available")
        return nil
    end
    
    log("Reading cache file: " .. filePath)
    
    local ok, reader = pcall(function()
        return getFileReader(filePath, false)
    end)
    
    if not ok or not reader then
        log("FAILED: Could not open cache file: " .. filePath)
        return nil
    end
    
    -- Read all lines
    local lines = {}
    local readOk, err = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            table.insert(lines, line)
            line = reader:readLine()
        end
        reader:close()
    end)
    
    if not readOk then
        log("ERROR reading cache file: " .. tostring(err))
        return nil
    end
    
    log("Successfully read " .. #lines .. " lines from cache")
    return lines
end

-- List activated mods
-- @return: Lua table of mod IDs (handles Java ArrayList conversion)
function CUI_FileUtils.getActivatedModIds()
    if not getActivatedMods then
        return {}
    end
    
    -- Wrap entire operation in pcall to handle Java exceptions gracefully
    local ok, result = pcall(function()
        local javaList = getActivatedMods()
        if not javaList then
            return {}
        end
        
        -- Convert Java ArrayList to Lua table
        -- Note: Java ArrayList uses :size() and :get(i) with 0-based indexing
        local mods = {}
        local count = javaList:size()
        for i = 0, count - 1 do
            table.insert(mods, javaList:get(i))
        end
        return mods
    end)
    
    if not ok then
        log("ERROR getting activated mods: " .. tostring(result))
        return {}
    end
    
    return result or {}
end

-----------------------------------------------------------
-- Debug Functions
-----------------------------------------------------------

-- Diagnose file access issues
-- @param modId: Mod ID to test
-- @param filePath: File path to test
function CUI_FileUtils.diagnose(modId, filePath)
    modId = modId or "MySpatialCore"
    filePath = filePath or "mod.info"
    
    print("======== CUI_FileUtils DIAGNOSIS ========")
    print("Mod ID: " .. tostring(modId))
    print("File Path: " .. tostring(filePath))
    
    -- List activated mods
    print("")
    print("ACTIVATED MODS:")
    local mods = CUI_FileUtils.getActivatedModIds()
    if #mods == 0 then
        print("  (none found or error occurred)")
    else
        for i, m in ipairs(mods) do
            local marker = ""
            if m == modId or m == "\\" .. modId or m == modId:gsub("^\\", "") then
                marker = " <-- MATCH"
            end
            print("  [" .. i .. "] = '" .. tostring(m) .. "'" .. marker)
        end
    end
    
    -- Check mod info
    print("")
    print("MOD INFO:")
    local modInfo = CUI_FileUtils.getModInfo(modId)
    if modInfo then
        print("  Found: YES")
        -- Wrap property access in pcall for safety
        local ok, name = pcall(function() return modInfo:getName() end)
        print("  Name: " .. (ok and tostring(name) or "(error)"))
        
        ok, dir = pcall(function() return modInfo:getDir() end)
        print("  Dir: " .. (ok and tostring(dir) or "(error)"))
        
        if modInfo.getVersionDir then
            ok, vdir = pcall(function() return modInfo:getVersionDir() end)
            print("  VersionDir: " .. (ok and tostring(vdir) or "(error)"))
        end
        if modInfo.getCommonDir then
            ok, cdir = pcall(function() return modInfo:getCommonDir() end)
            print("  CommonDir: " .. (ok and tostring(cdir) or "(error)"))
        end
    else
        print("  Found: NO")
    end
    
    -- Try to read file
    print("")
    print("FILE READ TEST:")
    local lines = CUI_FileUtils.readModFile(modId, filePath)
    if lines then
        print("  Success! Read " .. #lines .. " lines")
        if #lines > 0 then
            print("  First line: " .. tostring(lines[1]))
        end
    else
        print("  Failed to read file")
    end
    
    print("==========================================")
end

print("[CUI_FileUtils] File utilities loaded")

return CUI_FileUtils

