-- Spatial Refuge Upgrade Logic
-- Business logic for the upgrade system
-- Handles item checking, purchase flow, and transaction management

require "shared/SpatialRefugeUpgradeData"
require "shared/SpatialRefugeTransaction"
require "shared/SpatialRefugeConfig"

-- Prevent double-loading
if SpatialRefugeUpgradeLogic and SpatialRefugeUpgradeLogic._loaded then
    return SpatialRefugeUpgradeLogic
end

SpatialRefugeUpgradeLogic = {
    _loaded = true
}

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

local TRANSACTION_TYPE_UPGRADE = "REFUGE_FEATURE_UPGRADE"

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

-- Resolve player reference
local function resolvePlayer(player)
    if not player then return nil end
    
    if type(player) == "number" and getSpecificPlayer then
        return getSpecificPlayer(player)
    end
    
    if (type(player) == "userdata" or type(player) == "table") and player.getPlayerNum and getSpecificPlayer then
        local ok, num = pcall(function() return player:getPlayerNum() end)
        if ok and num ~= nil then
            local resolved = getSpecificPlayer(num)
            if resolved then
                return resolved
            end
        end
    end
    
    return player
end

-- Check if we're in multiplayer client mode
local _cachedIsMPClient = nil
local function isMultiplayerClient()
    if _cachedIsMPClient == nil then
        _cachedIsMPClient = isClient() and not isServer()
    end
    return _cachedIsMPClient
end

-----------------------------------------------------------
-- Item Source Management
-----------------------------------------------------------

-- Get all containers to check for items
function SpatialRefugeUpgradeLogic.getItemSources(player)
    return SpatialRefugeTransaction.GetItemSources(player)
end

-- Get total available count for a requirement (with substitutes)
function SpatialRefugeUpgradeLogic.getAvailableItemCount(player, requirement)
    if not requirement then return 0 end
    
    local total, _ = SpatialRefugeTransaction.GetSubstitutionCount(player, requirement)
    return total
end

-- Check if player has all required items for an upgrade level
function SpatialRefugeUpgradeLogic.hasRequiredItems(player, requirements)
    if not requirements or #requirements == 0 then
        return true
    end
    
    for _, req in ipairs(requirements) do
        local available = SpatialRefugeUpgradeLogic.getAvailableItemCount(player, req)
        local needed = req.count or 1
        
        if available < needed then
            return false
        end
    end
    
    return true
end

-----------------------------------------------------------
-- Upgrade Validation
-----------------------------------------------------------

-- Check if player can purchase an upgrade
function SpatialRefugeUpgradeLogic.canPurchaseUpgrade(player, upgradeId, targetLevel)
    local playerObj = resolvePlayer(player)
    if not playerObj then
        return false, "Invalid player"
    end
    
    -- Check if upgrade exists
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    if not upgrade then
        return false, "Unknown upgrade"
    end
    
    -- Check dependencies
    if not SpatialRefugeUpgradeData.isUpgradeUnlocked(playerObj, upgradeId) then
        return false, "Dependencies not met"
    end
    
    -- Check current level
    local currentLevel = SpatialRefugeUpgradeData.getPlayerUpgradeLevel(playerObj, upgradeId)
    
    -- Determine target level
    if not targetLevel then
        targetLevel = currentLevel + 1
    end
    
    -- Validate target level
    if targetLevel <= currentLevel then
        return false, "Already at this level"
    end
    
    if targetLevel > upgrade.maxLevel then
        return false, "Exceeds max level"
    end
    
    -- Can only upgrade one level at a time
    if targetLevel > currentLevel + 1 then
        return false, "Must upgrade one level at a time"
    end
    
    -- Get level requirements
    local levelData = SpatialRefugeUpgradeData.getLevelData(upgradeId, targetLevel)
    if not levelData then
        return false, "Invalid level data"
    end
    
    -- Check items
    local requirements = levelData.requirements or {}
    if not SpatialRefugeUpgradeLogic.hasRequiredItems(playerObj, requirements) then
        return false, "Missing required items"
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Upgrade Purchase
-----------------------------------------------------------

