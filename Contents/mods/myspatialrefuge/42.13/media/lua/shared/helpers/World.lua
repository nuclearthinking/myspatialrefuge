-- MSR_World - World/Grid Helpers
-- Wraps common PZ world API patterns for grid squares, objects, and area operations
-- Handles chunk loading checks, network sync, and iteration patterns
--
-- USAGE: After this module loads, use `MSR.World` anywhere:
--   MSR.World.getSquare(x, y, z)       - Get square (returns nil if cell unavailable)
--   MSR.World.getSquareSafe(x, y, z)   - Get square only if chunk is loaded
--   MSR.World.isChunkLoaded(x, y, z)   - Check if chunk is loaded at coords
--   MSR.World.iterateArea(...)         - Iterate squares in radius
--   MSR.World.addObject(square, obj)   - Add object with network sync
--   MSR.World.removeObject(square, obj)- Remove object with network sync

require "shared/00_core/00_MSR"
require "shared/00_core/04_Env"

if MSR.World and MSR.World._loaded then
    return MSR.World
end

MSR.World = {}
MSR.World._loaded = true

local World = MSR.World

-----------------------------------------------------------
-- Grid Square Access
-----------------------------------------------------------

---Get grid square at coordinates
---@param x number
---@param y number
---@param z number
---@return IsoGridSquare|nil
function World.getSquare(x, y, z)
    local cell = getCell()
    if not cell then return nil end
    return cell:getGridSquare(x, y, z)
end

---Get grid square only if chunk is loaded (safe for modifications)
---@param x number
---@param y number
---@param z number
---@return IsoGridSquare|nil
function World.getSquareSafe(x, y, z)
    local cell = getCell()
    if not cell then return nil end
    
    local square = cell:getGridSquare(x, y, z)
    if not square then return nil end
    if not square:getChunk() then return nil end
    
    return square
end

---Check if chunk is loaded at coordinates
---@param x number
---@param y number
---@param z number
---@return boolean
function World.isChunkLoaded(x, y, z)
    local square = World.getSquare(x, y, z)
    return square ~= nil and square:getChunk() ~= nil
end

---Check if all chunks in an area are loaded (corners + center)
---@param centerX number
---@param centerY number
---@param z number
---@param radius number
---@return boolean
function World.isAreaLoaded(centerX, centerY, z, radius)
    local checkPoints = {
        {0, 0},              -- Center
        {-radius, -radius},  -- NW
        {radius, -radius},   -- NE
        {-radius, radius},   -- SW
        {radius, radius}     -- SE
    }
    
    for _, offset in ipairs(checkPoints) do
        if not World.isChunkLoaded(centerX + offset[1], centerY + offset[2], z) then
            return false
        end
    end
    
    return true
end

-----------------------------------------------------------
-- Area Iteration
-----------------------------------------------------------

---Iterate squares in radius, skips unloaded chunks
---@param centerX number
---@param centerY number
---@param z number
---@param radius number
---@param callback fun(square: IsoGridSquare, x: number, y: number, dx: number, dy: number)
---@return number count Number of squares processed
function World.iterateArea(centerX, centerY, z, radius, callback)
    local cell = getCell()
    if not cell then return 0 end
    
    local count = 0
    for dx = -radius, radius do
        for dy = -radius, radius do
            local x = centerX + dx
            local y = centerY + dy
            local square = cell:getGridSquare(x, y, z)
            if square and square:getChunk() then
                callback(square, x, y, dx, dy)
                count = count + 1
            end
        end
    end
    
    return count
end

---Iterate perimeter squares only
---@param centerX number
---@param centerY number
---@param z number
---@param radius number
---@param callback fun(square: IsoGridSquare, x: number, y: number, side: "N"|"S"|"E"|"W")
---@return number count Number of squares processed
function World.iteratePerimeter(centerX, centerY, z, radius, callback)
    local cell = getCell()
    if not cell then return 0 end
    
    local count = 0
    local minX, maxX = centerX - radius, centerX + radius
    local minY, maxY = centerY - radius, centerY + radius
    
    -- North/South edges
    for x = minX, maxX do
        local sq = cell:getGridSquare(x, minY, z)
        if sq and sq:getChunk() then callback(sq, x, minY, "S"); count = count + 1 end
        sq = cell:getGridSquare(x, maxY + 1, z)
        if sq and sq:getChunk() then callback(sq, x, maxY + 1, "N"); count = count + 1 end
    end
    
    -- West/East edges
    for y = minY, maxY do
        local sq = cell:getGridSquare(minX, y, z)
        if sq and sq:getChunk() then callback(sq, minX, y, "W"); count = count + 1 end
        sq = cell:getGridSquare(maxX + 1, y, z)
        if sq and sq:getChunk() then callback(sq, maxX + 1, y, "E"); count = count + 1 end
    end
    
    return count
