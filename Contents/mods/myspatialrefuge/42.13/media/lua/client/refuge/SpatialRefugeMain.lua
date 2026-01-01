-- Spatial Refuge Main Module (Client)
-- Handles refuge data persistence and coordinate management for client
-- Uses shared SpatialRefugeData module for core functionality

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeData"
require "shared/SpatialRefugeMigration"
require "shared/SpatialRefugeShared"

if SpatialRefuge and SpatialRefuge._mainLoaded then
    return SpatialRefuge
end

SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}
SpatialRefuge._mainLoaded = true

-----------------------------------------------------------
-- Delegate to Shared Data Module
-----------------------------------------------------------

function SpatialRefuge.InitializeModData()
    return SpatialRefugeData.InitializeModData()
end

function SpatialRefuge.TransmitModData()
    return SpatialRefugeData.TransmitModData()
end

function SpatialRefuge.GetRefugeRegistry()
    return SpatialRefugeData.GetRefugeRegistry()
end

function SpatialRefuge.GetRefugeData(player)
    return SpatialRefugeData.GetRefugeData(player)
end

function SpatialRefuge.GetOrCreateRefugeData(player)
    return SpatialRefugeData.GetOrCreateRefugeData(player)
end

function SpatialRefuge.SaveRefugeData(refugeData)
    return SpatialRefugeData.SaveRefugeData(refugeData)
end

function SpatialRefuge.DeleteRefugeData(player)
    return SpatialRefugeData.DeleteRefugeData(player)
end

function SpatialRefuge.AllocateRefugeCoordinates()
    return SpatialRefugeData.AllocateRefugeCoordinates()
end

function SpatialRefuge.IsPlayerInRefuge(player)
    return SpatialRefugeData.IsPlayerInRefugeCoords(player)
end

function SpatialRefuge.GetReturnPosition(player)
    return SpatialRefugeData.GetReturnPosition(player)
end

function SpatialRefuge.SaveReturnPosition(player, x, y, z)
    return SpatialRefugeData.SaveReturnPosition(player, x, y, z)
end

function SpatialRefuge.ClearReturnPosition(player)
    SpatialRefugeData.ClearReturnPosition(player)
    
    if SpatialRefuge.InvalidateBoundsCache then
        SpatialRefuge.InvalidateBoundsCache(player)
    end
end

-----------------------------------------------------------
-- Client-Specific Functions
-----------------------------------------------------------

function SpatialRefuge.GetLastTeleportTime(player)
    if not player then return 0 end
    
    local pmd = player:getModData()
    return pmd.spatialRefuge_lastTeleport or 0
end

function SpatialRefuge.UpdateTeleportTime(player)
    if not player then return end
    
    local pmd = player:getModData()
    pmd.spatialRefuge_lastTeleport = getTimestamp()
end

function SpatialRefuge.GetLastDamageTime(player)
    if not player then return 0 end
    
    local pmd = player:getModData()
    return pmd.spatialRefuge_lastDamage or 0
end

function SpatialRefuge.UpdateDamageTime(player)
    if not player then return end
    
    local pmd = player:getModData()
    pmd.spatialRefuge_lastDamage = getTimestamp()
end

-- Cache to avoid expensive FindRelicInRefuge calls on every UI update
local _relicContainerCache = {
    container = nil,
    refugeId = nil,
    cacheTime = 0,
    CACHE_DURATION = 5
}

function SpatialRefuge.InvalidateRelicContainerCache()
    _relicContainerCache.container = nil
    _relicContainerCache.refugeId = nil
    _relicContainerCache.cacheTime = 0
end

-- @param bypassCache: If true, always do a fresh lookup (for transactions)
function SpatialRefuge.GetRelicContainer(player, bypassCache)
    if not player then return nil end
    
    local refugeData = SpatialRefuge.GetRefugeData(player)
    if not refugeData then return nil end
    
    local now = getTimestamp and getTimestamp() or 0
    local refugeId = refugeData.refugeId
    
    if not bypassCache 
        and _relicContainerCache.container 
        and _relicContainerCache.refugeId == refugeId 
        and (now - _relicContainerCache.cacheTime) < _relicContainerCache.CACHE_DURATION then
        return _relicContainerCache.container
    end
    
    local relicX = refugeData.relicX
    local relicY = refugeData.relicY
    local relicZ = refugeData.relicZ or 0
    
    if not relicX or not relicY then
        relicX = refugeData.centerX
        relicY = refugeData.centerY
        relicZ = refugeData.centerZ or 0
    end
    
    local radius = refugeData.radius or 1
    local relic = SpatialRefugeShared.FindRelicInRefuge(relicX, relicY, relicZ, radius, refugeId)
    
    if not relic then 
        _relicContainerCache.container = nil
        _relicContainerCache.refugeId = nil
        return nil 
    end
    
    local container = nil
    if relic.getContainer then
        container = relic:getContainer()
    end
    
    -- Update cache even when bypassing, so next UI call benefits
    _relicContainerCache.container = container
    _relicContainerCache.refugeId = refugeId
    _relicContainerCache.cacheTime = now
    
    return container
end

-----------------------------------------------------------
-- Event Handlers
-----------------------------------------------------------

-- OnPlayerGetDamage fires for ALL damage types (self-damage, hunger, etc.)
-- Only block teleport for WEAPONHIT (combat damage from zombies/players)
local function OnPlayerDamage(character, damageType, damage)
    if not character then return end
    
    if damageType == "WEAPONHIT" then
        SpatialRefuge.UpdateDamageTime(character)
    end
end

SpatialRefuge.worldReady = false

local function OnGameStart()
    if not isClient() then
        SpatialRefuge.InitializeModData()
        
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

Events.OnGameStart.Add(OnGameStart)
Events.OnInitWorld.Add(OnInitWorld)
Events.OnPlayerGetDamage.Add(OnPlayerDamage)

return SpatialRefuge
