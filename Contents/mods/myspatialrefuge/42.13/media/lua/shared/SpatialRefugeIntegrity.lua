-- Spatial Refuge Integrity Module
-- Unified validation and repair system for refuge structures
-- Consolidates all repair logic into a single, idempotent mechanism

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeEnv"
require "shared/SpatialRefugeData"

-- Prevent double-loading
if SpatialRefugeIntegrity and SpatialRefugeIntegrity._loaded then
    return SpatialRefugeIntegrity
end

SpatialRefugeIntegrity = SpatialRefugeIntegrity or {}
SpatialRefugeIntegrity._loaded = true

-----------------------------------------------------------
-- Environment Helpers
-----------------------------------------------------------

local function isServer()
    return SpatialRefugeEnv.isServer()
end

local function canModifyData()
    return SpatialRefugeEnv.canModifyData()
end

-----------------------------------------------------------
-- Sprite Cache
-----------------------------------------------------------

local _cachedRelicSprite = nil
local _cachedResolvedSprite = nil
local _cachedOldFallbackSprite = nil
local _spritesCached = false

local function getCachedRelicSprites()
    if not _spritesCached then
        _cachedRelicSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC
        _cachedOldFallbackSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC_FALLBACK
        
        -- Resolve sprite with fallbacks
        local spriteName = _cachedRelicSprite
        if getSprite and getSprite(spriteName) then
            _cachedResolvedSprite = spriteName
        else
            local digits = spriteName:match("_(%d+)$")
            if digits then
                local padded2 = spriteName:gsub("_(%d+)$", "_0" .. digits)
                if getSprite and getSprite(padded2) then 
                    _cachedResolvedSprite = padded2
                else
                    local padded3 = spriteName:gsub("_(%d+)$", "_00" .. digits)
                    if getSprite and getSprite(padded3) then 
                        _cachedResolvedSprite = padded3
                    end
                end
            end
            if not _cachedResolvedSprite then
                if _cachedOldFallbackSprite and getSprite and getSprite(_cachedOldFallbackSprite) then
                    _cachedResolvedSprite = _cachedOldFallbackSprite
                end
            end
        end
        _spritesCached = true
    end
    return _cachedRelicSprite, _cachedResolvedSprite, _cachedOldFallbackSprite
end

-----------------------------------------------------------
-- Internal Helper: Remove Object from Square
-----------------------------------------------------------

local function removeObjectFromSquare(square, obj)
    if not square or not obj then return false end
    
    if isServer() then
        square:transmitRemoveItemFromSquare(obj)
    else
        if square.RemoveWorldObject then pcall(function() square:RemoveWorldObject(obj) end) end
        if obj.removeFromSquare then pcall(function() obj:removeFromSquare() end) end
        if obj.removeFromWorld then pcall(function() obj:removeFromWorld() end) end
    end
    
    square:RecalcAllWithNeighbours(true)
    return true
end

-----------------------------------------------------------
-- Internal: Find Relic (Read-Only, No Repairs)
-----------------------------------------------------------

-- Find relic by ModData on specific square
local function findRelicOnSquareByModData(square, refugeId)
    if not square then return nil end
    local objects = square:getObjects()
    if not objects then return nil end
    
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj then
            local md = obj:getModData()
            if md and md.isSacredRelic and md.refugeId == refugeId then
                return obj
            end
        end
    end
    return nil
end

-- Find relic by sprite on specific square
-- Recognizes: current sprite, resolved sprite (with padding), and old fallback sprite
local function findRelicOnSquareBySprite(square, relicSprite, resolvedSprite, oldFallbackSprite)
    if not square then return nil end
    local objects = square:getObjects()
    if not objects then return nil end
    
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj and obj.getSprite then
            local sprite = obj:getSprite()
            if sprite then
                local spriteName = sprite:getName()
                if spriteName == relicSprite or spriteName == resolvedSprite or 
                   (oldFallbackSprite and spriteName == oldFallbackSprite) then
                    return obj
                end
            end
        end
    end
    return nil
end

-- Find relic in refuge area (read-only, no inline repairs)
local function findRelicReadOnly(centerX, centerY, z, radius, refugeId)
    local cell = getCell()
    if not cell then return nil, nil end
    
    local relicSprite, resolvedSprite, oldFallbackSprite = getCachedRelicSprites()
    local searchRadius = (radius or 1) + 1
    
    -- First pass: find by ModData (preferred)
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local relic = findRelicOnSquareByModData(square, refugeId)
                if relic then
                    return relic, "moddata"
                end
            end
        end
    end
    
    -- Second pass: find by sprite (fallback for old saves, including old fallback sprite)
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local relic = findRelicOnSquareBySprite(square, relicSprite, resolvedSprite, oldFallbackSprite)
                if relic then
                    return relic, "sprite"
                end
            end
        end
    end
    
    return nil, nil
