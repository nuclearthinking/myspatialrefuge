-- 01_KahluaCompat - Workarounds for missing Lua functions in Kahlua
-- Creates global K table. Kahlua lacks: next(), os.*, rawget/rawset
--
-- Key functions:
--   K.isEmpty(tbl), K.count(tbl), K.firstKey(tbl) - table checks (no next())
--   K.iter(obj), K.size(obj), K.toTable(list)     - Java ArrayList handling
--   K.time(), K.timeMs()                          - timestamps (no os.time())
--   K.safeCall(obj, method, ...)                  - safe method invocation
--
-- WARNING: PZ's xpairs() fails on some Java objects - use K.iter() instead

if K and K._loaded then
    return K
end

K = K or {}
K._loaded = true

if MSR then MSR.KahluaCompat = K end

-----------------------------------------------------------
-- Table Utilities
-----------------------------------------------------------

--- Check if a table is empty (replacement for `next(tbl) == nil`)
--- Kahlua doesn't have next(), so we use pairs() with early return
--- @param tbl table The table to check
--- @return boolean True if empty, false if has any entries
function K.isEmpty(tbl)
    if type(tbl) ~= "table" then return true end
    for _ in pairs(tbl) do return false end
    return true
end

--- Check if a table has any entries (inverse of isEmpty)
--- @param tbl table The table to check
--- @return boolean True if has entries, false if empty
function K.hasEntries(tbl)
    return not K.isEmpty(tbl)
end

--- Count entries in a hash table (replacement for table.getn on hash tables)
--- @param tbl table The table to count
--- @return number Number of key-value pairs
function K.count(tbl)
    if type(tbl) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

--- Get first key from a table (partial replacement for next(tbl))
--- @param tbl table The table to check
--- @return any|nil The first key, or nil if empty
function K.firstKey(tbl)
    if type(tbl) ~= "table" then return nil end
    for k in pairs(tbl) do return k end
    return nil
end

--- Get first value from a table
--- @param tbl table The table to check
--- @return any|nil The first value, or nil if empty
function K.firstValue(tbl)
    if type(tbl) ~= "table" then return nil end
    for _, v in pairs(tbl) do return v end
    return nil
end

--- Check if first key is numeric (to detect array vs hash table)
--- @param tbl table The table to check
--- @return boolean True if first key is numeric (array-like)
function K.isArrayLike(tbl)
    if type(tbl) ~= "table" then return false end
    for k in pairs(tbl) do
        return type(k) == "number"
    end
    return false
end

--- Shallow copy a table
--- @param tbl table The table to copy
--- @return table New table with same key-value pairs
function K.shallowCopy(tbl)
    if type(tbl) ~= "table" then return tbl end
    local copy = {}
    for k, v in pairs(tbl) do
        copy[k] = v
    end
    return copy
end

--- Get all keys from a table as an array
--- @param tbl table The table to get keys from
--- @return table Array of keys
function K.keys(tbl)
    local result = {}
    if type(tbl) ~= "table" then return result end
    for k in pairs(tbl) do
        table.insert(result, k)
    end
    return result
end

--- Get all values from a table as an array
--- @param tbl table The table to get values from
--- @return table Array of values
function K.values(tbl)
    local result = {}
    if type(tbl) ~= "table" then return result end
    for _, v in pairs(tbl) do
        table.insert(result, v)
    end
    return result
end

-----------------------------------------------------------
-- Java Object Utilities
-----------------------------------------------------------

--- Check if object is safely iterable by K.iter()
--- Returns true for Lua tables and Java ArrayLists, false for nil or other types
--- Use this before iterating over values from PZ API methods that may return unexpected types
--- @param obj any Value to check
--- @return boolean True if safe to iterate
function K.isIterable(obj)
    if not obj then return false end
    local t = type(obj)
    if t == "table" then return true end
    -- Java ArrayList shows as userdata with :size() method
    if t == "userdata" and type(obj.size) == "function" then return true end
    return false
end

--- Safely get size of a Java ArrayList or Lua table
--- @param obj any Java ArrayList or Lua table
--- @return number Size/length
function K.size(obj)
    if not obj then return 0 end
    if type(obj) == "table" then
        return #obj  -- For arrays, use # operator
    end
    -- Try Java :size() method
    if obj.size then
        local ok, result = pcall(function() return obj:size() end)
        if ok then return result end
    end
    return 0
end

--- Iterate over a Java ArrayList (0-based) or Lua array (1-based)
--- Returns an iterator function that yields (index, value) pairs
--- @param obj any Java ArrayList or Lua table
--- @return function Iterator function
function K.iter(obj)
    if not obj then
        return function() end
    end
    
    if type(obj) == "table" then
        -- Use ipairs for Lua tables
        return ipairs(obj)
    end
    
    -- Java ArrayList - use 0-based iteration
    if obj.size and obj.get then
        local i = -1
        local n = obj:size()
        return function()
            i = i + 1
            if i < n then
                return i, obj:get(i)
            end
        end
    end
    
    return function() end
end

--- Convert Java ArrayList to Lua table
--- @param javaList any Java ArrayList
--- @return table Lua array
function K.toTable(javaList)
    local result = {}
    if not javaList then return result end
    
    if type(javaList) == "table" then
        return javaList  -- Already a table
    end
    
    if javaList.size and javaList.get then
        for i = 0, javaList:size() - 1 do
            table.insert(result, javaList:get(i))
        end
    end
    
    return result
end

-----------------------------------------------------------
-- Time Utilities
-----------------------------------------------------------

--- Get current timestamp in seconds (replacement for os.time())
--- @return number Unix timestamp in seconds
function K.time()
    if getTimestamp then
        return getTimestamp()
    end
    return 0
end

--- Get current timestamp in milliseconds (replacement for os.clock())
--- @return number Unix timestamp in milliseconds
function K.timeMs()
    if getTimestampMs then
        return getTimestampMs()
    end
    return 0
end

-----------------------------------------------------------
-- Safe Method Calls
-----------------------------------------------------------

--- Safely call a method on an object (guards against nil/disconnected refs)
--- @param obj any The object to call method on
--- @param methodName string The method name
--- @param ... any Arguments to pass
--- @return any|nil The method result, or nil if call fails
function K.safeCall(obj, methodName, ...)
    if not obj or not methodName then return nil end
    
    local ok, method = pcall(function() return obj[methodName] end)
    if not ok or not method then return nil end
    
    local args = {...}
    local callOk, result = pcall(function()
        return method(obj, unpack(args))
    end)
    
    if not callOk then return nil end
    return result
end

return K
