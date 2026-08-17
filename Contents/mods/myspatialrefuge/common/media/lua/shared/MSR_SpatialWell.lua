-- Spatial Well domain logic shared by singleplayer, client placement, and server authority.

require "00_core/00_MSR"
require "helpers/World"
require "MSR_RefugeGeometry"
require "MSR_PlayerMessage"
require "MSR_Transaction"
require "MSR_InventoryAuthority"
require "MSR_Echo"

local SpatialWell = MSR.register("SpatialWell")
if not SpatialWell then return MSR.SpatialWell end

local Config = MSR.Config
local Data = MSR.Data
local Env = MSR.Env
local PM = MSR.PlayerMessage
local Transaction = MSR.Transaction
local World = MSR.World
local LOG = L.logger("SpatialWell")

SpatialWell.TRANSACTION_TYPE = "SPATIAL_WELL_BUILD"

local EMPTY_BUCKET_TYPE = Config.SPATIAL_WELL.EMPTY_BUCKET_TYPE or "Base.BucketEmpty"
local refillLastProcessedHours = {}

function SpatialWell.GetLastMoveTime(player)
    if not player then return 0 end
    local playerData = player:getModData()
    return playerData.spatialRefuge_lastWellMove or 0
end

function SpatialWell.GetMoveCooldownRemaining(player)
    local lastMove = SpatialWell.GetLastMoveTime(player)
    if lastMove <= 0 then return 0 end

    local cooldown = Config.SPATIAL_WELL_MOVE_COOLDOWN or 30
    return math.max(0, cooldown - (K.time() - lastMove))
end

function SpatialWell.UpdateMoveTime(player)
    if not player then return end
    local playerData = player:getModData()
    playerData.spatialRefuge_lastWellMove = K.time()
end

local function getBucketTypes()
    return Config.SPATIAL_WELL.BUCKET_TYPES or { EMPTY_BUCKET_TYPE }
end

local function getWorldAgeHours()
    local gameTime = getGameTime and getGameTime()
    if not gameTime or not gameTime.getWorldAgeHours then return 0 end
    return tonumber(gameTime:getWorldAgeHours()) or 0
end

local function getRefillTrackingKey(refugeData)
    if not refugeData then return nil end
    return refugeData.refugeId or refugeData.username
end

local function startTrackingRefill(refugeData, worldAgeHours)
    local key = getRefillTrackingKey(refugeData)
    if not key then return false end
    refillLastProcessedHours[key] = worldAgeHours or getWorldAgeHours()
    return true
end

function SpatialWell.IsSupportedBucketType(itemType)
    if not itemType then return false end
    for _, supportedType in ipairs(getBucketTypes()) do
        if itemType == supportedType then return true end
    end
    return false
end

function SpatialWell.IsEmptyBucket(item)
    if not item or not SpatialWell.IsSupportedBucketType(item:getFullType()) then return false end
    ---@type FluidContainer?
    local fluidContainer = item.getFluidContainer and item:getFluidContainer() or nil
    return fluidContainer ~= nil and fluidContainer:getAmount() <= 0.0001
end

function SpatialWell.CountEmptyBuckets(player)
    if not player then return 0 end
    local count = 0
    for _, itemType in ipairs(getBucketTypes()) do
        count = count + Transaction.GetMultiSourceCount(player, itemType, true, SpatialWell.IsEmptyBucket)
    end
    return count
end

local function getCustomizationTable(refugeData, create)
    if not refugeData then return nil end
    if not refugeData.customizations and create then
        refugeData.customizations = {}
    end
    return refugeData.customizations
end

function SpatialWell.GetRequirements()
    local requirements = {}
    local configuredCost = Config.SPATIAL_WELL and Config.SPATIAL_WELL.COST or {}
    for itemType, count in pairs(configuredCost) do
        requirements[itemType] = D.material(count)
    end
    return requirements
end

function SpatialWell.GetEchoCost()
    local baseCost = math.floor(tonumber(Config.SPATIAL_WELL.ECHO_COST) or 0)
    if baseCost <= 0 then return 0 end
    return math.max(1, math.ceil(baseCost * MSR.GetDifficultyMultiplier("coreCost")))
