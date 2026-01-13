require "00_core/00_MSR"
require "00_core/04_Env"
require "00_core/06_Data"
require "00_core/07_Events"
require "MSR_UpgradeData"

if MSR and MSR.ReadingSpeed and MSR.ReadingSpeed._loaded then
    return MSR.ReadingSpeed
end

MSR.ReadingSpeed = MSR.ReadingSpeed or {}
MSR.ReadingSpeed._loaded = true
MSR.ReadingSpeed._initialized = false
MSR.ReadingSpeed._originalGetDuration = nil

local ReadingSpeed = MSR.ReadingSpeed

local MIN_READING_MULTIPLIER = 0.1
local MAX_READING_MULTIPLIER = 1.0

local function getReadingSpeedMultiplier(player)
    if not player then 
        return 1.0 
    end
    
    local isInRefuge = MSR.Data.IsPlayerInRefugeCoords(player)
    if not isInRefuge then
        return 1.0
    end
    
    local ok, effects = pcall(MSR.UpgradeData.getPlayerActiveEffects, player)
    if not ok or not effects or not effects.readingSpeedMultiplier then
        return 1.0
    end
    
    local multiplier = effects.readingSpeedMultiplier
    if multiplier < MIN_READING_MULTIPLIER then multiplier = MIN_READING_MULTIPLIER end
    if multiplier > MAX_READING_MULTIPLIER then multiplier = MAX_READING_MULTIPLIER end
    
    return multiplier
end

local function hookReadABook()
    if not ISReadABook then
        return false
    end
    
    if ReadingSpeed._originalGetDuration then
        return true
    end
    
    local originalGetDuration = ISReadABook.getDuration
    if not originalGetDuration then
        return false
    end
    
    ReadingSpeed._originalGetDuration = originalGetDuration
    
    -- MP: duration must match on client AND server (magazines have no page tracking, purely time-based)
    ISReadABook.getDuration = function(self)
        local baseDuration = ReadingSpeed._originalGetDuration(self)
        
        if not baseDuration or baseDuration <= 0 then
            return baseDuration
        end
        
        if not self or not self.character then
            return baseDuration
        end
        
        local multiplier = getReadingSpeedMultiplier(self.character)
        if multiplier >= 1.0 then
            return baseDuration
        end
        
        return baseDuration * multiplier
    end
    
    local side = MSR.Env.isServer() and "SERVER" or "CLIENT"
    L.debug("ReadingSpeed", "Successfully hooked ISReadABook.getDuration on " .. side)
    return true
end

MSR.Events.OnAnyReady.Add(function()
    if ReadingSpeed._initialized then
        return
    end
    
    if not ISReadABook or not ISReadABook.getDuration then
        L.error("ReadingSpeed", "ISReadABook not available - reading speed upgrade will not work")
        return
    end
    
    if hookReadABook() then
        ReadingSpeed._initialized = true
        L.debug("ReadingSpeed", "Initialization complete")
    else
        L.error("ReadingSpeed", "Failed to hook ISReadABook.getDuration")
    end
end)

return MSR.ReadingSpeed
