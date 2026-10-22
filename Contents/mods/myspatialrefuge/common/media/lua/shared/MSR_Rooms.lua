-- One room lifecycle for refuge basements and player-built houses on all floors.
require "00_core/00_MSR"
require "MSR_RefugeGeometry"

local Rooms = MSR.register("Rooms")
if not Rooms then return MSR.Rooms end
local Topology = require "rooms/Topology"
local Engine = require "rooms/Engine"
local LOG = L.logger("Rooms")
local pending, applied = {}, {}
local scheduled, applying = false, false
---@type fun()
local process
local DEBOUNCE_TICKS = 15
local MAX_WAIT_TICKS = 300

local function identity(r)
    return r.centerX .. "," .. r.centerY
end

local function registry()
    return MSR.Data.GetRefugeRegistry() or {}
end

local function basementEnabled(r)
    return r.upgrades and (r.upgrades[MSR.Config.UPGRADES.REFUGE_BASEMENT] or 0) > 0
end

local function maxLevel(r, bounds)
    local cell, highest = getCell(), r.centerZ
    -- Require chunks, rather than squares: holes and empty upper floors are valid.
    for x = bounds.minX, bounds.maxX + 1 do
        for y = bounds.minY, bounds.maxY + 1 do
            local chunk = cell:getChunkForGridSquare(x, y, r.centerZ)
            if not chunk then return nil end
            highest = math.max(highest, chunk:getMaxLevel())
        end
    end
    return math.min(highest, 31)
end

local function sample(bounds, lowest, highest)
    local cell, tiles = getCell(), {}
    for z = lowest, highest do tiles[tostring(z)] = {} end
    for y = bounds.minY, bounds.maxY + 1 do
        for x = bounds.minX, bounds.maxX + 1 do
            local roofAbove = false
            for z = highest, lowest, -1 do
                local sq = cell:getGridSquare(x, y, z)
                tiles[tostring(z)][Topology.key(x, y)] = {
                    x = x, y = y, exists = sq ~= nil,
                    floor = sq ~= nil and (sq:hasFloor() or sq:HasStairs() or sq:HasStairsBelow() or sq:hasFloorAtTopOfStairs()),
                    roof = roofAbove,
                    north = sq ~= nil and (sq:has(IsoFlagType.cutN) or sq:has(IsoObjectType.doorFrN)),
                    west = sq ~= nil and ((sq:has(IsoFlagType.cutW) and not sq:has(IsoFlagType.WallSE))
                        or sq:has(IsoObjectType.doorFrW)),
                }
                -- haveRoofFull starts at level 1 even for upper-floor squares.
                -- Evaluate this column above EACH floor instead.
                if sq and (sq:hasRainBlockingTile() or sq:HasSlopedRoof()) then roofAbove = true end
            end
        end
    end
    return tiles
end

local function repairRenumberedRooms()
    local changed = Engine.changedCells
    Engine.changedCells = {}
    if K.isEmpty(changed) then return end
    for _, r in pairs(registry()) do
        local bounds = MSR.RefugeGeometry.GetTileBounds(r)
        for _, record in pairs(r.rooms and r.rooms.levels or {}) do
            local affected = changed[math.floor(record.ax / 256) .. "," .. math.floor(record.ay / 256)] ~= nil
            for _, cell in pairs(changed) do
                affected = affected or (bounds.minX < (cell.x + 1) * 256 and bounds.maxX >= cell.x * 256
                    and bounds.minY < (cell.y + 1) * 256 and bounds.maxY >= cell.y * 256)
            end
            if affected then Engine.repair(bounds, record.z, record.z) end
        end
    end
end

local function applyLevel(r, record)
    local key = identity(r) .. ":" .. record.z
    local signature = Topology.signature(record.rooms)
    if applied[key] ~= signature or not Engine.present(record) then
        local ok, reason = Engine.register(record)
        if not ok then
            LOG.warning("Registration deferred for %s z=%d: %s", identity(r), record.z, tostring(reason))
            return false
        end
        applied[key] = signature
        return true, reason == "owned"
    end
    return true
end

