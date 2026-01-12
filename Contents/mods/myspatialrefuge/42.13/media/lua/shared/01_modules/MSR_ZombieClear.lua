-- MSR_ZombieClear - Periodic zombie clearing for refuge areas
--
-- Subscribes to events:
--   MSR_PlayerDiedInRefuge - Pauses clearing to protect player corpse
--
-- Uses MSR.Data for refuge data lookups (core infrastructure)
-- Uses MSR.Shared.ClearZombiesFromArea for actual clearing

require "shared/00_core/00_MSR"
require "shared/00_core/05_Config"
require "shared/00_core/04_Env"
require "shared/00_core/07_Events"

if MSR.ZombieClear and MSR.ZombieClear._loaded then return MSR.ZombieClear end

MSR.ZombieClear = {}
MSR.ZombieClear._loaded = true

local ZombieClear = MSR.ZombieClear

-- Pause state - when player dies in refuge, pause clearing temporarily
local clearingPausedUntil = 0
local PAUSE_DURATION = 10 -- seconds

-----------------------------------------------------------
-- Pause Management
-----------------------------------------------------------

function ZombieClear.IsPaused()
    return K.time() < clearingPausedUntil
end

function ZombieClear.Pause(reason)
    clearingPausedUntil = K.time() + PAUSE_DURATION
    L.debug("ZombieClear", "Pausing clearing for " .. PAUSE_DURATION .. "s (" .. tostring(reason) .. ")")
end

-----------------------------------------------------------
-- Clearing Functions
-----------------------------------------------------------

--- Clear zombies/corpses from a refuge area
--- @param refugeData table Refuge data with centerX, centerY, centerZ, radius
--- @param player IsoPlayer Player for MP sync
--- @return number Number of entities cleared
function ZombieClear.ClearRefuge(refugeData, player)
    if not refugeData then return 0 end
    
    -- Lazy load MSR.Shared to avoid circular dependency at load time
    if not MSR.Shared or not MSR.Shared.ClearZombiesFromArea then
        L.debug("ZombieClear", "MSR.Shared not available")
        return 0
    end
    
    return MSR.Shared.ClearZombiesFromArea(
        refugeData.centerX, refugeData.centerY, refugeData.centerZ,
        refugeData.radius or 1, true, player
    )
end

--- Clear for single player (SP/Coop host)
function ZombieClear.PeriodicClearForPlayer(player)
    if not player then return 0 end
    
    -- Lazy load MSR.Data
    if not MSR.Data then return 0 end
    
    if not MSR.Data.IsPlayerInRefugeCoords(player) then return 0 end
    
    local refugeData = MSR.Data.GetRefugeData(player)
    if not refugeData then return 0 end
    
    local cleared = ZombieClear.ClearRefuge(refugeData, player)
    if cleared > 0 then
        L.debug("ZombieClear", "Periodic clear for player: removed " .. cleared .. " zombies/corpses")
    end
    return cleared
end

--- Clear for all online players (MP server)
function ZombieClear.PeriodicClearAllPlayers()
    local totalCleared = 0
    
    -- Lazy load MSR.Data
    if not MSR.Data then return 0 end
    
    for _, player in K.iter(getOnlinePlayers()) do
        if MSR.Data.IsPlayerInRefugeCoords(player) then
            local username = player:getUsername()
            local refugeData = MSR.Data.GetRefugeDataByUsername(username)
            if refugeData then
                totalCleared = totalCleared + ZombieClear.ClearRefuge(refugeData, player)
            end
        end
    end
    
    if totalCleared > 0 then
        L.debug("ZombieClear", "Periodic clear for all players: removed " .. totalCleared .. " zombies/corpses")
    end
    return totalCleared
end

-----------------------------------------------------------
-- Event Handlers
-----------------------------------------------------------

local function onServerPeriodicClear()
    if ZombieClear.IsPaused() then
        L.debug("ZombieClear", "Clearing paused, skipping periodic clear")
        return
    end
    
    -- Dedicated/Coop server: clear for all connected players
    -- SP: clear for local player only (getOnlinePlayers may not work in SP)
    if MSR.Env.isServer() then
        ZombieClear.PeriodicClearAllPlayers()
    else
        -- SP only path
        local player = getPlayer()
        if player then ZombieClear.PeriodicClearForPlayer(player) end
    end
end

--- Handle player death in refuge - pause clearing to protect corpse
local function onPlayerDiedInRefuge(username)
    ZombieClear.Pause("player " .. tostring(username) .. " died in refuge")
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

-- Subscribe to death event (decoupled from MSR_Death module)
MSR.Events.Custom.Add("MSR_PlayerDiedInRefuge", onPlayerDiedInRefuge)
L.debug("ZombieClear", "Subscribed to MSR_PlayerDiedInRefuge event")

-- Register periodic clearing based on environment
-- Only one handler should run per environment to avoid duplicates
MSR.Events.OnAnyReady.Add(function()
    if MSR.Env.hasServerAuthority() then
        -- SP, Coop host, Dedicated server: use server clearing
        Events.EveryOneMinute.Add(onServerPeriodicClear)
        L.debug("ZombieClear", "Server authority periodic clear registered")
    end
    -- MP clients don't need to register - server handles clearing
end)

return MSR.ZombieClear
