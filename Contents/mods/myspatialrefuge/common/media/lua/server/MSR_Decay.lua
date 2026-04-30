require "00_core/00_MSR"

local Decay = MSR.register("Decay")
if not Decay then
    return MSR.Decay
end

MSR.Decay = Decay

local Config = MSR.Config
local Data = MSR.Data
local LOG = L.logger("Decay")

local function getInactiveSeconds(refugeData, now)
    if not refugeData then
        return 0
    end

    local lastActiveTime = refugeData.lastActiveTime or refugeData.createdTime or 0
    return math.max(0, now - lastActiveTime)
end

function Decay.GetInactiveCandidates(minDays)
    local registry = Data.GetRefugeRegistry()
    if not registry then
        return {}
    end

    local now = K.time()
    local effectiveMinDays = tonumber(minDays)
    if not effectiveMinDays then
        effectiveMinDays = Config.getDecayMinDays()
    end
    if effectiveMinDays < 0 then
        effectiveMinDays = 0
    end

    local minSeconds = effectiveMinDays * 86400
    local candidates = {}

    for username, refugeData in pairs(registry) do
        local inactiveSeconds = getInactiveSeconds(refugeData, now)
        if inactiveSeconds >= minSeconds then
            table.insert(candidates, {
                username = username,
                refugeData = refugeData,
                inactiveSeconds = inactiveSeconds,
                inactiveDays = math.floor(inactiveSeconds / 86400),
                slot = Data.GetRefugeSlotFromCoordinates(refugeData.centerX, refugeData.centerY)
            })
        end
    end

    table.sort(candidates, function(a, b)
        if a.inactiveSeconds == b.inactiveSeconds then
            return tostring(a.username) < tostring(b.username)
        end
        return a.inactiveSeconds > b.inactiveSeconds
    end)

    return candidates
end

function Decay.ShouldAttemptReclaimForAllocation()
    if not Config.getDecayEnabled() then
        return false
    end

    local stats = Data.GetRefugeSlotStats()
    if not stats then
        return false
    end

    return stats.usedSlots >= Config.getDecayTriggerSlotCount()
end

function Decay.ReclaimOldestInactiveRefuge()
    if not Config.getDecayEnabled() then
        return nil, nil, nil
    end

    local candidates = Decay.GetInactiveCandidates(Config.getDecayMinDays())
    local victim = candidates[1]
    if not victim then
        return nil, nil, nil
    end

    local success, deletedData = Data.DeleteRefugeDataByUsername(victim.username)
    if not success or not deletedData then
        return nil, nil, nil
    end

    LOG.info("Reclaimed refuge from %s after %d days inactive at %d,%d tier %d",
        victim.username,
        victim.inactiveDays,
        deletedData.centerX or -1,
        deletedData.centerY or -1,
        deletedData.tier or 0)

    return deletedData.centerX, deletedData.centerY, deletedData.centerZ
end

function Decay.PurgeInactiveRefuges(minDays, limit)
    local candidates = Decay.GetInactiveCandidates(minDays)
    local purged = {}
    local maxCount = tonumber(limit)

    for _, candidate in ipairs(candidates) do
        if maxCount and #purged >= maxCount then
            break
        end

        local success, deletedData = Data.DeleteRefugeDataByUsername(candidate.username)
        if success and deletedData then
            table.insert(purged, {
                username = candidate.username,
                refugeData = deletedData,
                inactiveSeconds = candidate.inactiveSeconds,
                inactiveDays = candidate.inactiveDays,
                slot = candidate.slot
            })
        end
    end

    return purged
end

return MSR.Decay
