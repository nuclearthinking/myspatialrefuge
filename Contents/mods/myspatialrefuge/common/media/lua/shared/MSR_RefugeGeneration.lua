-- MSR_RefugeGeneration - Refuge structures/generation utilities

require "00_core/00_MSR"
require "00_core/Env"
require "helpers/World"
require "MSR_Shared"
require "MSR_Integrity"
require "MSR_ZombieClear"
require "MSR_BasementGeneration"
require "MSR_UpgradeData"

if MSR and MSR.RefugeGeneration and MSR.RefugeGeneration._loaded then
    return MSR.RefugeGeneration
end

MSR.RefugeGeneration = MSR.RefugeGeneration or {}
MSR.RefugeGeneration._loaded = true

local RG = MSR.RefugeGeneration
local LOG = L.logger("RefugeGeneration")
local _lastRepairAttempt = 0
local _repairCooldown = 60 -- seconds between repair attempts

local function addSpecialObjectToSquare(square, obj)
    return MSR.World.addObject(square, obj, true)
end

local function removeObjectFromSquare(square, obj)
    return MSR.World.removeObject(square, obj, true)
end

local TREE_CLEAR_BUFFER = 5

-----------------------------------------------------------
-- Wall Generation
-----------------------------------------------------------

local function createWallObject(square, spriteName, isNorthWall)
    if not square or not square:getChunk() then return nil end

    local existingWalls = MSR.World.findObjects(square, function(obj)
        local md = MSR.World.getModData(obj)
        return md and md.isRefugeBoundary and md.refugeBoundarySprite == spriteName
    end)

    if #existingWalls > 0 then return existingWalls[1] end

    local cell = getCell()
    if not cell then return nil end

    local wall = IsoThumpable.new(cell, square, spriteName, isNorthWall, {})
    if not wall then return nil end

    wall:setMaxHealth(999999)
    wall:setHealth(999999)
    wall:setCanBarricade(false)
    wall:setIsThumpable(false)
    wall:setBreakSound("none")
    wall:setIsDismantable(false)
    wall:setCanBePlastered(false)
    wall:setIsHoppable(false)
    if wall.setDestroyed then wall:setDestroyed(false) end

    local md = wall:getModData()
    md.isRefugeBoundary = true
    md.refugeBoundarySprite = spriteName
    md.canBeDisassembled = false
    md.isProtectedRefugeObject = true

    if addSpecialObjectToSquare(square, wall) then
        if MSR.Env.isServer() then
            if wall.transmitCompleteItemToClients then
                wall:transmitCompleteItemToClients()
            elseif wall.transmitModData then
                wall:transmitModData()
            end
        end
        return wall
    end
    return nil
end

function RG.CreateWall(x, y, z, addNorth, addWest, cornerSprite)
    local square = MSR.World.getSquareSafe(x, y, z)
    if not square then return nil end

    local created = false
    if addNorth and createWallObject(square, MSR.Config.SPRITES.WALL_NORTH, true) then
        created = true
    end
    if addWest and createWallObject(square, MSR.Config.SPRITES.WALL_WEST, false) then
        created = true
    end
    if cornerSprite and createWallObject(square, cornerSprite, false) then
        created = true
    end

    return created and square or nil
end

function RG.CheckBoundaryWallsExist(centerX, centerY, z, radius)
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius
    local sampleCount = 0
    local foundCount = 0

    for level = 0, wallHeight - 1 do
        local currentZ = z + level

        -- Check a few sample positions on each side
        local samplePositions = {
            { minX, minY }, { centerX, minY }, { maxX, minY },             -- South wall samples
            { minX, maxY + 1 }, { centerX, maxY + 1 }, { maxX, maxY + 1 }, -- North wall samples
            { minX,     minY }, { minX, centerY }, { minX, maxY },         -- West wall samples
            { maxX + 1, minY }, { maxX + 1, centerY }, { maxX + 1, maxY }  -- East wall samples
        }

        for _, pos in ipairs(samplePositions) do
            local square = MSR.World.getSquareSafe(pos[1], pos[2], currentZ)
            if square then
                sampleCount = sampleCount + 1
                local walls = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
                if #walls > 0 then
                    foundCount = foundCount + 1
                end
            end
        end
    end

    -- If we found walls at most sample positions, assume walls exist
    return sampleCount > 0 and foundCount >= (sampleCount * 0.7) -- 70% threshold
