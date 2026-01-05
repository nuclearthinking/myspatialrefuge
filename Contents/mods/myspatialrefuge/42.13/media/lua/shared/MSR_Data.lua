-- MSR_Data - Data Module (Shared)
-- ModData management functions accessible by both client and server
-- This ensures consistent data access in multiplayer

require "shared/core/MSR"
require "shared/MSR_Config"
require "shared/core/MSR_Env"

if MSR.Data and MSR.Data._loaded then
    return MSR.Data
end

MSR.Data = MSR.Data or {}
MSR.Data._loaded = true

-- Local aliases for internal use
local Data = MSR.Data
local Config = MSR.Config

-----------------------------------------------------------
-- Debug Helpers
-----------------------------------------------------------

-- Format upgrades table for debug logging
-- Returns string like "{faster_reading=3, other=1}" or "nil"
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
-- RefugeData Serialization (DRY helper)
-----------------------------------------------------------

-- Use this instead of manually copying fields everywhere
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
        upgrades = refugeData.upgrades
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

function Data.GetModData()
    return ModData.getOrCreate(Config.MODDATA_KEY)
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

-- Should only be called on server
function Data.AllocateRefugeCoordinates()
    local registry = Data.GetRefugeRegistry()
    if not registry then
        return Config.REFUGE_BASE_X, Config.REFUGE_BASE_Y, Config.REFUGE_BASE_Z
    end
    local baseX = Config.REFUGE_BASE_X
    local baseY = Config.REFUGE_BASE_Y
    local baseZ = Config.REFUGE_BASE_Z
    local spacing = Config.REFUGE_SPACING
    
    local count = K.count(registry)
    
    local row = math.floor(count / 10)
    local col = count % 10
    
    local centerX = baseX + (col * spacing)
    local centerY = baseY + (row * spacing)
    local centerZ = baseZ
    
    return centerX, centerY, centerZ
end

-- Creating new refuge data is only allowed on server or singleplayer
function Data.GetOrCreateRefugeData(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    local refugeData = Data.GetRefugeDataByUsername(username)
    
    if not refugeData then
        local canCreate = canModifyData()
        
        if not canCreate then
            L.debug("Data", "MP client cannot create refuge data - must request from server")
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
                    orphanData.username = username
                    orphanData.refugeId = "refuge_" .. username
                    
                    registry[oldUsername] = nil
                    registry[username] = orphanData
                    
                    Data.TransmitModData()
                    
                    L.debug("Data", "Inherited refuge: " .. oldUsername .. " -> " .. username ..
                            " (tier=" .. orphanData.tier .. ", radius=" .. orphanData.radius .. ")")
                    return orphanData
                end
            end
        end
        
        -- Create new refuge
        local centerX, centerY, centerZ = Data.AllocateRefugeCoordinates()
        
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
            lastExpanded = K.time(),
            dataVersion = Config.CURRENT_DATA_VERSION,
            upgrades = {}
        }
        
        Data.SaveRefugeData(refugeData)
        
        L.debug("Data", "Created new refuge for " .. username .. " at " .. centerX .. "," .. centerY)
    end
    
    return refugeData
end

-- Only server/singleplayer can save refuge data
function Data.SaveRefugeData(refugeData)
    if not refugeData or not refugeData.username then 
        print("[MSR.Data] SaveRefugeData: FAILED - no refugeData or username")
        return false 
    end
    
    if not canModifyData() then
        print("[MSR.Data] SaveRefugeData: FAILED - MP client cannot save")
        return false
    end
    
    local registry = Data.GetRefugeRegistry()
    if not registry then
        local modData = Data.InitializeModData()
        registry = modData[Config.REFUGES_KEY]
    end
    
    if not registry then 
        print("[MSR.Data] SaveRefugeData: FAILED - no registry")
        return false 
    end
    
    L.debug("Data", "SaveRefugeData: Saving for " .. refugeData.username .. 
          " with upgrades=" .. formatUpgradesTable(refugeData.upgrades))
    
    registry[refugeData.username] = refugeData
    Data.TransmitModData()
    
    if L.isDebug() then
        local verify = registry[refugeData.username]
        if verify and verify.upgrades then
            L.debug("Data", "SaveRefugeData: Verified upgrades=" .. formatUpgradesTable(verify.upgrades))
        else
            L.debug("Data", "SaveRefugeData: WARNING - verify.upgrades is nil after save!")
        end
    end
    
    return true
end

-- Only server/singleplayer can delete refuge data
function Data.DeleteRefugeData(player)
    if not player then return false end
    
    if not canModifyData() then
        L.debug("Data", "MP client cannot delete refuge data")
        return false
    end
    
    local username = player:getUsername()
    if not username then return false end
    
    local registry = Data.GetRefugeRegistry()
    if not registry then return false end
    
    registry[username] = nil
    Data.TransmitModData()
    return true
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
    
    L.debug("Data", "Marked refuge as orphaned: " .. username .. 
            " (tier=" .. refugeData.tier .. ", radius=" .. refugeData.radius .. ")")
    return true
end

function Data.FindOrphanRefuge()
    local registry = Data.GetRefugeRegistry()
    if not registry then return nil, nil end
    
    for username, refugeData in pairs(registry) do
        if refugeData.isOrphaned then
            L.debug("Data", "Found orphan refuge from " .. (refugeData.originalOwner or username) ..
                    " (tier=" .. refugeData.tier .. ", radius=" .. refugeData.radius .. ")")
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
    orphanData.username = newUsername
    orphanData.refugeId = "refuge_" .. newUsername
    
    registry[oldUsername] = nil
    registry[newUsername] = orphanData
    
    Data.TransmitModData()
    
    L.debug("Data", "Claimed orphan refuge: " .. oldUsername .. " -> " .. newUsername ..
            " (tier=" .. orphanData.tier .. ", radius=" .. orphanData.radius .. ")")
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
        refugeBoundsCache = {
            minX = baseX - maxRadius,
            minY = baseY - maxRadius,
            maxX = baseX + 1000,
            maxY = baseY + 1000
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
        L.debug("Data", "MP client cannot save return position")
        return false
    end
    
    -- Never save refuge coordinates as return position
    if Data.IsInRefugeCoordinates(x, y) then
        L.debug("Data", "WARNING: Attempted to save refuge coordinates as return position - blocked!")
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
        L.debug("Data", "MP client cannot clear return position")
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

return MSR.Data
