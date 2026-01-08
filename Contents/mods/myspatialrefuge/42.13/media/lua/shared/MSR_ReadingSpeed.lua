require "shared/00_core/00_MSR"
require "shared/00_core/04_Env"
require "shared/00_core/06_Data"
require "shared/MSR_UpgradeData"

if MSR.ReadingSpeed and MSR.ReadingSpeed._loaded then
    return MSR.ReadingSpeed
end

MSR.ReadingSpeed = MSR.ReadingSpeed or {}
MSR.ReadingSpeed._loaded = true
MSR.ReadingSpeed._initialized = false
MSR.ReadingSpeed._originalGetDuration = nil
MSR.ReadingSpeed._originalServerStart = nil
MSR.ReadingSpeed._originalAnimEvent = nil

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
    
    if not MSR.Env.isServer() then
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
            
            local modifiedDuration = baseDuration * multiplier
            L.debug("ReadingSpeed", string.format("Reading speed: %.1f -> %.1f ticks (%.0f%% faster, multiplier=%.2f)",
                baseDuration, modifiedDuration, (1.0 - multiplier) * 100, multiplier))
            
            return modifiedDuration
        end
    end
    
    if ISReadABook.serverStart and not ReadingSpeed._originalServerStart and MSR.Env.isServer() then
        ReadingSpeed._originalServerStart = ISReadABook.serverStart
        
        ISReadABook.serverStart = function(self)
            if not self.character or not self.maxTime then
                return ReadingSpeed._originalServerStart(self)
            end
            
            local multiplier = getReadingSpeedMultiplier(self.character)
            if multiplier >= 1.0 then
                return ReadingSpeed._originalServerStart(self)
            end
            
            local baseMaxTime = ReadingSpeed._originalGetDuration(self)
            local correctMaxTime = baseMaxTime * multiplier
            
            if math.abs(self.maxTime - correctMaxTime) > 1.0 then
                L.debug("ReadingSpeed", string.format("serverStart: correcting maxTime from %.1f to %.1f (multiplier=%.2f)", 
                    self.maxTime, correctMaxTime, multiplier))
                self.maxTime = correctMaxTime
            end
            
            return ReadingSpeed._originalServerStart(self)
        end
    end
    
    if ISReadABook.animEvent and not ReadingSpeed._originalAnimEvent then
        ReadingSpeed._originalAnimEvent = ISReadABook.animEvent
        
        ISReadABook.animEvent = function(self, event, parameter)
            if event ~= "ReadAPage" or not MSR.Env.isServer() then
                return ReadingSpeed._originalAnimEvent(self, event, parameter)
            end
            
            if not self.character or not self.netAction then
                return ReadingSpeed._originalAnimEvent(self, event, parameter)
            end
            
            local multiplier = getReadingSpeedMultiplier(self.character)
            if multiplier >= 1.0 then
                return ReadingSpeed._originalAnimEvent(self, event, parameter)
            end
            
            if not self.item or self.item:getNumberOfPages() <= 0 or not self.startPage then
                return ReadingSpeed._originalAnimEvent(self, event, parameter)
            end
            
            local netProgress = self.netAction:getProgress()
            local scaledProgress = math.min(netProgress / multiplier, 1.0)
            local pagesRead = math.floor(self.item:getNumberOfPages() * scaledProgress) + self.startPage
            
            self.item:setAlreadyReadPages(pagesRead)
            if self.item:getAlreadyReadPages() > self.item:getNumberOfPages() then
                self.item:setAlreadyReadPages(self.item:getNumberOfPages())
                self.netAction:forceComplete()
            end
            
            self.character:setAlreadyReadPages(self.item:getFullType(), self.item:getAlreadyReadPages())
            syncItemFields(self.character, self.item)
            
            local skillBook = SkillBook[self.item:getSkillTrained()]
            if skillBook then
                local perk = skillBook.perk
                local charLevel = self.character:getPerkLevel(perk)
                
                if self.item:getLvlSkillTrained() > charLevel + 1 or self.character:hasTrait(CharacterTrait.ILLITERATE) then
                    self.character:setAlreadyReadPages(self.item:getFullType(), 0)
                    self.item:setAlreadyReadPages(0)
                    syncItemFields(self.character, self.item)
                    self.netAction:forceComplete()
                    return
                elseif self.item:getMaxLevelTrained() >= charLevel + 1 then
                    ISReadABook.checkMultiplier(self)
                end
            end
        end
    end
    
    -- Note: No update() hook needed - serverStart() already corrects maxTime mismatches
    
    local side = MSR.Env.isServer() and "SERVER" or "CLIENT"
    if MSR.Env.isServer() then
        L.debug("ReadingSpeed", "Successfully hooked ISReadABook.serverStart/animEvent/update on " .. side)
    else
        L.debug("ReadingSpeed", "Successfully hooked ISReadABook.getDuration on " .. side)
    end
    return true
end

local function initialize()
    if ReadingSpeed._initialized then
        return true
    end
    
    local success = hookReadABook()
    if success then
        ReadingSpeed._initialized = true
        L.debug("ReadingSpeed", "Initialization complete")
        return true
    else
        L.debug("ReadingSpeed", "Initialization failed - will retry")
        return false
    end
end

-- Retry initialization periodically if initial attempt failed
local function retryInitialize()
    if ReadingSpeed._initialized then return end
    initialize()
end

-- Try immediate initialization on module load
if ISReadABook and ISReadABook.getDuration then
    local success = hookReadABook()
    if success then
        ReadingSpeed._initialized = true
        local side = MSR.Env.isServer() and "SERVER" or "CLIENT"
        L.debug("ReadingSpeed", "Immediate hook successful on " .. side)
    end
end

-- If not initialized, try on game start and periodically retry
if not ReadingSpeed._initialized then
    if Events.OnGameStart then
        Events.OnGameStart.Add(initialize)
    end
    -- Retry every minute until successful (ISReadABook may load late)
    if Events.EveryOneMinute then
        Events.EveryOneMinute.Add(retryInitialize)
    end
end

local side = MSR.Env.isServer() and "SERVER" or "CLIENT"
L.debug("ReadingSpeed", "Module loaded on " .. side .. " (initialized=" .. tostring(ReadingSpeed._initialized) .. ")")

return MSR.ReadingSpeed
