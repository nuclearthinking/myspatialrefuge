-- MSR_Death - Player Death Event Orchestrator
-- Server-authoritative death handling via event system
--
-- Events fired:
--   MSR_PlayerDeath        - All player deaths (for essence creation, logging)
--   MSR_PlayerDiedInRefuge - Deaths inside refuge (pauses zombie clearing)
--   MSR_CorpseProtected    - Corpse was protected (for data cleanup)
--
-- All handlers subscribe to these events - no direct module coupling

require "00_core/00_MSR"

local Death = MSR.register("Death")
if not Death then return MSR.Death end

local LOG = L.logger("Death")

Death.PROTECTED_KEY = "MSR_ProtectedCorpse"

--- @param body IsoDeadBody|IsoZombie
--- @return boolean
function Death.IsProtected(body)
    local md = body and body:getModData()
    return md and md[Death.PROTECTED_KEY] == true
end


local function findPlayerCorpse(x, y, z, username, playerOnlineId)
    local cell = getCell()
    if not cell then return nil end

    for dx = -2, 2 do
        for dy = -2, 2 do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            if square then
                for _, body in K.iter(square:getDeadBodys()) do
                    if body:isPlayer() then
                        local md = body:getModData()
                        
                        -- Match by onlineID (MP) or owner marker (SP)
                        local matchByOnlineId = playerOnlineId and body:getCharacterOnlineID() == playerOnlineId
                        local matchByOwner = md.MSR_CorpseOwner == username
                        
                        if matchByOnlineId or matchByOwner then
                            return body
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function protectCorpse(body, username)
    local md = body:getModData()
    md[Death.PROTECTED_KEY] = true
    md.MSR_CorpseOwner = nil
    
    LOG.debug("Protected corpse of %s", username)
    
    -- Fire event for any handlers interested in corpse protection
    MSR.Events.Custom.Fire("MSR_CorpseProtected", {
        username = username,
        corpse = body
    })
end

--- Start delayed corpse search (corpse spawns after death event fires)
--- @param deathX number
--- @param deathY number
--- @param deathZ number
--- @param username string
--- @param playerOnlineId number|nil
--- @param diedInRefuge boolean
--- @param earnedXp table|nil XP data to pass to MSR_CorpseFound
local function startCorpseSearch(deathX, deathY, deathZ, username, playerOnlineId, diedInRefuge, earnedXp)
    local tickCount = 0
    local maxTicks = 60  -- ~1 second timeout

    local function findCorpse()
        tickCount = tickCount + 1
        
        -- Wait a few ticks for corpse to spawn
        if tickCount < 3 then return end
        
        -- Timeout
        if tickCount > maxTicks then
            Events.OnTick.Remove(findCorpse)
            LOG.debug("Timeout finding corpse of %s", username)
            return
        end

        local corpse = findPlayerCorpse(deathX, deathY, deathZ, username, playerOnlineId)
        if corpse then
            Events.OnTick.Remove(findCorpse)
            
            -- Fire MSR_CorpseFound for all deaths (XP essence, etc.)
            MSR.Events.Custom.Fire("MSR_CorpseFound", {
                username = username,
                corpse = corpse,
                x = deathX,
                y = deathY,
                z = deathZ,
                diedInRefuge = diedInRefuge,
                earnedXp = earnedXp
            })
            
            -- Protect corpse only if died in refuge
            if diedInRefuge then
                protectCorpse(corpse, username)
            end
        end
    end

    Events.OnTick.Add(findCorpse)
end

-----------------------------------------------------------
-- Internal: Data Cleanup Handlers
-----------------------------------------------------------

--- Clear player's teleport-related ModData
local function clearPlayerModData(player)
    if not player then return end
    local pmd = player:getModData()
    if not pmd then return end
    
    pmd.spatialRefuge_id = nil
    pmd.spatialRefuge_return = nil
    pmd.spatialRefuge_lastTeleport = nil
    pmd.spatialRefuge_lastDamage = nil
    pmd.spatialRefuge_lastRelicMove = nil
end

