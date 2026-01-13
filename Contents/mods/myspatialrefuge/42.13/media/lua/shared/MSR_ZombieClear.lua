require "00_core/00_MSR"

-- Register module (returns nil if already loaded - skip initialization)
local ZombieClear = MSR.register("ZombieClear")
if not ZombieClear then return MSR.ZombieClear end
local LOG = L.logger("ZombieClear")

local clearingPausedUntil = 0
local PAUSE_DURATION = 10 -- seconds
local ZOMBIE_CLEAR_BUFFER = 3

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

local function isInArea(x, y, centerX, centerY, radius)
    return x >= centerX - radius and x <= centerX + radius and
        y >= centerY - radius and y <= centerY + radius
end

-----------------------------------------------------------
-- Core Clearing Function
-----------------------------------------------------------

--- Clear zombies and corpses from an area
--- @param centerX number Center X coordinate
--- @param centerY number Center Y coordinate
--- @param z number Z level
--- @param radius number Radius to clear
--- @param forceClean boolean Force cleaning even in tutorial area
--- @param player IsoPlayer Player for MP sync
--- @return number Number of entities cleared
function ZombieClear.ClearZombiesFromArea(centerX, centerY, z, radius, forceClean, player)
    if not forceClean and centerX < 2000 and centerY < 2000 then
        return 0
    end

    local cell = getCell()
    if not cell then return 0 end

    local cleared = 0
    local totalRadius = radius + ZOMBIE_CLEAR_BUFFER
    local isMPServer = MSR.Env.isMultiplayer() and MSR.Env.isServer()
    local zombieOnlineIDs = {}

    -- Clear zombies (reverse iteration for safe removal)
    local zombieList = cell:getZombieList()
    for i = K.size(zombieList) - 1, 0, -1 do
        local zombie = zombieList:get(i)
        if zombie and zombie:getZ() == z and isInArea(zombie:getX(), zombie:getY(), centerX, centerY, totalRadius) then
            local md = zombie:getModData()
            if md.MSR_ProtectedCorpse then
                LOG.debug("Skipping protected zombie (reanimated from player corpse)")
            else
                if isMPServer then
                    local onlineID = zombie:getOnlineID()
                    if onlineID >= 0 then
                        table.insert(zombieOnlineIDs, onlineID)
                    end
                end
                zombie:removeFromWorld()
                zombie:removeFromSquare()
                cleared = cleared + 1
            end
        end
    end

    -- Clear corpses (reverse iteration for safe removal)
    for dx = -totalRadius, totalRadius do
        for dy = -totalRadius, totalRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local bodies = square:getDeadBodys()
                for i = K.size(bodies) - 1, 0, -1 do
                    local body = bodies:get(i)
                    if body and not body:isAnimal() then
                        local md = body:getModData()
                        if not md.MSR_ProtectedCorpse then
                            square:removeCorpse(body, false)
                            cleared = cleared + 1
                        end
                    end
                end
            end
        end
    end

    if isMPServer and player and #zombieOnlineIDs > 0 then
        sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE,
            MSR.Config.COMMANDS.CLEAR_ZOMBIES, {
                zombieIDs = zombieOnlineIDs
            })
        LOG.debug("Sent %d zombie IDs to client for removal", #zombieOnlineIDs)
    end

    if cleared > 0 then
        LOG.debug("Cleared %d zombies/corpses from refuge area", cleared)
    end

    return cleared
end

function ZombieClear.IsPaused()
    return K.time() < clearingPausedUntil
end

function ZombieClear.Pause(reason)
    clearingPausedUntil = K.time() + PAUSE_DURATION
    L.debug("ZombieClear", "Pausing clearing for " .. PAUSE_DURATION .. "s (" .. tostring(reason) .. ")")
end

--- @param refugeData table Refuge data with centerX, centerY, centerZ, radius
--- @param player IsoPlayer Player for MP sync
--- @return number Number of entities cleared
function ZombieClear.ClearRefuge(refugeData, player)
    if not refugeData then return 0 end
    
    return ZombieClear.ClearZombiesFromArea(
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