end

function SpatialWell.GetTransactionRequirements()
    local scaledCost = SpatialWell.GetRequirements()
    local requirements = {}

    for itemType, count in pairs(scaledCost) do
        if itemType ~= EMPTY_BUCKET_TYPE then
            table.insert(requirements, { type = itemType, count = count })
        end
    end

    local substitutes = {}
    for _, itemType in ipairs(getBucketTypes()) do
        if itemType ~= EMPTY_BUCKET_TYPE then table.insert(substitutes, itemType) end
    end
    table.insert(requirements, {
        type = EMPTY_BUCKET_TYPE,
        count = scaledCost[EMPTY_BUCKET_TYPE] or 1,
        substitutes = substitutes,
        predicate = SpatialWell.IsEmptyBucket,
    })

    return requirements
end

function SpatialWell.GetState(refugeData)
    local customizations = getCustomizationTable(refugeData, false)
    return customizations and customizations.spatialWell or nil
end

function SpatialWell.IsBuilt(refugeData)
    local state = SpatialWell.GetState(refugeData)
    return state ~= nil and state.placed == true and state.x ~= nil and state.y ~= nil
end

function SpatialWell.IsObjectForRefuge(well, refugeData)
    if not well or not refugeData or not well.getModData then return false end
    local md = well:getModData()
    return md ~= nil and md.isSpatialWell == true and md.refugeId == refugeData.refugeId
end

function SpatialWell.BeginRefillSession(registry)
    refillLastProcessedHours = {}
    local now = getWorldAgeHours()

    for _, refugeData in pairs(registry or {}) do
        if SpatialWell.IsBuilt(refugeData) then
            startTrackingRefill(refugeData, now)
        end
    end
end

function SpatialWell.ResolveSprite()
    local preferred = Config.SPRITES.SPATIAL_WELL
    if preferred and getSprite(preferred) then return preferred end

    local fallback = Config.SPRITES.SPATIAL_WELL_FALLBACK
    if fallback and getSprite(fallback) then return fallback end
    return nil
end

local function isSquareFree(square)
    if not square or not square:getChunk() then return false end
    if square:isSolid() or square:isSolidTrans() then return false end
    if square:HasStairs() or square:HasTree() then return false end
    if not square:TreatAsSolidFloor() then return false end
    if square:isVehicleIntersecting() then return false end

    local movingObjects = square:getMovingObjects()
    if movingObjects and not movingObjects:isEmpty() then return false end

    local specialObjects = square:getSpecialObjects()
    if specialObjects then
        for i = 0, specialObjects:size() - 1 do
            local object = specialObjects:get(i)
            local modData = World.getModData(object)
            if not modData or modData.isRefugeBoundary ~= true then return false end
        end
    end

    if square.isFreeOrMidair then
        local ok, isFree = pcall(function() return square:isFreeOrMidair(true) end)
        if ok and not isFree then return false end
    end

    return true
end

function SpatialWell.CanPlaceAt(player, square, refugeData)
    if not player or not square then return false, PM.SPATIAL_WELL_INVALID_LOCATION end

    refugeData = refugeData or Data.GetRefugeData(player)
    if not refugeData then return false, PM.SPATIAL_WELL_NOT_IN_REFUGE end

    local username = player:getUsername()
    if not username or refugeData.username ~= username then
        return false, PM.SPATIAL_WELL_NOT_IN_REFUGE
    end

    if SpatialWell.IsBuilt(refugeData) then
        return false, PM.SPATIAL_WELL_ALREADY_BUILT
    end

    local playerRefuge = Data.GetRefugeDataAtPosition(
        math.floor(player:getX()),
        math.floor(player:getY()),
        math.floor(player:getZ())
    )
    if not playerRefuge or playerRefuge.username ~= username then
        return false, PM.SPATIAL_WELL_NOT_IN_REFUGE
    end

    local x, y, z = square:getX(), square:getY(), square:getZ()
    local targetRefuge = Data.GetRefugeDataAtPosition(x, y, z)
    if not targetRefuge or targetRefuge.username ~= username then
        return false, PM.SPATIAL_WELL_INVALID_LOCATION
    end
    if z ~= (refugeData.centerZ or 0) then
        return false, PM.SPATIAL_WELL_INVALID_LOCATION
    end
    if not isSquareFree(square) then
        return false, PM.SPATIAL_WELL_INVALID_LOCATION
    end

    return true, nil
