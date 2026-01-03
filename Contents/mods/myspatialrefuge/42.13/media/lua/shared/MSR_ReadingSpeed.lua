-- MSR_ReadingSpeed - Reading Speed Hook (Shared - Client & Server)
-- Modifies reading action time when player is in refuge with faster_reading upgrade
-- Must be in shared/ to work in multiplayer (ISReadABook runs on both sides)
--
-- IMPORTANT: We hook getDuration() instead of modifying maxTime after-the-fact.
-- This ensures both client AND server use the same reduced duration, including
-- the server's page reading schedule in serverStart().

require "shared/MSR"
require "shared/MSR_Data"
require "shared/MSR_UpgradeData"

-- Prevent double-loading
if MSR.ReadingSpeed and MSR.ReadingSpeed._loaded then
    return MSR.ReadingSpeed
end

MSR.ReadingSpeed = MSR.ReadingSpeed or {}
MSR.ReadingSpeed._loaded = true
MSR.ReadingSpeed._initialized = false
MSR.ReadingSpeed._originalGetDuration = nil

-- Local alias
local ReadingSpeed = MSR.ReadingSpeed

-----------------------------------------------------------
-- Reading Speed Calculation
-----------------------------------------------------------

-- Constants for reading speed bounds
local MIN_READING_MULTIPLIER = 0.1
local MAX_READING_MULTIPLIER = 1.0

-- Get reading speed multiplier for player based on upgrade level
-- Returns 1.0 if no upgrade or not in refuge
local function getReadingSpeedMultiplier(player)
    if not player then return 1.0 end
    
    -- Check if player is in refuge
    if not MSR.Data or not MSR.Data.IsPlayerInRefugeCoords then
        return 1.0
    end
    
    local isInRefuge = MSR.Data.IsPlayerInRefugeCoords(player)
    if not isInRefuge then
        return 1.0
    end
    
    -- Get active effects from upgrades
    if not MSR.UpgradeData or not MSR.UpgradeData.getPlayerActiveEffects then
        return 1.0
    end
    
    local effects = MSR.UpgradeData.getPlayerActiveEffects(player)
    if not effects or not effects.readingSpeedMultiplier then
        return 1.0
    end
    
    -- Return the multiplier (lower = faster reading)
    -- Clamp to prevent negative or zero time
    local multiplier = effects.readingSpeedMultiplier
    if multiplier < MIN_READING_MULTIPLIER then multiplier = MIN_READING_MULTIPLIER end
    if multiplier > MAX_READING_MULTIPLIER then multiplier = MAX_READING_MULTIPLIER end
    
    return multiplier
end

-----------------------------------------------------------
-- Hook ISReadABook:getDuration()
-- This is called during new() to calculate maxTime.
-- By hooking here, we affect the duration BEFORE it's set,
-- which ensures both client and server use the same timing.
-- The server uses maxTime in serverStart() to schedule page reads.
-----------------------------------------------------------

local function hookReadABook()
    -- Wait for ISReadABook to exist
    if not ISReadABook then
        return false
    end
    
    if ReadingSpeed._originalGetDuration then
        return true -- Already hooked
    end
    
    local originalGetDuration = ISReadABook.getDuration
    if not originalGetDuration then
        return false
    end
    
    ReadingSpeed._originalGetDuration = originalGetDuration
    
    -- Hook getDuration() - signature is: getDuration(self)
    -- self = the action being created
    -- self.character = the player
    ISReadABook.getDuration = function(self)
        -- Call original to get base duration
        local baseDuration = ReadingSpeed._originalGetDuration(self)
        
        if not baseDuration or baseDuration <= 0 then
            return baseDuration
        end
        
        -- Get speed multiplier based on player's refuge upgrades
        local multiplier = getReadingSpeedMultiplier(self.character)
        
        if multiplier < 1.0 then
            local modifiedDuration = baseDuration * multiplier
            
            -- Debug logging only when enabled
            if L.isDebug() then
                local side = isServer() and "SERVER" or "CLIENT"
                local itemName = self.item and self.item.getName and self.item:getName() or "unknown"
                L.debug("ReadingSpeed", string.format("%s on %s: %.1f -> %.1f ticks (%.0f%% faster)",
                    itemName, side, baseDuration, modifiedDuration, (1.0 - multiplier) * 100))
            end
            
            return modifiedDuration
        end
        
        return baseDuration
    end
    
    L.debug("ReadingSpeed", "Hooked ISReadABook.getDuration on " .. (isServer() and "SERVER" or "CLIENT"))
    return true
end

-----------------------------------------------------------
-- Initialization
-----------------------------------------------------------

local function initialize()
    if ReadingSpeed._initialized then
        return
    end
    
    local success = hookReadABook()
    if success then
        ReadingSpeed._initialized = true
    end
end

local function scheduleInitialize()
    if ReadingSpeed._initialized then
        return
    end
    
    local tickCount = 0
    local maxTicks = 600 -- ~10 seconds
    
    local function tickInit()
        tickCount = tickCount + 1
        
        if not ReadingSpeed._initialized then
            initialize()
        end
        
        if ReadingSpeed._initialized or tickCount >= maxTicks then
            Events.OnTick.Remove(tickInit)
        end
    end
    
    Events.OnTick.Add(tickInit)
end

-- Initialize on game start (works on both client and server)
Events.OnGameStart.Add(function()
    scheduleInitialize()
end)

-- For dedicated servers, also listen to OnServerStarted
if Events.OnServerStarted then
    Events.OnServerStarted.Add(function()
        scheduleInitialize()
    end)
end

L.debug("ReadingSpeed", "Module loaded on " .. (isServer() and "SERVER" or "CLIENT"))

return MSR.ReadingSpeed
