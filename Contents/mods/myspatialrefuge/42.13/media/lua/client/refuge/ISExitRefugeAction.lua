if not ISBaseTimedAction then
    print("[MSR] ERROR: ISBaseTimedAction not available! Cannot create ISExitRefugeAction")
    return
end

---@class ISExitRefugeAction : ISBaseTimedAction
ISExitRefugeAction = ISBaseTimedAction:derive("ISExitRefugeAction")

function ISExitRefugeAction:isValid()
    -- Just check character exists - the action is only available from relic context menu
    -- which is only accessible inside the refuge, so no need to re-validate location
    return self.character ~= nil
end

function ISExitRefugeAction:update()
    -- No-op: Player channels in place
end

function ISExitRefugeAction:start()
    self:setActionAnim("Loot")
    self:setOverrideHandModels(nil, nil)
end

function ISExitRefugeAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISExitRefugeAction:perform()
    -- Action completed - teleport player back
    if MSR and MSR.ExitRefuge then
        MSR.ExitRefuge(self.character)
    end
    ISBaseTimedAction.perform(self)
end

function ISExitRefugeAction:new(player, time)
    local o = ISBaseTimedAction.new(self, player)
    o.stopOnWalk = true   -- Cancel on movement (so player can interrupt)
    o.stopOnRun = true    -- Cancel on running
    o.maxTime = time      -- Duration in ticks
    return o
end

return ISExitRefugeAction
