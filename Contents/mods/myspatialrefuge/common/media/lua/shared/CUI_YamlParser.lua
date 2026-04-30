require "CUI_FileUtils"

-- Prevent double-loading
if CUI_YamlParser and CUI_YamlParser._loaded then
    return CUI_YamlParser
end

CUI_YamlParser = {
    _loaded = true,
    _debug = false
}

-----------------------------------------------------------
-- Internal Helper Functions
-----------------------------------------------------------

local function log(msg)
    if CUI_YamlParser._debug then
        print("[CUI_YamlParser] " .. msg)
    end
end

-- Trim whitespace from both ends of a string
local function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

-- Strip inline comments from a scalar string.
-- YAML comments start with # (typically preceded by whitespace).
-- This keeps # inside quoted strings.
local function stripInlineComment(s)
    if not s then return s end
    if type(s) ~= "string" then s = tostring(s) end
    local inSingle = false
    local inDouble = false
    local len = #s
    for i = 1, len do
        local c = s:sub(i, i)
        if c == "'" and not inDouble then
            inSingle = not inSingle
        elseif c == '"' and not inSingle then
            inDouble = not inDouble
        elseif c == "#" and not inSingle and not inDouble then
            if i == 1 then
                return ""
            end
            local prev = s:sub(i - 1, i - 1)
            if prev:match("%s") then
                return s:sub(1, i - 1)
            end
        end
    end
    return s
end

-- Get the indentation level (number of leading spaces)
local function getIndent(line)
    if not line then return 0 end
    local spaces = line:match("^(%s*)")
    return spaces and #spaces or 0
end

-- Check if a line is empty or a comment
local function isEmptyOrComment(line)
    local trimmed = trim(line)
    return trimmed == "" or trimmed:sub(1, 1) == "#"
end

-- Parse a scalar value (string, number, boolean, null)
local function parseScalar(value)
    if not value then return nil end
    
    local trimmed = trim(stripInlineComment(value))
    
    -- Empty or null
    if trimmed == "" or trimmed == "~" or trimmed == "null" or trimmed == "Null" or trimmed == "NULL" then
        return nil
    end
    
    -- Boolean true
    if trimmed == "true" or trimmed == "True" or trimmed == "TRUE" or
       trimmed == "yes" or trimmed == "Yes" or trimmed == "YES" or
       trimmed == "on" or trimmed == "On" or trimmed == "ON" then
        return true
    end
    
    -- Boolean false
    if trimmed == "false" or trimmed == "False" or trimmed == "FALSE" or
       trimmed == "no" or trimmed == "No" or trimmed == "NO" or
       trimmed == "off" or trimmed == "Off" or trimmed == "OFF" then
        return false
    end
    
    -- Number
    local num = tonumber(trimmed)
    if num then
        return num
    end
    
    -- Quoted string - remove quotes
    if (trimmed:sub(1, 1) == '"' and trimmed:sub(-1) == '"') or
       (trimmed:sub(1, 1) == "'" and trimmed:sub(-1) == "'") then
        return trimmed:sub(2, -2)
    end
    
    -- Unquoted string
    return trimmed
end

