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


--- Restore room IDs and refresh contents in a single optimized pass
function RoomPersistence.Restore(refugeData)
    if not refugeData then return 0 end
    
    migrateRoomData(refugeData)
    
    if not refugeData.roomIds or K.isEmpty(refugeData.roomIds) then
        return 0
    end
    
    local cell = getCell()
    local metaGrid = cell and getWorld():getMetaGrid()
    if not metaGrid then return 0 end
    
    -- Cache room objects (avoid repeated lookups for same roomId)
    local roomCache = {}  -- roomId -> room object or false (invalid)
    local function getRoom(roomId)
        if roomCache[roomId] == nil then
            local roomObj = metaGrid:getRoomByID(roomId)
            roomCache[roomId] = roomObj or false
        end
        return roomCache[roomId]
    end
    
    -- Group squares by roomId (single pass through data)
    local roomSquares = {}  -- roomId -> {squares}
    local restoredCount, skippedCount = 0, 0
    
    for key, roomId in pairs(refugeData.roomIds) do
        if roomId and roomId ~= -1 then
            -- Inline key parsing (avoid function call overhead)
            local x, y, z
            local i = 1
            for part in string.gmatch(key, "[^,]+") do
                if i == 1 then x = tonumber(part)
                elseif i == 2 then y = tonumber(part)
                else z = tonumber(part) end
                i = i + 1
            end
            
            if x and y and z then
                local square = cell:getGridSquare(x, y, z)
                if square and square:getChunk() then
                    -- Check if room is valid (cached lookup)
                    local room = getRoom(roomId)
                    if room then
                        -- Restore roomId if needed
                        if square:getRoomID() ~= roomId then
                            square:setRoomID(roomId)
                            restoredCount = restoredCount + 1
                        else
                            skippedCount = skippedCount + 1
                        end
                        
                        -- Collect square for room content refresh
                        if not roomSquares[roomId] then
                            roomSquares[roomId] = {}
                        end
                        table.insert(roomSquares[roomId], square)
                    else
                        skippedCount = skippedCount + 1
                    end
                end
            end
        end
    end
    
    -- Refresh room contents (water sources, light switches) if any restored
    if restoredCount > 0 then
        L.debug("RoomPersistence", string.format("Restored %d roomIds (%d skipped)", restoredCount, skippedCount))
        RoomPersistence.RefreshRoomContents(roomSquares, roomCache)
    end
    
    return restoredCount
end

--- Repopulate room contents (waterSources, lightSwitches) after restoration
--- @param roomSquares table roomId -> {squares} mapping (pre-computed)
--- @param roomCache table roomId -> room object cache (pre-computed)
function RoomPersistence.RefreshRoomContents(roomSquares, roomCache)
    if not roomSquares then return 0 end
    
    local refreshedRooms = 0
    
    for roomId, squares in pairs(roomSquares) do
        local room = roomCache and roomCache[roomId]
        if not room then
            -- Fallback if cache not provided
            local metaGrid = getWorld():getMetaGrid()
            if metaGrid then
                room = metaGrid:getRoomByID(roomId)
            end
        end
        
        if room then
            -- Add squares to room
            if room.addSquare then
                for _, square in ipairs(squares) do
                    pcall(function() room:addSquare(square) end)
                end
            end
            
            -- Find water sources and light switches
            local hasWaterSources = room.waterSources and room.waterSources.add
            local hasLightSwitches = room.lightSwitches and room.lightSwitches.add
            
            if hasWaterSources or hasLightSwitches then
                for _, square in ipairs(squares) do
                    local objects = square:getObjects()
                    if objects then
                        for i = 0, objects:size() - 1 do
                            local obj = objects:get(i)
                            if obj then
                                -- Water sources
                                if hasWaterSources and (obj.hasWater or obj.getUsesExternalWaterSource) then
                                    local isWater = obj.hasWater and obj:hasWater()
                                    if not isWater and obj.getUsesExternalWaterSource then
                                        isWater = pcall(function() return obj:getUsesExternalWaterSource() end)
                                    end
                                    if isWater and not room.waterSources:contains(obj) then
                                        pcall(function() room.waterSources:add(obj) end)
                                    end
                                end
                                
                                -- Light switches
                                if hasLightSwitches and instanceof(obj, "IsoLightSwitch") then
                                    if not room.lightSwitches:contains(obj) then
                                        pcall(function() room.lightSwitches:add(obj) end)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            
            refreshedRooms = refreshedRooms + 1
        end
    end
    
    return refreshedRooms
end

-----------------------------------------------------------
-- Direct Cutaway Control (bypasses room system)
-----------------------------------------------------------

--- Directly set cutaway flags on upper floor squares
--- This forces transparency regardless of room state
--- @param refugeData table The refuge data
--- @param playerIndex number The player index (0-based, default 0)
--- @return number Number of squares with cutaway applied
function RoomPersistence.ForceCutaway(refugeData, playerIndex)
    if not refugeData then return 0 end
    
    playerIndex = playerIndex or 0
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ or 0
    local tier = refugeData.tier or 0
    local tierData = MSR.Config.TIERS[tier]
    local radius = tierData and tierData.radius or 1
    
    local cell = getCell()
    if not cell then return 0 end
    
    local timestamp = getTimestampMs()
    local cutawayCount = 0
    local scanRadius = radius + 1
    
    -- Set cutaway on all floors ABOVE player z-level
    for z = centerZ + 1, centerZ + 3 do
        for x = centerX - scanRadius, centerX + scanRadius do
            for y = centerY - scanRadius, centerY + scanRadius do
                local square = cell:getGridSquare(x, y, z)
                if square then
                    pcall(function()
                        -- Flag 1 = CLDSF_SHOULD_RENDER (cutaway should render/be transparent)
                        square:setPlayerCutawayFlag(playerIndex, 1, timestamp)
                        square:setSquareChanged()
                    end)
                    cutawayCount = cutawayCount + 1
                end
            end
        end
    end
    
    -- Invalidate render chunks to apply changes
    for x = centerX - scanRadius, centerX + scanRadius do
        for y = centerY - scanRadius, centerY + scanRadius do
            for z = centerZ, centerZ + 3 do
                local square = cell:getGridSquare(x, y, z)
                if square then
                    pcall(function()
                        square:invalidateRenderChunkLevel(2048) -- DIRTY_CUTAWAYS flag
                    end)
                end
            end
        end
    end
    
    L.debug("RoomPersistence", string.format("Applied cutaway to %d upper floor squares", cutawayCount))
    return cutawayCount
end

-----------------------------------------------------------
-- Single Integration Point
-----------------------------------------------------------

--- Apply cutaway fix after entering refuge
--- This is the ONLY function that needs to be called from MSR_Teleport
--- @param refugeData table The refuge data
function RoomPersistence.ApplyCutaway(refugeData)
    if not refugeData then return end
    
    -- Restore room associations (required for cutaway to work)
    RoomPersistence.Restore(refugeData)
    
    -- Apply direct cutaway flags
    RoomPersistence.ForceCutaway(refugeData, 0)
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