end

function SpatialWell.CanMoveObject(player, well, refugeData)
    if not player or not well then return false, PM.SPATIAL_WELL_MOVE_FAILED end

    refugeData = refugeData or Data.GetRefugeData(player)
    if not refugeData or not SpatialWell.IsBuilt(refugeData) then
        return false, PM.SPATIAL_WELL_MOVE_FAILED
    end

    local username = player:getUsername()
    if not username or refugeData.username ~= username then
        return false, PM.SPATIAL_WELL_NOT_IN_REFUGE
    end

    local playerRefuge = Data.GetRefugeDataAtPosition(
        math.floor(player:getX()),
        math.floor(player:getY()),
        math.floor(player:getZ())
    )
    if not playerRefuge or playerRefuge.refugeId ~= refugeData.refugeId then
        return false, PM.SPATIAL_WELL_NOT_IN_REFUGE
    end

    if not SpatialWell.IsObjectForRefuge(well, refugeData) then
        return false, PM.SPATIAL_WELL_MOVE_FAILED
    end

    local state = SpatialWell.GetState(refugeData)
    local currentSquare = well:getSquare()
    if not state or not currentSquare or not currentSquare:getChunk() then
        return false, PM.SPATIAL_WELL_MOVE_FAILED
    end
    if currentSquare:getX() ~= state.x or currentSquare:getY() ~= state.y or
            currentSquare:getZ() ~= (state.z or refugeData.centerZ or 0) then
        return false, PM.SPATIAL_WELL_MOVE_FAILED
    end

    return true, nil
end

function SpatialWell.CanMoveTo(player, square, refugeData, well)
    refugeData = refugeData or Data.GetRefugeData(player)
    if not refugeData then return false, PM.SPATIAL_WELL_NOT_IN_REFUGE end

    if not well then
        well = SpatialWell.Find(refugeData)
    end
    local canMove, reason = SpatialWell.CanMoveObject(player, well, refugeData)
    if not canMove then return false, reason end
    if not square or not square:getChunk() then
        return false, PM.SPATIAL_WELL_INVALID_LOCATION
    end

    local currentSquare = well:getSquare()
    if currentSquare and currentSquare:getX() == square:getX() and
            currentSquare:getY() == square:getY() and currentSquare:getZ() == square:getZ() then
        return false, PM.SPATIAL_WELL_INVALID_LOCATION
    end

    local username = player:getUsername()
    local targetRefuge = Data.GetRefugeDataAtPosition(square:getX(), square:getY(), square:getZ())
    if not targetRefuge or targetRefuge.refugeId ~= refugeData.refugeId or
            targetRefuge.username ~= username then
        return false, PM.SPATIAL_WELL_INVALID_LOCATION
    end
    if square:getZ() ~= (refugeData.centerZ or 0) or not isSquareFree(square) then
        return false, PM.SPATIAL_WELL_INVALID_LOCATION
    end

    return true, nil
end

local function findAtState(refugeData)
    local state = SpatialWell.GetState(refugeData)
    if not state or state.x == nil or state.y == nil then return nil, nil end

    local cell = getCell()
    if not cell then return nil, nil end
    local square = cell:getGridSquare(state.x, state.y, state.z or refugeData.centerZ or 0)
    if not square or not square:getChunk() then return nil, square end

    local matches = World.findObjectsByModData(square, "isSpatialWell")
    for _, object in ipairs(matches) do
        local md = World.getModData(object)
        if md and md.refugeId == refugeData.refugeId then
            return object, square
        end
    end
    return nil, square
end

