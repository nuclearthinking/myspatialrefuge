-- Engine boundary: room definitions and loaded square references have distinct
-- lifetimes. Never serialize a Java long ID through Lua's floating point numbers.
local Engine = { revision = 0, changedCells = {} }
local PREFIX = "msr_room_"

function Engine.isOwn(def)
    return def ~= nil and string.sub(def:getName() or "", 1, #PREFIX) == PREFIX
end

local function eachRoomTile(room, z, fn)
    for _, r in ipairs(room.rects) do
        for x = r.x, r.x + r.w - 1 do
            for y = r.y, r.y + r.h - 1 do fn(x, y, z) end
        end
    end
end

local function ownerName(record)
    return PREFIX .. record.ax .. "_" .. record.ay .. "_" .. record.z .. "_"
end

local function belongsTo(def, record)
    local prefix = ownerName(record)
    return def ~= nil and string.sub(def:getName() or "", 1, #prefix) == prefix
end

local function isNative(def, z)
    if not def or z < 0 then return false end
    -- Room-level ownership was added after 42.16. Earlier B42 layouts expose
    -- this flag only on the building; retain the newer semantics when present.
    if def.isUserDefined then return def:isUserDefined() end
    local building = def:getBuilding()
    return building ~= nil and building:isUserDefined()
end

local function previousSquares(anchorDef)
    local result = {}
    if not anchorDef then return result end
    local defs = anchorDef:getBuilding():getRooms()
    for i = 0, defs:size() - 1 do
        local def, rects = defs:get(i), defs:get(i):getRects()
        for j = 0, rects:size() - 1 do
            local r = rects:get(j)
            for x = r:getX(), r:getX() + r:getW() - 1 do
                for y = r:getY(), r:getY() + r:getH() - 1 do
                    result[#result + 1] = {x=x,y=y,z=def:getZ()}
                end
            end
        end
    end
    return result
end

local function clearUnassigned(positions)
    local grid, cell = getWorld():getMetaGrid(), getCell()
    for _, p in ipairs(positions) do
        local sq = cell:getGridSquare(p.x, p.y, p.z)
        if sq and not grid:getRoomAt(p.x, p.y, p.z) then
            sq:setRoomID(-1)
            sq:setRoom(nil)
            sq:RecalcProperties()
            sq:setSquareChanged()
        end
    end
end

local function matchingDefinition(room, z)
    local grid, first, matches = getWorld():getMetaGrid(), nil, true
    local expected = {}
    eachRoomTile(room, z, function(x, y)
        expected[x .. "," .. y] = true
        local def = grid:getRoomAt(x, y, z)
        if not def or (first and first ~= def) then matches = false end
        first = first or def
    end)
    if not matches or not first then return nil end
    local rects = first:getRects()
    for i = 0, rects:size() - 1 do
        local r = rects:get(i)
        for x = r:getX(), r:getX() + r:getW() - 1 do
            for y = r:getY(), r:getY() + r:getH() - 1 do
                if not expected[x .. "," .. y] then return nil end
            end
        end
    end
    return first
end

-- Production APIs only. The editor has no public draft definition getter.
-- Protect immediately after apply, in the SAME main-thread Lua invocation:
-- IsoRegions.update cannot observe it between these two calls. No timer/yield.
local function applyEditor(editor, record)
    getCell():ProcessSpottedRooms()
    editor:applyChanges(false)
    local grid = getWorld():getMetaGrid()
    local anchor = grid:getRoomAt(record.ax, record.ay, record.z) --[[@as RoomDef|nil]]
    assert(anchor, "Editor did not register the room anchor")
    local def = anchor:getBuilding()
    def:setUserDefined(false)
    def:setAllExplored(true)
    def:setHasBeenVisited(true)
    local rooms = def:getRooms()
    for i = 0, rooms:size() - 1 do rooms:get(i):setExplored(true) end
    Engine.revision = Engine.revision + 1
    Engine.changedCells[math.floor(record.ax / 256) .. "," .. math.floor(record.ay / 256)] = {
        x = math.floor(record.ax / 256), y = math.floor(record.ay / 256),
    }
end

-- A stable real room anchor occupies a reserved tile outside the usable
-- refuge. Expansion and changing the first room cannot change BuildingDef.metaID.
-- emptyoutside is excluded from metaID as soon as a real room exists!
function Engine.register(record)
    local grid = getWorld():getMetaGrid()
    local anchorDef = grid:getRoomAt(record.ax, record.ay, record.z)
        or grid:getEmptyOutsideAt(record.ax, record.ay, record.z)
    if anchorDef and not belongsTo(anchorDef, record) then
        return false, "Room anchor occupied by another building"
    end
    local owned = {}
    for _, room in ipairs(record.rooms) do
        local native, conflict = false, false
        eachRoomTile(room, record.z, function(x, y, z)
            local def = grid:getRoomAt(x, y, z)
            if def and not belongsTo(def, record) then
                if isNative(def, z) then native = true else conflict = true end
            end
        end)
        if conflict then return false, "Room overlaps a foreign definition" end
        if native then
            if not matchingDefinition(room, record.z) then return false, "Native room rebuild pending" end
        else
            owned[#owned + 1] = room
        end
    end
    if #owned == 0 and not anchorDef then return true, "native-or-empty" end
    local oldSquares = previousSquares(anchorDef)

    local editor = BuildingRoomsEditor.new()
    local building = editor:createBuilding()
    local anchor = building:createRoom(record.z)
    anchor:setName(ownerName(record) .. "anchor")
    anchor:addRectangle(record.ax, record.ay, 1, 1)
    for i, room in ipairs(owned) do
        local draft = building:createRoom(record.z)
        draft:setName(ownerName(record) .. tostring(i))
        for _, r in ipairs(room.rects) do draft:addRectangle(r.x, r.y, r.w, r.h) end
    end
    if not editor:isValid() then return false, editor:getInvalidString() end
    -- The editor clears old IsoRooms. Drain the native discovery queue while
    -- those rooms still have definitions, rather than leaving dangling entries.
    applyEditor(editor, record)
    clearUnassigned(oldSquares)
    return true, "owned"
end

-- Repair both references. setRoomID alone can round a Java long and look up a
-- different/null room; getIsoRoom performs the long lookup entirely inside Java.
function Engine.repair(bounds, minZ, maxZ, relight)
    local grid, cell = getWorld():getMetaGrid(), getCell()
    local fixed = 0
    for z = minZ, maxZ do
        for x = bounds.minX, bounds.maxX do
            for y = bounds.minY, bounds.maxY do
                local sq = cell:getGridSquare(x, y, z)
                local def = sq and sq:getChunk() and grid:getRoomAt(x, y, z)
                local room = def and def:getIsoRoom()
                if sq and def and room then
                    local rebound = sq:getRoom() ~= room or sq:isOutside()
                        or sq:getRoomIDString() ~= def:getIDString()
                    if rebound then
                        sq:setRoomID(def:getID())
                        sq:setRoom(room)
                        if not room:getSquares():contains(sq) then room:addSquare(sq) end
                        sq:RecalcProperties()
                        sq:setSquareChanged()
                        fixed = fixed + 1
                    end
                    local switches, sources, objects = room:getLightSwitches(), room:getWaterSources(), sq:getObjects()
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if instanceof(obj, "IsoLightSwitch") then
                            ---@cast obj IsoLightSwitch
                            if not switches:contains(obj) then switches:add(obj) end
                            if (relight or rebound) and obj:isActivated() then
                                obj:switchLight(true)
                            end
                        end
                        if obj:hasWater() and not sources:contains(obj) then sources:add(obj) end
                    end
                elseif sq then
                    -- IsoGridSquare.getRoomDef is absent in 42.14; IsoRoom's
                    -- accessor is available in every supported B42 layout.
                    local currentRoom = sq:getRoom()
                    local currentDef = currentRoom and currentRoom:getRoomDef()
                    if currentRoom and (Engine.isOwn(currentDef) or not currentDef) then
                        sq:setRoomID(-1)
                        sq:setRoom(nil)
                        sq:RecalcProperties()
                        sq:setSquareChanged()
                    end
                end
            end
        end
    end
    return fixed
end

function Engine.present(record)
    local seen = {}
    for _, room in ipairs(record.rooms) do
        local def = matchingDefinition(room, record.z)
        if not def or seen[def] then return false end
        if not belongsTo(def, record) and not isNative(def, record.z) then return false end
        seen[def] = true
    end
    return true
end

-- Retire usable rooms, retaining only our inaccessible real anchor. The anchor
-- stays recognizable if a reclaimed slot is reused later in this session.
function Engine.remove(record)
    local grid = getWorld():getMetaGrid()
    local def = grid:getRoomAt(record.ax, record.ay, record.z)
    if not belongsTo(def, record) then return end
    local oldSquares = previousSquares(def)
    local editor = BuildingRoomsEditor.new()
    local building = editor:createBuilding()
    local anchor = building:createRoom(record.z)
    anchor:setName(ownerName(record) .. "anchor")
    anchor:addRectangle(record.ax, record.ay, 1, 1)
    assert(editor:isValid(), editor:getInvalidString())
    applyEditor(editor, record)
    clearUnassigned(oldSquares)
end

return Engine
