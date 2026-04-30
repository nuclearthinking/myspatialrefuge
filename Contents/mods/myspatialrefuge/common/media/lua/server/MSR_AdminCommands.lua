-- MSR_AdminCommands - Server Admin Debug Functions
-- Provides functions for refuge management, recovery, and decay cleanup.

require "00_core/00_MSR"
require "MSR_Decay"

local Config = MSR.Config
local Data = MSR.Data
local Decay = MSR.Decay

-----------------------------------------------------------
-- Helpers
-----------------------------------------------------------

local function newLines()
    return {}
end

local function addLine(lines, text)
    table.insert(lines, text)
end

local function printLines(fn, ...)
    local lines = fn(...)
    if not lines then
        return nil
    end

    for _, line in ipairs(lines) do
        print(line)
    end

    return lines
end

local function resolvePlayer(playerOverride)
    if playerOverride then
        return playerOverride
    end

    if getPlayer then
        return getPlayer()
    end

    return nil
end

local function getMaxSlot()
    return Config.getRefugeSlotCount() - 1
end

local function getSlotRangeText()
    return "0-" .. tostring(getMaxSlot())
end

local function getSlotFromCoords(x, y)
    return Data.GetRefugeSlotFromCoordinates(x, y)
end

local function getCoordsForSlot(slot)
    return Data.GetRefugeCoordinatesForSlot(slot)
end

local function getInactiveDays(refugeData)
    if not refugeData then
        return 0
    end

    local lastActiveTime = refugeData.lastActiveTime or refugeData.createdTime or 0
    return math.floor(math.max(0, K.time() - lastActiveTime) / 86400)
end

local function parseDays(days, defaultValue)
    local value = tonumber(days)
    if not value then
        value = defaultValue
    end

    value = math.floor(value or 0)
    if value < 0 then
        value = 0
    end

    return value
end

local function isExecuteFlag(value)
    return value == true or value == "true" or value == 1 or value == "1"
end

local function findRelicAt(x, y, z, searchRadius)
    local cell = getCell()
    if not cell then return nil end

    searchRadius = searchRadius or 5
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            if square then
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj and obj.getModData then
                            local md = obj:getModData()
                            if md and md.isSacredRelic then
                                return obj, md, x + dx, y + dy
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

local function measureRefugeRadius(centerX, centerY, centerZ)
    local cell = getCell()
    if not cell then return nil end

    for dist = 1, 15 do
        local square = cell:getGridSquare(centerX + dist, centerY, centerZ)
        if square then
            local objects = square:getObjects()
            if objects then
                for i = 0, objects:size() - 1 do
                    local obj = objects:get(i)
                    if obj and obj.getModData then
                        local md = obj:getModData()
                        if md and md.isRefugeBoundary then
                            return dist - 1
                        end
                    end
                end
            end
        end
    end

    return nil
end

local function tierFromRadius(radius)
    for tier, data in pairs(Config.TIERS) do
        if data.radius == radius then
            return tier
        end
    end

    return nil
end

-----------------------------------------------------------
-- Command Handlers
-----------------------------------------------------------

local function cmdList()
    local lines = newLines()
    local registry = Data.GetRefugeRegistry()
    if not registry then
        addLine(lines, "[MSR] Error: Registry not available")
        return lines
    end

    local count = 0
    addLine(lines, "[MSR] === Refuge Registry ===")
    for username, refugeData in pairs(registry) do
        count = count + 1
        local slot = getSlotFromCoords(refugeData.centerX, refugeData.centerY)
        local upgrades = refugeData.upgrades and K.count(refugeData.upgrades) or 0
        local inactiveDays = getInactiveDays(refugeData)
        addLine(lines, "  " .. username ..
            ": slot=" .. tostring(slot) ..
            " coords=" .. refugeData.centerX .. "," .. refugeData.centerY ..
            " tier=" .. tostring(refugeData.tier or 0) ..
            " upgrades=" .. tostring(upgrades) ..
            " inactiveDays=" .. tostring(inactiveDays))
    end
    addLine(lines, "[MSR] Total: " .. count .. " refuges")
    return lines
