-- Dedicated/server authority for Spatial Well placement and water regeneration.

require "00_core/00_MSR"
require "MSR_SpatialWell"
require "MSR_InventoryAuthority"
require "MSR_Transaction"

local SpatialWellServer = MSR.register("SpatialWellServer")
if not SpatialWellServer then return MSR.SpatialWellServer end

local Config = MSR.Config
local Data = MSR.Data
local InventoryAuthority = MSR.InventoryAuthority
local SpatialWell = MSR.SpatialWell
local Transaction = MSR.Transaction
local LOG = L.logger("SpatialWellServer")

local function sendError(player, transactionId, reason)
    sendServerCommand(player, Config.COMMAND_NAMESPACE, Config.COMMANDS.SPATIAL_WELL_ERROR, {
        transactionId = transactionId,
        reason = reason or MSR.PlayerMessage.SPATIAL_WELL_BUILD_FAILED,
    })
end

local function hasUniqueItemIds(allocation)
    local seen = {}
    for _, itemIds in pairs(allocation) do
        for _, itemId in ipairs(itemIds) do
            if seen[itemId] then return false end
            seen[itemId] = true
        end
    end
    return true
end

local function isWellItemAvailable(item, container)
    if not Transaction.IsItemAvailable(item, container) then return false end
    if SpatialWell.IsSupportedBucketType(item:getFullType()) then
        return SpatialWell.IsEmptyBucket(item)
    end
    return true
end

function SpatialWellServer.HandlePlaceRequest(player, args)
    if not player or type(args) ~= "table" then return end

    local transactionId = args.transactionId
    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z)
    local allocation = args.lockedItemIds
    if type(transactionId) ~= "string" or not x or not y or not z or
            x ~= math.floor(x) or y ~= math.floor(y) or z ~= math.floor(z) then
        sendError(player, transactionId, MSR.PlayerMessage.SPATIAL_WELL_INVALID_LOCATION)
        return
    end

    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, z) or nil
    local refugeData = Data.GetRefugeData(player)
    local canPlace, reason = SpatialWell.CanPlaceAt(player, square, refugeData)
    if not canPlace then
        sendError(player, transactionId, reason)
        return
    end

    local requirements = SpatialWell.GetTransactionRequirements()
    if not SpatialWell.ValidateLockedAllocation(allocation, requirements) or
            not hasUniqueItemIds(allocation) then
        sendError(player, transactionId, MSR.PlayerMessage.SPATIAL_WELL_MISSING_RESOURCES)
        return
    end

    local sources = Transaction.GetItemSources(player, true)
    if not InventoryAuthority.validateAllocation(sources, allocation, isWellItemAvailable) then
        sendError(player, transactionId, MSR.PlayerMessage.SPATIAL_WELL_MISSING_RESOURCES)
        return
    end

    local well, createError = SpatialWell.CreateAt(player, x, y, z)
    if not well then
        sendError(player, transactionId, createError)
        return
    end

    -- Validation immediately precedes consumption; the server command handler is
    -- single-threaded, so these selected IDs cannot change between the two calls.
    local consumed = InventoryAuthority.consumeByIds(sources, allocation, isWellItemAvailable)
    if not consumed then
        SpatialWell.RollbackPlacement(refugeData, well)
        sendError(player, transactionId, MSR.PlayerMessage.SPATIAL_WELL_BUILD_FAILED)
        return
    end

    sendServerCommand(player, Config.COMMAND_NAMESPACE, Config.COMMANDS.SPATIAL_WELL_COMPLETE, {
        transactionId = transactionId,
        refugeData = Data.SerializeRefugeData(refugeData),
        x = x,
        y = y,
        z = z,
    })
    LOG.info("Completed Spatial Well transaction %s for %s",
        transactionId, tostring(player:getUsername()))
end

local function processSpatialWells()
    local registry = Data.GetRefugeRegistry()
    if not registry then return end

    for _, refugeData in pairs(registry) do
        if SpatialWell.IsBuilt(refugeData) then
            SpatialWell.ProcessRefill(refugeData)
        end
    end
end

local function beginRefillSession()
    SpatialWell.BeginRefillSession(Data.GetRefugeRegistry())
    LOG.debug("Started Spatial Well refill session")
end

MSR.Events.OnServerReady.Add(beginRefillSession)

if not MSR._spatialWellRefillEventRegistered and Events.EveryTenMinutes then
    Events.EveryTenMinutes.Add(processSpatialWells)
    MSR._spatialWellRefillEventRegistered = true
    LOG.debug("Registered Spatial Well refill checks")
end

return MSR.SpatialWellServer
