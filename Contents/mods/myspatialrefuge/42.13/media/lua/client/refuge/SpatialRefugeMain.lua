-- Spatial Refuge Main Module
-- Handles refuge data persistence and coordinate management

-- Prevent double-loading
if SpatialRefuge and SpatialRefuge._mainLoaded then
    return SpatialRefuge
end

-- Use global modules (loaded by main)
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-- Mark as loaded
SpatialRefuge._mainLoaded = true

-- Initialize ModData structure
function SpatialRefuge.InitializeModData()
    local modData = ModData.getOrCreate(SpatialRefugeConfig.MODDATA_KEY)
    if not modData[SpatialRefugeConfig.REFUGES_KEY] then
        modData[SpatialRefugeConfig.REFUGES_KEY] = {}
    end
    -- Also ensure ReturnPositions table exists
    if not modData.ReturnPositions then
        modData.ReturnPositions = {}
    end
    return modData
end

-- Transmit ModData changes (for multiplayer sync)
function SpatialRefuge.TransmitModData()
    if ModData.transmit then
        ModData.transmit(SpatialRefugeConfig.MODDATA_KEY)
    end
end

-- Get global refuge registry
function SpatialRefuge.GetRefugeRegistry()
    local modData = SpatialRefuge.InitializeModData()
    return modData[SpatialRefugeConfig.REFUGES_KEY]
end

-- Get refuge data for a specific player
function SpatialRefuge.GetRefugeData(player)
    if not player then return nil end
    
    local username = player:getUsername()
    local registry = SpatialRefuge.GetRefugeRegistry()
    
    return registry[username]
end

-- Get or create refuge data for a player
function SpatialRefuge.GetOrCreateRefugeData(player)
    if not player then return nil end
    
    local refugeData = SpatialRefuge.GetRefugeData(player)
    
    if not refugeData then
        -- Allocate coordinates for new refuge
        local centerX, centerY, centerZ = SpatialRefuge.AllocateRefugeCoordinates()
        
        local username = player:getUsername()
        refugeData = {
            refugeId = "refuge_" .. username,
            username = username,
            centerX = centerX,
            centerY = centerY,
            centerZ = centerZ,
            tier = 0,
            radius = SpatialRefugeConfig.TIERS[0].radius,
            createdTime = os.time(),
            lastExpanded = os.time()
        }
        
        -- Save to registry
        SpatialRefuge.SaveRefugeData(refugeData)
    end
    
    return refugeData
end

-- Save refuge data to ModData
function SpatialRefuge.SaveRefugeData(refugeData)
    if not refugeData or not refugeData.username then return end
    
    local registry = SpatialRefuge.GetRefugeRegistry()
    registry[refugeData.username] = refugeData
end

-- Delete refuge data from ModData
function SpatialRefuge.DeleteRefugeData(player)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    local registry = SpatialRefuge.GetRefugeRegistry()
    registry[username] = nil
end

-- Allocate coordinates for a new refuge
-- Returns: centerX, centerY, centerZ
function SpatialRefuge.AllocateRefugeCoordinates()
    local registry = SpatialRefuge.GetRefugeRegistry()
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

-- Check if player is currently in their refuge
function SpatialRefuge.IsPlayerInRefuge(player)
    if not player then return false end
    
    -- Safety check for player position functions
    if not player.getX or not player.getY then
        return false
    end
    
    local x = player:getX()
    local y = player:getY()
    
    if not x or not y then return false end
    
    -- Check if in refuge coordinate space
    -- Refuges are CENTERED at baseX/baseY, so they extend BELOW/LEFT of base too
    -- First refuge center is at (1000, 1000) with radius, so tiles extend to ~998
    local baseX = SpatialRefugeConfig.REFUGE_BASE_X
    local baseY = SpatialRefugeConfig.REFUGE_BASE_Y
    local maxRadius = 10  -- Max tier radius (tier 5 = radius 7, plus buffer)
    
    -- Account for refuge radius extending below/left of base coordinates
    local minX = baseX - maxRadius
    local minY = baseY - maxRadius
    local maxX = baseX + 1000
    local maxY = baseY + 1000
    
    return x >= minX and x < maxX and 
           y >= minY and y < maxY