end

local function cmdInfo(username)
    local lines = newLines()
    if not username or username == "" then
        addLine(lines, "[MSR] Usage: /msr info <username> or msrInfo(\"username\")")
        return lines
    end

    local refugeData = Data.GetRefugeDataByUsername(username)
    if not refugeData then
        addLine(lines, "[MSR] No refuge found for: " .. username)
        return lines
    end

    addLine(lines, "[MSR] === Refuge: " .. username .. " ===")
    addLine(lines, "  refugeId: " .. tostring(refugeData.refugeId))
    addLine(lines, "  slot: " .. tostring(getSlotFromCoords(refugeData.centerX, refugeData.centerY)))
    addLine(lines, "  coords: " .. refugeData.centerX .. "," .. refugeData.centerY .. "," .. (refugeData.centerZ or 0))
    addLine(lines, "  tier: " .. tostring(refugeData.tier))
    addLine(lines, "  radius: " .. tostring(refugeData.radius))
    addLine(lines, "  relic: " .. (refugeData.relicX or refugeData.centerX) .. "," .. (refugeData.relicY or refugeData.centerY))
    addLine(lines, "  dataVersion: " .. tostring(refugeData.dataVersion))
    addLine(lines, "  createdTime: " .. tostring(refugeData.createdTime))
    addLine(lines, "  lastActiveTime: " .. tostring(refugeData.lastActiveTime))
    addLine(lines, "  inactiveDays: " .. tostring(getInactiveDays(refugeData)))

    if refugeData.upgrades then
        addLine(lines, "  upgrades:")
        for name, level in pairs(refugeData.upgrades) do
            addLine(lines, "    " .. name .. ": " .. level)
        end
    end

    if refugeData.inheritedFrom then
        addLine(lines, "  inheritedFrom: " .. refugeData.inheritedFrom)
    end

    return lines
end

local function cmdDelete(username)
    local lines = newLines()
    if not username or username == "" then
        addLine(lines, "[MSR] Usage: /msr delete <username> or msrDelete(\"username\")")
        return lines
    end

    local success, existing = Data.DeleteRefugeDataByUsername(username)
    if not success or not existing then
        addLine(lines, "[MSR] No refuge found for: " .. username)
        return lines
    end

    addLine(lines, "[MSR] Deleted refuge for: " .. username)
    addLine(lines, "[MSR]   Was at: " .. existing.centerX .. "," .. existing.centerY .. " tier " .. tostring(existing.tier))
    addLine(lines, "[MSR]   Return position cleared")
    return lines
end

local function cmdGoto(slotNum, playerOverride)
    local lines = newLines()
    local player = resolvePlayer(playerOverride)
    if not player then
        addLine(lines, "[MSR] Error: No player found.")
        return lines
    end

    local username = player:getUsername()
    if not username then
        addLine(lines, "[MSR] Error: Could not get player username")
        return lines
    end

    local slot = tonumber(slotNum) or 0
    local x, y = getCoordsForSlot(slot)
    if not x or not y then
        addLine(lines, "[MSR] Error: Invalid slot. Valid range is " .. getSlotRangeText())
        return lines
    end

    local returnX = player:getX()
    local returnY = player:getY()
    local returnZ = player:getZ()

    Data.SaveReturnPositionByUsername(username, returnX, returnY, returnZ)

    player:teleportTo(x, y, 0)
    K.safeCall(player, "setLastX", x)
    K.safeCall(player, "setLastY", y)
    K.safeCall(player, "setLastZ", 0)

    addLine(lines, "[MSR] Teleported to refuge slot " .. slot .. " (" .. x .. "," .. y .. ")")
    addLine(lines, "[MSR] Return position saved: " .. math.floor(returnX) .. "," .. math.floor(returnY) .. "," .. math.floor(returnZ))
    addLine(lines, "[MSR] Wait a few seconds for chunk to load, then run /msr scan or msrScan()")
    return lines