end

-- Find all relics in area (for duplicate detection)
local function findAllRelicsInArea(centerX, centerY, z, radius, refugeId)
    local cell = getCell()
    if not cell then return {} end
    
    local relicSprite, resolvedSprite, oldFallbackSprite = getCachedRelicSprites()
    local searchRadius = (radius or 1) + 2
    local foundRelics = {}
    
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, z)
            if square then
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj then
                            local md = obj:getModData()
                            local isRelic = false
                            local foundBy = nil
                            
                            if md and md.isSacredRelic and md.refugeId == refugeId then
                                isRelic = true
                                foundBy = "moddata"
                            elseif obj.getSprite then
                                local sprite = obj:getSprite()
                                if sprite then
                                    local spriteName = sprite:getName()
                                    if spriteName == relicSprite or spriteName == resolvedSprite or
                                       (oldFallbackSprite and spriteName == oldFallbackSprite) then
                                        isRelic = true
                                        foundBy = "sprite"
                                    end
                                end
                            end
                            
                            if isRelic then
                                -- Count items in container
                                local itemCount = 0
                                if obj.getContainer then
                                    local container = obj:getContainer()
                                    if container then
                                        local items = container:getItems()
                                        itemCount = items and items:size() or 0
                                    end
                                end
                                
                                table.insert(foundRelics, {
                                    obj = obj,
                                    square = square,
                                    foundBy = foundBy,
                                    itemCount = itemCount,
                                    x = square:getX(),
                                    y = square:getY(),
                                    z = square:getZ()
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    
    return foundRelics
end

-----------------------------------------------------------
-- Internal Validators
-----------------------------------------------------------

-- Validate and repair relic ModData
local function validateRelicModData(relic, refugeId, report)
    if not relic then return false end
    
    local md = relic:getModData()
    local repaired = false
    
    -- Ensure isSacredRelic flag
    if not md.isSacredRelic then
        md.isSacredRelic = true
        repaired = true
        report.relic.modDataRepaired = true
        if getDebug() then
            print("[SpatialRefugeIntegrity] Added isSacredRelic flag")
        end
    end
    
    -- Ensure refugeId
    if not md.refugeId or md.refugeId ~= refugeId then
        md.refugeId = refugeId
        repaired = true
        report.relic.modDataRepaired = true
        if getDebug() then
            print("[SpatialRefugeIntegrity] Fixed refugeId: " .. tostring(refugeId))
        end
    end
    
    -- Ensure isProtectedRefugeObject
    if not md.isProtectedRefugeObject then
        md.isProtectedRefugeObject = true
        repaired = true
    end
    
    -- Ensure canBeDisassembled is false
    if md.canBeDisassembled ~= false then
        md.canBeDisassembled = false
        repaired = true
    end
    
    return repaired
end

-- Validate and repair relic sprite
local function validateRelicSprite(relic, report)
    if not relic then return false end
    
    local expectedSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC
    local oldFallbackSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC_FALLBACK
    local currentSprite = relic:getSpriteName()
    local repaired = false
    
    -- Check if sprite is valid
    local spriteValid = false
    if currentSprite and relic.getSprite then
        local sprite = relic:getSprite()
        spriteValid = (sprite ~= nil and sprite:getName() == currentSprite)
    end
    
    -- Check if sprite needs migration/repair
    local needsRepair = false
    local isOldFallback = false
    
    if not spriteValid then
        needsRepair = true
    elseif currentSprite ~= expectedSprite then
        -- Check if it's the old fallback sprite (legacy migration)
        if oldFallbackSprite and currentSprite == oldFallbackSprite then
            needsRepair = true
            isOldFallback = true
        else
            -- Different sprite (corrupted or wrong)
            needsRepair = true
        end
    end
    
    -- Repair if needed
    if needsRepair then
        local newSprite = getSprite(expectedSprite)
        if newSprite then
            relic:setSprite(expectedSprite)
            local md = relic:getModData()
            md.relicSprite = expectedSprite
            repaired = true
            report.relic.spriteRepaired = true
            
            if getDebug() then
                if not spriteValid then
                    print("[SpatialRefugeIntegrity] Repaired corrupted relic sprite")
                elseif isOldFallback then
                    print("[SpatialRefugeIntegrity] Migrated old fallback sprite to new: " .. 
                          tostring(currentSprite) .. " -> " .. expectedSprite)
                else
                    print("[SpatialRefugeIntegrity] Migrated relic sprite: " .. 
                          tostring(currentSprite) .. " -> " .. expectedSprite)
                end
            end
        end
    end
    
    return repaired
end

-- Validate and repair relic properties (thumpable settings)
local function validateRelicProperties(relic)
    if not relic then return false end
    
    if relic.setIsThumpable then relic:setIsThumpable(false) end
    if relic.setIsHoppable then relic:setIsHoppable(false) end
    if relic.setIsDismantable then relic:setIsDismantable(false) end
    if relic.setCanBarricade then relic:setCanBarricade(false) end
    if relic.setCanBePlastered then relic:setCanBePlastered(false) end
    
    return true
end

-- Ensure only one relic exists, remove duplicates
local function ensureSingleRelic(refugeData, report)
    if not refugeData then return nil end
    if not canModifyData() then return nil end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    
    local allRelics = findAllRelicsInArea(centerX, centerY, centerZ, radius, refugeId)
    
    if #allRelics == 0 then
        return nil -- No relic found
    end
    
    if #allRelics == 1 then
        return allRelics[1].obj -- Single relic, no duplicates
    end
    
    -- Multiple relics found - need to pick one and remove others
    if getDebug() then
        print("[SpatialRefugeIntegrity] Found " .. #allRelics .. " relics - removing duplicates")
    end
    
    -- Priority for keeping:
    -- 1. Relic at stored position (refugeData.relicX/Y/Z)
    -- 2. Relic with most items
    -- 3. First one found by ModData
    -- 4. First one found
    
    local storedX = refugeData.relicX
    local storedY = refugeData.relicY
    local storedZ = refugeData.relicZ
    
    local keepIndex = 1
    local keepRelic = allRelics[1]
    local foundStoredPosition = false
    
    -- Check for relic at stored position
    if storedX and storedY and storedZ then
        for i, relicData in ipairs(allRelics) do
            if relicData.x == storedX and relicData.y == storedY and relicData.z == storedZ then
                keepIndex = i
                keepRelic = relicData
                foundStoredPosition = true
                if getDebug() then
                    print("[SpatialRefugeIntegrity] Keeping relic at stored position")
                end
                break
            end
        end
    end
    
    -- If no stored position match, prefer relic with items
    if not foundStoredPosition then
        local maxItems = -1
        for i, relicData in ipairs(allRelics) do
            if relicData.itemCount > maxItems then
                maxItems = relicData.itemCount
                keepIndex = i
                keepRelic = relicData
            end
        end
        
        if maxItems > 0 and getDebug() then
            print("[SpatialRefugeIntegrity] Keeping relic with " .. maxItems .. " items")
        end
    end
    
    -- Remove duplicates
    local removed = 0
    for i, relicData in ipairs(allRelics) do
        if i ~= keepIndex then
            if getDebug() then
                print("[SpatialRefugeIntegrity] Removing duplicate at " .. relicData.x .. "," .. relicData.y)
            end
            removeObjectFromSquare(relicData.square, relicData.obj)
            removed = removed + 1
        end
    end
    
    report.relic.duplicatesRemoved = removed
    
    -- Update refugeData with kept relic position
    if keepRelic and keepRelic.x and keepRelic.y then
        if refugeData.relicX ~= keepRelic.x or refugeData.relicY ~= keepRelic.y then
            refugeData.relicX = keepRelic.x
            refugeData.relicY = keepRelic.y
            refugeData.relicZ = keepRelic.z
            table.insert(report.modData.fieldsRepaired, "relicX")
            table.insert(report.modData.fieldsRepaired, "relicY")
        end
    end
    
    return keepRelic.obj
end

-- Validate and repair wall properties
local function validateWalls(refugeData, report)
    if not refugeData then return 0 end
    
    local cell = getCell()
    if not cell then return 0 end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local repaired = 0
    
    for dx = -radius - 2, radius + 2 do
        for dy = -radius - 2, radius + 2 do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, centerZ)
            if square then
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj and obj.getModData then
                            local md = obj:getModData()
                            if md and md.isRefugeBoundary then
                                -- Repair wall properties
                                if obj.setIsThumpable then obj:setIsThumpable(false) end
                                if obj.setIsHoppable then obj:setIsHoppable(false) end
                                if obj.setCanBarricade then obj:setCanBarricade(false) end
                                if obj.setIsDismantable then obj:setIsDismantable(false) end
                                if obj.setCanBePlastered then obj:setCanBePlastered(false) end
                                repaired = repaired + 1
                            end
                        end
                    end
                end
            end
        end
    end
    
    report.walls.repaired = repaired
    return repaired
end

-----------------------------------------------------------
-- Internal: Sync All (Atomic MP Sync)
-----------------------------------------------------------

local function syncAll(refugeData, relic, context, report)
    -- Only sync if we have authority to modify data
    if not canModifyData() then 
        report.modData.synced = false
        return false 
    end
    
    -- Save global ModData (works for SP, dedicated server, and coop host)
    if refugeData then
        SpatialRefugeData.SaveRefugeData(refugeData)
    end
    
    -- In multiplayer (coop host or dedicated server), transmit to connected clients
    if SpatialRefugeEnv.needsClientSync() then
        if relic then
            if relic.transmitModData then
                relic:transmitModData()
            end
            if relic.transmitUpdatedSpriteToClients then
                relic:transmitUpdatedSpriteToClients()
            end
        end
        
        if getDebug() then
            local envType = SpatialRefugeEnv.isCoopHost() and "coop_host" or "dedicated_server"
            print("[SpatialRefugeIntegrity] Synced ModData to clients (" .. envType .. ")")
        end
    else
        if getDebug() then
            print("[SpatialRefugeIntegrity] Saved ModData (singleplayer)")
        end
    end
    
    report.modData.synced = true
    return true
end

-----------------------------------------------------------
-- Public API
-----------------------------------------------------------

-- Create a new IntegrityReport
local function createReport(source)
    return {
        success = true,
        source = source or "unknown",
        timestamp = getTimestamp and getTimestamp() or 0,
        relic = {
            found = false,
            created = false,
            spriteRepaired = false,
            modDataRepaired = false,
            duplicatesRemoved = 0,
            position = nil
        },
        walls = {
            repaired = 0,
            created = 0
        },
        modData = {
            synced = false,
            fieldsRepaired = {}
        },
        errors = {}
    }
end

--- Main entry point - validates and repairs everything
--- @param refugeData table Player's refuge data
--- @param context table { source = "enter"|"reconnect"|"upgrade"|"periodic", player = IsoPlayer }
--- @return table IntegrityReport
function SpatialRefugeIntegrity.ValidateAndRepair(refugeData, context)
    context = context or {}
    local source = context.source or "unknown"
    local report = createReport(source)
    
    if not refugeData then
        table.insert(report.errors, "No refuge data provided")
        report.success = false
        return report
    end
    
    if getDebug() then
        print("[SpatialRefugeIntegrity] ValidateAndRepair triggered by: " .. source)
    end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    
    -- Only server/SP can do full repairs
    local canRepair = canModifyData()
    
    -- Step 1: Ensure single relic (remove duplicates)
    local relic
    if canRepair then
        relic = ensureSingleRelic(refugeData, report)
    end
    
    -- Step 2: Find relic if not found by duplicate check
    if not relic then
        local relicX = refugeData.relicX or centerX
        local relicY = refugeData.relicY or centerY
        local relicZ = refugeData.relicZ or centerZ
        relic = findRelicReadOnly(relicX, relicY, relicZ, radius, refugeId)
        
        -- Also search from center if not found at stored position
        if not relic and (relicX ~= centerX or relicY ~= centerY) then
            relic = findRelicReadOnly(centerX, centerY, centerZ, radius, refugeId)
        end
    end
    
    if relic then
        report.relic.found = true
        local square = relic:getSquare()
        if square then
            report.relic.position = {
                x = square:getX(),
                y = square:getY(),
                z = square:getZ()
            }
        end
        
        if canRepair then
            -- Step 3: Validate and repair relic ModData
            validateRelicModData(relic, refugeId, report)
            
            -- Step 4: Validate and repair relic sprite
            validateRelicSprite(relic, report)
            
            -- Step 5: Validate relic properties
            validateRelicProperties(relic)
        end
    else
        report.relic.found = false
        if getDebug() then
            print("[SpatialRefugeIntegrity] WARNING: No relic found in refuge")
        end
    end
    
    -- Step 6: Validate walls
    if canRepair then
        validateWalls(refugeData, report)
    end
    
    -- Step 7: Sync everything atomically
    if canRepair and (report.relic.modDataRepaired or report.relic.spriteRepaired or 
                      report.relic.duplicatesRemoved > 0 or #report.modData.fieldsRepaired > 0) then
        syncAll(refugeData, relic, context, report)
    end
    
    if getDebug() then
        print("[SpatialRefugeIntegrity] Complete: relic=" .. tostring(report.relic.found) ..
              " duplicates=" .. report.relic.duplicatesRemoved ..
              " walls=" .. report.walls.repaired ..
              " synced=" .. tostring(report.modData.synced))
    end
    
    return report
end

--- Lightweight check - returns true if repair is needed (read-only)
--- @param refugeData table Player's refuge data
--- @return boolean needsRepair
function SpatialRefugeIntegrity.CheckNeedsRepair(refugeData)
    if not refugeData then return true end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    
    -- Check if relic exists
    local relic, foundBy = findRelicReadOnly(centerX, centerY, centerZ, radius, refugeId)
    
    if not relic then
        return true -- No relic found
    end
    
    -- Check if found by sprite instead of ModData (needs repair)
    if foundBy == "sprite" then
        return true
    end
    
    -- Check if sprite is valid and not the old fallback sprite
    local expectedSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC
    local oldFallbackSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC_FALLBACK
    local currentSprite = relic:getSpriteName()
    if not currentSprite or currentSprite ~= expectedSprite then
        local sprite = relic:getSprite()
        if not sprite or not sprite:getName() then
            return true -- Corrupted sprite
        end
        -- Also needs repair if it's the old fallback sprite
        if oldFallbackSprite and currentSprite == oldFallbackSprite then
            return true -- Old fallback sprite needs migration
        end
    end
    
    -- Check for duplicates (expensive, only do if other checks pass)
    local allRelics = findAllRelicsInArea(centerX, centerY, centerZ, radius, refugeId)
    if #allRelics > 1 then
        return true -- Duplicates exist
    end
    
    return false
end

--- Client-only sprite fix (for MP clients when ModData is correct but sprite is wrong)
--- @param relic IsoObject The relic object to fix
--- @return boolean success
function SpatialRefugeIntegrity.ClientSpriteRepair(relic)
    if not relic then return false end
    
    -- Only run on client
    if isServer() then return false end
    
    local expectedSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC
    local oldFallbackSprite = SpatialRefugeConfig.SPRITES.SACRED_RELIC_FALLBACK
    local currentSprite = relic:getSpriteName()
    
    -- Check if sprite needs repair
    local spriteValid = false
    if currentSprite and relic.getSprite then
        local sprite = relic:getSprite()
        spriteValid = (sprite ~= nil and sprite:getName() == currentSprite)
    end
    
    -- Check if it's the old fallback sprite or corrupted
    local needsRepair = false
    local isOldFallback = false
    
    if not spriteValid then
        needsRepair = true
    elseif currentSprite ~= expectedSprite then
        needsRepair = true
        if oldFallbackSprite and currentSprite == oldFallbackSprite then
            isOldFallback = true
        end
    end
    
    if needsRepair then
        local newSprite = getSprite(expectedSprite)
        if newSprite then
            relic:setSprite(expectedSprite)
            
            -- Also ensure local ModData is set (client-side only, won't sync)
            local md = relic:getModData()
            if not md.isSacredRelic then
                md.isSacredRelic = true
            end
            md.relicSprite = expectedSprite
            
            if getDebug() then
                if isOldFallback then
                    print("[SpatialRefugeIntegrity] Client sprite repair: migrated old fallback sprite")
                else
                    print("[SpatialRefugeIntegrity] Client sprite repair applied")
                end
            end
            return true
        end
    end
    
    return false
end

--- Find relic using the integrity system (read-only)
--- Exposed for use by other modules that need to find relics
--- @param refugeData table Player's refuge data
--- @return IsoObject|nil relic, string|nil foundBy
function SpatialRefugeIntegrity.FindRelic(refugeData)
    if not refugeData then return nil, nil end
    
    local relicX = refugeData.relicX or refugeData.centerX
    local relicY = refugeData.relicY or refugeData.centerY
    local relicZ = refugeData.relicZ or refugeData.centerZ
    local radius = refugeData.radius or 1
    local refugeId = refugeData.refugeId
    
    local relic, foundBy = findRelicReadOnly(relicX, relicY, relicZ, radius, refugeId)
    
    -- Also search from center if not found at stored position
    if not relic then
        relic, foundBy = findRelicReadOnly(refugeData.centerX, refugeData.centerY, refugeData.centerZ, radius, refugeId)
    end
    
    return relic, foundBy
end

return SpatialRefugeIntegrity
