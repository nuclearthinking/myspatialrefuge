if not ISBaseTimedAction then return end

---@class ISEnterRefugeAction : ISBaseTimedAction
ISEnterRefugeAction = ISBaseTimedAction:derive("ISEnterRefugeAction")

function ISEnterRefugeAction:isValid()
    if not self.character then return false end
    if MSR and MSR.IsPlayerInRefuge and MSR.IsPlayerInRefuge(self.character) then
        return false
    end
    return true
end

function ISEnterRefugeAction:update() end

function ISEnterRefugeAction:start()
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
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = time
    return o
end

return ISEnterRefugeAction
