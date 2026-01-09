-- Spatial Refuge Main Module (Client)

require "shared/00_core/05_Config"
require "shared/00_core/06_Data"
require "shared/00_core/04_Env"
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

function MSR.UpdateTeleportTimeWithPenalty(player, penaltySeconds)
    if not player then return 0 end
    
    penaltySeconds = penaltySeconds or 0
    local pmd = player:getModData()
    local now = K.time()
    
    pmd.spatialRefuge_lastTeleport = now + penaltySeconds
    pmd.spatialRefuge_lastEncumbrancePenalty = penaltySeconds
    
    if penaltySeconds > 0 then
        L.debug("Main", "Applied encumbrance penalty: " .. penaltySeconds .. "s")
    end
    
    return penaltySeconds
end

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

-- Track if we're in initial game load phase (OnGameStart will handle inheritance)
local _initialLoadPhase = false

-- Check for orphan refuges and claim them (singleplayer only)
-- Only shows message when inheritance actually happens (claiming an orphan)
-- HasOrphanRefuge() returns false after claiming, so safe to call multiple times
local function checkRefugeInheritance(player)
    if not MSR.Env.isSingleplayer() then return end
    
    -- Only claim orphan if one exists - this is when inheritance actually happens
    if MSR.Data.HasOrphanRefuge() then
        local refugeData = MSR.Data.GetOrCreateRefugeData(player)
        -- Show message immediately after claiming orphan refuge
        if refugeData and refugeData.inheritedFrom then
            L.debug("Main", "Inherited refuge from " .. refugeData.inheritedFrom)
            PM.Say(player, PM.INHERITED_REFUGE_CONNECTION)
        end
    end
end

local function OnGameStart()
    if not isClient() then
        MSR.InitializeModData()
        
        -- Mark that we're in initial load phase (OnCreatePlayer should skip)
        _initialLoadPhase = true
        
        local tickCount = 0
        local function delayedInit()
            tickCount = tickCount + 1
            if tickCount < 30 then return end
            
            Events.OnTick.Remove(delayedInit)
            
            -- Initial load phase complete
            _initialLoadPhase = false
            
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

-- Check inheritance when new character is created (same session after death)
local function OnCreatePlayer(playerIndex, player)
    if not player then return end
    if not MSR.Env.isSingleplayer() then return end
    
    -- Small delay to ensure world is ready
    local tickCount = 0
    local function delayedCheck()
        tickCount = tickCount + 1
        if tickCount < 10 then return end
        
        Events.OnTick.Remove(delayedCheck)
        
        -- Skip if this is initial game load (OnGameStart will handle it)
        -- Check here because OnCreatePlayer might fire before OnGameStart sets the flag
        if _initialLoadPhase then return end
        
        -- Re-get player in case reference changed
        local currentPlayer = getPlayer()
        if not currentPlayer then return end
        
        checkRefugeInheritance(currentPlayer)
    end
    
    Events.OnTick.Add(delayedCheck)
end

Events.OnGameStart.Add(OnGameStart)
Events.OnInitWorld.Add(OnInitWorld)
Events.OnPlayerGetDamage.Add(OnPlayerDamage)
if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(OnCreatePlayer)
end

return MSR
