-- Spatial Refuge Data Module (Shared)
-- ModData management functions accessible by both client and server
-- This ensures consistent data access in multiplayer

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeEnv"

if SpatialRefugeData and SpatialRefugeData._loaded then
    return SpatialRefugeData
end

SpatialRefugeData = SpatialRefugeData or {}
SpatialRefugeData._loaded = true

-----------------------------------------------------------
-- Debug Helpers
-----------------------------------------------------------

-- Format upgrades table for debug logging
-- Returns string like "{faster_reading=3, other=1}" or "nil"
local function formatUpgradesTable(upgrades)
    if not upgrades then return "nil" end
    local parts = {}
    for k, v in pairs(upgrades) do
        table.insert(parts, k .. "=" .. tostring(v))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

function SpatialRefugeData.FormatUpgradesTable(upgrades)
    return formatUpgradesTable(upgrades)
end

-----------------------------------------------------------
-- RefugeData Serialization (DRY helper)
-----------------------------------------------------------

-- Use this instead of manually copying fields everywhere
function SpatialRefugeData.SerializeRefugeData(refugeData)
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
-- Environment Helpers (delegated to SpatialRefugeEnv)
-----------------------------------------------------------

local function getCachedIsServer()
    return SpatialRefugeEnv.isServer()
end

local function getCachedIsClient()
    return SpatialRefugeEnv.isClient()
end

local function canModifyData()
    return SpatialRefugeEnv.canModifyData()
end

local function isMultiplayerClient()
    return SpatialRefugeEnv.isClient() and not SpatialRefugeEnv.isServer()
end

function SpatialRefugeData.CanModifyData()
    return canModifyData()
end

function SpatialRefugeData.IsMultiplayerClient()
    return isMultiplayerClient()
end

-----------------------------------------------------------
-- ModData Initialization
-----------------------------------------------------------

function SpatialRefugeData.GetModData()
    return ModData.getOrCreate(SpatialRefugeConfig.MODDATA_KEY)
end

-- In MP, only the server should call this to create the structure
function SpatialRefugeData.InitializeModData()
    local modData = ModData.getOrCreate(SpatialRefugeConfig.MODDATA_KEY)
    
    local shouldCreateTables = canModifyData()
    
    if shouldCreateTables then
        if not modData[SpatialRefugeConfig.REFUGES_KEY] then
            modData[SpatialRefugeConfig.REFUGES_KEY] = {}
        end
        if not modData.ReturnPositions then
            modData.ReturnPositions = {}
        end
    end
    
    return modData
end

function SpatialRefugeData.TransmitModData()
    if ModData.transmit then
        ModData.transmit(SpatialRefugeConfig.MODDATA_KEY)
    end
end

-----------------------------------------------------------
-- Refuge Registry Access
-----------------------------------------------------------

function SpatialRefugeData.GetRefugeRegistry()
    local modData = SpatialRefugeData.InitializeModData()
    return modData[SpatialRefugeConfig.REFUGES_KEY]
end

function SpatialRefugeData.HasRefugeData()
    local modData = SpatialRefugeData.GetModData()
    return modData and modData[SpatialRefugeConfig.REFUGES_KEY] ~= nil
end

function SpatialRefugeData.GetRefugeData(player)
    if not player then return nil end
    
    local username = player:getUsername()
    return SpatialRefugeData.GetRefugeDataByUsername(username)
end

function SpatialRefugeData.GetRefugeDataByUsername(username)
    if not username then return nil end
    
    local registry = SpatialRefugeData.GetRefugeRegistry()
    if not registry then return nil end
    
    return registry[username]
end

-- Should only be called on server
function SpatialRefugeData.AllocateRefugeCoordinates()
    local registry = SpatialRefugeData.GetRefugeRegistry()
    if not registry then
        return SpatialRefugeConfig.REFUGE_BASE_X, SpatialRefugeConfig.REFUGE_BASE_Y, SpatialRefugeConfig.REFUGE_BASE_Z
    end
    local baseX = SpatialRefugeConfig.REFUGE_BASE_X
    local baseY = SpatialRefugeConfig.REFUGE_BASE_Y
    local baseZ = SpatialRefugeConfig.REFUGE_BASE_Z
    local spacing = SpatialRefugeConfig.REFUGE_SPACING
    
    local count = 0
    for _ in pairs(registry) do
        count = count + 1
    end
    
    local row = math.floor(count / 10)
    local col = count % 10
    
    local centerX = baseX + (col * spacing)
    local centerY = baseY + (row * spacing)
    local centerZ = baseZ
    
    return centerX, centerY, centerZ
end