end

local function cmdScan(slotNum, playerOverride)
    local lines = newLines()
    local player = resolvePlayer(playerOverride)
    local slot = tonumber(slotNum) or 0
    local centerX, centerY, centerZ = getCoordsForSlot(slot)
    if not centerX or not centerY then
        addLine(lines, "[MSR] Error: Invalid slot. Valid range is " .. getSlotRangeText())
        return lines
    end
    centerZ = centerZ or 0

    addLine(lines, "[MSR] === Scanning Refuge Slot " .. slot .. " ===")
    addLine(lines, "[MSR] Location: " .. centerX .. "," .. centerY)

    local cell = getCell()
    if not cell then
        addLine(lines, "[MSR] ERROR: Cell not available. Load the game first.")
        return lines
    end

    local square = cell:getGridSquare(centerX, centerY, centerZ)
    if not square then
        addLine(lines, "[MSR] WARNING: Chunk not loaded. Teleport to " .. centerX .. "," .. centerY .. " first.")
        addLine(lines, "[MSR] Use: /goto " .. centerX .. " " .. centerY .. " 0")
        return lines
    end

    local relic, relicMd, relicX, relicY = findRelicAt(centerX, centerY, centerZ, 5)
    if not relic then
        addLine(lines, "[MSR] No relic found at this location.")
        addLine(lines, "[MSR] This refuge slot may be empty or never used.")
        return lines
    end

    local refugeId = relicMd and relicMd.refugeId or nil
    addLine(lines, "[MSR] RELIC FOUND at " .. relicX .. "," .. relicY)
    addLine(lines, "[MSR]   refugeId: " .. tostring(refugeId))

    local username = nil
    if refugeId and type(refugeId) == "string" then
        username = refugeId:gsub("^refuge_", "")
    end
    addLine(lines, "[MSR]   Owner (from refugeId): " .. tostring(username))

    if player and player.getUsername then
        addLine(lines, "[MSR]   Requested by: " .. tostring(player:getUsername()))
    end

    local radius = measureRefugeRadius(centerX, centerY, centerZ)
    local tier = nil
    if radius then
        tier = tierFromRadius(radius)
        addLine(lines, "[MSR]   Detected radius: " .. radius .. " (tier " .. tostring(tier) .. ")")
    else
        addLine(lines, "[MSR]   Could not detect radius (walls not loaded or missing)")
    end

    local registered = username and Data.GetRefugeDataByUsername(username)
    if registered then
        addLine(lines, "[MSR]   Registry: REGISTERED at " .. registered.centerX .. "," .. registered.centerY)
    else
        addLine(lines, "[MSR]   Registry: NOT REGISTERED")
    end

    return lines
end