--- Handle refuge data cleanup on death
--- Orphans refuge (allows recovery by new character)
local function handleRefugeDataCleanup(args)
    -- Only run with server authority
    if not MSR.Env.hasServerAuthority() then return end
    
    local username = args.username
    local player = args.player
    
    -- Load Data module lazily to avoid circular dependency
    local Data = MSR.Data
    if not Data then
        LOG.debug("MSR.Data not available for cleanup")
        return
    end
    
    -- Always orphan refuge data (allows recovery with new character)
    local refugeData = Data.GetRefugeDataByUsername(username)
    if refugeData then
        Data.MarkRefugeOrphaned(username)
        LOG.debug("Orphaned refuge for %s", username)
    end
    
    -- Clear return position
    if Data.ClearReturnPositionByUsername then
        Data.ClearReturnPositionByUsername(username)
    end
    
    -- Clear player ModData
    clearPlayerModData(player)
end

-----------------------------------------------------------
-- Server-Authoritative Death Handler
-----------------------------------------------------------

--- Main death handler - runs with server authority only
--- Orchestrates all death-related events
local function handlePlayerDeath(player, args, reply)
    if not player then return end
    
    local username = args.username
    local deathX = args.x
    local deathY = args.y
    local deathZ = args.z
    local diedInRefuge = args.diedInRefuge
    local playerOnlineId = args.onlineId
    
    LOG.debug("Processing death for %s at %d,%d,%d (inRefuge=%s)",
        username, deathX, deathY, deathZ, tostring(diedInRefuge))
    
    -- Fire main death event (for data cleanup, logging, etc.)
    -- Note: XP essence is created via MSR_CorpseFound after corpse spawns
    MSR.Events.Custom.Fire("MSR_PlayerDeath", {
        username = username,
        x = deathX,
        y = deathY,
        z = deathZ,
        diedInRefuge = diedInRefuge,
        player = player
    })
    
    -- Handle refuge-specific death
    if diedInRefuge then
        -- Fire event to pause zombie clearing (prevents race condition)
        MSR.Events.Custom.Fire("MSR_PlayerDiedInRefuge", username)
        
        -- Mark corpse owner for finding (copies to corpse)
        if player and player:getModData() then
            player:getModData().MSR_CorpseOwner = username
        end
    end
    
    -- Always search for corpse (for XP essence, etc.)
    -- Pass earnedXp so it can be added to corpse inventory
    startCorpseSearch(deathX, deathY, deathZ, username, playerOnlineId, diedInRefuge, args.earnedXp)
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

-- Register server-authoritative OnPlayerDeath handler
-- This automatically handles SP/Coop/MP client→server forwarding
MSR.Events.Server.On("OnPlayerDeath")
    :withArgs(function(player)
        if not player then return {} end
        
        local username = player:getUsername()
        local x = math.floor(player:getX())
        local y = math.floor(player:getY())
        local z = math.floor(player:getZ())
        
        -- Check if died in refuge (need to do this on client side too for immediate feedback)
        -- Load Data module lazily
        local diedInRefuge = false
        if MSR.Data and MSR.Data.IsPlayerInRefugeCoords then
            diedInRefuge = MSR.Data.IsPlayerInRefugeCoords(player)
        end
        
        -- Get onlineID for MP corpse matching
        local onlineId = nil
        if player.getOnlineID then
            onlineId = player:getOnlineID()
        end
        
        -- Include earned XP from client's ModData
        -- transmitModData() doesn't sync nested tables reliably, so we send XP in event args
        local earnedXp = nil
        local pmd = player:getModData()
        if pmd and pmd.MSR_XPEarnedXp then
            earnedXp = {}
            local xpCount = 0
            local totalXp = 0
            for perkName, amount in pairs(pmd.MSR_XPEarnedXp) do
                earnedXp[perkName] = amount
                xpCount = xpCount + 1
                totalXp = totalXp + (amount or 0)
            end
            LOG.debug("CLIENT sending XP data: xpPerks=%d, totalXp=%.1f", xpCount, totalXp)
        end
        
        return {
            username = username,
            x = x,
            y = y,
            z = z,
            diedInRefuge = diedInRefuge,
            onlineId = onlineId,
            earnedXp = earnedXp
        }
    end)
    :onServer(handlePlayerDeath)
    :register()

-- Subscribe to MSR_PlayerDeath for data cleanup
-- This runs after the main death handler fires the event
MSR.Events.Custom.Add("MSR_PlayerDeath", handleRefugeDataCleanup)

LOG.debug("Death event orchestrator loaded")

return MSR.Death