-- Purchase an upgrade (main entry point)
function SpatialRefugeUpgradeLogic.purchaseUpgrade(player, upgradeId, targetLevel)
    local playerObj = resolvePlayer(player)
    if not playerObj then
        print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Invalid player")
        return false, "Invalid player"
    end
    
    print("[SpatialRefugeUpgradeLogic] ========================================")
    print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: " .. tostring(upgradeId) .. " level " .. tostring(targetLevel))
    
    -- Validate
    local canPurchase, err = SpatialRefugeUpgradeLogic.canPurchaseUpgrade(playerObj, upgradeId, targetLevel)
    if not canPurchase then
        print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: CANNOT purchase - " .. tostring(err))
        return false, err
    end
    print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Validation passed")
    
    -- Get requirements
    local levelData = SpatialRefugeUpgradeData.getLevelData(upgradeId, targetLevel)
    local requirements = levelData.requirements or {}
    
    print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Requirements count = " .. #requirements)
    for i, req in ipairs(requirements) do
        print("[SpatialRefugeUpgradeLogic]   Req " .. i .. ": " .. tostring(req.type) .. " x" .. tostring(req.count))
    end
    
    if isMultiplayerClient() then
        -- Multiplayer: Use transaction system
        print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Using MP flow")
        return SpatialRefugeUpgradeLogic.purchaseUpgradeMP(playerObj, upgradeId, targetLevel, requirements)
    else
        -- Singleplayer: Direct purchase
        print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Using SP flow")
        return SpatialRefugeUpgradeLogic.purchaseUpgradeSP(playerObj, upgradeId, targetLevel, requirements)
    end
end

-- Singleplayer purchase flow
function SpatialRefugeUpgradeLogic.purchaseUpgradeSP(player, upgradeId, targetLevel, requirements)
    print("[SpatialRefugeUpgradeLogic] SP: Starting singleplayer purchase")
    
    -- Consume items directly
    local success = SpatialRefugeUpgradeLogic.consumeItems(player, requirements)
    if not success then
        print("[SpatialRefugeUpgradeLogic] SP: FAILED to consume items")
        return false, "Failed to consume items"
    end
    print("[SpatialRefugeUpgradeLogic] SP: Items consumed successfully")
    
    -- Special case: expand_refuge triggers the refuge expansion system
    if upgradeId == "expand_refuge" then
        print("[SpatialRefugeUpgradeLogic] SP: Processing expand_refuge")
        
        -- Get refuge data
        local refugeData = SpatialRefuge.GetRefugeData(player)
        if not refugeData then
            print("[SpatialRefugeUpgradeLogic] SP: ERROR - No refuge data found")
            return false, "Refuge data not found"
        end
        
        local currentTier = refugeData.tier or 0
        local nextTier = currentTier + 1
        print("[SpatialRefugeUpgradeLogic] SP: Tier " .. currentTier .. " -> " .. nextTier)
        
        -- Call PerformUpgrade directly (cores already consumed by consumeItems above)
        if SpatialRefuge and SpatialRefuge.PerformUpgrade then
            local success = SpatialRefuge.PerformUpgrade(player, refugeData, nextTier)
            if success then
                print("[SpatialRefugeUpgradeLogic] SP: PerformUpgrade SUCCESS")
                local tierConfig = SpatialRefugeConfig.TIERS[nextTier]
                if tierConfig and player and player.Say then
                    player:Say("Refuge upgraded to " .. tierConfig.displayName .. "!")
                end
            else
                print("[SpatialRefugeUpgradeLogic] SP: PerformUpgrade FAILED")
                return false, "Expansion failed"
            end
        else
            print("[SpatialRefugeUpgradeLogic] SP: WARNING - SpatialRefuge.PerformUpgrade not available!")
            return false, "Upgrade system not available"
        end
    else
        -- Standard upgrade: Update player level
        print("[SpatialRefugeUpgradeLogic] SP: Setting upgrade level")
        SpatialRefugeUpgradeData.setPlayerUpgradeLevel(player, upgradeId, targetLevel)
        
        -- Apply effects
        SpatialRefugeUpgradeLogic.applyUpgradeEffects(player, upgradeId, targetLevel)
    end
    
    -- Notify player
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    if player and player.Say then
        player:Say(string.format("Upgraded %s to level %d!", name, targetLevel))
    end
    
    print("[SpatialRefugeUpgradeLogic] SP: Purchase complete")
    return true, nil