function SpatialWell.Find(refugeData)
    if not refugeData then return nil, nil end

    local object, square = findAtState(refugeData)
    if object or square then return object, square end

    local foundObject, foundSquare = nil, nil
    local areaCenterX, areaCenterY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
    World.iterateArea(
        areaCenterX,
        areaCenterY,
        refugeData.centerZ or 0,
        refugeData.radius or 1,
        function(candidateSquare)
            if foundObject then return end
            local matches = World.findObjectsByModData(candidateSquare, "isSpatialWell")
            for _, candidate in ipairs(matches) do
                local md = World.getModData(candidate)
                if md and md.refugeId == refugeData.refugeId then
                    foundObject = candidate
                    foundSquare = candidateSquare
                    return
                end
            end
        end
    )
    return foundObject, foundSquare
end

local function applyProtectedProperties(well)
    well:setMaxHealth(999999)
    well:setHealth(999999)
    well:setCanBarricade(false)
    well:setIsThumpable(false)
    well:setBreakSound("none")
    well:setSpecialTooltip(true)
    well:setIsDismantable(false)
    well:setCanBePlastered(false)
    well:setIsHoppable(false)
    well:setCanPassThrough(false)
    well:setBlockAllTheSquare(true)
    ---@diagnostic disable-next-line: undefined-field -- Optional compatibility API across supported B42 builds.
    if well.setDestroyed then well:setDestroyed(false) end
end

local function attachEntity(well)
    if not well then return false end
    if well.getFluidContainer and well:getFluidContainer() then return true end

    local scriptName = Config.SPATIAL_WELL and Config.SPATIAL_WELL.ENTITY_SCRIPT
    local script = scriptName and ScriptManager.instance:getGameEntityScript(scriptName) or nil
    if not script then
        LOG.error("Missing entity script: %s", tostring(scriptName))
        return false
    end

    GameEntityFactory.CreateIsoObjectEntity(well, script, true)
    return well.getFluidContainer and well:getFluidContainer() ~= nil
end

local function tagWell(well, refugeData, spriteName)
    local md = well:getModData()
    local values = {
        isSpatialWell = true,
        isProtectedRefugeObject = true,
        canBeDisassembled = false,
        refugeId = refugeData.refugeId,
        refugeUsername = refugeData.username,
        spatialWellSprite = spriteName,
    }
    local changed = false
    for key, value in pairs(values) do
        if md[key] ~= value then
            md[key] = value
            changed = true
        end
    end
    return changed
end

local function ensureInitialWater(well)
    local fluidContainer = well and well.getFluidContainer and well:getFluidContainer() or nil
    if not fluidContainer then return false end

    local capacity = Config.SPATIAL_WELL.CAPACITY or 400
    fluidContainer:setCapacity(capacity)
    if fluidContainer:getAmount() <= 0 then
        fluidContainer:addFluid(FluidType.Water, Config.SPATIAL_WELL.INITIAL_WATER or 40)
    end
    return true
end

function SpatialWell.CreateAt(player, x, y, z)
    if not Env.hasServerAuthority() then return nil, PM.SPATIAL_WELL_BUILD_FAILED end

    local refugeData = Data.GetRefugeData(player)
    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, z) or nil
    local canPlace, reason = SpatialWell.CanPlaceAt(player, square, refugeData)
    if not canPlace then return nil, reason end
    ---@cast square IsoGridSquare

    local existing = SpatialWell.Find(refugeData)
    if existing then return nil, PM.SPATIAL_WELL_ALREADY_BUILT end

    local spriteName = SpatialWell.ResolveSprite()
    if not spriteName then return nil, PM.SPATIAL_WELL_BUILD_FAILED end

    local well = IsoThumpable.new(cell, square, spriteName, false, nil --[[@as table]])
    if not well then return nil, PM.SPATIAL_WELL_BUILD_FAILED end

    applyProtectedProperties(well)
    tagWell(well, refugeData, spriteName)
    if not attachEntity(well) or not ensureInitialWater(well) then
        return nil, PM.SPATIAL_WELL_BUILD_FAILED
    end

    if not World.addObject(square, well, true) then
        return nil, PM.SPATIAL_WELL_BUILD_FAILED
    end

    local customizations = getCustomizationTable(refugeData, true)
    customizations.spatialWell = {
        placed = true,
        x = x,
        y = y,
        z = z,
        createdTime = K.time(),
    }

    if not Data.SaveRefugeData(refugeData) then
        World.removeObject(square, well, true)
        customizations.spatialWell = nil
        return nil, PM.SPATIAL_WELL_BUILD_FAILED
    end

    startTrackingRefill(refugeData)
    World.transmitModData(well)
    if well.sync then well:sync() end
    LOG.info("Created Spatial Well for %s at %d,%d,%d", refugeData.username, x, y, z)
    return well, nil
