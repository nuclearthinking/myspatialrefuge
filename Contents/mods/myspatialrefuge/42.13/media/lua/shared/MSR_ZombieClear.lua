-- MSR_ZombieClear - Zombie Clearing Module
-- Centralized zombie clearing logic for refuge areas
-- Prevents zombie respawns inside protected refuge space

require "shared/core/MSR"
require "shared/MSR_Config"
require "shared/MSR_Data"
require "shared/core/MSR_Env"

if MSR.ZombieClear and MSR.ZombieClear._loaded then
    return MSR.ZombieClear
end

MSR.ZombieClear = MSR.ZombieClear or {}
MSR.ZombieClear._loaded = true

local ZombieClear = MSR.ZombieClear

-- Buffer tiles around refuge to clear zombies (matches MSR_Shared)
local ZOMBIE_CLEAR_BUFFER = 3

-----------------------------------------------------------
-- Core Clearing Function
-----------------------------------------------------------

--- Clear zombies and corpses from a refuge area
-- @param refugeData table - Refuge data with centerX, centerY, centerZ, radius
-- @param player IsoPlayer - Player for network sync (MP)
-- @return number - Count of zombies/corpses cleared
function ZombieClear.ClearRefuge(refugeData, player)
    if not refugeData then return 0 end
    
    -- Delegate to MSR.Shared.ClearZombiesFromArea
    if MSR.Shared and MSR.Shared.ClearZombiesFromArea then
        return MSR.Shared.ClearZombiesFromArea(
            refugeData.centerX,
            refugeData.centerY,
            refugeData.centerZ,
            refugeData.radius or 1,
            true,  -- forceClean
            player
        )
    end
    
    return 0
end

-----------------------------------------------------------
-- Periodic Clearing Functions
-----------------------------------------------------------

--- Clear zombies for a single player if they are in their refuge
-- Used by client-side periodic checks (SP/Coop host)
-- @param player IsoPlayer - The player to check and clear for
-- @return number - Count of zombies cleared (0 if not in refuge)
function ZombieClear.PeriodicClearForPlayer(player)
    if not player then return 0 end
    
    -- Skip if player is not in refuge
    if not MSR.Data.IsPlayerInRefugeCoords(player) then
        return 0
    end
    
    -- Get refuge data using appropriate method for environment
    local refugeData
    if MSR.GetRefugeData then
        refugeData = MSR.GetRefugeData(player)
    elseif MSR.Data.GetRefugeData then
        refugeData = MSR.Data.GetRefugeData(player)
    end
    
    if not refugeData then return 0 end
    
    local cleared = ZombieClear.ClearRefuge(refugeData, player)
    
    if cleared > 0 then
        L.debug("ZombieClear", "Periodic clear for player: removed " .. cleared .. " zombies/corpses")
    end
    
    return cleared
end

--- Clear zombies for all online players in their refuges
-- Used by server-side periodic checks (MP)
-- @return number - Total count of zombies cleared across all refuges
function ZombieClear.PeriodicClearAllPlayers()
    local players = getOnlinePlayers()
    if not players then return 0 end
    
    local playerCount = players:size()
    if playerCount == 0 then return 0 end
    
    local totalCleared = 0
    
    for i = 0, playerCount - 1 do
        local player = players:get(i)
        if player then
            -- Check if player is inside their refuge
            if MSR.Data.IsPlayerInRefugeCoords(player) then
                local username = player:getUsername()
                if username then
                    local refugeData = MSR.Data.GetRefugeDataByUsername(username)
                    if refugeData then
                        local cleared = ZombieClear.ClearRefuge(refugeData, player)
                        totalCleared = totalCleared + cleared
                    end
                end
            end
        end
    end
    
    if totalCleared > 0 then
        L.debug("ZombieClear", "Periodic clear for all players: removed " .. totalCleared .. " zombies/corpses")
    end
    
    return totalCleared
end

-----------------------------------------------------------
-- Event Handlers (Self-Registering)
-----------------------------------------------------------

--- Client-side periodic zombie clearing
-- Runs every minute for SP/Coop host
local function onClientPeriodicZombieClear()
    -- Only run on SP or Coop host, not MP client
    if MSR.Env.isMultiplayerClient() then return end
    
    local player = getPlayer()
    if not player then return end
    
    ZombieClear.PeriodicClearForPlayer(player)
end

--- Server-side periodic zombie clearing
-- Runs every minute for MP server
local function onServerPeriodicZombieClear()
    ZombieClear.PeriodicClearAllPlayers()
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

-- Register appropriate handler based on environment
-- Client: Register for SP/Coop
-- Server: Register for MP
if MSR.Env.isServer() then
    Events.EveryOneMinute.Add(onServerPeriodicZombieClear)
    L.debug("ZombieClear", "Server periodic zombie clear registered")
else
    Events.EveryOneMinute.Add(onClientPeriodicZombieClear)
    L.debug("ZombieClear", "Client periodic zombie clear registered")
end

return MSR.ZombieClear