local function refresh(r, rebuild)
    if not getCell() or not getWorld() then return false end
    local bounds = MSR.RefugeGeometry.GetTileBounds(r)
    local highest = maxLevel(r, bounds)
    if not highest then return false end
    local changed, complete = false, true
    local state = r.rooms or { version = 1, levels = {} }
    if not isClient() and rebuild then
        if not basementEnabled(r) then
            local previous = state.levels[tostring(r.centerZ - 1)]
            if previous then
                Engine.remove(previous)
                state.levels[tostring(r.centerZ - 1)] = nil
                applied[identity(r) .. ":" .. previous.z] = nil
                changed = true
            end
        end
        local lowest = basementEnabled(r) and r.centerZ - 1 or r.centerZ
        for _, record in pairs(state.levels) do highest = math.max(highest, record.z) end
        local snapshot = sample(bounds, lowest, highest)
        for z = lowest, highest do
            local tiles = assert(snapshot[tostring(z)])
            local ready = true
            if z < r.centerZ then
                for y = bounds.minY, bounds.maxY do
                    for x = bounds.minX, bounds.maxX do
                        if not tiles[Topology.key(x, y)].exists then ready = false end
                    end
                end
            end
            local rooms = ready and Topology.rooms(bounds, tiles, z < r.centerZ) or nil
            if rooms then
                local previous = state.levels[tostring(z)]
                if #rooms == 0 then
                    if previous then
                        Engine.remove(previous)
                        state.levels[tostring(z)] = nil
                        applied[identity(r) .. ":" .. z] = nil
                        changed = true
                    end
                elseif not previous or Topology.signature(previous.rooms) ~= Topology.signature(rooms) then
                    local extent = MSR.RefugeGeometry.GetMaximumDirectionalExtent()
                    state.levels[tostring(z)] = {
                        z = z, ax = r.centerX - extent, ay = r.centerY - extent, rooms = rooms,
                    }
                    changed = true
                end
            else
                complete = false
            end
        end
        r.rooms = state
    end
    local relight = false
    for _, record in pairs(state.levels) do
        local ok, rebuilt = applyLevel(r, record)
        if not ok then complete = false end
        relight = relight or rebuilt == true
    end
    Engine.repair(bounds, r.centerZ - 1, math.max(highest, r.centerZ), relight)
    -- Consume a shared mutation journal, including changes made by deletion or
    -- network pruning outside refresh. Java renumbers other rooms in that cell.
    repairRenumberedRooms()
    if changed then
        -- These lossy ID/bounding-box formats have no role in the new service.
        r.roomIds, r.roomData, r.roomBounds = nil, nil, nil
        MSR.Data.SaveRefugeData(r)
    end
    return complete
end

function Rooms.Refresh(r)
    if not r or applying then return false end
    applying = true
    local ok, result = pcall(refresh, r, not isClient())
    applying = false
    if not ok then LOG.error("Room refresh failed for %s: %s", identity(r), tostring(result)) end
    return ok and result == true
end

-- A single short-lived dispatcher coalesces construction, loading and entry.
-- Failed/incomplete loads retain saved geometry and stop after a bounded wait;
-- the next chunk, entry or structural event schedules another attempt.
function Rooms.Schedule(r, rebuild)
    if not r or applying then return end
    local key = identity(r)
    local job = pending[key]
    if job then
        job.refuge = r
        job.rebuild = job.rebuild or rebuild
        job.quiet = 0
        return
    end
    pending[key] = { refuge = r, rebuild = rebuild, ticks = 0, quiet = 0 }
    if not scheduled then
        scheduled = true
        Events.OnTick.Add(process)
    end
end

process = function()
    for key, job in pairs(pending) do
        job.ticks = job.ticks + 1
        job.quiet = job.quiet + 1
        if job.quiet == DEBOUNCE_TICKS or job.quiet == 60 or job.quiet % 120 == 0
            or (job.ticks >= MAX_WAIT_TICKS and job.quiet >= 120) then
            -- Resolve the current registry object: deletion, inheritance, MP
            -- sync and expansion can replace an object while a job is pending.
            local current
            for _, candidate in pairs(registry()) do
                if identity(candidate) == key then current = candidate; break end
            end
            if not current then
                pending[key] = nil
            else
                job.refuge = current
                applying = true
                local ok, complete = pcall(refresh, job.refuge, job.rebuild and not isClient())
                applying = false
                if not ok then
                    LOG.error("Room lifecycle failed for %s: %s", key, tostring(complete))
                    pending[key] = nil
                elseif (complete and job.quiet >= 120)
                    or (job.ticks >= MAX_WAIT_TICKS and job.quiet >= 120) then
                    pending[key] = nil
                end
            end
        end
    end
    if K.isEmpty(pending) then
        Events.OnTick.Remove(process)
        scheduled = false
    end
end

