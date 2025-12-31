-- Spatial Refuge Data Module (Shared)
-- ModData management functions accessible by both client and server
-- This ensures consistent data access in multiplayer

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeEnv"

-- Prevent double-loading
if SpatialRefugeData and SpatialRefugeData._loaded then
    return SpatialRefugeData
end

SpatialRefugeData = SpatialRefugeData or {}
SpatialRefugeData._loaded = true

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

-- Expose for other modules to use
function SpatialRefugeData.CanModifyData()
    return canModifyData()
end

function SpatialRefugeData.IsMultiplayerClient()
    return isMultiplayerClient()
end

-----------------------------------------------------------
-- ModData Initialization
-----------------------------------------------------------

-- Get ModData without creating structure (for MP clients)
function SpatialRefugeData.GetModData()
    return ModData.getOrCreate(SpatialRefugeConfig.MODDATA_KEY)
end

-- Initialize ModData structure (creates tables if missing)
-- In MP, only the server should call this to create the structure
-- Clients receive the structure via transmit from server
function SpatialRefugeData.InitializeModData()
    local modData = ModData.getOrCreate(SpatialRefugeConfig.MODDATA_KEY)
    
    -- Only create empty tables on server or singleplayer
    -- MP clients should receive these from server via transmit
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

-- Transmit ModData changes (for multiplayer sync)
function SpatialRefugeData.TransmitModData()
    if ModData.transmit then
        ModData.transmit(SpatialRefugeConfig.MODDATA_KEY)
    end
end

-----------------------------------------------------------
-- Refuge Registry Access
-----------------------------------------------------------

-- Get global refuge registry
-- Returns nil if ModData hasn't been received yet on MP clients
function SpatialRefugeData.GetRefugeRegistry()
    local modData = SpatialRefugeData.InitializeModData()
    return modData[SpatialRefugeConfig.REFUGES_KEY]
end

-- Check if ModData has been initialized (for MP clients to verify data received)
function SpatialRefugeData.HasRefugeData()
    local modData = SpatialRefugeData.GetModData()
    return modData and modData[SpatialRefugeConfig.REFUGES_KEY] ~= nil
end

-- Get refuge data for a specific player (by player object)
function SpatialRefugeData.GetRefugeData(player)
    if not player then return nil end
    
    local username = player:getUsername()
    return SpatialRefugeData.GetRefugeDataByUsername(username)
end

-- Get refuge data by username string
function SpatialRefugeData.GetRefugeDataByUsername(username)
    if not username then return nil end
    
    local registry = SpatialRefugeData.GetRefugeRegistry()
    if not registry then return nil end  -- Registry not available yet (MP client waiting for server data)
    
    return registry[username]
end

-- Allocate coordinates for a new refuge
-- Returns: centerX, centerY, centerZ
-- NOTE: Should only be called on server
function SpatialRefugeData.AllocateRefugeCoordinates()
    local registry = SpatialRefugeData.GetRefugeRegistry()
    if not registry then
        -- Fallback - should never happen on server
        return SpatialRefugeConfig.REFUGE_BASE_X, SpatialRefugeConfig.REFUGE_BASE_Y, SpatialRefugeConfig.REFUGE_BASE_Z
    end
    local baseX = SpatialRefugeConfig.REFUGE_BASE_X
    local baseY = SpatialRefugeConfig.REFUGE_BASE_Y
    local baseZ = SpatialRefugeConfig.REFUGE_BASE_Z
    local spacing = SpatialRefugeConfig.REFUGE_SPACING
    
    -- Simple allocation: count existing refuges and offset
    local count = 0
    for _ in pairs(registry) do
        count = count + 1
    end
    
    -- Arrange refuges in a grid pattern
    local row = math.floor(count / 10)
    local col = count % 10
    
    local centerX = baseX + (col * spacing)
    local centerY = baseY + (row * spacing)
    local centerZ = baseZ
    
    return centerX, centerY, centerZ
end

-- Get or create refuge data for a player
-- NOTE: Creating new refuge data is only allowed on server or singleplayer
-- MP clients must request ModData from server via REQUEST_MODDATA command
function SpatialRefugeData.GetOrCreateRefugeData(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    local refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    
    if not refugeData then
        -- Only server/singleplayer can create new refuge data
        -- MP clients must wait for server to send data via MODDATA_RESPONSE
        local canCreate = canModifyData()
        
        if not canCreate then
            if getDebug() then
                print("[SpatialRefugeData] MP client cannot create refuge data - must request from server")
            end
            return nil
        end
        
        -- Allocate coordinates for new refuge
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
            dataVersion = 2
        }
        
        -- Save to registry
        SpatialRefugeData.SaveRefugeData(refugeData)
        
        if getDebug() then
            print("[SpatialRefugeData] Created new refuge for " .. username .. " at " .. centerX .. "," .. centerY)
        end
    end
    
    return refugeData
