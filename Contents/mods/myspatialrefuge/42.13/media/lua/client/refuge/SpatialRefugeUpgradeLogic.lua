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
        return false, "Invalid player"
    end
    
    -- Validate
    local canPurchase, err = SpatialRefugeUpgradeLogic.canPurchaseUpgrade(playerObj, upgradeId, targetLevel)
    if not canPurchase then
        return false, err
    end
    
    -- Get requirements
    local levelData = SpatialRefugeUpgradeData.getLevelData(upgradeId, targetLevel)
    local requirements = levelData.requirements or {}
    
    if isMultiplayerClient() then
        -- Multiplayer: Use transaction system
        return SpatialRefugeUpgradeLogic.purchaseUpgradeMP(playerObj, upgradeId, targetLevel, requirements)
    else
        -- Singleplayer: Direct purchase
        return SpatialRefugeUpgradeLogic.purchaseUpgradeSP(playerObj, upgradeId, targetLevel, requirements)
    end
end

-- Singleplayer purchase flow
function SpatialRefugeUpgradeLogic.purchaseUpgradeSP(player, upgradeId, targetLevel, requirements)
    -- Consume items directly
    local success = SpatialRefugeUpgradeLogic.consumeItems(player, requirements)
    if not success then
        return false, "Failed to consume items"
    end
    
    -- Update player level
    SpatialRefugeUpgradeData.setPlayerUpgradeLevel(player, upgradeId, targetLevel)
    
    -- Apply effects
    SpatialRefugeUpgradeLogic.applyUpgradeEffects(player, upgradeId, targetLevel)
    
    -- Notify player
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    if player and player.Say then
        player:Say(string.format("Upgraded %s to level %d!", name, targetLevel))
    end
    
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
    
    -- Get inventory
    local inv = playerObj:getInventory()
    if not inv then return false end
    
    -- Consume each item type
    for itemType, count in pairs(resolved) do
        local remaining = count
        local items = inv:getItems()
        
        for i = items:size() - 1, 0, -1 do
            if remaining <= 0 then break end
            
            local item = items:get(i)
            if item and item:getFullType() == itemType then
                inv:Remove(item)
                remaining = remaining - 1
            end
        end
        
        if remaining > 0 then
            -- Failed to consume all items - should not happen if validation passed
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
    local playerObj = resolvePlayer(player)
    if not playerObj then return end
    
    -- Commit transaction (consume locked items)
    if transactionId then
        SpatialRefugeTransaction.Commit(playerObj, transactionId)
    end
    
    -- Update player level
    SpatialRefugeUpgradeData.setPlayerUpgradeLevel(playerObj, upgradeId, targetLevel)
    
    -- Apply effects
    SpatialRefugeUpgradeLogic.applyUpgradeEffects(playerObj, upgradeId, targetLevel)
    
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
end

-- Called when server reports error
function SpatialRefugeUpgradeLogic.onUpgradeError(player, transactionId, reason)
    local playerObj = resolvePlayer(player)
    if not playerObj then return end
    
    -- Rollback transaction (unlock items)
    if transactionId then
        SpatialRefugeTransaction.Rollback(playerObj, transactionId)
    end
    
    -- Notify player
    if playerObj and playerObj.Say then
        playerObj:Say(reason or "Upgrade failed")
    end
end

-----------------------------------------------------------
-- Module Export
-----------------------------------------------------------

print("[SpatialRefugeUpgradeLogic] Upgrade logic loaded")

return SpatialRefugeUpgradeLogic