end

function SpatialWell.RollbackPlacement(refugeData, well)
    if well and well.getSquare then
        local square = well:getSquare()
        if square then World.removeObject(square, well, true) end
    end

    local customizations = getCustomizationTable(refugeData, false)
    if customizations then customizations.spatialWell = nil end
    if refugeData and Env.hasServerAuthority() then Data.SaveRefugeData(refugeData) end
end

function SpatialWell.ValidateLockedAllocation(allocation, requirements)
    if type(allocation) ~= "table" or type(requirements) ~= "table" then return false end

    local seenIds = {}
    local function validateItemIds(itemIds, maximumCount)
        if itemIds == nil then return true end
        if type(itemIds) ~= "table" or #itemIds > maximumCount then return false end
        local visited = 0
        for index, itemId in pairs(itemIds) do
            visited = visited + 1
            if visited > maximumCount
                or type(index) ~= "number"
                or index < 1
                or index > #itemIds
                or index ~= math.floor(index)
                or type(itemId) ~= "number"
                or itemId ~= math.floor(itemId)
                or seenIds[itemId]
            then
                return false
            end
            seenIds[itemId] = true
        end
        return visited == #itemIds
    end

    if K.isArrayLike(requirements) then
        local allowedTypes = {}
        for _, requirement in ipairs(requirements) do
            if not requirement.type or allowedTypes[requirement.type]
                or type(requirement.count) ~= "number"
                or requirement.count < 0
                or requirement.count ~= math.floor(requirement.count)
            then
                return false
            end

            local groupCount = 0
            local groupTypes = { requirement.type }
            for _, substitute in ipairs(requirement.substitutes or {}) do
                table.insert(groupTypes, substitute)
            end

            for _, itemType in ipairs(groupTypes) do
                if allowedTypes[itemType] then return false end
                allowedTypes[itemType] = true
                local itemIds = allocation[itemType]
                if not validateItemIds(itemIds, requirement.count) then return false end
                groupCount = groupCount + (itemIds and #itemIds or 0)
            end
            if groupCount ~= requirement.count then return false end
        end

        for itemType, itemIds in pairs(allocation) do
            if not allowedTypes[itemType] or type(itemIds) ~= "table" then return false end
        end
        return true
    end

    local expectedTypes = 0
    local actualTypes = 0
    for itemType, requiredCount in pairs(requirements) do
        if type(itemType) ~= "string"
            or type(requiredCount) ~= "number"
            or requiredCount < 0
            or requiredCount ~= math.floor(requiredCount)
        then
            return false
        end
        expectedTypes = expectedTypes + 1
        local itemIds = allocation[itemType]
        if type(itemIds) ~= "table"
            or not validateItemIds(itemIds, requiredCount)
            or #itemIds ~= requiredCount
        then
            return false
        end
    end
    for itemType, itemIds in pairs(allocation) do
        actualTypes = actualTypes + 1
        if requirements[itemType] == nil or type(itemIds) ~= "table" then return false end
    end
    return expectedTypes == actualTypes
end

function SpatialWell.IsBuildItemAvailable(item, container)
    if not Transaction.IsItemAvailable(item, container) then return false end
    if SpatialWell.IsSupportedBucketType(item:getFullType()) then
        return SpatialWell.IsEmptyBucket(item)
    end
    return true
end

--- Consume building materials and Echo, create the well, or restore both resources.
function SpatialWell.ExecutePlacement(player, x, y, z, allocation, operationId)
    if not Env.hasServerAuthority() then return false, PM.SPATIAL_WELL_BUILD_FAILED, nil, false end
    if type(operationId) ~= "string" or operationId == "" or #operationId > 128 then
        return false, PM.SPATIAL_WELL_BUILD_FAILED, nil, false
    end

    local refugeData = Data.GetRefugeData(player)
    if not refugeData then return false, PM.SPATIAL_WELL_NOT_IN_REFUGE, nil, false end
    local existing = MSR.Echo.FindHistoryEntry(refugeData, operationId)
    if existing then
        if existing.type == "spatial_well" then return true, nil, nil, true end
        return false, PM.SPATIAL_WELL_BUILD_FAILED, nil, false
    end

    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, z) or nil
    local canPlace, placeError = SpatialWell.CanPlaceAt(player, square, refugeData)
    if not canPlace then return false, placeError, nil, false end

    local requirements = SpatialWell.GetTransactionRequirements()
    if not SpatialWell.ValidateLockedAllocation(allocation, requirements) then
        return false, PM.SPATIAL_WELL_MISSING_RESOURCES, nil, false
    end

    local sources = Transaction.GetItemRoots(player, true)
    local itemReceipt, itemError = MSR.InventoryAuthority.consumeWithReceipt(
        player,
        sources,
        allocation,
        SpatialWell.IsBuildItemAvailable
    )
    if not itemReceipt then
        LOG.debug("Spatial Well material consumption failed: %s", tostring(itemError))
        return false, PM.SPATIAL_WELL_MISSING_RESOURCES, nil, false
    end

    local echoReceipt, echoError = MSR.Echo.BeginSpend(
        refugeData,
        SpatialWell.GetEchoCost(),
        operationId,
        "spatial_well",
        tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
    )
    if not echoReceipt then
        MSR.InventoryAuthority.refundReceipt(player, itemReceipt)
        LOG.debug("Spatial Well Echo spend failed: %s", tostring(echoError))
        return false, PM.SPATIAL_WELL_MISSING_RESOURCES, nil, false
    end

    local well, createError = SpatialWell.CreateAt(player, x, y, z)
    if not well then
        MSR.Echo.RollbackReceipt(echoReceipt, true)
        MSR.InventoryAuthority.refundReceipt(player, itemReceipt)
        return false, createError or PM.SPATIAL_WELL_BUILD_FAILED, nil, false
    end

    MSR.Echo.FinalizeReceipt(echoReceipt)
    MSR.InventoryAuthority.finalizeReceipt(itemReceipt)
    return true, nil, well, false
