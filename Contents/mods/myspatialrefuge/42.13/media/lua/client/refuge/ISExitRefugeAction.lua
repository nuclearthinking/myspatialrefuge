-- ISExitRefugeAction
-- Timed action for exiting Spatial Refuge (with progress bar)

-- Check if ISBaseTimedAction is available
if not ISBaseTimedAction then
    print("[SpatialRefuge] ERROR: ISBaseTimedAction not available! Cannot create ISExitRefugeAction")
    return
end

-- Create the class
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
    if SpatialRefuge and SpatialRefuge.ExitRefuge then
        SpatialRefuge.ExitRefuge(self.character)
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
