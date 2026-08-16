if not ISBaseTimedAction then return end

---@class ISExitRefugeAction : ISBaseTimedAction
ISExitRefugeAction = ISBaseTimedAction:derive("ISExitRefugeAction")

---@return boolean
function ISExitRefugeAction:isValid()
    return self.character ~= nil
end

---@diagnostic disable-next-line: unused -- Timed-action override required by PZ.
function ISExitRefugeAction:update() end

function ISExitRefugeAction:start()
    self:setActionAnim("Loot")
    self:setOverrideHandModels(nil, nil)
end

function ISExitRefugeAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISExitRefugeAction:perform()
    if MSR and MSR.ExitRefuge then
        MSR.ExitRefuge(self.character)
    end
    ISBaseTimedAction.perform(self)
end

function ISExitRefugeAction:new(player, time)
    local o = ISBaseTimedAction.new(self, player)
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = time
    return o
end

return ISExitRefugeAction