end

-----------------------------------------------------------
-- Object Iteration
-----------------------------------------------------------

---Iterate objects on square, handles Java ArrayList via K.iter
---@param square IsoGridSquare?
---@param callback fun(obj: IsoObject, index: number)
---@return number count Number of objects processed
function World.iterateObjects(square, callback)
    if not square then return 0 end
    
    local objects = square:getObjects()
    if not K.isIterable(objects) then return 0 end
    
    local count = 0
    for i, obj in K.iter(objects) do
        if obj then
            callback(obj, i)
            count = count + 1
        end
    end
    
    return count
end

---Find objects matching predicate
---@param square IsoGridSquare?
---@param predicate fun(obj: IsoObject): boolean
---@return IsoObject[]
function World.findObjects(square, predicate)
    local results = {}
    
    World.iterateObjects(square, function(obj)
        if predicate(obj) then
            table.insert(results, obj)
        end
    end)
    
    return results
end

---Find objects by ModData key (optional value match)
---@param square IsoGridSquare?
---@param modDataKey string
---@param modDataValue any?
---@return IsoObject[]
function World.findObjectsByModData(square, modDataKey, modDataValue)
    return World.findObjects(square, function(obj)
        if not obj.getModData then return false end
        local md = obj:getModData()
        if not md then return false end
        
        if modDataValue ~= nil then
            return md[modDataKey] == modDataValue
        else
            return md[modDataKey]
        end
    end)
end

-----------------------------------------------------------
-- Object Add/Remove with Network Sync
-----------------------------------------------------------

---Add an object to a square with network sync (handles client/server)
---@param square IsoGridSquare
---@param obj IsoObject
---@param recalc boolean? Whether to recalculate visibility (default: true)
---@return boolean success
function World.addObject(square, obj, recalc)
    if not square or not obj then return false end
    if not square:getChunk() then return false end
    
    recalc = (recalc ~= false)  -- Default to true
    
    if MSR.Env.isServer() then
        square:transmitAddObjectToSquare(obj, -1)
    else
        square:AddSpecialObject(obj)
    end
    
    if recalc then
        square:RecalcAllWithNeighbours(true)
    end
    
    return true
end

---Remove an object from a square with network sync (pcall for safety)
---@param square IsoGridSquare
---@param obj IsoObject
---@param recalc boolean? Whether to recalculate visibility (default: true)
---@return boolean success
function World.removeObject(square, obj, recalc)
    if not square or not obj then return false end
    
    recalc = (recalc ~= false)  -- Default to true
    
    -- Use pcall for safety (object may already be removed)
    local ok = pcall(function()
        square:transmitRemoveItemFromSquare(obj)
    end)
    
    if recalc then
        square:RecalcAllWithNeighbours(true)
    end
    
    return ok
end

---Recalculate visibility for a square and its neighbors
---@param square IsoGridSquare?
function World.recalcSquare(square)
    if not square then return end
    square:RecalcAllWithNeighbours(true)
end

---Recalculate visibility for an entire area
---@param centerX number
---@param centerY number
---@param z number
---@param radius number
---@return number count Number of squares recalculated
function World.recalcArea(centerX, centerY, z, radius)
    return World.iterateArea(centerX, centerY, z, radius, function(square)
        square:RecalcAllWithNeighbours(true)
    end)
end

-----------------------------------------------------------
-- ModData Helpers
-----------------------------------------------------------

---Safely get ModData from an object
---@param obj any Object that may have getModData
---@return table|nil
function World.getModData(obj)
    if not obj then return nil end
    if not obj.getModData then return nil end
    
    local ok, md = pcall(function() return obj:getModData() end)
    if not ok then return nil end
    
    return md
end

---Safely transmit ModData for an object (server only)
---@param obj any
---@return boolean success True if transmission was attempted
function World.transmitModData(obj)
    if not obj then return false end
    if not MSR.Env.isServer() then return false end
    if not obj.transmitModData then return false end
    
    local ok = pcall(function() obj:transmitModData() end)
    return ok
end

---Set ModData flag and optionally transmit
---@param obj any Object to modify
---@param key string ModData key
---@param value any Value to set
---@param transmit boolean? Whether to transmit (default: auto based on env)
---@return boolean success
function World.setModDataFlag(obj, key, value, transmit)
    local md = World.getModData(obj)
    if not md then return false end
    
    md[key] = value
    
    if transmit == nil then
        transmit = MSR.Env.isServer()
    end
    
    if transmit then
        World.transmitModData(obj)
    end
    
    return true
end

return MSR.World
