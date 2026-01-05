-- MSR_RoomPersistence - Room Persistence Module
-- Handles saving and restoring room IDs for player-built structures
--
-- Flow:
--   1. SAVE before teleport OUT  (capture current room state)
--   2. RESTORE after teleport IN (apply saved room state)
--
-- Why: Game loses room associations when player teleports away.
--      Normal gameplay (game load, building) works fine without this.

require "shared/MSR"
require "shared/MSR_Config"
require "shared/MSR_Data"
require "shared/MSR_Env"

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

-- Create room data key from coordinates
local function getRoomDataKey(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

-- Parse room data key to coordinates
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

-- Migrate old roomData structure to new roomIds structure
local function migrateRoomData(refugeData)
    if not refugeData then return end
    
    -- If roomIds already exists, no migration needed
    if refugeData.roomIds then return end
    
    -- If roomData exists, migrate it
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

-- Save room IDs from refuge area to ModData
-- Uses ONLY square:getRoomID() (proven reliable method)
-- Also cleans up stale entries (squares that no longer have rooms)
function RoomPersistence.Save(refugeData)
    if not refugeData then return 0 end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local tier = refugeData.tier or 0
    local tierData = MSR.Config.TIERS[tier]
    local radius = tierData and tierData.radius or 1
    
    local cell = getCell()
    if not cell then return 0 end
    
    -- Initialize roomIds structure (migrate if needed)
    if not refugeData.roomIds then
        refugeData.roomIds = {}
    end
    migrateRoomData(refugeData)
    
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius
    local savedCount = 0
    local updatedCount = 0
    local unchangedCount = 0
    local removedCount = 0
    
    L.debug("RoomPersistence", string.format("Starting save scan for refuge at %d,%d (radius=%d)", 
        centerX, centerY, radius))
    
    -- Step 1: Mark all existing entries for potential cleanup
    -- Entries that are still valid will be unmarked during scan
    local entriesToRemove = {}
    for key in pairs(refugeData.roomIds) do
        entriesToRemove[key] = true
    end
    
    -- Step 2: Scan all squares in refuge area
    for x = minX - 1, maxX + 1 do
        for y = minY - 1, maxY + 1 do
            local square = cell:getGridSquare(x, y, centerZ)
            if square and square:getChunk() then
                local key = getRoomDataKey(x, y, centerZ)
                
                -- Use ONLY getRoomID() (proven reliable)
                local roomId = -1
                if square.getRoomID then
                    local success, id = pcall(function() return square:getRoomID() end)
                    if success and id and id ~= -1 then
                        roomId = id
                    end
                end
                
                if roomId ~= -1 then
                    -- Valid room - keep this entry
                    entriesToRemove[key] = nil
                    
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
                -- If roomId == -1 and entry exists, it stays in entriesToRemove (will be cleaned up)
            end
        end
    end
    
    -- Step 3: Remove stale entries (squares that no longer have rooms)
    -- This handles: demolished rooms, room shape changes, room splits/merges
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

-- Sync room IDs from client to server (for multiplayer)
-- In MP, clients discover rooms but can't save to ModData
-- This sends discovered roomIds to the server for saving
function RoomPersistence.SyncToServer(refugeData)
    -- Only run on client in multiplayer
    if MSR.Env.isServer() then return 0 end
    if MSR.Env.isSingleplayer() then return 0 end  -- Singleplayer doesn't need sync
    
    if not refugeData or not refugeData.roomIds then return 0 end
    
    local count = K.count(refugeData.roomIds)
    if count == 0 then return 0 end
    
    local player = getPlayer()
    if not player then return 0 end
    
    -- Convert roomIds to a format that can be sent over network
    -- Network commands can't send tables with numeric keys that are large numbers (roomId)
    -- So we send as a simple key-value table
    local roomIdsToSync = {}
    for key, roomId in pairs(refugeData.roomIds) do
        roomIdsToSync[key] = roomId
    end
    
    -- Send to server using general-purpose sync command
    -- Server acts as data store; client-discovered data needs to persist in server's ModData
    sendClientCommand(player, MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.SYNC_CLIENT_DATA, {
        username = player:getUsername(),
        dataType = "roomIds",
        data = roomIdsToSync
    })
    
    L.debug("RoomPersistence", string.format("Sent %d room IDs to server for saving", count))
    return count
end

-----------------------------------------------------------
-- General-Purpose Client Data Sync (Server-Side Handler)
-----------------------------------------------------------
-- In multiplayer, clients cannot write to global ModData.
-- This handler receives client-discovered data and persists it.
-- Currently supports: roomIds
-- Future: can be extended for other client-side data

-- Handle incoming client data sync (server-side)
-- Merges client data into the player's refuge ModData
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
    
    -- Handle different data types
    if dataType == "roomIds" then
        -- Sync room IDs
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


-- Restore room IDs from saved ModData
-- Uses ONLY getRoomByID() + setRoomID() (proven 100% success method)
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
                    -- Try to restore: need RoomDef + IsoRoom
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

-- Refresh room contents after restoration
-- This populates waterSources, lightSwitches, containers, etc. which are empty after getRoomByID()
function RoomPersistence.RefreshRoomContents(refugeData)
    if not refugeData or not refugeData.roomIds then return 0 end
    
    local cell = getCell()
    if not cell then return 0 end
    
    local metaGrid = getWorld():getMetaGrid()
    if not metaGrid then return 0 end
    
    -- Collect unique rooms and their squares
    local roomSquares = {}  -- roomId -> list of squares
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
    
    -- For each room, populate its content lists
    for roomId, squares in pairs(roomSquares) do
        -- Use repeat-until for early exit pattern (Lua 5.1 compatible)
        repeat
            local success, room = pcall(function()
                return metaGrid:getRoomByID(roomId)
            end)
            
            -- Early exit if room not found or pcall failed
            if not success or not room then
                break
            end
            
            local addedSquares = 0
            local waterSourcesFound = 0
            local lightSwitchesFound = 0
            
            for _, square in ipairs(squares) do
                -- Try to add square to room's squares list
                if room.addSquare then
                    local addSuccess = pcall(function()
                        room:addSquare(square)
                    end)
                    if addSuccess then
                        addedSquares = addedSquares + 1
                    end
                end
                
                -- Scan square objects for water sources and light switches
                local objects = square:getObjects()
                if K.isIterable(objects) then
                    for _, obj in K.iter(objects) do
                        if obj then
                            -- Check for water sources (sinks, etc.)
                            if obj.hasWater or obj.getUsesExternalWaterSource then
                                local isWaterSource = false
                                if obj.getUsesExternalWaterSource then
                                    local usesExternal = pcall(function() return obj:getUsesExternalWaterSource() end)
                                    isWaterSource = usesExternal
                                end
                                if isWaterSource or (obj.hasWater and obj:hasWater()) then
                                    -- Try to add to room's waterSources
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
                            
                            -- Check for light switches
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
                        end
                    end
                end
            end
            
            if addedSquares > 0 or waterSourcesFound > 0 or lightSwitchesFound > 0 then
                refreshedRooms = refreshedRooms + 1
                L.debug("RoomPersistence", string.format("Room %d: added %d squares, %d water sources, %d light switches",
                    roomId, addedSquares, waterSourcesFound, lightSwitchesFound))
            end
        until true  -- Execute once, allows break for early exit
    end
    
    return refreshedRooms
end

-- Cleanup stale room IDs (maintenance function)
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
    
    -- Check each saved room ID
    for key, _ in pairs(refugeData.roomIds) do
        local x, y, z = parseRoomDataKey(key)
        if x and y and z then
            -- Check if square is still in refuge bounds
            if x < minX - 1 or x > maxX + 1 or y < minY - 1 or y > maxY + 1 or z ~= centerZ then
                refugeData.roomIds[key] = nil
                removedCount = removedCount + 1
            else
                -- Check if square exists and has chunk loaded
                local square = cell:getGridSquare(x, y, z)
                if not square or not square:getChunk() then
                    -- Square doesn't exist or chunk not loaded - keep for now (might be temporary)
                end
            end
        else
            -- Invalid key format - remove it
            refugeData.roomIds[key] = nil
            removedCount = removedCount + 1
        end
    end
    
    if removedCount > 0 then
        MSR.Data.SaveRefugeData(refugeData)
        L.debug("RoomPersistence", string.format("Cleanup: Removed %d stale room IDs", removedCount))
    end
    
    return removedCount
end

-- Verify restoration success (monitoring function)
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
    
    -- Count saved rooms
    if refugeData.roomIds then
        for _ in pairs(refugeData.roomIds) do
            stats.savedRooms = stats.savedRooms + 1
        end
    end
    
    -- Scan refuge area
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
-- In multiplayer, ModData is server-authoritative.
-- Client saves room IDs on exit, syncs to server for persistence.
-- Server restores on enter (same as client).
-----------------------------------------------------------

-- Server-side restore - just delegates to client Restore
-- Called from MSR_Server.lua after chunks are loaded
function RoomPersistence.RestoreServer(refugeData)
    if not refugeData then return 0 end
    return RoomPersistence.Restore(refugeData)
end

-- Server-side save on exit
-- Called from MSR_Server.lua when player exits refuge
-- Just logs current state - actual data comes from client sync
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