end

function RG.CreateBoundaryWalls(centerX, centerY, z, radius)
    if RG.CheckBoundaryWallsExist(centerX, centerY, z, radius) then
        return 0 -- Already exist
    end

    local wallsCreated = 0
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    local minX = centerX - radius
    local maxX = centerX + radius
    local minY = centerY - radius
    local maxY = centerY + radius

    for level = 0, wallHeight - 1 do
        local currentZ = z + level

        for x = minX, maxX do
            if RG.CreateWall(x, minY, currentZ, true, false, nil) then wallsCreated = wallsCreated + 1 end
            if RG.CreateWall(x, maxY + 1, currentZ, true, false, nil) then
                wallsCreated = wallsCreated + 1
            end
        end

        for y = minY, maxY do
            if RG.CreateWall(minX, y, currentZ, false, true, nil) then wallsCreated = wallsCreated + 1 end
            if RG.CreateWall(maxX + 1, y, currentZ, false, true, nil) then
                wallsCreated = wallsCreated + 1
            end
        end

        RG.CreateWall(minX, minY, currentZ, false, false, MSR.Config.SPRITES.WALL_CORNER_NW)
        RG.CreateWall(maxX + 1, maxY + 1, currentZ, false, false, MSR.Config.SPRITES.WALL_CORNER_SE)
    end

    if wallsCreated > 0 then
        LOG.debug("Created %d wall segments", wallsCreated)
    end
    return wallsCreated
end

function RG.RemoveAllRefugeWalls(centerX, centerY, z, maxRadius)
    local wallsRemoved = 0
    local wallHeight = MSR.Config.WALL_HEIGHT or 1
    local scanRadius = maxRadius + 2
    local modifiedSquares = {}

    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        MSR.World.iterateArea(centerX, centerY, currentZ, scanRadius, function(square)
            local walls = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
            for _, obj in ipairs(walls) do
                MSR.World.removeObject(square, obj, false)
                wallsRemoved = wallsRemoved + 1
                table.insert(modifiedSquares, square)
            end
        end)
    end

    for _, square in ipairs(modifiedSquares) do
        MSR.World.recalcSquare(square)
        if square.RecalcProperties then square:RecalcProperties() end
    end

    LOG.debug("RemoveAllRefugeWalls: removed %d wall segments", wallsRemoved)
    return wallsRemoved
end

function RG.RemoveBoundaryWalls(centerX, centerY, z, radius)
    local wallsRemoved = 0
    local wallHeight = MSR.Config.WALL_HEIGHT or 1

    for level = 0, wallHeight - 1 do
        local currentZ = z + level
        MSR.World.iteratePerimeter(centerX, centerY, currentZ, radius, function(square)
            local walls = MSR.World.findObjectsByModData(square, "isRefugeBoundary")
            for _, obj in ipairs(walls) do
                MSR.World.removeObject(square, obj, true)
                wallsRemoved = wallsRemoved + 1
            end
        end)
    end

    LOG.debug("Removed %d wall segments", wallsRemoved)
    return wallsRemoved
end

-----------------------------------------------------------
-- Sacred Relic Generation
-----------------------------------------------------------

