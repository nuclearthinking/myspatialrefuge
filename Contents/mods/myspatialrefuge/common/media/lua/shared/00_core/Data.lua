-- 06_Data - ModData management (Shared)
-- Assumes: MSR, MSR.Config, MSR.Env, L exist (loaded by 00_MSR.lua)

local Data = MSR.register("Data")
if not Data then
    return MSR.Data
end

MSR.Data = Data
local Config = MSR.Config
local LOG = L.logger("Data")

-----------------------------------------------------------
-- Debug Helpers
-----------------------------------------------------------

-- Format upgrades table for logging: "{key=val, ...}" or "nil"
local function formatUpgradesTable(upgrades)
    if not upgrades then return "nil" end
    if K.isEmpty(upgrades) then return "{}" end
    local parts = {}
    for k, v in pairs(upgrades) do
        table.insert(parts, k .. "=" .. tostring(v))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

function Data.FormatUpgradesTable(upgrades)
    return formatUpgradesTable(upgrades)
end

-----------------------------------------------------------
-- RefugeData Serialization
-----------------------------------------------------------

function Data.SerializeRefugeData(refugeData)
    if not refugeData then return nil end
    return {
        refugeId = refugeData.refugeId,
        username = refugeData.username,
        centerX = refugeData.centerX,
        centerY = refugeData.centerY,
        centerZ = refugeData.centerZ,
        tier = refugeData.tier,
        radius = refugeData.radius,
        relicX = refugeData.relicX,
        relicY = refugeData.relicY,
        relicZ = refugeData.relicZ,
        upgrades = refugeData.upgrades,
        createdTime = refugeData.createdTime,
        lastActiveTime = refugeData.lastActiveTime,
        lastExpanded = refugeData.lastExpanded,
        dataVersion = refugeData.dataVersion
    }
end

-----------------------------------------------------------
-- Environment Helpers (delegated to MSR.Env)
-----------------------------------------------------------

local function getCachedIsServer()
    if not MSR.Env then return isServer() end
    return MSR.Env.isServer()
end

local function getCachedIsClient()
    if not MSR.Env then return isClient() end
    return MSR.Env.isClient()
end

local function canModifyData()
    if not MSR.Env then
        -- Fallback if MSR.Env not loaded yet
        return isServer() or (not isClient())
    end
    return MSR.Env.canModifyData()
end

local function isMultiplayerClient()
    if not MSR.Env then
        return isClient() and not isServer()
    end
    return MSR.Env.isClient() and not MSR.Env.isServer()
end

function Data.CanModifyData()
    return canModifyData()
end

function Data.IsMultiplayerClient()
    return isMultiplayerClient()
end

-----------------------------------------------------------
-- ModData Initialization
-----------------------------------------------------------

-- Tracks whether ModData has been confirmed loaded from disk
-- CRITICAL: Do NOT create new refuges until this is true!
local _modDataReady = false
local _modDataRequested = false
local MODDATA_READY_EVENT = MSR.Config.EVENTS.MODDATA_READY

function Data.GetModData()
    return ModData.getOrCreate(Config.MODDATA_KEY)
end

-- Check if ModData has been confirmed loaded and ready for use
function Data.IsModDataReady()
    return _modDataReady
end

-- Mark ModData as ready (call ONLY after confirming data is loaded from disk)
function Data.SetModDataReady(ready)
    _modDataReady = ready
    if ready then
        LOG.debug("ModData marked as ready")
        if MSR.Env.isMultiplayerClient() then
            MSR.Events.Custom.Fire(MODDATA_READY_EVENT, { player = getPlayer() })
        end
    end
end

-----------------------------------------------------------
-- ModData Sync (MP Client)
-----------------------------------------------------------

function Data.HandleModDataResponse(args, player)
    if not args or not args.refugeData then return end
    player = player or getPlayer()
    if not player then return end
    local username = player:getUsername()
    if not username or args.refugeData.username ~= username then return end

    local modData = ModData.getOrCreate(Config.MODDATA_KEY)
    modData[Config.REFUGES_KEY] = modData[Config.REFUGES_KEY] or {}
    modData[Config.REFUGES_KEY][username] = args.refugeData

    if args.returnPosition then
        modData.ReturnPositions = modData.ReturnPositions or {}
        modData.ReturnPositions[username] = args.returnPosition
    end

    -- Mark data as ready on client after receiving valid data from server
    Data.SetModDataReady(true)

    LOG.debug("Received ModData: refuge at %s,%s", tostring(args.refugeData.centerX), tostring(args.refugeData.centerY))
