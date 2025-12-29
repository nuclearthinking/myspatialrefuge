-- Spatial Refuge Main Module (Client)
-- Handles refuge data persistence and coordinate management for client
-- Uses shared SpatialRefugeData module for core functionality

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeData"
require "shared/SpatialRefugeMigration"

-- Prevent double-loading
if SpatialRefuge and SpatialRefuge._mainLoaded then
    return SpatialRefuge
end

-- Use global modules (loaded by main)
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-- Mark as loaded
SpatialRefuge._mainLoaded = true

-----------------------------------------------------------
-- Delegate to Shared Data Module
-- These functions maintain the existing API for client code
-----------------------------------------------------------

-- Initialize ModData structure
function SpatialRefuge.InitializeModData()
    return SpatialRefugeData.InitializeModData()
end

-- Transmit ModData changes (for multiplayer sync)
function SpatialRefuge.TransmitModData()
    return SpatialRefugeData.TransmitModData()
end

-- Get global refuge registry
function SpatialRefuge.GetRefugeRegistry()
    return SpatialRefugeData.GetRefugeRegistry()
end

-- Get refuge data for a specific player
function SpatialRefuge.GetRefugeData(player)
    return SpatialRefugeData.GetRefugeData(player)
end

-- Get or create refuge data for a player
function SpatialRefuge.GetOrCreateRefugeData(player)
    return SpatialRefugeData.GetOrCreateRefugeData(player)
end

-- Save refuge data to ModData
function SpatialRefuge.SaveRefugeData(refugeData)
    return SpatialRefugeData.SaveRefugeData(refugeData)
end

-- Delete refuge data from ModData
function SpatialRefuge.DeleteRefugeData(player)
    return SpatialRefugeData.DeleteRefugeData(player)
end

-- Allocate coordinates for a new refuge
function SpatialRefuge.AllocateRefugeCoordinates()
    return SpatialRefugeData.AllocateRefugeCoordinates()
end

-- Check if player is currently in their refuge
function SpatialRefuge.IsPlayerInRefuge(player)
    return SpatialRefugeData.IsPlayerInRefugeCoords(player)
end

-- Get player's return position from global ModData
function SpatialRefuge.GetReturnPosition(player)
    return SpatialRefugeData.GetReturnPosition(player)
end

-- Save player's return position to global ModData
function SpatialRefuge.SaveReturnPosition(player, x, y, z)
    return SpatialRefugeData.SaveReturnPosition(player, x, y, z)
end

-- Clear player's return position from global ModData
function SpatialRefuge.ClearReturnPosition(player)
    SpatialRefugeData.ClearReturnPosition(player)
    
    -- Also invalidate boundary cache when exiting
    if SpatialRefuge.InvalidateBoundsCache then
        SpatialRefuge.InvalidateBoundsCache(player)
    end
end

-----------------------------------------------------------
-- Client-Specific Functions
-- These remain in client code (not shared)
-----------------------------------------------------------

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

-----------------------------------------------------------
-- Event Handlers
-----------------------------------------------------------

-- Track damage events for combat teleport blocking
local function OnPlayerDamage(player)
    SpatialRefuge.UpdateDamageTime(player)
end

-- Global flag to track world readiness
SpatialRefuge.worldReady = false

local function OnGameStart()
    -- Singleplayer only (MP: server transmits authoritative ModData)
    if not isClient() then
        SpatialRefuge.InitializeModData()
        
        -- Delayed migration (wait for player to load)
        local tickCount = 0
        local function delayedMigration()
            tickCount = tickCount + 1
            if tickCount < 30 then return end
            
            Events.OnTick.Remove(delayedMigration)
            
            local player = getPlayer()
            if player and SpatialRefugeMigration.NeedsMigration(player) then
                local success, msg = SpatialRefugeMigration.MigratePlayer(player)
                if success then
                    print("[SpatialRefuge] " .. msg)
                end
            end
        end
        
        Events.OnTick.Add(delayedMigration)
    end
end

local function OnInitWorld()
    SpatialRefuge.worldReady = true
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnGameStart.Add(OnGameStart)
Events.OnInitWorld.Add(OnInitWorld)
Events.OnPlayerGetDamage.Add(OnPlayerDamage)

return SpatialRefuge