end

-- Multiplayer purchase flow
function SpatialRefugeUpgradeLogic.purchaseUpgradeMP(player, upgradeId, targetLevel, requirements)
    -- Begin transaction with substitutions
    local transaction, err = SpatialRefugeTransaction.BeginWithSubstitutions(
        player,
        TRANSACTION_TYPE_UPGRADE,
        requirements
    )
    
    if not transaction then
        return false, err or "Failed to start transaction"
    end
    
    -- Send request to server
    local args = {
        upgradeId = upgradeId,
        targetLevel = targetLevel,
        transactionId = transaction.id
    }
    
    sendClientCommand(
        SpatialRefugeConfig.COMMAND_NAMESPACE,
        "RequestFeatureUpgrade",
        args
    )
    
    if player and player.Say then
        player:Say("Upgrading...")
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Item Consumption
-----------------------------------------------------------

-- Consume items for an upgrade (singleplayer only)
function SpatialRefugeUpgradeLogic.consumeItems(player, requirements)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false end
    
    -- Resolve which specific items to consume
    local resolved, err = SpatialRefugeTransaction.ResolveSubstitutions(playerObj, requirements)
    if not resolved then
        return false
    end
    
    -- Get all item sources (inventory + relic container)
    local sources = SpatialRefugeTransaction.GetItemSources(playerObj)
    if not sources or #sources == 0 then return false end
    
    -- Consume each item type from all available sources
    for itemType, count in pairs(resolved) do
        local remaining = count
        
        -- Try each source until we have enough items
        for _, container in ipairs(sources) do
            if remaining <= 0 then break end
            if not container then
                -- Skip invalid container
            else
                local items = container:getItems()
                if items then
                    -- Iterate backwards to safely remove items
                    for i = items:size() - 1, 0, -1 do
                        if remaining <= 0 then break end
                        
                        local item = items:get(i)
                        if item and item:getFullType() == itemType then
                            container:Remove(item)
                            remaining = remaining - 1
                        end
                    end
                end
            end
        end
        
        if remaining > 0 then
            -- Failed to consume all items - should not happen if validation passed
            print("[SpatialRefugeUpgradeLogic] consumeItems: Failed to consume " .. tostring(remaining) .. " of " .. tostring(itemType))
            return false
        end
    end
    
    return true
end

-----------------------------------------------------------
-- Effect Application
-----------------------------------------------------------

-- Apply upgrade effects to player
function SpatialRefugeUpgradeLogic.applyUpgradeEffects(player, upgradeId, level)
    -- Effects are stored in moddata and checked when relevant
    -- This function is called after a successful upgrade
    
    local effects = SpatialRefugeUpgradeData.getLevelEffects(upgradeId, level)
    if not effects then return end
    
    -- Log effects for debugging
    if getDebug and getDebug() then
        print("[SpatialRefugeUpgradeLogic] Applied effects for " .. upgradeId .. " level " .. level .. ":")
        for name, value in pairs(effects) do
            print("  - " .. name .. ": " .. tostring(value))
        end
    end
    
    -- Specific effect handlers can be added here
    -- For now, effects are passively stored and queried via getPlayerActiveEffects
end

-- Get a specific effect value for a player
function SpatialRefugeUpgradeLogic.getPlayerEffect(player, effectName)
    local effects = SpatialRefugeUpgradeData.getPlayerActiveEffects(player)
    return effects[effectName] or 0
end

-----------------------------------------------------------
-- Transaction Callbacks (for multiplayer)
-----------------------------------------------------------