end

-- Get player's return position from global ModData (more reliable than player modData)
function SpatialRefuge.GetReturnPosition(player)
    if not player then return nil end
    
    local username = player:getUsername()
    if not username then return nil end
    
    local modData = SpatialRefuge.InitializeModData()
    if not modData or not modData.ReturnPositions then return nil end
    
    return modData.ReturnPositions[username]
end

-- Save player's return position to global ModData (more reliable than player modData)
function SpatialRefuge.SaveReturnPosition(player, x, y, z)
    if not player then return false end
    
    local username = player:getUsername()
    if not username then return false end
    
    -- CRITICAL: Never save refuge coordinates as return position
    -- This prevents losing original world position if enter is called while inside
    local baseX = SpatialRefugeConfig.REFUGE_BASE_X
    local baseY = SpatialRefugeConfig.REFUGE_BASE_Y
    local maxRadius = 10  -- Account for refuge extending below/left of base
    local minX = baseX - maxRadius
    local minY = baseY - maxRadius
    local maxX = baseX + 1000
    local maxY = baseY + 1000
    
    if x >= minX and x < maxX and y >= minY and y < maxY then
        print("[SpatialRefuge] WARNING: Attempted to save refuge coordinates as return position - blocked!")
        return false
    end
    
    local modData = SpatialRefuge.InitializeModData()
    if not modData then return false end
    
    -- Ensure ReturnPositions table exists
    if not modData.ReturnPositions then
        modData.ReturnPositions = {}
    end
    
    -- Save the position
    modData.ReturnPositions[username] = { x = x, y = y, z = z }
    
    -- Transmit for multiplayer sync
    SpatialRefuge.TransmitModData()
    
    return true
end

-- Clear player's return position from global ModData
function SpatialRefuge.ClearReturnPosition(player)
    if not player then return end
    
    local username = player:getUsername()
    if not username then return end
    
    local modData = SpatialRefuge.InitializeModData()
    if modData and modData.ReturnPositions then
        modData.ReturnPositions[username] = nil
        SpatialRefuge.TransmitModData()
    end
    
    -- Also invalidate boundary cache when exiting
    if SpatialRefuge.InvalidateBoundsCache then
        SpatialRefuge.InvalidateBoundsCache(player)
    end
end

-- Get last teleport timestamp
function SpatialRefuge.GetLastTeleportTime(player)
    if not player then return 0 end
    
    local pmd = player:getModData()
    return pmd.spatialRefuge_lastTeleport or 0
end

-- Update last teleport timestamp
function SpatialRefuge.UpdateTeleportTime(player)
    if not player then return end
    
    local pmd = player:getModData()
    pmd.spatialRefuge_lastTeleport = getTimestamp()  -- Use game time instead of os.time()
end

-- Get last damage timestamp
function SpatialRefuge.GetLastDamageTime(player)
    if not player then return 0 end
    
    local pmd = player:getModData()
    return pmd.spatialRefuge_lastDamage or 0
end

-- Update last damage timestamp (called from damage event)
function SpatialRefuge.UpdateDamageTime(player)
    if not player then return end
    
    local pmd = player:getModData()
    pmd.spatialRefuge_lastDamage = getTimestamp()  -- Use game time instead of os.time()
end

-- Track damage events for combat teleport blocking
local function OnPlayerDamage(player)
    SpatialRefuge.UpdateDamageTime(player)
end

-- Global flag to track world readiness
SpatialRefuge.worldReady = false

-- Initialize on game start
local function OnGameStart()
    SpatialRefuge.InitializeModData()
end

-- World initialization (wait for world to be fully loaded)
local function OnInitWorld()
    SpatialRefuge.worldReady = true
end

-- Register events
Events.OnGameStart.Add(OnGameStart)
Events.OnInitWorld.Add(OnInitWorld)
Events.OnPlayerGetDamage.Add(OnPlayerDamage)

return SpatialRefuge

