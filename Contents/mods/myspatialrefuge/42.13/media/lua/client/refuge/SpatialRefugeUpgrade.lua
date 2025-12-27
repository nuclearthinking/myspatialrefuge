-- Spatial Refuge Upgrade Mechanics
-- Handles tier upgrades with core consumption and expansion

-- Dependencies are loaded by main loader - assert they exist
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-- Verify required dependencies are loaded
assert(SpatialRefuge.GetRefugeData, "[SpatialRefuge] SpatialRefugeMain not loaded")
assert(SpatialRefuge.ExpandRefuge, "[SpatialRefuge] SpatialRefugeGeneration not loaded")
assert(SpatialRefuge.CountCores, "[SpatialRefuge] SpatialRefugeContext not loaded")

-- Find Sacred Relic in the refuge area
local function findSacredRelicInRefuge(refugeData)
    if not refugeData then return nil end
    
    local cell = getCell()
    if not cell then return nil end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 2
    
    -- Search the refuge area for the relic
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, centerZ)
            if square then
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj and obj.getModData then
                            local md = obj:getModData()
                            if md and md.isSacredRelic then
                                return obj
                            end
                        end
                    end
                end
            end
        end
    end
    
    return nil
end

-- Perform refuge upgrade
-- Returns: true if successful, false otherwise
function SpatialRefuge.PerformUpgrade(player, refugeData, newTier)
    if not player or not refugeData then return false end
    
    local tierConfig = SpatialRefugeConfig.TIERS[newTier]
    if not tierConfig then return false end
    
    -- Find the Sacred Relic before expansion (to reposition after)
    local relic = findSacredRelicInRefuge(refugeData)
    
    -- Expand the refuge (creates new floor tiles and walls)
    local success = SpatialRefuge.ExpandRefuge(refugeData, newTier)
    
    if not success then
        player:Say("Failed to expand refuge!")
        return false
    end
    
    -- Invalidate cached boundary data so player can move in expanded area
    if SpatialRefuge.InvalidateBoundsCache then
        SpatialRefuge.InvalidateBoundsCache(player)
    end
    
    -- Reposition relic to assigned corner if it has one
    if relic and SpatialRefuge.RepositionRelicToAssignedCorner then
        SpatialRefuge.RepositionRelicToAssignedCorner(relic, refugeData)
    end
    
    return true
end

-- Override the upgrade callback from context menu
function SpatialRefuge.OnUpgradeRefuge(player)
    if not player then return end
    
    -- Handle player index vs player object
    local playerObj = player
    if type(player) == "number" then
        playerObj = getSpecificPlayer(player)
    end
    if not playerObj then return end
    
    local refugeData = SpatialRefuge.GetRefugeData(playerObj)
    if not refugeData then
        playerObj:Say("Refuge data not found!")
        return
    end
    
    local currentTier = refugeData.tier
    local nextTier = currentTier + 1
    
    if nextTier > SpatialRefugeConfig.MAX_TIER then
        playerObj:Say("Already at max tier!")
        return
    end
    
    local tierConfig = SpatialRefugeConfig.TIERS[nextTier]
    local coreCost = tierConfig.cores
    
    -- Check if player has enough cores
    if SpatialRefuge.CountCores(playerObj) < coreCost then
        playerObj:Say("Not enough cores!")
        return
    end
    
    -- Consume cores
    if not SpatialRefuge.ConsumeCores(playerObj, coreCost) then
        playerObj:Say("Failed to consume cores!")
        return
    end
    
    -- Perform upgrade
    if SpatialRefuge.PerformUpgrade(playerObj, refugeData, nextTier) then
        playerObj:Say("Refuge upgraded successfully!")
    else
        -- Refund cores if upgrade failed
        local inv = playerObj:getInventory()
        if inv then
            for i = 1, coreCost do
                inv:AddItem(SpatialRefugeConfig.CORE_ITEM)
            end
        end
        playerObj:Say("Upgrade failed - cores refunded")
    end
end

return SpatialRefuge