end

function Data.RequestModDataFromServer()
    if not MSR.Env.isMultiplayerClient() or _modDataRequested then return false end

    local player = getPlayer()
    if not player or not player:getUsername() then return false end

    _modDataRequested = true
    LOG.debug("Requesting ModData from server")
    sendClientCommand(Config.COMMAND_NAMESPACE, Config.COMMANDS.REQUEST_MODDATA, {})
    return true
end

local function setupClientModDataSync()
    if not MSR.Env.isMultiplayerClient() then return end

    _modDataRequested = false

    MSR.delay(60, function()
        Data.RequestModDataFromServer()
    end)
end

-- In MP, only the server should call this to create the structure
function Data.InitializeModData()
    local modData = ModData.getOrCreate(Config.MODDATA_KEY)
    
    local shouldCreateTables = canModifyData()
    
    if shouldCreateTables then
        if not modData[Config.REFUGES_KEY] then
            modData[Config.REFUGES_KEY] = {}
        end
        if not modData.ReturnPositions then
            modData.ReturnPositions = {}
        end
        
        -- Mark data as ready after successful initialization on server/SP
        _modDataReady = true
    end
    
    return modData
end

function Data.TransmitModData()
    if ModData.transmit then
        ModData.transmit(Config.MODDATA_KEY)
    end
end

-----------------------------------------------------------
-- Refuge Registry Access
-----------------------------------------------------------

function Data.GetRefugeRegistry()
    local modData = Data.InitializeModData()
    return modData[Config.REFUGES_KEY]
end

function Data.HasRefugeData()
    local modData = Data.GetModData()
    return modData and modData[Config.REFUGES_KEY] ~= nil
end

function Data.GetRefugeData(player)
    if not player then return nil end
    
    local username = player:getUsername()
    return Data.GetRefugeDataByUsername(username)
end

function Data.GetRefugeDataByUsername(username)
    if not username then return nil end
    
    local registry = Data.GetRefugeRegistry()
    if not registry then return nil end
    
    return registry[username]
end

