-- Spatial Refuge Main Module (Client)

require "shared/MSR_Config"
require "shared/MSR_Data"
require "shared/MSR_Env"
require "shared/MSR_Migration"
require "shared/MSR_Shared"
require "shared/MSR_PlayerMessage"
local PM = MSR.PlayerMessage

if MSR and MSR._mainLoaded then
    return MSR
end

MSR._mainLoaded = true

function MSR.InitializeModData()
    return MSR.Data.InitializeModData()
end

function MSR.TransmitModData()
    return MSR.Data.TransmitModData()
end

function MSR.GetRefugeRegistry()
    return MSR.Data.GetRefugeRegistry()
end

function MSR.GetRefugeData(player)
    return MSR.Data.GetRefugeData(player)
end

function MSR.GetOrCreateRefugeData(player)
    return MSR.Data.GetOrCreateRefugeData(player)
end

function MSR.SaveRefugeData(refugeData)
    return MSR.Data.SaveRefugeData(refugeData)
end

function MSR.DeleteRefugeData(player)
    return MSR.Data.DeleteRefugeData(player)
end

function MSR.AllocateRefugeCoordinates()
    return MSR.Data.AllocateRefugeCoordinates()
end

function MSR.IsPlayerInRefuge(player)
    return MSR.Data.IsPlayerInRefugeCoords(player)
end

function MSR.GetReturnPosition(player)
    return MSR.Data.GetReturnPosition(player)
end

function MSR.SaveReturnPosition(player, x, y, z)
    return MSR.Data.SaveReturnPosition(player, x, y, z)
end

function MSR.ClearReturnPosition(player)
    MSR.Data.ClearReturnPosition(player)
    if MSR.InvalidateBoundsCache then
        MSR.InvalidateBoundsCache(player)
    end
end

function MSR.GetLastTeleportTime(player)
    if not player then return 0 end
    
    local pmd = player:getModData()
    return pmd.spatialRefuge_lastTeleport or 0
end

function MSR.UpdateTeleportTime(player)
    if not player then return end
    player:getModData().spatialRefuge_lastTeleport = K.time()
end

-- Update teleport time with encumbrance penalty
-- The penalty is added to the timestamp, making the next cooldown check wait longer
-- Example: If penalty is 120s and cooldown is 10s, next teleport is blocked for 130s total
function MSR.UpdateTeleportTimeWithPenalty(player, penaltySeconds)
    if not player then return 0 end
    
    penaltySeconds = penaltySeconds or 0
    local pmd = player:getModData()
    local now = K.time()
    
    -- Store current time + penalty
    -- This makes cooldown check wait: (now + penalty) + cooldown from now
    pmd.spatialRefuge_lastTeleport = now + penaltySeconds
    pmd.spatialRefuge_lastEncumbrancePenalty = penaltySeconds
    
    if penaltySeconds > 0 then
        L.debug("Main", "Applied encumbrance penalty: " .. penaltySeconds .. "s")
    end
    
    return penaltySeconds
end

-- Get the last applied encumbrance penalty (for UI display)
function MSR.GetLastEncumbrancePenalty(player)
    if not player then return 0 end
    return player:getModData().spatialRefuge_lastEncumbrancePenalty or 0
end

function MSR.GetLastDamageTime(player)
    if not player then return 0 end
    
    local pmd = player:getModData()
    return pmd.spatialRefuge_lastDamage or 0
end

function MSR.UpdateDamageTime(player)
    if not player then return end
    player:getModData().spatialRefuge_lastDamage = K.time()
end

local _relicContainerCache = {
    container = nil,
    refugeId = nil,
    cacheTime = 0,
    CACHE_DURATION = 5
}

function MSR.InvalidateRelicContainerCache()
    _relicContainerCache.container = nil
    _relicContainerCache.refugeId = nil
    _relicContainerCache.cacheTime = 0
end

function MSR.GetRelicContainer(player, bypassCache)
    if not player then return nil end
    
    local refugeData = MSR.GetRefugeData(player)
    if not refugeData then return nil end
    
    local now = K.time()
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
    local relic = MSR.Shared.FindRelicInRefuge(relicX, relicY, relicZ, radius, refugeId)
    
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

local function OnPlayerDamage(character, damageType, damage)
    if character and damageType == "WEAPONHIT" then
        MSR.UpdateDamageTime(character)
    end
end

MSR.worldReady = false

-- Check for orphan refuges and claim them (singleplayer only)
local function checkRefugeInheritance(player)
    if not MSR.Env.isSingleplayer() then return end
    
    local existingRefuge = MSR.Data.GetRefugeData(player)
    if existingRefuge and existingRefuge.inheritedFrom then
        L.debug("Main", "Inherited refuge from " .. existingRefuge.inheritedFrom)
        PM.Say(player, PM.INHERITED_REFUGE_CONNECTION)
        return
    end
    
    if MSR.Data.HasOrphanRefuge() then
        MSR.Data.GetOrCreateRefugeData(player)
    end
end

local function OnGameStart()
    if not isClient() then
        MSR.InitializeModData()
        
        local tickCount = 0
        local function delayedInit()
            tickCount = tickCount + 1
            if tickCount < 30 then return end
            
            Events.OnTick.Remove(delayedInit)
            
            local player = getPlayer()
            if not player then return end
            
            -- Check for data migration (old format to new)
            if MSR.Migration.NeedsMigration(player) then
                local success, msg = MSR.Migration.MigratePlayer(player)
                if success then
                    print("[MSR] " .. msg)
                end
            end
            
            -- Check for refuge inheritance (SP only - claim orphan refuge)
            checkRefugeInheritance(player)
        end
        
        Events.OnTick.Add(delayedInit)
    end
end

local function OnInitWorld()
    MSR.worldReady = true
end

Events.OnGameStart.Add(OnGameStart)
Events.OnInitWorld.Add(OnInitWorld)
Events.OnPlayerGetDamage.Add(OnPlayerDamage)

return MSR