local function createRelicObject(square, refugeId)
    if not square or not square:getChunk() then return nil end

    local cell = getCell()
    if not cell then return nil end

    local spriteName = MSR.Shared.ResolveRelicSprite()
    if not spriteName then return nil end

    local sprite = getSprite(spriteName)
    if not sprite then
        LOG.error("Sprite object is nil: %s", tostring(spriteName))
        return nil
    end

    local relic = IsoThumpable.new(cell, square, spriteName, false, nil)
    if not relic then return nil end

    local createdSprite = relic:getSprite()
    if not createdSprite or not createdSprite:getName() then
        relic:setSprite(spriteName)
        createdSprite = relic:getSprite()
        if not createdSprite or not createdSprite:getName() then
            LOG.error("Failed to repair relic sprite - removing invalid relic")
            removeObjectFromSquare(square, relic)
            return nil
        end
    end

    relic:setMaxHealth(999999)
    relic:setHealth(999999)
    relic:setCanBarricade(false)
    relic:setIsThumpable(false)
    relic:setBreakSound("none")
    relic:setSpecialTooltip(true)
    relic:setIsDismantable(false)
    relic:setCanBePlastered(false)
    relic:setIsHoppable(false)
    relic:setCanPassThrough(false)
    relic:setBlockAllTheSquare(true)
    if relic.setDestroyed then relic:setDestroyed(false) end

    local md = relic:getModData()
    md.isSacredRelic = true
    md.refugeId = refugeId
    md.relicSprite = spriteName
    md.canBeDisassembled = false
    md.isProtectedRefugeObject = true

    relic:setIsContainer(true)
    local container = relic:getContainer()
    if container then
        -- Get capacity based on upgrade level (refugeId is the username)
        local refugeData = MSR.Data.GetRefugeDataByUsername(refugeId)
        local capacity = MSR.Config.getRelicStorageCapacity(refugeData)
        container:setCapacity(capacity)
    end

    if addSpecialObjectToSquare(square, relic) then
        if MSR.Env.isServer() and relic.transmitModData then
            relic:transmitModData()
        end

        LOG.debug("Created Sacred Relic at %s,%s", square:getX(), square:getY())
        return relic, spriteName
    end

    return nil, nil
end

function RG.CreateSacredRelic(x, y, z, refugeId, searchRadius)
    return RG.CreateSacredRelicAtPosition(x, y, z, x, y, z, refugeId, searchRadius)
end

function RG.CreateSacredRelicAtPosition(searchX, searchY, searchZ, createX, createY, createZ, refugeId,
                                       searchRadius)
    local cell = getCell()
    if not cell then return nil end

    local radius = (searchRadius or 10) + 1

    -- Check for existing relic (integrity system handles repairs)
    local existing = MSR.Shared.FindRelicInRefuge(searchX, searchY, searchZ, radius, refugeId)
    if existing then return existing end

    -- Extended search for duplicates
    local duplicateCheck = MSR.Shared.FindRelicInRefuge(searchX, searchY, searchZ, radius + 2, refugeId)
    if duplicateCheck then return duplicateCheck end

    local square = cell:getGridSquare(createX, createY, createZ)
    if not square or not square:getChunk() then return nil end

    LOG.debug("Creating Sacred Relic at %s,%s", createX, createY)
    return createRelicObject(square, refugeId)
end

-----------------------------------------------------------
-- Tree Clearing
-----------------------------------------------------------

function RG.ClearTreesFromArea(centerX, centerY, z, radius, dropLoot)
    if MSR.Env.isClient() then
        LOG.debug("ClearTreesFromArea: Skipping on client")
        return 0
    end

    local cleared = 0
    local totalRadius = radius + TREE_CLEAR_BUFFER

    MSR.World.iterateArea(centerX, centerY, z, totalRadius, function(square)
        local tree = square:getTree()
        if tree then
            if dropLoot then
                if tree.toppleTree then tree:toppleTree() end
            else
                MSR.World.removeObject(square, tree, true)
            end
            cleared = cleared + 1
        end
    end)

    if cleared > 0 then
        LOG.debug("Cleared %d trees from refuge area", cleared)
    end

    return cleared
end

-----------------------------------------------------------
-- Refuge Expansion
-----------------------------------------------------------

function RG.ExpandRefuge(refugeData, newTier, player)
    if not refugeData then return false end

    local tierConfig = MSR.Config.TIERS[newTier]
    if not tierConfig then return false end

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local oldRadius = refugeData.radius
    local newRadius = tierConfig.radius

    LOG.debug("ExpandRefuge: tier %d -> %d radius %d -> %d", (refugeData.tier or 0), newTier, oldRadius, newRadius)

    RG.RemoveAllRefugeWalls(centerX, centerY, centerZ, newRadius)
    RG.CreateBoundaryWalls(centerX, centerY, centerZ, newRadius)
    RG.ClearTreesFromArea(centerX, centerY, centerZ, newRadius, false)

    refugeData.tier = newTier
    refugeData.radius = newRadius
    refugeData.lastExpanded = K.time()

    MSR.ZombieClear.ClearZombiesFromArea(centerX, centerY, centerZ, newRadius, true, player)

    return true
end

-----------------------------------------------------------
-- Full Refuge Generation
-----------------------------------------------------------