function Data.GetRefugeSlotFromCoordinates(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end

    local gridSize = Config.getRefugeGridSize()
    local col = math.floor((x - Config.REFUGE_BASE_X) / Config.REFUGE_SPACING + 0.5)
    local row = math.floor((y - Config.REFUGE_BASE_Y) / Config.REFUGE_SPACING + 0.5)

    if col < 0 or col >= gridSize or row < 0 or row >= gridSize then
        return nil
    end

    return row * gridSize + col
end

function Data.GetRefugeCoordinatesForSlot(slot)
    slot = tonumber(slot)
    if not slot or slot < 0 then return nil end

    local gridSize = Config.getRefugeGridSize()
    local totalSlots = Config.getRefugeSlotCount()
    if slot >= totalSlots then
        return nil
    end

    local col = slot % gridSize
    local row = math.floor(slot / gridSize)

    return Config.REFUGE_BASE_X + (col * Config.REFUGE_SPACING),
           Config.REFUGE_BASE_Y + (row * Config.REFUGE_SPACING),
           Config.REFUGE_BASE_Z
end

function Data.GetRefugeSlotStats()
    local registry = Data.GetRefugeRegistry()
    local usedSlots = registry and K.count(registry) or 0
    local totalSlots = Config.getRefugeSlotCount()

    return {
        usedSlots = usedSlots,
        totalSlots = totalSlots,
        freeSlots = math.max(0, totalSlots - usedSlots)
    }
end

local function buildOccupiedRefugeLookup(registry)
    local occupied = {}
    if not registry then
        return occupied
    end

    for _, refugeData in pairs(registry) do
        if refugeData and refugeData.centerX ~= nil and refugeData.centerY ~= nil then
            occupied[refugeData.centerX .. "," .. refugeData.centerY] = true
        end
    end

    return occupied
end

-- Should only be called on server
function Data.AllocateRefugeCoordinates()
    local registry = Data.GetRefugeRegistry()
    if not registry then
        return Config.REFUGE_BASE_X, Config.REFUGE_BASE_Y, Config.REFUGE_BASE_Z
    end

    local occupied = buildOccupiedRefugeLookup(registry)
    local totalSlots = Config.getRefugeSlotCount()

    for slot = 0, totalSlots - 1 do
        local centerX, centerY, centerZ = Data.GetRefugeCoordinatesForSlot(slot)
        if centerX and not occupied[centerX .. "," .. centerY] then
            return centerX, centerY, centerZ
        end
    end

    return nil, nil, nil
end

-- Creating new refuge data is only allowed on server or singleplayer
-- CRITICAL: Will return nil if ModData hasn't been confirmed loaded yet
function Data.GetOrCreateRefugeData(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    local refugeData = Data.GetRefugeDataByUsername(username)
    
    if not refugeData then
        local canCreate = canModifyData()
        
        if not canCreate then
            LOG.debug("MP client cannot create refuge data - must request from server")
            return nil
        end
        
        -- SAFETY: Don't create new refuges if ModData hasn't been confirmed loaded
        -- This prevents data loss when server starts but ModData isn't ready yet
        if not _modDataReady then
            LOG.debug("BLOCKED: Refusing to create refuge for %s - ModData not yet confirmed ready (may still be loading)", username)
            return nil
        end
        
        -- SP: Check for orphan refuge before creating new one
        if MSR.Env and MSR.Env.isSingleplayer() then
            local orphanData, oldUsername = Data.FindOrphanRefuge()
            if orphanData and oldUsername then
                local registry = Data.GetRefugeRegistry()
                if registry then
                    orphanData.isOrphaned = nil
                    orphanData.orphanedTime = nil
                    orphanData.inheritedFrom = orphanData.originalOwner or oldUsername
                    orphanData.inheritedTime = K.time()
                    orphanData.lastActiveTime = K.time()
                    orphanData.username = username
                    orphanData.refugeId = "refuge_" .. username
                    orphanData.dataVersion = Config.CURRENT_DATA_VERSION
                    
                    registry[oldUsername] = nil
                    registry[username] = orphanData
                    
                    Data.TransmitModData()
                    
                    LOG.debug("Inherited refuge: %s -> %s (tier=%d, radius=%d)",
                        oldUsername, username, orphanData.tier, orphanData.radius)
                    return orphanData
                end
            end
        end
        
        if Config.getDecayEnabled() and MSR.Decay and MSR.Decay.ShouldAttemptReclaimForAllocation and
                MSR.Decay.ShouldAttemptReclaimForAllocation() then
            MSR.Decay.ReclaimOldestInactiveRefuge()
        end

        -- Create new refuge
        local centerX, centerY, centerZ = Data.AllocateRefugeCoordinates()
        if not centerX then
            LOG.error("Cannot create refuge for %s - no free refuge slots available", username)
            return nil
        end
        
        refugeData = {
            refugeId = "refuge_" .. username,
            username = username,
            centerX = centerX,
            centerY = centerY,
            centerZ = centerZ,
            tier = 0,
            radius = Config.TIERS[0].radius,
            relicX = centerX,
            relicY = centerY,
            relicZ = centerZ,
            createdTime = K.time(),
            lastActiveTime = K.time(),
            lastExpanded = K.time(),
            dataVersion = Config.CURRENT_DATA_VERSION,
            upgrades = {}
        }
        
        Data.SaveRefugeData(refugeData)
        
        LOG.debug("Created new refuge for %s at %d,%d", username, centerX, centerY)
    end
    
    return refugeData
end

function Data.TouchRefugeActivity(username)
    if not username or not canModifyData() then
        return false
    end

    local refugeData = Data.GetRefugeDataByUsername(username)
    if not refugeData then
        return false
    end

    refugeData.lastActiveTime = K.time()
    return Data.SaveRefugeData(refugeData)
end

function Data.DeleteRefugeDataByUsername(username)
    if not username then return false, nil end

    if not canModifyData() then
        LOG.debug("MP client cannot delete refuge data")
        return false, nil
    end

    local registry = Data.GetRefugeRegistry()
    if not registry then return false, nil end

    local existing = registry[username]
    if not existing then return false, nil end

    registry[username] = nil

    local modData = Data.InitializeModData()
    if modData and modData.ReturnPositions then
        modData.ReturnPositions[username] = nil
    end

    Data.TransmitModData()
    return true, existing
end

-- Only server/singleplayer can save refuge data
function Data.SaveRefugeData(refugeData)
    if not refugeData or not refugeData.username then 
        LOG.error("SaveRefugeData: FAILED - no refugeData or username")
        return false 
    end
    
    if not canModifyData() then
        LOG.error("SaveRefugeData: FAILED - MP client cannot save")
        return false
    end
    
    local registry = Data.GetRefugeRegistry()
    if not registry then
        local modData = Data.InitializeModData()
        registry = modData[Config.REFUGES_KEY]
    end
    
    if not registry then 
        LOG.error("SaveRefugeData: FAILED - no registry")
        return false 
    end
    
    LOG.debug("SaveRefugeData: Saving for %s with upgrades=%s",
        refugeData.username, formatUpgradesTable(refugeData.upgrades))
    
    registry[refugeData.username] = refugeData
    Data.TransmitModData()
    
    local verify = registry[refugeData.username]
    if verify and verify.upgrades then
        LOG.debug("SaveRefugeData: Verified upgrades=%s", formatUpgradesTable(verify.upgrades))
    else
        LOG.warning("SaveRefugeData: verify.upgrades is nil after save!")
    end
    
    return true
end

-- Only server/singleplayer can delete refuge data
function Data.DeleteRefugeData(player)
    if not player then return false end

    local username = player:getUsername()
    if not username then return false end

    local success = Data.DeleteRefugeDataByUsername(username)
    return success
end

-----------------------------------------------------------
-- Refuge Inheritance (Singleplayer Only)
-----------------------------------------------------------

function Data.MarkRefugeOrphaned(username)
    if not username or not canModifyData() then return false end
    
    local registry = Data.GetRefugeRegistry()
    if not registry then return false end
    
    local refugeData = registry[username]
    if not refugeData then return false end
    
    refugeData.isOrphaned = true
    refugeData.orphanedTime = K.time()
    refugeData.originalOwner = username
    
    Data.TransmitModData()
    
    LOG.debug("Marked refuge as orphaned: %s (tier=%d, radius=%d)",
        username, refugeData.tier, refugeData.radius)
    return true
end

function Data.FindOrphanRefuge()
    local registry = Data.GetRefugeRegistry()
    if not registry then return nil, nil end
    
    for username, refugeData in pairs(registry) do
        if refugeData.isOrphaned then
            LOG.debug("Found orphan refuge from %s (tier=%d, radius=%d)",
                refugeData.originalOwner or username, refugeData.tier, refugeData.radius)
            return refugeData, username
        end
    end
    
    return nil, nil
end

function Data.ClaimOrphanRefuge(player)
    if not player or not canModifyData() then return false end
    
    local newUsername = player:getUsername()
    if not newUsername then return false end
    
    local existingRefuge = Data.GetRefugeDataByUsername(newUsername)
    if existingRefuge then return false end
    
    local orphanData, oldUsername = Data.FindOrphanRefuge()
    if not orphanData or not oldUsername then return false end
    
    local registry = Data.GetRefugeRegistry()
    if not registry then return false end
    
    orphanData.isOrphaned = nil
    orphanData.orphanedTime = nil
    orphanData.inheritedFrom = orphanData.originalOwner or oldUsername
    orphanData.inheritedTime = K.time()
    orphanData.lastActiveTime = K.time()
    orphanData.username = newUsername
    orphanData.refugeId = "refuge_" .. newUsername
    orphanData.dataVersion = Config.CURRENT_DATA_VERSION
    
    registry[oldUsername] = nil
    registry[newUsername] = orphanData
    
    Data.TransmitModData()
    
    LOG.debug("Claimed orphan refuge: %s -> %s (tier=%d, radius=%d)",
        oldUsername, newUsername, orphanData.tier, orphanData.radius)
    return true
end

-- Check if there's an orphan refuge available for claiming
function Data.HasOrphanRefuge()
    local orphan, _ = Data.FindOrphanRefuge()
    return orphan ~= nil
end

-----------------------------------------------------------
-- Return Position Management
-----------------------------------------------------------

local refugeBoundsCache = nil

local function getRefugeBounds()
    if not refugeBoundsCache then
        local baseX = Config.REFUGE_BASE_X
        local baseY = Config.REFUGE_BASE_Y
        local maxRadius = 10
        local edgeOffset = (Config.getRefugeGridSize() - 1) * Config.REFUGE_SPACING
        refugeBoundsCache = {
            minX = baseX - maxRadius,
            minY = baseY - maxRadius,
            maxX = baseX + edgeOffset + maxRadius + 1,
            maxY = baseY + edgeOffset + maxRadius + 1
        }
    end
    return refugeBoundsCache
end

function Data.IsInRefugeCoordinates(x, y)
    local bounds = getRefugeBounds()
    return x >= bounds.minX and x < bounds.maxX and 
           y >= bounds.minY and y < bounds.maxY
end

function Data.IsPlayerInRefugeCoords(player)
    if not player then return false end
    
    if not player.getX or not player.getY then
        return false
    end
    
    local x = player:getX()
    local y = player:getY()
    
    if not x or not y then return false end
    
    return Data.IsInRefugeCoordinates(x, y)
end

function Data.GetReturnPosition(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    return Data.GetReturnPositionByUsername(username)
end

function Data.GetReturnPositionByUsername(username)
    if not username then return nil end
    
    local modData = Data.InitializeModData()
    if not modData or not modData.ReturnPositions then return nil end
    
    return modData.ReturnPositions[username]
end

function Data.SaveReturnPosition(player, x, y, z)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    return Data.SaveReturnPositionByUsername(username, x, y, z)
end

-- Only server/singleplayer can save return positions
function Data.SaveReturnPositionByUsername(username, x, y, z)
    if not username then return false end
    
    if not canModifyData() then
        LOG.debug( "MP client cannot save return position")
        return false
    end
    
    -- Never save refuge coordinates as return position
    if Data.IsInRefugeCoordinates(x, y) then
        LOG.warning("Attempted to save refuge coordinates as return position - blocked!")
        return false
    end
    
    local modData = Data.InitializeModData()
    if not modData then return false end
    
    if not modData.ReturnPositions then
        modData.ReturnPositions = {}
    end
    
    modData.ReturnPositions[username] = { x = x, y = y, z = z }
    Data.TransmitModData()
    
    return true
end

--- Save return position with vehicle data (for vehicle teleport upgrade)
--- Structure: {x, y, z, fromVehicle, vehicleId, vehicleSeat, vehicleX, vehicleY, vehicleZ}
function Data.SaveReturnPositionWithVehicle(username, x, y, z, vehicleId, vehicleSeat, vehicleX, vehicleY, vehicleZ)
    if not username then return false end
    
    if not canModifyData() then
        LOG.debug("MP client cannot save return position (vehicle)")
        return false
    end
    
    -- Never save refuge coordinates as return position
    if Data.IsInRefugeCoordinates(x, y) then
        LOG.warning("Attempted to save refuge coordinates as return position (vehicle) - blocked!")
        return false
    end
    
    local modData = Data.InitializeModData()
    if not modData then return false end
    
    if not modData.ReturnPositions then
        modData.ReturnPositions = {}
    end
    
    modData.ReturnPositions[username] = {
        x = x,
        y = y,
        z = z,
        fromVehicle = true,
        vehicleId = vehicleId,
        vehicleSeat = vehicleSeat,
        vehicleX = vehicleX,
        vehicleY = vehicleY,
        vehicleZ = vehicleZ
    }
    Data.TransmitModData()
    
    LOG.debug("Saved return position with vehicle: %s at %.1f,%.1f,%.1f vehicleId=%s seat=%s",
        username, x, y, z, tostring(vehicleId), tostring(vehicleSeat))
    
    return true
end

function Data.ClearReturnPosition(player)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    Data.ClearReturnPositionByUsername(username)
end

-- Only server/singleplayer can clear return positions
function Data.ClearReturnPositionByUsername(username)
    if not username then return false end
    
    if not canModifyData() then
        LOG.debug("MP client cannot clear return position")
        return false
    end
    
    local modData = Data.InitializeModData()
    if modData and modData.ReturnPositions then
        modData.ReturnPositions[username] = nil
        Data.TransmitModData()
        return true
    end
    return false
end

local _eventsRegistered = false

function Data.RegisterEvents()
    if _eventsRegistered then return end
    _eventsRegistered = true

    MODDATA_READY_EVENT = MSR.Config.EVENTS.MODDATA_READY
    if MSR.Events and MSR.Events.OnClientReady then
        MSR.Events.OnClientReady.Add(setupClientModDataSync)
    end
end

return MSR.Data
