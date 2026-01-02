if not ISBaseTimedAction then
    print("[MSR] ERROR: ISBaseTimedAction not available! Cannot create ISEnterRefugeAction")
    return
end

---@class ISEnterRefugeAction : ISBaseTimedAction
ISEnterRefugeAction = ISBaseTimedAction:derive("ISEnterRefugeAction")

function ISEnterRefugeAction:isValid()
    -- Use self.character - standard PZ convention (set by ISBaseTimedAction.new)
    if not self.character then return false end
    
    -- Don't allow entering if already in refuge
    if MSR and MSR.IsPlayerInRefuge then
        if MSR.IsPlayerInRefuge(self.character) then
            return false
        end
    end
    
    return true
end

function ISEnterRefugeAction:update()
    -- No-op: Player channels in place
end

function ISEnterRefugeAction:start()
    -- Set animation (praying/meditating pose)
    self:setActionAnim("Loot")
    self:setOverrideHandModels(nil, nil)
end

function ISEnterRefugeAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISEnterRefugeAction:perform()
    ISBaseTimedAction.perform(self)
    
    if MSR and MSR.EnterRefuge then
        MSR.EnterRefuge(self.character)
    end
end

function ISEnterRefugeAction:new(player, time)
    local o = ISBaseTimedAction.new(self, player)
    o.stopOnWalk = true  -- Interrupt on movement
    o.stopOnRun = true   -- Interrupt on running
    o.maxTime = time     -- Duration in ticks (180 = 3 seconds)
    return o
end

return ISEnterRefugeAction