-- Creating new refuge data is only allowed on server or singleplayer
function SpatialRefugeData.GetOrCreateRefugeData(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    
    if not refugeData then
        local canCreate = canModifyData()
        
        if not canCreate then
            if getDebug() then
                print("[SpatialRefugeData] MP client cannot create refuge data - must request from server")
            end
            return nil
        end
        
        local centerX, centerY, centerZ = SpatialRefugeData.AllocateRefugeCoordinates()
        
        refugeData = {
            refugeId = "refuge_" .. username,
            username = username,
            centerX = centerX,
            centerY = centerY,
            centerZ = centerZ,
            tier = 0,
            radius = SpatialRefugeConfig.TIERS[0].radius,
            relicX = centerX,
            relicY = centerY,
            relicZ = centerZ,
            createdTime = os.time(),
            lastExpanded = os.time(),
            dataVersion = SpatialRefugeConfig.CURRENT_DATA_VERSION,
            upgrades = {}
        }
        
        SpatialRefugeData.SaveRefugeData(refugeData)
        
        if getDebug() then
            print("[SpatialRefugeData] Created new refuge for " .. username .. " at " .. centerX .. "," .. centerY)
        end
    end
    
    return refugeData
end

-- Only server/singleplayer can save refuge data
function SpatialRefugeData.SaveRefugeData(refugeData)
    if not refugeData or not refugeData.username then 
        print("[SpatialRefugeData] SaveRefugeData: FAILED - no refugeData or username")
        return false 
    end
    
    if not canModifyData() then
        print("[SpatialRefugeData] SaveRefugeData: FAILED - MP client cannot save")
        return false
    end
    
    local registry = SpatialRefugeData.GetRefugeRegistry()
    if not registry then
        local modData = SpatialRefugeData.InitializeModData()
        registry = modData[SpatialRefugeConfig.REFUGES_KEY]
    end
    
    if not registry then 
        print("[SpatialRefugeData] SaveRefugeData: FAILED - no registry")
        return false 
    end
    
    if getDebug and getDebug() then
        print("[SpatialRefugeData] SaveRefugeData: Saving for " .. refugeData.username .. 
              " with upgrades=" .. formatUpgradesTable(refugeData.upgrades))
    end
    
    registry[refugeData.username] = refugeData
    SpatialRefugeData.TransmitModData()
    
    if getDebug and getDebug() then
        local verify = registry[refugeData.username]
        if verify and verify.upgrades then
            print("[SpatialRefugeData] SaveRefugeData: Verified upgrades=" .. formatUpgradesTable(verify.upgrades))
        else
            print("[SpatialRefugeData] SaveRefugeData: WARNING - verify.upgrades is nil after save!")
        end
    end
    
    return true
end

-- Only server/singleplayer can delete refuge data
function SpatialRefugeData.DeleteRefugeData(player)
    if not player then return false end
    
    if not canModifyData() then
        if getDebug() then
            print("[SpatialRefugeData] MP client cannot delete refuge data")
        end
        return false
    end
    
    local username = player:getUsername()
    if not username then return false end
    
    local registry = SpatialRefugeData.GetRefugeRegistry()
    if not registry then return false end
    
    registry[username] = nil
    SpatialRefugeData.TransmitModData()
    return true
end

-----------------------------------------------------------
-- Return Position Management
-----------------------------------------------------------

local refugeBoundsCache = nil

local function getRefugeBounds()
    if not refugeBoundsCache then
        local baseX = SpatialRefugeConfig.REFUGE_BASE_X
        local baseY = SpatialRefugeConfig.REFUGE_BASE_Y
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

function SpatialRefugeData.IsInRefugeCoordinates(x, y)
    local bounds = getRefugeBounds()
    return x >= bounds.minX and x < bounds.maxX and 
           y >= bounds.minY and y < bounds.maxY
end

function SpatialRefugeData.IsPlayerInRefugeCoords(player)
    if not player then return false end
    
    if not player.getX or not player.getY then
        return false
    end
    
    local x = player:getX()
    local y = player:getY()
    
    if not x or not y then return false end
    
    return SpatialRefugeData.IsInRefugeCoordinates(x, y)
end

function SpatialRefugeData.GetReturnPosition(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    return SpatialRefugeData.GetReturnPositionByUsername(username)
end

function SpatialRefugeData.GetReturnPositionByUsername(username)
    if not username then return nil end
    
    local modData = SpatialRefugeData.InitializeModData()
    if not modData or not modData.ReturnPositions then return nil end
    
    return modData.ReturnPositions[username]
end

function SpatialRefugeData.SaveReturnPosition(player, x, y, z)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    return SpatialRefugeData.SaveReturnPositionByUsername(username, x, y, z)
end

-- Only server/singleplayer can save return positions
function SpatialRefugeData.SaveReturnPositionByUsername(username, x, y, z)
    if not username then return false end
    
    if not canModifyData() then
        if getDebug() then
            print("[SpatialRefugeData] MP client cannot save return position")
        end
        return false
    end
    
    -- Never save refuge coordinates as return position
    if SpatialRefugeData.IsInRefugeCoordinates(x, y) then
        if getDebug() then
            print("[SpatialRefugeData] WARNING: Attempted to save refuge coordinates as return position - blocked!")
        end
        return false
    end
    
    local modData = SpatialRefugeData.InitializeModData()
    if not modData then return false end
    
    if not modData.ReturnPositions then
        modData.ReturnPositions = {}
    end
    
    modData.ReturnPositions[username] = { x = x, y = y, z = z }
    SpatialRefugeData.TransmitModData()
    
    return true
end

function SpatialRefugeData.ClearReturnPosition(player)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    SpatialRefugeData.ClearReturnPositionByUsername(username)
end

-- Only server/singleplayer can clear return positions
function SpatialRefugeData.ClearReturnPositionByUsername(username)
    if not username then return false end
    
    if not canModifyData() then
        if getDebug() then
            print("[SpatialRefugeData] MP client cannot clear return position")
        end
        return false
    end
    
    local modData = SpatialRefugeData.InitializeModData()
    if modData and modData.ReturnPositions then
        modData.ReturnPositions[username] = nil
        SpatialRefugeData.TransmitModData()
        return true
    end
    return false
end

return SpatialRefugeData