function RG.EnsureRefugeStructures(refugeData, player)
    if not refugeData then return false end

    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    local relicX = refugeData.relicX or centerX
    local relicY = refugeData.relicY or centerY
    local relicZ = refugeData.relicZ or centerZ

    RG.CreateBoundaryWalls(centerX, centerY, centerZ, radius)
    RG.ClearTreesFromArea(centerX, centerY, centerZ, radius, false)

    local relic = RG.CreateSacredRelicAtPosition(
        centerX, centerY, centerZ,
        relicX, relicY, relicZ,
        refugeId, radius
    )

    local report = MSR.Integrity.ValidateAndRepair(refugeData, {
        source = "generation",
        player = player
    })

    MSR.Shared.SyncRelicPositionToModData(refugeData)
    MSR.ZombieClear.ClearZombiesFromArea(centerX, centerY, centerZ, radius, true, player)

    LOG.debug("Ensured refuge structures for %s", tostring(refugeId))

    return report.relic.found or relic ~= nil
end

-----------------------------------------------------------
-- Enter Preparation (SP/Host)
-----------------------------------------------------------

---Create context for refuge enter preparation flow
---@param refugeData table
---@param player IsoPlayer
---@return table
function RG.CreateEnterContext(refugeData, player)
    local radius = refugeData.radius or 1
    return {
        player = player,
        refugeData = refugeData,
        centerX = refugeData.centerX,
        centerY = refugeData.centerY,
        centerZ = refugeData.centerZ,
        radius = radius,
        refugeId = refugeData.refugeId,
        floorPrepared = false,
        relicCreated = false,
        wallsCreated = false,
        centerSquareSeen = false,
        buildingsRecalculated = false,
        refugeInitialized = false,
        basementChecked = false
    }
end

---Step refuge enter preparation flow; returns true when fully prepared
---@param ctx table
---@return boolean
function RG.StepEnterPreparation(ctx)
    local centerSquare = MSR.World.getLoadedSquare(ctx.centerX, ctx.centerY, ctx.centerZ)
    local chunkLoaded = centerSquare ~= nil

    if chunkLoaded then
        ctx.centerSquareSeen = true
    end

    if not MSR.Env.isMultiplayerClient() then
        -- Check if refuge already initialized
        if not ctx.refugeInitialized and chunkLoaded then
            local existingRelic = MSR.Shared.FindRelicInRefuge(
                ctx.centerX, ctx.centerY, ctx.centerZ, ctx.radius, ctx.refugeId
            )
            local wallsExist = RG.CheckBoundaryWallsExist(ctx.centerX, ctx.centerY, ctx.centerZ, ctx.radius)

            if existingRelic and wallsExist then
                ctx.refugeInitialized = true
                ctx.floorPrepared = true
                ctx.wallsCreated = true
                ctx.relicCreated = true
                LOG.debug("Refuge already initialized - skipping creation")
            end
        end

        if not ctx.refugeInitialized then
            if not ctx.floorPrepared and chunkLoaded then
                MSR.ZombieClear.ClearZombiesFromArea(ctx.centerX, ctx.centerY, ctx.centerZ, ctx.radius, true, ctx.player)
                ctx.floorPrepared = true
            end

            if not ctx.wallsCreated and chunkLoaded then
                if MSR.World.arePerimeterChunksLoaded(ctx.centerX, ctx.centerY, ctx.centerZ, ctx.radius) then
                    RG.ClearTreesFromArea(ctx.centerX, ctx.centerY, ctx.centerZ, ctx.radius, false)

                    local wallsCount = RG.CreateBoundaryWalls(ctx.centerX, ctx.centerY, ctx.centerZ, ctx.radius)
                    if wallsCount > 0 or RG.CheckBoundaryWallsExist(ctx.centerX, ctx.centerY, ctx.centerZ, ctx.radius) then
                        ctx.wallsCreated = true
                    end
                end
            end

            if not ctx.relicCreated and chunkLoaded and ctx.wallsCreated then
                local relicX = ctx.refugeData.relicX or ctx.centerX
                local relicY = ctx.refugeData.relicY or ctx.centerY
                local relicZ = ctx.refugeData.relicZ or ctx.centerZ
                
                local relic = RG.CreateSacredRelicAtPosition(
                    ctx.centerX, ctx.centerY, ctx.centerZ,
                    relicX, relicY, relicZ,
                    ctx.refugeId, ctx.radius
                )
                if relic then
                    ctx.relicCreated = true
                    if ctx.refugeData.relicX == nil then
                        local relicSquare = relic:getSquare()
                        if relicSquare then
                            ctx.refugeData.relicX = relicSquare:getX()
                            ctx.refugeData.relicY = relicSquare:getY()
                            ctx.refugeData.relicZ = relicSquare:getZ()
                        else
                            ctx.refugeData.relicX = ctx.centerX
                            ctx.refugeData.relicY = ctx.centerY
                            ctx.refugeData.relicZ = ctx.centerZ
                        end
                        MSR.Data.SaveRefugeData(ctx.refugeData)
                    end
                end
            end
        end
    else
        ctx.floorPrepared = true
        ctx.wallsCreated = true
        ctx.relicCreated = true
    end

    -- Wait for chunks to load, then apply cutaway fix
    if not ctx.buildingsRecalculated and ctx.floorPrepared and ctx.relicCreated and ctx.wallsCreated then
        if MSR.World.areAreaChunksLoaded(ctx.centerX, ctx.centerY, ctx.centerZ, ctx.radius) then
            ctx.buildingsRecalculated = true
            MSR.RoomPersistence.ApplyCutaway(ctx.refugeData)
        end
    end

    if ctx.buildingsRecalculated and not ctx.basementChecked and not MSR.Env.isMultiplayerClient() then
        ctx.basementChecked = true
        local basementLevel = MSR.UpgradeData.getPlayerUpgradeLevel(ctx.player, MSR.Config.UPGRADES.REFUGE_BASEMENT)
        if basementLevel > 0 and not MSR.BasementGeneration.IsBasementPresent(ctx.refugeData) then
            local success, errorMsg = MSR.BasementGeneration.Generate(ctx.refugeData, ctx.player)
            if not success then
                LOG.debug("Basement generation failed during entry: %s", tostring(errorMsg))
            end
        end
    end

    return ctx.floorPrepared and ctx.relicCreated and ctx.wallsCreated and ctx.buildingsRecalculated