end

-- Save refuge data to ModData
-- NOTE: Only server/singleplayer can save refuge data
function SpatialRefugeData.SaveRefugeData(refugeData)
    if not refugeData or not refugeData.username then return false end
    
    -- Only server/singleplayer can save
    if not canModifyData() then
        if getDebug() then
            print("[SpatialRefugeData] MP client cannot save refuge data")
        end
        return false
    end
    
    local registry = SpatialRefugeData.GetRefugeRegistry()
    if not registry then
        -- Initialize if needed
        local modData = SpatialRefugeData.InitializeModData()
        registry = modData[SpatialRefugeConfig.REFUGES_KEY]
    end
    
    if not registry then return false end
    
    registry[refugeData.username] = refugeData
    
    -- Transmit for multiplayer sync
    SpatialRefugeData.TransmitModData()
    
    return true
end

-- Delete refuge data from ModData
-- NOTE: Only server/singleplayer can delete refuge data
function SpatialRefugeData.DeleteRefugeData(player)
    if not player then return false end
    
    -- Only server/singleplayer can delete
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

-- Cached refuge bounds for performance
local refugeBoundsCache = nil

-- Get cached refuge bounds
local function getRefugeBounds()
    if not refugeBoundsCache then
        local baseX = SpatialRefugeConfig.REFUGE_BASE_X
        local baseY = SpatialRefugeConfig.REFUGE_BASE_Y
        local maxRadius = 10  -- Account for refuge extending below/left of base
        refugeBoundsCache = {
            minX = baseX - maxRadius,
            minY = baseY - maxRadius,
            maxX = baseX + 1000,
            maxY = baseY + 1000
        }
    end
    return refugeBoundsCache
end

-- Check if coordinates are within refuge space
function SpatialRefugeData.IsInRefugeCoordinates(x, y)
    local bounds = getRefugeBounds()
    return x >= bounds.minX and x < bounds.maxX and 
           y >= bounds.minY and y < bounds.maxY
end

-- Check if player is currently in refuge coordinates
function SpatialRefugeData.IsPlayerInRefugeCoords(player)
    if not player then return false end
    
    -- Safety check for player position functions
    if not player.getX or not player.getY then
        return false
    end
    
    local x = player:getX()
    local y = player:getY()
    
    if not x or not y then return false end
    
    return SpatialRefugeData.IsInRefugeCoordinates(x, y)
end

-- Get player's return position from global ModData
function SpatialRefugeData.GetReturnPosition(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    return SpatialRefugeData.GetReturnPositionByUsername(username)
end

-- Get return position by username
function SpatialRefugeData.GetReturnPositionByUsername(username)
    if not username then return nil end
    
    local modData = SpatialRefugeData.InitializeModData()
    if not modData or not modData.ReturnPositions then return nil end
    
    return modData.ReturnPositions[username]
end

-- Save player's return position to global ModData
function SpatialRefugeData.SaveReturnPosition(player, x, y, z)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    return SpatialRefugeData.SaveReturnPositionByUsername(username, x, y, z)
end

-- Save return position by username
-- NOTE: Only server/singleplayer can save return positions
function SpatialRefugeData.SaveReturnPositionByUsername(username, x, y, z)
    if not username then return false end
    
    -- Only server/singleplayer can save
    if not canModifyData() then
        if getDebug() then
            print("[SpatialRefugeData] MP client cannot save return position")
        end
        return false
    end
    
    -- CRITICAL: Never save refuge coordinates as return position
    if SpatialRefugeData.IsInRefugeCoordinates(x, y) then
        if getDebug() then
            print("[SpatialRefugeData] WARNING: Attempted to save refuge coordinates as return position - blocked!")
        end
        return false
    end
    
    local modData = SpatialRefugeData.InitializeModData()
    if not modData then return false end
    
    -- Ensure ReturnPositions table exists
    if not modData.ReturnPositions then
        modData.ReturnPositions = {}
    end
    
    -- Save the position
    modData.ReturnPositions[username] = { x = x, y = y, z = z }
    
    -- Transmit for multiplayer sync
    SpatialRefugeData.TransmitModData()
    
    return true
end

-- Clear player's return position from global ModData
function SpatialRefugeData.ClearReturnPosition(player)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    SpatialRefugeData.ClearReturnPositionByUsername(username)
end

-- Clear return position by username
-- NOTE: Only server/singleplayer can clear return positions
function SpatialRefugeData.ClearReturnPositionByUsername(username)
    if not username then return false end
    
    -- Only server/singleplayer can clear
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


