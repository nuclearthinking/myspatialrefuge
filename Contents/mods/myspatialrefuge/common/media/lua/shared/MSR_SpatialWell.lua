-- Spatial Well domain logic shared by singleplayer, client placement, and server authority.

require "00_core/00_MSR"
require "helpers/World"
require "MSR_RefugeGeometry"
require "MSR_PlayerMessage"
require "MSR_Transaction"

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
        if itemType == Config.CORE_ITEM then
            requirements[itemType] = D.core(count)
        else
            requirements[itemType] = D.material(count)
        end
    end
    return requirements
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
    md.isSpatialWell = true
    md.isProtectedRefugeObject = true
    md.canBeDisassembled = false
    md.refugeId = refugeData.refugeId
    md.refugeUsername = refugeData.username
    md.spatialWellSprite = spriteName
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

local function copyLockedAllocation(transaction)
    local allocation = {}
    for itemType, data in pairs(transaction.lockedItems or {}) do
        allocation[itemType] = {}
        for _, itemId in ipairs(data.itemIds or {}) do
            table.insert(allocation[itemType], itemId)
        end
    end
    return allocation
end

function SpatialWell.ValidateLockedAllocation(allocation, requirements)
    if type(allocation) ~= "table" or type(requirements) ~= "table" then return false end

    if K.isArrayLike(requirements) then
        local allowedTypes = {}
        for _, requirement in ipairs(requirements) do
            if not requirement.type or allowedTypes[requirement.type] then return false end

            local groupCount = 0
            local groupTypes = { requirement.type }
            for _, substitute in ipairs(requirement.substitutes or {}) do
                table.insert(groupTypes, substitute)
            end

            for _, itemType in ipairs(groupTypes) do
                if allowedTypes[itemType] then return false end
                allowedTypes[itemType] = true
                local itemIds = allocation[itemType]
                if itemIds ~= nil and type(itemIds) ~= "table" then return false end
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
        expectedTypes = expectedTypes + 1
        local itemIds = allocation[itemType]
        if type(itemIds) ~= "table" or #itemIds ~= requiredCount then return false end
    end
    for itemType, itemIds in pairs(allocation) do
        actualTypes = actualTypes + 1
        if requirements[itemType] == nil or type(itemIds) ~= "table" then return false end
    end
    return expectedTypes == actualTypes
end

function SpatialWell.RequestPlacement(player, x, y, z)
    if not player then return false, PM.SPATIAL_WELL_BUILD_FAILED end

    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, z) or nil
    local canPlace, reason = SpatialWell.CanPlaceAt(player, square)
    if not canPlace then return false, reason end

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
            lockedItemIds = copyLockedAllocation(transaction),
        })
        PM.Say(player, PM.SPATIAL_WELL_BUILDING)
        return true, nil
    end

    local well, createError = SpatialWell.CreateAt(player, x, y, z)
    if not well then
        Transaction.Rollback(player, transaction.id)
        return false, createError or PM.SPATIAL_WELL_BUILD_FAILED
    end

    if not Transaction.Commit(player, transaction.id) then
        SpatialWell.RollbackPlacement(Data.GetRefugeData(player), well)
        Transaction.Rollback(player, transaction.id)
        return false, PM.SPATIAL_WELL_BUILD_FAILED
    end

    PM.Say(player, PM.SPATIAL_WELL_BUILT)
    return true, nil
end

function SpatialWell.EnsureForRefuge(refugeData)
    if not SpatialWell.IsBuilt(refugeData) then return nil end

    local well, square = findAtState(refugeData)
    if not square then return nil end

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
        tagWell(well, refugeData, SpatialWell.ResolveSprite())
        attachEntity(well)
    end

    World.transmitModData(well)
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
    if well.sync then well:sync() end
    local newAmount = fluidContainer:getAmount()
    if newAmount <= previousAmount then
        LOG.warning("Spatial Well refill failed for %s (amount %.2f, requested %.2f)",
            tostring(refugeData.username), previousAmount, refill)
        return false
    end

    refillLastProcessedHours[trackingKey] = now
    World.transmitModData(well)
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
