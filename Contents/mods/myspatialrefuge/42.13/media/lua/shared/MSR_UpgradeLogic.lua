-- MSR_UpgradeLogic - Upgrade Logic

require "shared/core/MSR"
require "shared/core/MSR_Env"
require "shared/MSR_UpgradeData"
require "shared/MSR_Transaction"
require "shared/MSR_Config"
require "shared/MSR_Shared"
require "shared/MSR_Data"
require "shared/MSR_RefugeExpansion"
require "shared/MSR_PlayerMessage"
local PM = MSR.PlayerMessage
if MSR.UpgradeLogic and MSR.UpgradeLogic._loaded then
    return MSR.UpgradeLogic
end

MSR.UpgradeLogic = MSR.UpgradeLogic or {}
MSR.UpgradeLogic._loaded = true

local UpgradeLogic = MSR.UpgradeLogic
local TRANSACTION_TYPE_UPGRADE = "REFUGE_FEATURE_UPGRADE"

-- Use shared utility from MSR namespace
local function resolvePlayer(player)
    return MSR.resolvePlayer(player)
end

function UpgradeLogic.getItemSources(player)
    return MSR.Transaction.GetItemSources(player)
end

function UpgradeLogic.getAvailableItemCount(player, requirement)
    if not requirement then return 0 end
    
    -- Use filtered count: excludes favorites, crafting-consumed items, locked items
    -- This ensures UI shows accurate counts matching what can actually be consumed
    local total, _ = MSR.Transaction.GetSubstitutionCount(player, requirement, true)
    return total
end

function UpgradeLogic.hasRequiredItems(player, requirements)
    if not requirements or #requirements == 0 then return true end
    
    for _, req in ipairs(requirements) do
        if UpgradeLogic.getAvailableItemCount(player, req) < (req.count or 1) then
            return false
        end
    end
    return true
end

function UpgradeLogic.canPurchaseUpgrade(player, upgradeId, targetLevel)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false, "Invalid player" end
    
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return false, "Unknown upgrade" end
    if not MSR.UpgradeData.isUpgradeUnlocked(playerObj, upgradeId) then return false, "Dependencies not met" end
    
    local currentLevel = MSR.UpgradeData.getPlayerUpgradeLevel(playerObj, upgradeId)
    targetLevel = targetLevel or (currentLevel + 1)
    
    if targetLevel <= currentLevel then return false, "Already at this level" end
    if targetLevel > upgrade.maxLevel then return false, "Exceeds max level" end
    if targetLevel > currentLevel + 1 then return false, "Must upgrade one level at a time" end
    
    local levelData = MSR.UpgradeData.getLevelData(upgradeId, targetLevel)
    if not levelData then return false, "Invalid level data" end
    
    -- Use getNextLevelRequirements for difficulty-scaled costs
    local requirements = MSR.UpgradeData.getNextLevelRequirements(playerObj, upgradeId)
    if not UpgradeLogic.hasRequiredItems(playerObj, requirements or {}) then
        return false, "Missing required items"
    end
    
    return true, nil
end

function UpgradeLogic.purchaseUpgrade(player, upgradeId, targetLevel)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false, "Invalid player" end
    
    L.debug("Upgrade", "purchaseUpgrade: " .. tostring(upgradeId) .. " level " .. tostring(targetLevel))
    
    local canPurchase, err = UpgradeLogic.canPurchaseUpgrade(playerObj, upgradeId, targetLevel)
    if not canPurchase then
        L.debug("Upgrade", "CANNOT purchase - " .. tostring(err))
        return false, err
    end
    
    -- Use getNextLevelRequirements for difficulty-scaled costs
    local requirements = MSR.UpgradeData.getNextLevelRequirements(playerObj, upgradeId) or {}
    
    if MSR.Env.isMultiplayerClient() then
        return UpgradeLogic.purchaseUpgradeMP(playerObj, upgradeId, targetLevel, requirements)
    else
        return UpgradeLogic.purchaseUpgradeSP(playerObj, upgradeId, targetLevel, requirements)
    end
end

function UpgradeLogic.purchaseUpgradeSP(player, upgradeId, targetLevel, requirements)
    if not UpgradeLogic.consumeItems(player, requirements) then
        return false, "Failed to consume items"
    end
    
    if upgradeId == "expand_refuge" then
        local refugeData = MSR.Data.GetRefugeData(player)
        if not refugeData then return false, "Refuge data not found" end
        
        -- Use shared expansion module
        local success, errorMsg, resultData = MSR.RefugeExpansion.Execute(player, refugeData)
        if not success then
            return false, errorMsg or "Expansion failed"
        end
        
        -- Show tier-specific message
        if resultData.tierConfig then
            PM.Say(player, PM.REFUGE_UPGRADED_TO, resultData.tierConfig.displayName)
        end
    else
        MSR.UpgradeData.setPlayerUpgradeLevel(player, upgradeId, targetLevel)
        UpgradeLogic.applyUpgradeEffects(player, upgradeId, targetLevel)
    end
    
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    PM.Say(player, PM.UPGRADED_TO_LEVEL, name, targetLevel)
    
    return true, nil
end