end

function SpatialWell.RequestPlacement(player, x, y, z)
    if not player then return false, PM.SPATIAL_WELL_BUILD_FAILED end

    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, z) or nil
    local canPlace, reason = SpatialWell.CanPlaceAt(player, square)
    if not canPlace then return false, reason end

    local refugeData = Data.GetRefugeData(player)
    if not MSR.Echo.CanSpend(refugeData, SpatialWell.GetEchoCost()) then
        return false, PM.SPATIAL_WELL_MISSING_RESOURCES
    end

    local transaction, transactionError = Transaction.Begin(
        player,
        SpatialWell.TRANSACTION_TYPE,
        SpatialWell.GetTransactionRequirements()
    )
    if not transaction then
        LOG.debug("Unable to begin well transaction: %s", tostring(transactionError))
        return false, PM.SPATIAL_WELL_MISSING_RESOURCES
    end

    if Env.isMultiplayerClient() then
        sendClientCommand(Config.COMMAND_NAMESPACE, Config.COMMANDS.REQUEST_PLACE_SPATIAL_WELL, {
            x = x,
            y = y,
            z = z,
            transactionId = transaction.id,
            lockedItemIds = Transaction.CopyAllocation(transaction),
        })
        PM.Say(player, PM.SPATIAL_WELL_BUILDING)
        return true, nil
    end

    local success, createError = SpatialWell.ExecutePlacement(
        player,
        x,
        y,
        z,
        Transaction.CopyAllocation(transaction),
        transaction.id
    )
    if not success then
        Transaction.Rollback(player, transaction.id)
        return false, createError or PM.SPATIAL_WELL_BUILD_FAILED
    end

    Transaction.Finalize(player, transaction.id)

    PM.Say(player, PM.SPATIAL_WELL_BUILT)
    return true, nil
