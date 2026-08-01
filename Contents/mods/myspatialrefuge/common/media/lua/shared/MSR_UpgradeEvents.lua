-- Local upgrade lifecycle events shared by server and singleplayer systems.

require "00_core/00_MSR"

local UpgradeEvents = MSR.register("UpgradeEvents")
if not UpgradeEvents then
    return MSR.UpgradeEvents
end

local LOG = L.logger("UpgradeEvents")
local levelChangedHandlers = {}

UpgradeEvents.OnLevelChanged = {}

--- @param handler function
function UpgradeEvents.OnLevelChanged.Add(handler)
    if type(handler) ~= "function" then return false end
    levelChangedHandlers[#levelChangedHandlers + 1] = handler
    return true
end

--- @param handler function
function UpgradeEvents.OnLevelChanged.Remove(handler)
    for index = #levelChangedHandlers, 1, -1 do
        if levelChangedHandlers[index] == handler then
            table.remove(levelChangedHandlers, index)
            return true
        end
    end
    return false
end

--- Fire after an upgrade level has been persisted locally by the authority.
--- @param player IsoPlayer
--- @param upgradeId string
--- @param previousLevel number
--- @param newLevel number
function UpgradeEvents.OnLevelChanged.Fire(player, upgradeId, previousLevel, newLevel)
    for index = 1, #levelChangedHandlers do
        local ok, err = pcall(levelChangedHandlers[index], player, upgradeId, previousLevel, newLevel)
        if not ok then
            LOG.error("OnLevelChanged handler #%d error: %s", index, tostring(err))
        end
    end
end

return UpgradeEvents