-- Parse an inline array: [item1, item2, item3]
local function parseInlineArray(value)
    local trimmed = trim(value)
    if trimmed:sub(1, 1) ~= "[" or trimmed:sub(-1) ~= "]" then
        return nil
    end
    
    local content = trimmed:sub(2, -2)
    local result = {}
    
    -- Simple split by comma (doesn't handle nested structures)
    for item in content:gmatch("([^,]+)") do
        local parsed = parseScalar(item)
        if parsed ~= nil then
            table.insert(result, parsed)
        end
    end
    
    return result
end

-- Parse an inline object: {key: value, key2: value2}
local function parseInlineObject(value)
    local trimmed = trim(value)
    if trimmed:sub(1, 1) ~= "{" or trimmed:sub(-1) ~= "}" then
        return nil
    end
    
    local content = trimmed:sub(2, -2)
    local result = {}
    
    -- Simple split by comma
    for pair in content:gmatch("([^,]+)") do
        local key, val = pair:match("^%s*([^:]+):%s*(.-)%s*$")
        if key then
            result[trim(key)] = parseScalar(val)
        end
    end
    
    return result
end

-----------------------------------------------------------
-- Public API
-----------------------------------------------------------

-- Enable/disable debug logging
function CUI_YamlParser.setDebug(enabled)
    CUI_YamlParser._debug = enabled
end

-- Parse YAML content from a table of lines
-- @param lines: Table of strings (one per line)
-- @return: Parsed Lua table
function CUI_YamlParser.parseLines(lines)
    if not lines or #lines == 0 then
        return {}
    end
    
    log("Parsing " .. #lines .. " lines")
    
    local result = {}
    local stack = {{obj = result, indent = -1}}
    local i = 1
    
    while i <= #lines do
        local line = lines[i]
        local indent = getIndent(line)
        local content = trim(line)
        
        -- Skip empty lines and comments
        if isEmptyOrComment(line) then
            i = i + 1
        else
            -- Pop stack to find parent at correct indentation level
            while #stack > 1 and stack[#stack].indent >= indent do
                table.remove(stack)
            end
            
            local parent = stack[#stack].obj
            
            -- Check for array item (starts with -)
            if content:sub(1, 2) == "- " then
                local itemContent = trim(content:sub(3))
                
                -- Array item with key: value
                local key, value = itemContent:match("^([^:]+):%s*(.*)$")
                if key then
                    -- This is an object in an array
                    local newObj = {}
                    newObj[trim(key)] = parseScalar(value)
                    
                    -- Ensure parent is an array
                    if type(parent) ~= "table" then
                        parent = {}
                    end
                    table.insert(parent, newObj)
                    
                    -- Push for nested content
                    table.insert(stack, {obj = newObj, indent = indent})
                else
                    -- Simple array item
                    local parsed = parseInlineArray(itemContent)
                    if parsed then
                        table.insert(parent, parsed)
                    else
                        parsed = parseInlineObject(itemContent)
                        if parsed then
                            table.insert(parent, parsed)
                        else
                            table.insert(parent, parseScalar(itemContent))
                        end
                    end
                end
                i = i + 1
                
            -- Check for key: value pair
            elseif content:find(":") then
                local key, value = content:match("^([^:]+):%s*(.*)$")
                if key then
                    key = trim(key)
                    value = trim(value)
                    
                    if value == "" then
                        -- Value is on following lines (nested object or array)
                        -- Peek at next non-empty line to determine type
                        local j = i + 1
                        while j <= #lines and isEmptyOrComment(lines[j]) do
                            j = j + 1
                        end
                        
                        if j <= #lines then
                            local nextContent = trim(lines[j])
                            if nextContent:sub(1, 1) == "-" then
                                -- It's an array
                                parent[key] = {}
                                table.insert(stack, {obj = parent[key], indent = indent})
                            else
                                -- It's an object
                                parent[key] = {}
                                table.insert(stack, {obj = parent[key], indent = indent})
                            end
                        else
                            parent[key] = {}
                        end
                    else
                        -- Inline value
                        local parsed = parseInlineArray(value)
                        if parsed then
                            parent[key] = parsed
                        else
                            parsed = parseInlineObject(value)
                            if parsed then
                                parent[key] = parsed
                            else
                                parent[key] = parseScalar(value)
                            end
                        end
                    end
                end
                i = i + 1
            else
                -- Unknown line format, skip
                i = i + 1
            end
        end
    end
    
    return result
end

-----------------------------------------------------------
-- Reference Expansion (Item Groups)
-----------------------------------------------------------

-- This parser is intentionally lightweight and doesn't implement full YAML anchors/aliases.
-- Instead, we support an opt-in "group expansion" pass that lets mods define reusable lists,
-- then reference them from arrays without copy/pasting.
--
-- YAML example:
-- itemGroups:
--   skillbooks:
--     - Base.BookCarpentry1
--     - Base.BookCarpentry2
-- upgrades:
--   some_upgrade:
--     levels:
--       1:
--         requirements:
--           - type: Base.BookCarpentry1
--             count: 3
--             substitutes:
--               - $skillbooks
--
-- Supported reference tokens (inside arrays):
--   "$groupName" or "*groupName"                  -> expands to the group's items (spliced)
--   "$groupName+ItemA+ItemB" (or "*" prefix)      -> expands group + appends extra items

local function _splitPlus(value)
    local parts = {}
    if not value or value == "" then return parts end
    for part in tostring(value):gmatch("([^+]+)") do
        table.insert(parts, part)
    end
    return parts
end

local function _makePrefixSet(prefixes)
    local set = {}
    if prefixes and type(prefixes) == "table" then
        for _, p in ipairs(prefixes) do
            if type(p) == "string" and p ~= "" then
                set[p] = true
            end
        end
    end
    if not set["$"] and not set["*"] then
        -- Default prefixes
        set["$"] = true
        set["*"] = true
    end
    return set
end

local function _isArray(tbl)
    if type(tbl) ~= "table" then return false end
    local count = 0
    for k, _ in pairs(tbl) do
        count = count + 1
        if type(k) ~= "number" or k ~= count then
            return false
        end
    end
    return true
end

local function _isGroupRefToken(value, prefixSet)
    if type(value) ~= "string" then return false end
    local p = value:sub(1, 1)
    return prefixSet[p] == true
end

-- Resolve a group by name into a flat array of strings (supports nested refs)
local function _resolveGroup(groupName, groups, resolving, prefixSet)
    if not groupName or groupName == "" then return {} end
    if not groups or type(groups) ~= "table" then return {} end
    local groupVal = groups[groupName]
    if not groupVal or type(groupVal) ~= "table" then return {} end

    -- Cycle detection
    resolving = resolving or {}
    if resolving[groupName] then
        log("WARNING: group cycle detected for '" .. tostring(groupName) .. "'")
        return {}
    end
    resolving[groupName] = true

    local out = {}
    for _, item in ipairs(groupVal) do
        if _isGroupRefToken(item, prefixSet) then
            local prefix = item:sub(1, 1)
            local ref = item:sub(2)
            local parts = _splitPlus(ref)
            local baseName = parts[1]

            local expanded = _resolveGroup(baseName, groups, resolving, prefixSet)
            for _, e in ipairs(expanded) do
                table.insert(out, e)
            end

            -- extras
            for i = 2, #parts do
                table.insert(out, parts[i])
            end
        else
            table.insert(out, item)
        end
    end

    resolving[groupName] = nil
    return out
end

local function _expandInArray(arr, groups, resolving, prefixSet)
    local out = {}
    for _, v in ipairs(arr) do
        if _isGroupRefToken(v, prefixSet) then
            local ref = v:sub(2)
            local parts = _splitPlus(ref)
            local groupName = parts[1]

            local expanded = _resolveGroup(groupName, groups, resolving, prefixSet)
            for _, e in ipairs(expanded) do
                table.insert(out, e)
            end
            for i = 2, #parts do
                table.insert(out, parts[i])
            end
        else
            table.insert(out, v)
        end
    end
    return out
end

local function _expandInValue(value, groups, resolving, prefixSet)
    if type(value) ~= "table" then
        return value
    end

    if _isArray(value) then
        -- Expand array items first, then recurse into nested tables
        local expanded = _expandInArray(value, groups, resolving, prefixSet)
        for i = 1, #expanded do
            expanded[i] = _expandInValue(expanded[i], groups, resolving, prefixSet)
        end
        return expanded
    end

    -- Object/map: recurse each key
    for k, v in pairs(value) do
        value[k] = _expandInValue(v, groups, resolving, prefixSet)
    end
    return value
end

-- Expand group references in-place on the parsed root table.
-- opts:
--   - expandGroups: boolean (required to enable)
--   - groupsKey: string (default "itemGroups")
--   - refPrefixes: array of strings (default {"$","*"})
function CUI_YamlParser.expandGroups(root, opts)
    if type(root) ~= "table" then return root end
    if not opts or not opts.expandGroups then return root end

    local groupsKey = opts.groupsKey or "itemGroups"
    local groups = root[groupsKey]
    if type(groups) ~= "table" then
        return root
    end

    local prefixSet = _makePrefixSet(opts.refPrefixes)
    local resolving = {}

    -- Expand everywhere except inside the groups table itself (avoid accidental mutation)
    for k, v in pairs(root) do
        if k ~= groupsKey then
            root[k] = _expandInValue(v, groups, resolving, prefixSet)
        end
    end

    return root
end

-- Parse YAML from a string
-- @param yamlString: YAML content as a single string
-- @return: Parsed Lua table (empty table on failure, never throws)
function CUI_YamlParser.parse(yamlString, opts)
    if not yamlString or yamlString == "" then
        return {}
    end
    
    local lines = {}
    for line in yamlString:gmatch("([^\r\n]*)[\r\n]?") do
        table.insert(lines, line)
    end
    
    -- Wrap parsing in pcall to ensure we never throw
    local ok, parsed = pcall(function()
        return CUI_YamlParser.parseLines(lines)
    end)
    
    if not ok then
        log("ERROR parsing YAML string: " .. tostring(parsed))
        return {}
    end
    
    -- Wrap group expansion in pcall too
    local expandOk, result = pcall(function()
        return CUI_YamlParser.expandGroups(parsed, opts)
    end)
    
    if not expandOk then
        log("ERROR expanding groups: " .. tostring(result))
        return parsed or {}  -- Return unparsed result as fallback
    end
    
    return result or {}
end

-- Parse YAML from a file in a mod's directory
-- Uses CUI_FileUtils for B42+ compatible file reading
-- @param modId: The mod ID from mod.info (e.g., "myspatialrefuge")
-- @param filePath: Path relative to mod's version folder (e.g., "media/lua/shared/config.yaml")
-- @return: Parsed Lua table, or nil on failure (never throws)
function CUI_YamlParser.parseFile(modId, filePath, opts)
    if not modId or not filePath then
        log("ERROR: modId and filePath are required")
        return nil
    end
    
    -- Check if mod is installed first (avoids Java NPE)
    if not CUI_FileUtils.isModInstalled(modId) then
        log("Mod not installed: " .. modId)
        return nil
    end
    
    log("Parsing YAML file: " .. filePath .. " from mod: " .. modId)
    
    local lines = CUI_FileUtils.readModFile(modId, filePath)
    if not lines then
        log("Failed to read file")
        return nil
    end
    
    -- Wrap parsing in pcall to ensure we never throw
    log("Read " .. #lines .. " lines, parsing...")
    local ok, parsed = pcall(function()
        return CUI_YamlParser.parseLines(lines)
    end)
    
    if not ok then
        log("ERROR parsing YAML: " .. tostring(parsed))
        return nil
    end
    
    -- Wrap group expansion in pcall too
    local expandOk, result = pcall(function()
        return CUI_YamlParser.expandGroups(parsed, opts)
    end)
    
    if not expandOk then
        log("ERROR expanding groups: " .. tostring(result))
        return parsed  -- Return unparsed result as fallback
    end
    
    return result
end

-- Parse YAML from a file in the Lua cache directory
-- @param filePath: Path relative to Lua cache root
-- @return: Parsed Lua table, or nil on failure (never throws)
function CUI_YamlParser.parseCacheFile(filePath, opts)
    if not filePath then
        log("ERROR: filePath is required")
        return nil
    end
    
    local lines = CUI_FileUtils.readCacheFile(filePath)
    if not lines then
        log("Failed to read cache file")
        return nil
    end
    
    -- Wrap parsing in pcall to ensure we never throw
    local ok, parsed = pcall(function()
        return CUI_YamlParser.parseLines(lines)
    end)
    
    if not ok then
        log("ERROR parsing YAML: " .. tostring(parsed))
        return nil
    end
    
    -- Wrap group expansion in pcall too
    local expandOk, result = pcall(function()
        return CUI_YamlParser.expandGroups(parsed, opts)
    end)
    
    if not expandOk then
        log("ERROR expanding groups: " .. tostring(result))
        return parsed  -- Return unparsed result as fallback
    end
    
    return result
end

-----------------------------------------------------------
-- Utility Functions
-----------------------------------------------------------

-- Deep print a table for debugging
-- @param obj: The object to dump
-- @param indent: Current indentation level (default 0)
function CUI_YamlParser.dump(obj, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)
    
    if type(obj) ~= "table" then
        print(prefix .. tostring(obj))
        return
    end
    
    -- Check if it's an array
    local isArray = true
    local count = 0
    for k, _ in pairs(obj) do
        count = count + 1
        if type(k) ~= "number" or k ~= count then
            isArray = false
            break
        end
    end
    
    if isArray then
        for i, v in ipairs(obj) do
            if type(v) == "table" then
                print(prefix .. "[" .. i .. "]:")
                CUI_YamlParser.dump(v, indent + 1)
            else
                print(prefix .. "[" .. i .. "]: " .. tostring(v))
            end
        end
    else
        for k, v in pairs(obj) do
            if type(v) == "table" then
                print(prefix .. tostring(k) .. ":")
                CUI_YamlParser.dump(v, indent + 1)
            else
                print(prefix .. tostring(k) .. ": " .. tostring(v))
            end
        end
    end
end

-- Serialize a Lua table to YAML string
-- @param obj: The object to serialize
-- @param indent: Current indentation level (default 0)
-- @return: YAML formatted string
function CUI_YamlParser.serialize(obj, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)
    local lines = {}
    
    if type(obj) ~= "table" then
        return tostring(obj)
    end
    
    -- Check if it's an array
    local isArray = true
    local count = 0
    for k, _ in pairs(obj) do
        count = count + 1
        if type(k) ~= "number" or k ~= count then
            isArray = false
            break
        end
    end
    
    if isArray then
        for _, v in ipairs(obj) do
            if type(v) == "table" then
                table.insert(lines, prefix .. "-")
                table.insert(lines, CUI_YamlParser.serialize(v, indent + 1))
            else
                table.insert(lines, prefix .. "- " .. tostring(v))
            end
        end
    else
        for k, v in pairs(obj) do
            if type(v) == "table" then
                table.insert(lines, prefix .. tostring(k) .. ":")
                table.insert(lines, CUI_YamlParser.serialize(v, indent + 1))
            else
                table.insert(lines, prefix .. tostring(k) .. ": " .. tostring(v))
            end
        end
    end
    
    return table.concat(lines, "\n")
end

print("[CUI_YamlParser] YAML parser loaded")

return CUI_YamlParser