-- Called when server confirms upgrade
function SpatialRefugeUpgradeLogic.onUpgradeComplete(player, upgradeId, targetLevel, transactionId)
    print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: ========================================")
    print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: upgradeId=" .. tostring(upgradeId))
    print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: targetLevel=" .. tostring(targetLevel))
    print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: transactionId=" .. tostring(transactionId))
    
    local playerObj = resolvePlayer(player)
    if not playerObj then 
        print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: ERROR - No player")
        return 
    end
    
    -- Commit transaction (consume locked items)
    if transactionId then
        print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: Committing transaction")
        SpatialRefugeTransaction.Commit(playerObj, transactionId)
    end
    
    -- Special case: expand_refuge triggers the refuge expansion system
    if upgradeId == "expand_refuge" then
        -- Server already handled the tier upgrade and expansion
        print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: expand_refuge - server handled expansion")
        
        -- CRITICAL: Invalidate cached boundary bounds so player can move in expanded area
        if SpatialRefuge and SpatialRefuge.InvalidateBoundsCache then
            print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: Invalidating bounds cache for MP")
            SpatialRefuge.InvalidateBoundsCache(playerObj)
        end
        
        -- Notify about the new tier
        local refugeData = SpatialRefuge and SpatialRefuge.GetRefugeData and SpatialRefuge.GetRefugeData(playerObj)
        if refugeData then
            local tierConfig = SpatialRefugeConfig.TIERS[refugeData.tier]
            if tierConfig then
                print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: New tier=" .. tostring(refugeData.tier) .. " size=" .. tostring(tierConfig.size))
            end
        end
    else
        -- Standard upgrade: Update player level
        print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: Setting upgrade level")
        SpatialRefugeUpgradeData.setPlayerUpgradeLevel(playerObj, upgradeId, targetLevel)
        
        -- Apply effects
        SpatialRefugeUpgradeLogic.applyUpgradeEffects(playerObj, upgradeId, targetLevel)
    end
    
    -- Refresh UI if open
    local SpatialRefugeUpgradeWindow = require "refuge/SpatialRefugeUpgradeWindow"
    if SpatialRefugeUpgradeWindow.instance then
        SpatialRefugeUpgradeWindow.instance:refreshUpgradeList()
        SpatialRefugeUpgradeWindow.instance:refreshCurrentUpgrade()
    end
    
    -- Notify player
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    if playerObj and playerObj.Say then
        playerObj:Say(string.format("Upgraded %s to level %d!", name, targetLevel))
    end
    print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: Done")
end

-- Called when server reports error
function SpatialRefugeUpgradeLogic.onUpgradeError(player, transactionId, reason)
    print("[SpatialRefugeUpgradeLogic] onUpgradeError: ========================================")
    print("[SpatialRefugeUpgradeLogic] onUpgradeError: transactionId=" .. tostring(transactionId))
    print("[SpatialRefugeUpgradeLogic] onUpgradeError: reason=" .. tostring(reason))
    
    local playerObj = resolvePlayer(player)
    if not playerObj then 
        print("[SpatialRefugeUpgradeLogic] onUpgradeError: ERROR - No player")
        return 
    end
    
    -- Rollback transaction (unlock items)
    if transactionId then
        print("[SpatialRefugeUpgradeLogic] onUpgradeError: Rolling back transaction")
        local success = SpatialRefugeTransaction.Rollback(playerObj, transactionId)
        if success then
            print("[SpatialRefugeUpgradeLogic] onUpgradeError: Rollback SUCCESS - items unlocked")
        else
            print("[SpatialRefugeUpgradeLogic] onUpgradeError: Rollback FAILED - transaction not found or already committed")
        end
    end
    
    -- Notify player
    if playerObj and playerObj.Say then
        playerObj:Say(reason or "Upgrade failed")
    end
    print("[SpatialRefugeUpgradeLogic] onUpgradeError: Done")
end

-----------------------------------------------------------
-- Module Export
-----------------------------------------------------------

print("[SpatialRefugeUpgradeLogic] Upgrade logic loaded")

return SpatialRefugeUpgradeLogic

