-- Spatial Refuge Generation Module (Client)
-- Thin wrapper around SpatialRefugeShared for client-side use
-- In multiplayer, server handles generation; this is used for singleplayer

require "shared/MSR_Shared"
require "shared/MSR_Config"
require "shared/MSR_PlayerMessage"

-- Assume SpatialRefuge is already loaded


-----------------------------------------------------------
-- Delegate to Shared Module
-- These functions maintain the existing API for client code
-----------------------------------------------------------

-- Clear all zombies and zombie corpses from an area
-- @param forceClean: if true, clears zombies even in remote areas
-- @param player: optional player for MP sync (server only)
function MSR.ClearZombiesFromArea(centerX, centerY, z, radius, forceClean, player)
    return MSR.Shared.ClearZombiesFromArea(centerX, centerY, z, radius, forceClean, player)
end

-- NOTE: Floor generation removed - natural terrain should remain

-- Create or find Sacred Relic
function MSR.CreateSacredRelic(x, y, z, refugeId, searchRadius)
    return MSR.Shared.CreateSacredRelic(x, y, z, refugeId, searchRadius)
end

-- Create boundary wall at coordinates
function MSR.CreateWall(x, y, z, addNorth, addWest, cornerSprite)
    return MSR.Shared.CreateWall(x, y, z, addNorth, addWest, cornerSprite)
end

-- Create solid boundary walls around a refuge area
function MSR.CreateBoundaryWalls(centerX, centerY, z, radius)
    return MSR.Shared.CreateBoundaryWalls(centerX, centerY, z, radius)
end

-- Remove boundary walls (for expansion)
function MSR.RemoveBoundaryWalls(centerX, centerY, z, radius)
    return MSR.Shared.RemoveBoundaryWalls(centerX, centerY, z, radius)
    end
    
-----------------------------------------------------------
-- Client-Only Functions
-- These functions are specific to client-side operation
-----------------------------------------------------------

-- Generate a new refuge for a player (singleplayer only)
-- In multiplayer, server handles this via RequestEnter command
function MSR.GenerateNewRefuge(player)
    if not player then return nil end
    
    -- Check if world is ready
    if not MSR.worldReady then return nil end
    
    -- Get or create refuge data (allocates coordinates)
    local refugeData = MSR.GetOrCreateRefugeData(player)
    if not refugeData then return nil end
    
    local PM = MSR.PlayerMessage
    PM.Say(player, PM.REFUGE_INITIALIZING)
    
    return refugeData
end

-- Expand an existing refuge to a new tier
function MSR.ExpandRefuge(refugeData, newTier)
    if not refugeData then return false end
    
    -- Use shared expansion logic
    local success = MSR.Shared.ExpandRefuge(refugeData, newTier)
    
    if success then
        -- Save the updated refuge data
    MSR.SaveRefugeData(refugeData)
    end
    
    return success
end

-- Delete a refuge completely (for death penalty)
-- NOTE: In multiplayer, the SERVER handles refuge deletion via OnPlayerDeath event
-- This function only runs fully in singleplayer to avoid desync issues
function MSR.DeleteRefuge(player)
    -- In multiplayer CLIENT mode, do NOT delete physical structures
    -- Server handles this authoritatively via OnPlayerDeathServer
    if isClient() and not isServer() then
        if getDebug() then
            print("[MSR] DeleteRefuge called on MP client - skipping (server handles this)")
        end
        -- Only clear local ModData cache (server will transmit authoritative data)
        -- Don't remove physical objects - server is authoritative for that
        return
    end
    
    -- SINGLEPLAYER ONLY: Delete physical structures
    local refugeData = MSR.GetRefugeData(player)
    if not refugeData then return end
    
    local cell = getCell and getCell()
    if not cell then return end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius
    local wallHeight = MSR.Config.WALL_HEIGHT or 1  -- Use config default, not 3
    
    -- Remove all world objects in refuge area at all z-levels (including buffer zone)
    for level = 0, wallHeight - 1 do
        local currentZ = centerZ + level
        for x = -radius-2, radius+2 do
            for y = -radius-2, radius+2 do
                local square = cell:getGridSquare(centerX + x, centerY + y, currentZ)
                if square then
                    local objects = square:getObjects()
                    if objects then
                        for i = objects:size()-1, 0, -1 do
                            local obj = objects:get(i)
                            if obj then
                                square:transmitRemoveItemFromSquare(obj)
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Remove from ModData
    MSR.DeleteRefugeData(player)
end

return MSR
