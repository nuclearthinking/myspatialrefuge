-- MSR_RoomPersistence - Room Persistence Module
-- Handles saving and restoring room IDs for player-built structures
--
-- Flow:
--   1. SAVE before teleport OUT  (capture current room state)
--   2. RESTORE after teleport IN (apply saved room state)
--
-- Why: Game loses room associations when player teleports away.
--      Normal gameplay (game load, building) works fine without this.

require "shared/00_core/00_MSR"
require "shared/00_core/05_Config"
require "shared/00_core/06_Data"
require "shared/00_core/04_Env"
require "shared/helpers/World"

-- Prevent double-loading
if MSR.RoomPersistence and MSR.RoomPersistence._loaded then
    return MSR.RoomPersistence
end

MSR.RoomPersistence = MSR.RoomPersistence or {}
MSR.RoomPersistence._loaded = true

-- Local alias
local RoomPersistence = MSR.RoomPersistence

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

local function getRoomDataKey(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

local function parseRoomDataKey(key)
    local parts = {}
    for part in string.gmatch(key, "[^,]+") do
        table.insert(parts, tonumber(part))
    end
    if #parts == 3 then
        return parts[1], parts[2], parts[3]
    end
    return nil, nil, nil
end

local function migrateRoomData(refugeData)
    if not refugeData then return end
    if refugeData.roomIds then return end  -- Already migrated
    
    if refugeData.roomData then
        refugeData.roomIds = {}
        for key, data in pairs(refugeData.roomData) do
            local roomId = data.roomId or data
            if roomId and roomId ~= -1 then
                refugeData.roomIds[key] = roomId
            end
        end
        L.debug("RoomPersistence", string.format("[MIGRATION] Migrated %d room IDs from roomData to roomIds", 
            K.count(refugeData.roomIds)))
    end
end

-----------------------------------------------------------
-- Core Functions
-----------------------------------------------------------

--- Save room IDs from refuge area to ModData. Cleans up stale entries.
function RoomPersistence.Save(refugeData)
    if not refugeData then return 0 end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local tier = refugeData.tier or 0
    local tierData = MSR.Config.TIERS[tier]
    local radius = tierData and tierData.radius or 1
    
    -- Check if world is ready
    if not MSR.World.isChunkLoaded(centerX, centerY, centerZ) then
        return 0
    end
    
    -- Initialize roomIds structure (migrate if needed)
    if not refugeData.roomIds then
        refugeData.roomIds = {}
    end
    migrateRoomData(refugeData)
    
    local savedCount = 0
    local updatedCount = 0
    local unchangedCount = 0
    local removedCount = 0
    
    L.debug("RoomPersistence", string.format("Starting save scan for refuge at %d,%d (radius=%d)", 
        centerX, centerY, radius))
    
    -- Mark entries for potential cleanup (valid ones will be unmarked)
    local entriesToRemove = {}
    for key in pairs(refugeData.roomIds) do
        entriesToRemove[key] = true
    end
    
    local scanRadius = radius + 1
    MSR.World.iterateArea(centerX, centerY, centerZ, scanRadius, function(square, x, y)
        local key = getRoomDataKey(x, y, centerZ)
        local roomId = -1
        if square.getRoomID then
            local success, id = pcall(function() return square:getRoomID() end)
            if success and id and id ~= -1 then
                roomId = id
            end
        end
        
        if roomId ~= -1 then
            entriesToRemove[key] = nil  -- Keep this entry
            
            local existing = refugeData.roomIds[key]
            if existing == roomId then
                unchangedCount = unchangedCount + 1
            else
                refugeData.roomIds[key] = roomId
                if existing then
                    updatedCount = updatedCount + 1
                    L.debug("RoomPersistence", string.format("UPDATED %s: roomId=%d (was %d)", 
                        key, roomId, existing))
                else
                    savedCount = savedCount + 1
                    L.debug("RoomPersistence", string.format("SAVED %s: roomId=%d", key, roomId))
                end
            end
        end
    end)
    
    -- Remove stale entries (demolished/changed rooms)
    for key in pairs(entriesToRemove) do
        local oldRoomId = refugeData.roomIds[key]
        refugeData.roomIds[key] = nil
        removedCount = removedCount + 1
        L.debug("RoomPersistence", string.format("REMOVED %s: old roomId=%d (room demolished or changed)", 
            key, oldRoomId or -1))
    end
    
    if savedCount > 0 or updatedCount > 0 or removedCount > 0 then
        -- Save to ModData
        MSR.Data.SaveRefugeData(refugeData)
        L.debug("RoomPersistence", string.format("SUMMARY: %d new, %d updated, %d unchanged, %d removed (stale)", 
            savedCount, updatedCount, unchangedCount, removedCount))
        return savedCount + updatedCount
    else
        local totalSaved = 0
        if refugeData.roomIds then
            for _ in pairs(refugeData.roomIds) do
                totalSaved = totalSaved + 1
            end
        end
        L.debug("RoomPersistence", string.format("NO CHANGES: %d room IDs already saved in ModData", totalSaved))
        return 0
    end
end

--- Sync room IDs from client to server (MP only, clients can't write ModData)
function RoomPersistence.SyncToServer(refugeData)
    if MSR.Env.isServer() then return 0 end
    if MSR.Env.isSingleplayer() then return 0 end
    
    if not refugeData or not refugeData.roomIds then return 0 end
    
    local count = K.count(refugeData.roomIds)
    if count == 0 then return 0 end
    
    local player = getPlayer()
    if not player then return 0 end
    
    local roomIdsToSync = {}
    for key, roomId in pairs(refugeData.roomIds) do
        roomIdsToSync[key] = roomId
    end
    
    sendClientCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.SYNC_CLIENT_DATA, {
        username = player:getUsername(),
        dataType = "roomIds",
        data = roomIdsToSync
    })
    
    L.debug("RoomPersistence", string.format("Sent %d room IDs to server for saving", count))
    return count
end

-----------------------------------------------------------
-- Server-Side Sync Handler
-----------------------------------------------------------

--- Handle client data sync (server persists client-discovered data)
function RoomPersistence.HandleSyncFromClient(player, args)
    if not MSR.Env.isServer() then return end
    if not player or not args then return end
    
    local username = args.username or (player:getUsername())
    local dataType = args.dataType
    local data = args.data
    
    if not dataType or not data then
        L.debug("RoomPersistence", string.format("[SERVER] Received invalid sync from %s: missing dataType or data", username))
        return
    end
    
    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
    if not refugeData then
        L.debug("RoomPersistence", string.format("[SERVER] No refuge data found for %s", username))
        return
    end
    
    if dataType == "roomIds" then
        refugeData.roomIds = refugeData.roomIds or {}
        
        local newCount = 0
        local updatedCount = 0
        for key, roomId in pairs(data) do
            if not refugeData.roomIds[key] then
                refugeData.roomIds[key] = roomId
                newCount = newCount + 1
            elseif refugeData.roomIds[key] ~= roomId then
                refugeData.roomIds[key] = roomId
                updatedCount = updatedCount + 1
            end
        end
        
        if newCount > 0 or updatedCount > 0 then
            MSR.Data.SaveRefugeData(refugeData)
            L.debug("RoomPersistence", string.format("[SERVER] Synced roomIds from %s: %d new, %d updated", 
                username, newCount, updatedCount))
        else
            L.debug("RoomPersistence", string.format("[SERVER] roomIds from %s already up to date", username))
        end
    else
        -- Unknown data type - log warning but still try to save
        L.debug("RoomPersistence", string.format("[SERVER] Unknown dataType '%s' from %s - storing anyway", dataType, username))
        refugeData[dataType] = data
        MSR.Data.SaveRefugeData(refugeData)
    end
end


--- Restore room IDs from saved ModData
function RoomPersistence.Restore(refugeData)
    if not refugeData then return 0 end
    
    migrateRoomData(refugeData)
    
    if not refugeData.roomIds or K.isEmpty(refugeData.roomIds) then
        return 0
    end
    
    local cell = getCell()
    local metaGrid = cell and getWorld():getMetaGrid()
    if not metaGrid then return 0 end
    
    local restoredCount, skippedCount = 0, 0
    
    for key, roomId in pairs(refugeData.roomIds) do
        local x, y, z = parseRoomDataKey(key)
        if roomId and roomId ~= -1 and x and y and z then
            local square = cell:getGridSquare(x, y, z)
            if square and square:getChunk() then
                if square:getRoomID() == roomId then
                    skippedCount = skippedCount + 1
                else
                    local roomDef = metaGrid:getRoomDefByID(roomId)
                    local roomObj = roomDef and metaGrid:getRoomByID(roomId)
                    if roomObj then
                        square:setRoomID(roomId)
                        restoredCount = restoredCount + 1
                    else
                        skippedCount = skippedCount + 1
                    end
                end
            end
        end
    end
    
    if restoredCount > 0 then
        L.debug("RoomPersistence", string.format("Restored %d roomIds (%d skipped)", restoredCount, skippedCount))
        RoomPersistence.RefreshRoomContents(refugeData)
    end
    
    return restoredCount
end

--- Repopulate room contents (waterSources, lightSwitches) after restoration
function RoomPersistence.RefreshRoomContents(refugeData)
    if not refugeData or not refugeData.roomIds then return 0 end
    
    local cell = getCell()
    if not cell then return 0 end
    
    local metaGrid = getWorld():getMetaGrid()
    if not metaGrid then return 0 end
    
    local roomSquares = {}  -- roomId -> squares
    for key, roomId in pairs(refugeData.roomIds) do
        if roomId and roomId ~= -1 then
            local x, y, z = parseRoomDataKey(key)
            if x and y and z then
                local square = cell:getGridSquare(x, y, z)
                if square and square:getChunk() then
                    if not roomSquares[roomId] then
                        roomSquares[roomId] = {}
                    end
                    table.insert(roomSquares[roomId], square)
                end
            end
        end
    end
    
    local refreshedRooms = 0
    
    for roomId, squares in pairs(roomSquares) do
        repeat  -- Lua 5.1: repeat-until true for early exit
            local success, room = pcall(function()
                return metaGrid:getRoomByID(roomId)
            end)
            
            if not success or not room then break end
            
            local addedSquares = 0
            local waterSourcesFound = 0
            local lightSwitchesFound = 0
            
            for _, square in ipairs(squares) do
                if room.addSquare then
                    local addSuccess = pcall(function()
                        room:addSquare(square)
                    end)
                    if addSuccess then
                        addedSquares = addedSquares + 1
                    end
                end
                
                MSR.World.iterateObjects(square, function(obj)
                    -- Water sources
                    if obj.hasWater or obj.getUsesExternalWaterSource then
                        local isWaterSource = false
                        if obj.getUsesExternalWaterSource then
                            local usesExternal = pcall(function() return obj:getUsesExternalWaterSource() end)
                            isWaterSource = usesExternal
                        end
                        if isWaterSource or (obj.hasWater and obj:hasWater()) then
                            if room.waterSources and room.waterSources.add then
                                local addWaterSuccess = pcall(function()
                                    if not room.waterSources:contains(obj) then
                                        room.waterSources:add(obj)
                                    end
                                end)
                                if addWaterSuccess then
                                    waterSourcesFound = waterSourcesFound + 1
                                end
                            end
                        end
                    end
                    
                    -- Light switches
                    if instanceof(obj, "IsoLightSwitch") then
                        if room.lightSwitches and room.lightSwitches.add then
                            local addLightSuccess = pcall(function()
                                if not room.lightSwitches:contains(obj) then
                                    room.lightSwitches:add(obj)
                                end
                            end)
                            if addLightSuccess then
                                lightSwitchesFound = lightSwitchesFound + 1
                            end
                        end
                    end
                end)
            end
            
            if addedSquares > 0 or waterSourcesFound > 0 or lightSwitchesFound > 0 then
                refreshedRooms = refreshedRooms + 1
                L.debug("RoomPersistence", string.format("Room %d: added %d squares, %d water sources, %d light switches",
                    roomId, addedSquares, waterSourcesFound, lightSwitchesFound))
            end
        until true
    end
    
    return refreshedRooms
end

--- Remove room IDs outside refuge bounds
function RoomPersistence.CleanupStaleData(refugeData)
    if not refugeData or not refugeData.roomIds then return 0 end
    
    migrateRoomData(refugeData)
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local tier = refugeData.tier or 0
    local tierData = MSR.Config.TIERS[tier]
    local radius = tierData and tierData.radius or 1
    
    local cell = getCell()
    if not cell then return 0 end
    
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius
    
    local removedCount = 0
    
    for key, _ in pairs(refugeData.roomIds) do
        local x, y, z = parseRoomDataKey(key)
        if x and y and z then
            if x < minX - 1 or x > maxX + 1 or y < minY - 1 or y > maxY + 1 or z ~= centerZ then
                refugeData.roomIds[key] = nil
                removedCount = removedCount + 1
            end
            -- Keep entries for unloaded chunks (might be temporary)
        else
            refugeData.roomIds[key] = nil  -- Invalid key
            removedCount = removedCount + 1
        end
    end
    
    if removedCount > 0 then
        MSR.Data.SaveRefugeData(refugeData)
        L.debug("RoomPersistence", string.format("Cleanup: Removed %d stale room IDs", removedCount))
    end
    
    return removedCount
end

--- Verify restoration success (for debugging)
function RoomPersistence.Verify(refugeData)
    if not refugeData then return nil end
    
    migrateRoomData(refugeData)
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local tier = refugeData.tier or 0
    local tierData = MSR.Config.TIERS[tier]
    local radius = tierData and tierData.radius or 1
    
    local cell = getCell()
    if not cell then return nil end
    
    local stats = {
        totalSquares = 0,
        squaresWithRoomId = 0,
        savedRooms = 0,
        restoredRooms = 0,
        missingRooms = 0
    }
    
    if refugeData.roomIds then
        for _ in pairs(refugeData.roomIds) do
            stats.savedRooms = stats.savedRooms + 1
        end
    end
    
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius
    
    for x = minX - 1, maxX + 1 do
        for y = minY - 1, maxY + 1 do
            local square = cell:getGridSquare(x, y, centerZ)
            if square and square:getChunk() then
                stats.totalSquares = stats.totalSquares + 1
                
                local roomId = -1
                if square.getRoomID then
                    roomId = square:getRoomID()
                end
                
                if roomId ~= -1 then
                    stats.squaresWithRoomId = stats.squaresWithRoomId + 1
                end
                
                -- Check if this square should have a room (from saved data)
                local key = getRoomDataKey(x, y, centerZ)
                local savedRoomId = refugeData.roomIds and refugeData.roomIds[key]
                
                if savedRoomId then
                    if roomId == savedRoomId then
                        stats.restoredRooms = stats.restoredRooms + 1
                    else
                        stats.missingRooms = stats.missingRooms + 1
                    end
                end
            end
        end
    end
    
    local restorationRate = stats.savedRooms > 0 and (stats.restoredRooms / stats.savedRooms * 100) or 0
    L.debug("RoomPersistence", string.format("VERIFY: %d total squares, %d with roomId, %d saved, %d restored, %d missing (%.1f%% restoration rate)", 
        stats.totalSquares, stats.squaresWithRoomId, stats.savedRooms, stats.restoredRooms, stats.missingRooms, restorationRate))
    
    return stats
end

-----------------------------------------------------------
-- Server-Side Functions
-----------------------------------------------------------

--- Server-side restore (delegates to Restore)
function RoomPersistence.RestoreServer(refugeData)
    if not refugeData then return 0 end
    return RoomPersistence.Restore(refugeData)
end

--- Log current state on exit (actual data comes from client sync)
function RoomPersistence.SaveServerOnExit(refugeData)
    if not refugeData then return 0 end
    local count = refugeData.roomIds and K.count(refugeData.roomIds) or 0
    if count > 0 then
        L.debug("RoomPersistence", string.format("[SERVER] Exit: %s has %d room IDs persisted", 
            refugeData.username or "unknown", count))
    end
    return count
end

return MSR.RoomPersistence