function Rooms.Forget(r)
    local key = identity(r)
    pending[key] = nil
    applying = true
    for _, record in pairs(r.rooms and r.rooms.levels or {}) do
        local ok, reason = pcall(Engine.remove, record)
        if not ok then LOG.error("Room removal failed for %s: %s", key, tostring(reason)) end
        applied[key .. ":" .. record.z] = nil
    end
    repairRenumberedRooms()
    applying = false
end

local function scheduleAll(rebuild)
    for _, r in pairs(registry()) do Rooms.Schedule(r, rebuild) end
end

local function atPosition(x, y, z, rebuild)
    local r = MSR.Data.GetRefugeDataAtPosition(x, y, z)
    if r and z >= r.centerZ - 1 and z <= 31 then Rooms.Schedule(r, rebuild) end
    return r
end

local function onSquareLoaded(sq)
    if applying then return end
    atPosition(sq:getX(), sq:getY(), sq:getZ(), true)
end

local function onObjectChanged(obj)
    if applying then return end
    local sq = obj and obj:getSquare()
    if not sq then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    -- East/south wall tiles can lie just beyond the usable refuge bounds.
    local r = atPosition(x, y, z, true) or atPosition(x - 1, y, z, true)
        or atPosition(x, y - 1, z, true)
    if r and isClient() then
        -- A hint only. The server derives geometry from its own world squares.
        Rooms.RequestRefresh(r)
    end
end

function Rooms.RequestRefresh(r)
    if not isClient() then Rooms.Schedule(r, true); return end
    local player = getPlayer()
    if not player or not MSR.RefugeGeometry.ContainsTile(r, player:getX(), player:getY()) then return end
    local key = identity(r)
    -- At most one network hint per pending work batch.
    local job = pending[key]
    if job and job.requested then return end
    Rooms.Schedule(r, false)
    job = pending[key]
    if job then job.requested = true end
    sendClientCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.ROOMS_CHANGED, {})
end

function Rooms.HandleRefreshRequest(player)
    if not isServer() or not player then return end
    local r = MSR.Data.GetRefugeData(player)
    if r and MSR.RefugeGeometry.ContainsTile(r, player:getX(), player:getY()) then
        Rooms.Schedule(r, true)
    end
end

-- Keep the existing visual contract independent of persistence/registration.
function Rooms.UpdateCutaway(r, playerIndex)
    if not r or not getCell() then return end
    local bounds, now = MSR.RefugeGeometry.GetTileBounds(r), getTimestampMs()
    for z = r.centerZ, math.min(31, r.centerZ + 3) do
        for x = bounds.minX - 1, bounds.maxX + 1 do
            for y = bounds.minY - 1, bounds.maxY + 1 do
                local sq = getCell():getGridSquare(x, y, z)
                if sq then
                    if z > r.centerZ then sq:setPlayerCutawayFlag(playerIndex or 0, 1, now) end
                    sq:invalidateRenderChunkLevel(2048)
                end
            end
        end
    end
end

-- Read-only acceptance report. Useful after teleport, reload and construction;
-- deliberately performs no repair so it cannot hide a lifecycle regression.
function Rooms.Verify(r)
    local report = { ready = r ~= nil and r.rooms ~= nil, levels = {}, expected = 0, matched = 0 }
    if not r or not getCell() or not getWorld() then report.ready = false; return report end
    local grid = getWorld():getMetaGrid()
    local bounds = MSR.RefugeGeometry.GetTileBounds(r)
    local highest = maxLevel(r, bounds)
    if highest then
        for _, record in pairs(r.rooms and r.rooms.levels or {}) do highest = math.max(highest, record.z) end
        local lowest = basementEnabled(r) and r.centerZ - 1 or r.centerZ
        local snapshot = sample(bounds, lowest, highest)
        for z = lowest, highest do
            local desired = Topology.rooms(bounds, snapshot[tostring(z)], z < r.centerZ)
            local saved = r.rooms and r.rooms.levels[tostring(z)]
            if Topology.signature(desired) ~= Topology.signature(saved and saved.rooms or {}) then
                report.ready = false
                LOG.info("Verify %s z=%d: physical geometry differs from saved rooms", identity(r), z)
            end
        end
    else
        report.ready = false
    end
    if basementEnabled(r) and not (r.rooms and r.rooms.levels[tostring(r.centerZ - 1)]) then report.ready = false end
    for z, record in pairs(r.rooms and r.rooms.levels or {}) do
        local layer = { expected = 0, loaded = 0, matched = 0, outside = 0 }
        for _, room in ipairs(record.rooms) do
            for _, rect in ipairs(room.rects) do
                for x = rect.x, rect.x + rect.w - 1 do
                    for y = rect.y, rect.y + rect.h - 1 do
                        layer.expected = layer.expected + 1
                        local sq = getCell():getGridSquare(x, y, record.z)
                        local def = sq and sq:getChunk() and grid:getRoomAt(x, y, record.z)
                        if sq and sq:getChunk() then
                            layer.loaded = layer.loaded + 1
                            if sq:isOutside() then layer.outside = layer.outside + 1 end
                            if def and sq:getRoom() == def:getIsoRoom() and not sq:isOutside()
                                and sq:getRoomIDString() == def:getIDString() then
                                layer.matched = layer.matched + 1
                            end
                        end
                    end
                end
            end
        end
        report.expected = report.expected + layer.expected
        report.matched = report.matched + layer.matched
        report.ready = report.ready and layer.expected == layer.matched and Engine.present(record)
        report.levels[z] = layer
        LOG.info("Verify %s z=%d: expected=%d loaded=%d matched=%d outside=%d",
            identity(r), record.z, layer.expected, layer.loaded, layer.matched, layer.outside)
    end
    LOG.info("Verify %s: %s (%d/%d)", identity(r), report.ready and "PASS" or "FAIL", report.matched, report.expected)
    return report