end

-----------------------------------------------------------
-- Periodic Integrity Check (shared, client/server safe)
-----------------------------------------------------------

local function onPeriodicIntegrityCheck()
    local player = getPlayer()
    if not player then return end
    if not MSR.Data.IsPlayerInRefugeCoords(player) then return end

    local refugeData = MSR.GetRefugeData(player)
    if not refugeData then return end

    -- Only run repairs on server/host (SP, coop host, dedicated server)
    -- Pure MP clients should not attempt repairs - server will handle it
    if MSR.Env.isMultiplayerClient() then
        -- MP client: only do local visual fixes, no authoritative repairs
        if MSR.Integrity.CheckNeedsRepair(refugeData) then
            local relic = MSR.Integrity.FindRelic(refugeData)
            if relic then
                MSR.Integrity.ClientSpriteRepair(relic)
            end
        end
        return
    end

    -- Server/host: do full repair but with cooldown to avoid spam
    local now = K.time()
    if now - _lastRepairAttempt < _repairCooldown then
        return
    end

    if MSR.Integrity.CheckNeedsRepair(refugeData) then
        _lastRepairAttempt = now
        LOG.debug("Periodic check detected issues, running repair")
        local report = MSR.Integrity.ValidateAndRepair(refugeData, { source = "periodic", player = player })

        -- If repair failed (sprite issue), extend cooldown to avoid spam
        if report and report.relic.found and not report.relic.spriteRepaired
           and not report.modData.synced then
            -- Sprite repair failed - likely sprite not loaded. Extend cooldown.
            _repairCooldown = 300 -- 5 minutes
            LOG.debug("Sprite repair failed (sprite may not be loaded), extending cooldown")
        else
            _repairCooldown = 60 -- Reset to normal
        end
    end

    -- NOTE: Periodic zombie clearing is handled by MSR.ZombieClear module
    -- It self-registers on EveryOneMinute for both client and server
end

if not MSR._refugeGenerationIntegrityRegistered then
    Events.EveryOneMinute.Add(onPeriodicIntegrityCheck)
    MSR._refugeGenerationIntegrityRegistered = true
end

return MSR.RefugeGeneration