function UpgradeLogic.purchaseUpgradeMP(player, upgradeId, targetLevel, requirements)
    local transaction, err = MSR.Transaction.Begin(player, TRANSACTION_TYPE_UPGRADE, requirements)
    if not transaction then
        return false, err or "Failed to start transaction"
    end
    
    -- Collect locked item IDs for server verification (ID-based consumption)
    -- This enables precise server-side consumption by specific item IDs
    local lockedItemIds = {}
    for itemType, data in pairs(transaction.lockedItems) do
        lockedItemIds[itemType] = data.itemIds
        L.debug("Upgrade", "[DEBUG] purchaseUpgradeMP: Sending " .. #data.itemIds .. " item IDs for " .. itemType)
    end
    
    L.debug("Upgrade", "[DEBUG] purchaseUpgradeMP: Transaction " .. transaction.id .. " with " .. K.count(lockedItemIds) .. " item types")
    
    sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_FEATURE_UPGRADE, {
        upgradeId = upgradeId,
        targetLevel = targetLevel,
        transactionId = transaction.id,
        lockedItemIds = lockedItemIds  -- Send specific item IDs for server consumption
    })
    
    PM.Say(player, PM.UPGRADING)
    return true, nil
end

function UpgradeLogic.consumeItems(player, requirements)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false end
    
    local resolved = MSR.Transaction.ResolveSubstitutions(playerObj, requirements)
    if not resolved then return false end
    
    local sources = MSR.Transaction.GetItemSources(playerObj)
    if not sources or #sources == 0 then return false end
    
    local needsSync = MSR.Env.needsClientSync() and sendRemoveItemFromContainer
    
    for itemType, count in pairs(resolved) do
        local remaining = count
        
        for _, container in ipairs(sources) do
            if remaining <= 0 then break end
            local items = container and container:getItems()
            if K.isIterable(items) then
                for i = K.size(items) - 1, 0, -1 do
                    if remaining <= 0 then break end
                    local item = items:get(i)
                    if item and item:getFullType() == itemType then
                        container:Remove(item)
                        if needsSync then sendRemoveItemFromContainer(container, item) end
                        remaining = remaining - 1
                    end
                end
            end
        end
        
        if remaining > 0 then return false end
    end
    
    return true
end

function UpgradeLogic.applyUpgradeEffects(player, upgradeId, level)
    local effects = MSR.UpgradeData.getLevelEffects(upgradeId, level)
    if not effects then return end
    
    L.debug("Upgrade", "Applied effects for " .. upgradeId .. " level " .. level)
end

function UpgradeLogic.getPlayerEffect(player, effectName)
    local effects = MSR.UpgradeData.getPlayerActiveEffects(player)
    return effects[effectName] or 0
end

function UpgradeLogic.onUpgradeComplete(player, upgradeId, targetLevel, transactionId)
    local playerObj = resolvePlayer(player)
    if not playerObj then return end
    
    -- Handle transaction completion:
    -- - MP client: Finalize (server already consumed items, just clear local locks)
    -- - SP/Coop host: Commit (consume items locally)
    if transactionId then
        if MSR.Env.isMultiplayerClient() then
            MSR.Transaction.Finalize(playerObj, transactionId)
        else
            MSR.Transaction.Commit(playerObj, transactionId)
        end
    end
    
    if upgradeId == "expand_refuge" then
        if MSR.InvalidateBoundsCache then MSR.InvalidateBoundsCache(playerObj) end
    else
        -- Set upgrade level in local state
        -- For MP clients: ModData cache was already updated with server's refugeData before this function is called,
        -- but we still call setPlayerUpgradeLevel to ensure the upgradeData object is properly set for immediate use
        -- (e.g., reading speed calculations need the level to be available right away).
        -- SaveRefugeData call inside setPlayerUpgradeLevel is a no-op on MP clients (only server can save).
        -- For SP: This saves to GlobalModData and updates local state.
        MSR.UpgradeData.setPlayerUpgradeLevel(playerObj, upgradeId, targetLevel)
        UpgradeLogic.applyUpgradeEffects(playerObj, upgradeId, targetLevel)
    end
    
    if MSR.InvalidateRelicContainerCache then MSR.InvalidateRelicContainerCache() end
    
    if MSR.Env.isClient() then
        if ISInventoryPage and ISInventoryPage.dirtyUI then ISInventoryPage.dirtyUI() end
        
        local MSR_UpgradeWindow = require "MSR_UpgradeWindow"
        if MSR_UpgradeWindow and MSR_UpgradeWindow.instance then
            MSR_UpgradeWindow.instance:refreshUpgradeList()
            MSR_UpgradeWindow.instance:refreshCurrentUpgrade()
        end
    end
    
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    PM.Say(playerObj, PM.UPGRADED_TO_LEVEL, name, targetLevel)
end

function UpgradeLogic.onUpgradeError(player, transactionId, reason)
    local playerObj = resolvePlayer(player)
    if not playerObj then return end
    
    if transactionId then
        MSR.Transaction.Rollback(playerObj, transactionId)
    end
    
    if reason then
        PM.SayRaw(playerObj, reason)
    else
        PM.Say(playerObj, PM.UPGRADE_FAILED)
    end
end

return MSR.UpgradeLogic