end

local function onEntry(payload)
    local player = payload and payload.player
    local r = payload and payload.refugeData or (player and MSR.Data.GetRefugeData(player))
    if not r then return end
    Rooms.Schedule(r, true)
    Rooms.UpdateCutaway(r, player and player:getPlayerNum() or 0)
end

local function installConstructionHooks()
    if buildUtil and not buildUtil.MSR_roomsWrapped then
        local original = buildUtil.setHaveConstruction
        buildUtil.setHaveConstruction = function(sq, ...)
            local result = original(sq, ...)
            if sq then
                local r = atPosition(sq:getX(), sq:getY(), sq:getZ(), true)
                if r and isClient() then Rooms.RequestRefresh(r) end
            end
            return result
        end
        buildUtil.MSR_roomsWrapped = true
    end
    if ISBuildIsoEntity and not ISBuildIsoEntity.MSR_roomsWrapped then
        ---@type fun(self: ISBuildIsoEntity, x: number, y: number, z: number, north: boolean, sprite: string): boolean?
        local original = ISBuildIsoEntity.create
        ---@param self ISBuildIsoEntity
        ---@param x number
        ---@param y number
        ---@param z number
        ---@param north boolean
        ---@param sprite string
        local function create(self, x, y, z, north, sprite)
            local result = original(self, x, y, z, north, sprite)
            local r = atPosition(x, y, z, true) or atPosition(x - 1, y, z, true)
                or atPosition(x, y - 1, z, true)
            if r and isClient() then Rooms.RequestRefresh(r) end
            return result
        end
        ---@diagnostic disable-next-line: assign-type-mismatch -- Lua method values include their implicit self parameter.
        ISBuildIsoEntity.create = create
        ISBuildIsoEntity.MSR_roomsWrapped = true
    end
end

Events.LoadGridsquare.Add(onSquareLoaded)
Events.OnObjectAdded.Add(onObjectChanged)
Events.OnObjectAboutToBeRemoved.Add(onObjectChanged)
Events.OnGameBoot.Add(installConstructionHooks)
Events.OnGameStart.Add(installConstructionHooks)
Events.OnServerStarted.Add(installConstructionHooks)
Events.OnSave.Add(function()
    if not isClient() then
        for _, r in pairs(registry()) do Rooms.Refresh(r) end
    end
end)
Events.OnReceiveGlobalModData.Add(function(key, data)
    if not isClient() or key ~= MSR.Config.MODDATA_KEY or type(data) ~= "table" then return end
    local incoming = data[MSR.Config.REFUGES_KEY] or {}
    for username, r in pairs(registry()) do
        local replacement = incoming[username]
        if not replacement or identity(replacement) ~= identity(r) then
            Rooms.Forget(r)
        else
            for z, record in pairs(r.rooms and r.rooms.levels or {}) do
                if not (replacement.rooms and replacement.rooms.levels[z]) then
                    applying = true
                    Engine.remove(record)
                    applying = false
                    applied[identity(r) .. ":" .. record.z] = nil
                end
            end
        end
    end
    ModData.add(key, data)
    repairRenumberedRooms()
    scheduleAll(false)
end)
MSR.Events.OnAnyReady.Add(function() scheduleAll(true) end)
MSR.Events.Custom.Add("MSR_TeleportEnterCompleted", onEntry)
MSR.Events.Custom.Add("MSR_ModDataReady", function() scheduleAll(false) end)

return Rooms
