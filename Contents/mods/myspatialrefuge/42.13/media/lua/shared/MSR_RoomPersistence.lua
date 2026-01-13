-- MSR_RoomPersistence - Room Persistence Module
-- Storage: roomBounds = { [roomIdStr] = { x, y, w, h, z }, ... }

require "00_core/00_MSR"
require "helpers/World"

local LOG = L.logger("RoomPersistence")

if MSR and MSR.RoomPersistence and MSR.RoomPersistence._loaded then
    return MSR.RoomPersistence
end

MSR.RoomPersistence = MSR.RoomPersistence or {}
MSR.RoomPersistence._loaded = true

local RoomPersistence = MSR.RoomPersistence

-----------------------------------------------------------
-- Compression
-----------------------------------------------------------

--- @param scannedCells table[] { x, y, z, roomId }
--- @return table roomBounds { [roomIdStr] = { x, y, w, h, z } }
local function compressRoomData(scannedCells)
    if not scannedCells or #scannedCells == 0 then return {} end
    
    local boundsMap = {}
    for _, c in ipairs(scannedCells) do
        local key = tostring(c.roomId)
        local b = boundsMap[key]
        if not b then
            boundsMap[key] = { minX = c.x, maxX = c.x, minY = c.y, maxY = c.y, z = c.z }
        else
            if c.x < b.minX then b.minX = c.x end
            if c.x > b.maxX then b.maxX = c.x end
            if c.y < b.minY then b.minY = c.y end
            if c.y > b.maxY then b.maxY = c.y end
        end
    end
    
    -- Sort by area desc for nested room detection
    local roomList = {}
    for key, b in pairs(boundsMap) do
        local w, h = b.maxX - b.minX + 1, b.maxY - b.minY + 1
        table.insert(roomList, { key = key, x = b.minX, y = b.minY, w = w, h = h, z = b.z, area = w * h })
    end
    table.sort(roomList, function(a, b) return a.area > b.area end)
    
    -- Skip rooms fully contained in larger rooms
    local result, kept = {}, {}
    for _, r in ipairs(roomList) do
        local nested = false
        for _, k in ipairs(kept) do
            if r.x >= k.x and r.y >= k.y and r.x + r.w <= k.x + k.w and r.y + r.h <= k.y + k.h and r.z == k.z then
                nested = true
                break
            end
        end
        if not nested then
            table.insert(kept, r)
            result[r.key] = { x = r.x, y = r.y, w = r.w, h = r.h, z = r.z }
        end
    end
    
    LOG.debug("Compressed %d cells -> %d bounds", #scannedCells, K.count(result))
    return result
end

-----------------------------------------------------------
-- Save
-----------------------------------------------------------

function RoomPersistence.Save(refugeData)
    if not refugeData then return 0 end
    
    local centerX, centerY, centerZ = refugeData.centerX, refugeData.centerY, refugeData.centerZ
    local radius = refugeData.radius or 1
    
    if not MSR.World.isChunkLoaded(centerX, centerY, centerZ) then return 0 end
    
    local cells = {}
    MSR.World.iterateArea(centerX, centerY, centerZ, radius + 1, function(square, x, y)
        local id = square:getRoomID()
        if id and id ~= -1 then
            table.insert(cells, { x = x, y = y, z = centerZ, roomId = id })
        end
    end)
    
    local bounds = compressRoomData(cells)
    refugeData.roomIds = nil
    refugeData.roomData = nil
    refugeData.roomBounds = bounds
    MSR.Data.SaveRefugeData(refugeData)
    
    local count = K.count(bounds)
    LOG.debug("Saved %d room bounds", count)
    return count
end

-----------------------------------------------------------
-- Restore
-----------------------------------------------------------

function RoomPersistence.Restore(refugeData)
    if not refugeData or not refugeData.roomBounds or K.isEmpty(refugeData.roomBounds) then return 0 end
    
    local gameCell = getCell()
    local metaGrid = gameCell and getWorld():getMetaGrid()
    if not metaGrid then return 0 end
    
    local roomCache = {}
    local roomSquares = {}
    local restored = 0
    
    for roomIdStr, b in pairs(refugeData.roomBounds) do
        repeat -- continue pattern: break skips to next iteration
            local roomId = tonumber(roomIdStr)
            if not roomId then break end
            
            if roomCache[roomId] == nil then
                roomCache[roomId] = metaGrid:getRoomByID(roomId) or false
            end
            local room = roomCache[roomId]
            if not room then break end
            
            roomSquares[roomId] = roomSquares[roomId] or {}
            
            for x = b.x, b.x + b.w - 1 do
                for y = b.y, b.y + b.h - 1 do
                    local square = gameCell:getGridSquare(x, y, b.z)
                    if square and square:getChunk() then
                        if square:getRoomID() ~= roomId then
                            square:setRoomID(roomId)
                            restored = restored + 1
                        end
                        table.insert(roomSquares[roomId], square)
                    end
                end
            end
        until true
    end
    
    if restored > 0 then
        LOG.debug("Restored %d room IDs", restored)
        RoomPersistence.RefreshRoomContents(roomSquares, roomCache)
    end
    
    return restored
end

--- Re-register water sources and light switches after room restoration
function RoomPersistence.RefreshRoomContents(roomSquares, roomCache)
    if not roomSquares then return end
    
    for roomId, squares in pairs(roomSquares) do
        local room = roomCache[roomId]
        if room then
            for _, square in ipairs(squares) do
                if room.addSquare then pcall(room.addSquare, room, square) end
                
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj then
                            if room.waterSources and (obj.hasWater or obj.getUsesExternalWaterSource) then
                                local isWater = (obj.hasWater and obj:hasWater()) or 
                                               (obj.getUsesExternalWaterSource and obj:getUsesExternalWaterSource())
                                if isWater and not room.waterSources:contains(obj) then
                                    pcall(room.waterSources.add, room.waterSources, obj)
                                end
                            end
                            if room.lightSwitches and instanceof(obj, "IsoLightSwitch") then
                                if not room.lightSwitches:contains(obj) then
                                    pcall(room.lightSwitches.add, room.lightSwitches, obj)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-----------------------------------------------------------
-- Cutaway
-----------------------------------------------------------

--- Force upper floors transparent via cutaway flags
function RoomPersistence.ForceCutaway(refugeData, playerIndex)
    if not refugeData then return 0 end
    
    local gameCell = getCell()
    if not gameCell then return 0 end
    
    local cx, cy, cz = refugeData.centerX, refugeData.centerY, refugeData.centerZ or 0
    local r = (refugeData.radius or 1) + 1
    local timestamp = getTimestampMs()
    local count = 0
    
    for x = cx - r, cx + r do
        for y = cy - r, cy + r do
            for z = cz, cz + 3 do
                local square = gameCell:getGridSquare(x, y, z)
                if square then
                    if z > cz then
                        square:setPlayerCutawayFlag(playerIndex or 0, 1, timestamp)
                        square:setSquareChanged()
                        count = count + 1
                    end
                    square:invalidateRenderChunkLevel(2048) -- DIRTY_CUTAWAYS
                end
            end
        end
    end
    
    LOG.debug("Applied cutaway to %d squares", count)
    return count
end

-----------------------------------------------------------
-- Entry Point
-----------------------------------------------------------

--- Called on refuge entry: restore -> save new -> restore new -> cutaway
function RoomPersistence.ApplyCutaway(refugeData)
    if not refugeData then return end
    
    RoomPersistence.Restore(refugeData)
    if RoomPersistence.Save(refugeData) > 0 then
        RoomPersistence.Restore(refugeData)
    end
    RoomPersistence.ForceCutaway(refugeData, 0)
end

-----------------------------------------------------------
-- MP Sync
-----------------------------------------------------------

function RoomPersistence.SyncToServer(refugeData)
    if MSR.Env.isServer() or MSR.Env.isSingleplayer() then return 0 end
    if not refugeData or not refugeData.roomBounds then return 0 end
    
    local count = K.count(refugeData.roomBounds)
    if count == 0 then return 0 end
    
    local player = getPlayer()
    if not player then return 0 end
    
    sendClientCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.SYNC_CLIENT_DATA, {
        username = player:getUsername(),
        dataType = "roomBounds",
        data = refugeData.roomBounds
    })
    return count
end

function RoomPersistence.HandleSyncFromClient(player, args)
    if not MSR.Env.isServer() or not player or not args or not args.data then return end
    
    local refugeData = MSR.Data.GetRefugeDataByUsername(args.username or player:getUsername())
    if not refugeData then return end
    
    refugeData.roomIds = nil
    refugeData.roomData = nil
    refugeData.roomBounds = args.data
    MSR.Data.SaveRefugeData(refugeData)
end

-----------------------------------------------------------
-- Server
-----------------------------------------------------------

function RoomPersistence.RestoreServer(refugeData)
    return refugeData and RoomPersistence.Restore(refugeData) or 0
end

function RoomPersistence.SaveServerOnExit(refugeData)
    return refugeData and refugeData.roomBounds and K.count(refugeData.roomBounds) or 0
end

return MSR.RoomPersistence
