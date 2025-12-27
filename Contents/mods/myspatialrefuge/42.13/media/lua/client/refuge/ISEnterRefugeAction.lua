-- ISEnterRefugeAction
-- Timed action for entering Spatial Refuge (with progress bar)

-- Check if ISBaseTimedAction is available
if not ISBaseTimedAction then
    print("[SpatialRefuge] ERROR: ISBaseTimedAction not available! Cannot create ISEnterRefugeAction")
    return
end

-- Create the class
ISEnterRefugeAction = ISBaseTimedAction:derive("ISEnterRefugeAction")

function ISEnterRefugeAction:isValid()
    -- Use self.character - standard PZ convention (set by ISBaseTimedAction.new)
    if not self.character then return false end
    
    -- Don't allow entering if already in refuge
    if SpatialRefuge and SpatialRefuge.IsPlayerInRefuge then
        if SpatialRefuge.IsPlayerInRefuge(self.character) then
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
    
    if SpatialRefuge and SpatialRefuge.EnterRefuge then
        SpatialRefuge.EnterRefuge(self.character)
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

