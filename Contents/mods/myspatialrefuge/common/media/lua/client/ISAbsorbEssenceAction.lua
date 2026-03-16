-- ISAbsorbEssenceAction - Timed action for absorbing XP essence

if not ISBaseTimedAction then return end

require "TimedActions/ISBaseTimedAction"

---@class ISAbsorbEssenceAction : ISBaseTimedAction
---@field item InventoryItem
ISAbsorbEssenceAction = ISBaseTimedAction:derive("ISAbsorbEssenceAction")

function ISAbsorbEssenceAction:isValidStart()
    return self.item ~= nil
end

function ISAbsorbEssenceAction:isValid()
    if not self.item then return false end
    
    local playerInv = self.character:getInventory()
    if isClient() then
        return playerInv:containsID(self.item:getID())
    else
        return playerInv:contains(self.item)
    end
end

function ISAbsorbEssenceAction:waitToStart()
    if not self.item then return false end
    
    local playerInv = self.character:getInventory()
    local inInventory
    if isClient() then
        inInventory = playerInv:containsID(self.item:getID())
    else
        inInventory = playerInv:contains(self.item)
    end
    
    return not inInventory
end

function ISAbsorbEssenceAction:start()
    self:setActionAnim("Loot")
end

function ISAbsorbEssenceAction:update()
end

function ISAbsorbEssenceAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISAbsorbEssenceAction:perform()
    local playerInv = self.character:getInventory()
    local inInventory
    if isClient() then
        inInventory = self.item and playerInv:containsID(self.item:getID())
    else
        inInventory = self.item and playerInv:contains(self.item)
    end
    
    if inInventory and MSR and MSR.XPRetention and MSR.XPRetention.DoAbsorb then
        MSR.XPRetention.DoAbsorb(self.character, self.item)
    end
    
    ISBaseTimedAction.perform(self)
end

---@param character IsoPlayer
---@param item InventoryItem
---@return ISAbsorbEssenceAction
function ISAbsorbEssenceAction:new(character, item)
    local o = ISBaseTimedAction.new(self, character)
    ---@cast o ISAbsorbEssenceAction
    o.item = item
    o.maxTime = 100
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = false
    return o
end