end

local function moveObjectBetweenSquares(well, sourceSquare, targetSquare)
    if not World.removeObject(sourceSquare, well, false) then return false end

    well:setSquare(targetSquare)
    if not World.addObject(targetSquare, well, false) then
        well:setSquare(sourceSquare)
        World.addObject(sourceSquare, well, false)
        World.recalcSquare(sourceSquare)
        return false
    end

    World.recalcSquare(sourceSquare)
    World.recalcSquare(targetSquare)
    return true
end

function SpatialWell.MoveTo(player, x, y, z)
    if not Env.hasServerAuthority() then return false, PM.SPATIAL_WELL_MOVE_FAILED end

    local refugeData = Data.GetRefugeData(player)
    local well, sourceSquare = SpatialWell.Find(refugeData)
    local targetSquare = World.getLoadedSquare(x, y, z)
    local canMove, reason = SpatialWell.CanMoveTo(player, targetSquare, refugeData, well)
    if not canMove then return false, reason end
    ---@cast well IsoThumpable
    ---@cast sourceSquare IsoGridSquare
    ---@cast targetSquare IsoGridSquare

    -- Move the same IsoThumpable instance. Its attached FluidContainer therefore
    -- remains intact, including the current water amount and lock state.
    local fluidContainer = well:getFluidContainer()
    if not fluidContainer then return false, PM.SPATIAL_WELL_MOVE_FAILED end
    local waterBeforeMove = fluidContainer:getAmount()
    if not moveObjectBetweenSquares(well, sourceSquare, targetSquare) then
        return false, PM.SPATIAL_WELL_MOVE_FAILED
    end

    local movedFluidContainer = well:getFluidContainer()
    local waterAfterMove = movedFluidContainer and movedFluidContainer:getAmount() or nil
    if not movedFluidContainer or waterAfterMove ~= waterBeforeMove then
        if not moveObjectBetweenSquares(well, targetSquare, sourceSquare) then
            LOG.error("Failed to roll back a water-changing Spatial Well move for %s",
                tostring(refugeData.username))
        end
        LOG.error("Spatial Well water changed during move for %s: %.4f -> %.4f",
            tostring(refugeData.username), waterBeforeMove, tonumber(waterAfterMove) or -1)
        return false, PM.SPATIAL_WELL_MOVE_FAILED
    end

    local state = SpatialWell.GetState(refugeData)
    local oldX, oldY, oldZ = state.x, state.y, state.z
    state.x, state.y, state.z = x, y, z

    if not Data.SaveRefugeData(refugeData) then
        state.x, state.y, state.z = oldX, oldY, oldZ
        if not moveObjectBetweenSquares(well, targetSquare, sourceSquare) then
            LOG.error("Failed to roll back Spatial Well move for %s", tostring(refugeData.username))
        end
        return false, PM.SPATIAL_WELL_MOVE_FAILED
    end

    World.transmitModData(well)
    if well.sync then well:sync() end
    LOG.info("Moved Spatial Well for %s from %d,%d,%d to %d,%d,%d with %.2f water",
        tostring(refugeData.username), oldX, oldY, oldZ or refugeData.centerZ or 0,
        x, y, z, tonumber(waterAfterMove) or 0)
    return true, nil
end

function SpatialWell.RequestMove(player, well, x, y, z)
    if not player then return false, PM.SPATIAL_WELL_MOVE_FAILED end

    local remaining = SpatialWell.GetMoveCooldownRemaining(player)
    if remaining > 0 then
        return false, PM.CANNOT_MOVE_SPATIAL_WELL_YET, { math.ceil(remaining) }
    end

    local targetSquare = World.getLoadedSquare(x, y, z)
    local canMove, reason = SpatialWell.CanMoveTo(player, targetSquare, nil, well)
    if not canMove then return false, reason end

    if Env.isMultiplayerClient() then
        sendClientCommand(Config.COMMAND_NAMESPACE, Config.COMMANDS.REQUEST_MOVE_SPATIAL_WELL, {
            x = x,
            y = y,
            z = z,
        })
        PM.Say(player, PM.SPATIAL_WELL_MOVING)
        return true, nil
    end

    local moved, moveError = SpatialWell.MoveTo(player, x, y, z)
    if not moved then return false, moveError or PM.SPATIAL_WELL_MOVE_FAILED end

    SpatialWell.UpdateMoveTime(player)
    PM.Say(player, PM.SPATIAL_WELL_MOVED)
    return true, nil