local function cmdStats()
    local lines = newLines()
    local stats = Data.GetRefugeSlotStats()
    local triggerSlots = Config.getDecayTriggerSlotCount()
    local inactiveDays = Config.getDecayMinDays()
    local usagePercent = 0
    if stats.totalSlots > 0 then
        usagePercent = math.floor((stats.usedSlots / stats.totalSlots) * 100 + 0.5)
    end

    local reclaimable = Decay.GetInactiveCandidates(inactiveDays)
    local oldest = Decay.GetInactiveCandidates(0)[1]

    addLine(lines, "[MSR] === Refuge Slot Stats ===")
    addLine(lines, "[MSR] Slots: used=" .. stats.usedSlots .. " free=" .. stats.freeSlots .. " total=" .. stats.totalSlots)
    addLine(lines, "[MSR] Usage: " .. usagePercent .. "%")
    addLine(lines, "[MSR] Decay enabled: " .. tostring(Config.getDecayEnabled()))
    addLine(lines, "[MSR] Decay trigger: " .. triggerSlots .. " used slots (" .. Config.getDecayTriggerPercent() .. "%)")
    addLine(lines, "[MSR] Reclaim threshold: inactive >= " .. inactiveDays .. " days")
    addLine(lines, "[MSR] Reclaimable now: " .. tostring(#reclaimable))
    if oldest then
        addLine(lines, "[MSR] Oldest inactive: " .. tostring(oldest.username) ..
            " slot=" .. tostring(oldest.slot) ..
            " days=" .. tostring(oldest.inactiveDays))
    end
    return lines
end

local function cmdInactive(days)
    local lines = newLines()
    local minDays = parseDays(days, Config.getDecayMinDays())
    local candidates = Decay.GetInactiveCandidates(minDays)

    addLine(lines, "[MSR] === Inactive Refuges (" .. minDays .. "+ days) ===")
    if #candidates == 0 then
        addLine(lines, "[MSR] No inactive refuges match the filter.")
        return lines
    end

    for _, candidate in ipairs(candidates) do
        local refugeData = candidate.refugeData
        addLine(lines, "  " .. candidate.username ..
            ": slot=" .. tostring(candidate.slot) ..
            " coords=" .. refugeData.centerX .. "," .. refugeData.centerY ..
            " tier=" .. tostring(refugeData.tier or 0) ..
            " inactiveDays=" .. tostring(candidate.inactiveDays))
    end
    addLine(lines, "[MSR] Total matching refuges: " .. tostring(#candidates))
    return lines
end

local function cmdPurge(days, executeNow)
    local lines = newLines()
    local minDays = parseDays(days, Config.getDecayMinDays())
    local candidates = Decay.GetInactiveCandidates(minDays)

    if #candidates == 0 then
        addLine(lines, "[MSR] No refuges inactive for " .. minDays .. "+ days.")
        return lines
    end

    if not isExecuteFlag(executeNow) then
        addLine(lines, "[MSR] Purge dry-run (" .. minDays .. "+ days): " .. tostring(#candidates) .. " refuges would be removed.")
        for _, candidate in ipairs(candidates) do
            addLine(lines, "  " .. candidate.username ..
                ": slot=" .. tostring(candidate.slot) ..
                " inactiveDays=" .. tostring(candidate.inactiveDays))
        end
        addLine(lines, "[MSR] Run /msr purge " .. minDays .. " confirm or msrPurge(" .. minDays .. ", true) to execute.")
        return lines
    end

    local purged = Decay.PurgeInactiveRefuges(minDays)
    addLine(lines, "[MSR] Purged " .. tostring(#purged) .. " refuges inactive for " .. minDays .. "+ days.")
    for _, candidate in ipairs(purged) do
        addLine(lines, "  " .. candidate.username ..
            ": slot=" .. tostring(candidate.slot) ..
            " inactiveDays=" .. tostring(candidate.inactiveDays))
    end
    return lines
end

local function cmdHelp()
    local lines = newLines()
    addLine(lines, "[MSR] === My Spatial Refuge Admin Commands ===")
    addLine(lines, "[MSR]")
    addLine(lines, "[MSR] MULTIPLAYER SLASH COMMANDS:")
    addLine(lines, "[MSR]   /msr help")
    addLine(lines, "[MSR]   /msr stats")
    addLine(lines, "[MSR]   /msr list")
    addLine(lines, "[MSR]   /msr info <username>")
    addLine(lines, "[MSR]   /msr inactive [days]")
    addLine(lines, "[MSR]   /msr purge <days>")
    addLine(lines, "[MSR]   /msr purge <days> confirm")
    addLine(lines, "[MSR]   /msr delete <username>")
    addLine(lines, "[MSR]   /msr goto [slot]")
    addLine(lines, "[MSR]   /msr scan [slot]")
    addLine(lines, "[MSR]")
    addLine(lines, "[MSR] DEBUG CONSOLE:")
    addLine(lines, "[MSR]   msrGoto()           - Teleport to slot 0 (" .. Config.REFUGE_BASE_X .. "," .. Config.REFUGE_BASE_Y .. ")")
    addLine(lines, "[MSR]   msrGoto(slot)       - Teleport to specific slot (" .. getSlotRangeText() .. ")")
    addLine(lines, "[MSR]   msrScan()           - Scan slot 0, show info")
    addLine(lines, "[MSR]   msrScan(slot)       - Scan specific slot (" .. getSlotRangeText() .. ")")
    addLine(lines, "[MSR]   msrStats()          - Show slot usage and reclaim stats")
    addLine(lines, "[MSR]   msrInactive(days)   - List refuges inactive for N+ days")
    addLine(lines, "[MSR]   msrPurge(days)      - Dry-run purge of inactive refuges")
    addLine(lines, "[MSR]   msrPurge(days, true)- Execute purge of inactive refuges")
    addLine(lines, "[MSR]   msrList()                       - List all refuges")
    addLine(lines, "[MSR]   msrInfo(\"username\")             - Show refuge details")
    addLine(lines, "[MSR]   msrDelete(\"username\")           - Delete refuge entry")
    addLine(lines, "[MSR]   MSR.Admin.help()                 - Print this help in console")
    return lines
end

-----------------------------------------------------------
-- Global API Registration
-----------------------------------------------------------

MSR.Admin = MSR.Admin or {}
MSR.Admin.Commands = MSR.Admin.Commands or {}
MSR.Admin.Commands.list = cmdList
MSR.Admin.Commands.info = cmdInfo
MSR.Admin.Commands.delete = cmdDelete
MSR.Admin.Commands.scan = cmdScan
MSR.Admin.Commands.goto = cmdGoto
MSR.Admin.Commands.stats = cmdStats
MSR.Admin.Commands.inactive = cmdInactive
MSR.Admin.Commands.purge = cmdPurge
MSR.Admin.Commands.help = cmdHelp
MSR.Admin.list = function(...)
    return printLines(cmdList, ...)
end
MSR.Admin.info = function(...)
    return printLines(cmdInfo, ...)
end
MSR.Admin.delete = function(...)
    return printLines(cmdDelete, ...)
end
MSR.Admin.scan = function(...)
    return printLines(cmdScan, ...)
end
MSR.Admin.goto = function(...)
    return printLines(cmdGoto, ...)
end
MSR.Admin.stats = function(...)
    return printLines(cmdStats, ...)
end
MSR.Admin.inactive = function(...)
    return printLines(cmdInactive, ...)
end
MSR.Admin.purge = function(...)
    return printLines(cmdPurge, ...)
end
MSR.Admin.help = function(...)
    return printLines(cmdHelp, ...)
end
MSR.Admin.assign = nil
MSR.Admin.assignHere = nil
MSR.Admin.coords = nil

_G.msrList = function(...)
    return printLines(cmdList, ...)
end
_G.msrInfo = function(...)
    return printLines(cmdInfo, ...)
end
_G.msrDelete = function(...)
    return printLines(cmdDelete, ...)
end
_G.msrScan = function(...)
    return printLines(cmdScan, ...)
end
_G.msrGoto = function(...)
    return printLines(cmdGoto, ...)
end
_G.msrStats = function(...)
    return printLines(cmdStats, ...)
end
_G.msrInactive = function(...)
    return printLines(cmdInactive, ...)
end
_G.msrPurge = function(...)
    return printLines(cmdPurge, ...)
end
_G.msrHelp = function(...)
    return printLines(cmdHelp, ...)
end

_G.msrAssign = nil
_G.msrAssignHere = nil
_G.msrCoords = nil

print("[MSR] Admin functions loaded. Use MSR.Admin.help() or msrHelp() from debug console.")