end

function SpatialWell.EnsureForRefuge(refugeData)
    if not SpatialWell.IsBuilt(refugeData) then return nil end

    local well, square = findAtState(refugeData)
    if not square then return nil end

    local modDataChanged = false
    if not well then
        local state = SpatialWell.GetState(refugeData)
        local spriteName = SpatialWell.ResolveSprite()
        if not spriteName then return nil end

        well = IsoThumpable.new(getCell(), square, spriteName, false, nil --[[@as table]])
        if not well then return nil end
        applyProtectedProperties(well)
        tagWell(well, refugeData, spriteName)
        if not attachEntity(well) or not ensureInitialWater(well) then return nil end
        if not World.addObject(square, well, true) then return nil end
        LOG.warning("Recreated missing Spatial Well for %s at %d,%d,%d",
            refugeData.username, state.x, state.y, state.z or 0)
    else
        applyProtectedProperties(well)
        local spriteName = SpatialWell.ResolveSprite()
        if not spriteName then return nil end
        modDataChanged = tagWell(well, refugeData, spriteName)
        attachEntity(well)
    end

    if modDataChanged then World.transmitModData(well) end
    return well
end

function SpatialWell.ProcessRefill(refugeData)
    if not Env.hasServerAuthority() or not SpatialWell.IsBuilt(refugeData) then return false end

    local trackingKey = getRefillTrackingKey(refugeData)
    if not trackingKey then return false end

    local now = getWorldAgeHours()
    local lastProcessed = refillLastProcessedHours[trackingKey]
    if not lastProcessed or now < lastProcessed then
        refillLastProcessedHours[trackingKey] = now
        return true
    end

    local elapsedHours = now - lastProcessed
    if elapsedHours <= 0 then return true end

    local well = SpatialWell.EnsureForRefuge(refugeData)
    if not well then return false end

    local fluidContainer = well:getFluidContainer()
    if not fluidContainer then return false end

    local freeCapacity = tonumber(fluidContainer:getFreeCapacity()) or 0
    local refillPerHour = math.max(0, tonumber(Config.SPATIAL_WELL.REFILL_PER_HOUR) or 2)
    local refill = math.min(freeCapacity, elapsedHours * refillPerHour)
    if refill <= 0 then
        refillLastProcessedHours[trackingKey] = now
        return true
    end

    local previousAmount = fluidContainer:getAmount()
    local inputWasLocked = fluidContainer:isInputLocked()
    if inputWasLocked then fluidContainer:setInputLocked(false) end
    fluidContainer:addFluid(FluidType.Water, refill)
    if inputWasLocked then fluidContainer:setInputLocked(true) end
    local newAmount = fluidContainer:getAmount()
    if newAmount <= previousAmount then
        LOG.warning("Spatial Well refill failed for %s (amount %.2f, requested %.2f)",
            tostring(refugeData.username), previousAmount, refill)
        return false
    end

    if well.sync then well:sync() end
    refillLastProcessedHours[trackingKey] = now
    LOG.debug("Refilled Spatial Well for %s after %.2f hours: %.2f -> %.2f",
        tostring(refugeData.username), elapsedHours, previousAmount, newAmount)
    return true
end

function SpatialWell.RemoveForRefuge(refugeData, saveState)
    if not refugeData then return false end

    local well, square = findAtState(refugeData)
    local removed = well and square and World.removeObject(square, well, true) or false
    local customizations = getCustomizationTable(refugeData, false)
    if customizations then customizations.spatialWell = nil end
    local trackingKey = getRefillTrackingKey(refugeData)
    if trackingKey then refillLastProcessedHours[trackingKey] = nil end
    if saveState ~= false and Env.hasServerAuthority() then Data.SaveRefugeData(refugeData) end
    return removed
end

return MSR.SpatialWell
