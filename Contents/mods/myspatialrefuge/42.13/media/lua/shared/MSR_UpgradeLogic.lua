-- MSR_UpgradeLogic - Upgrade Logic

require "shared/MSR"
require "shared/MSR_Env"
require "shared/MSR_UpgradeData"
require "shared/MSR_Transaction"
require "shared/MSR_Config"
require "shared/MSR_Shared"
require "shared/MSR_Data"
if MSR.UpgradeLogic and MSR.UpgradeLogic._loaded then
    return MSR.UpgradeLogic
end

MSR.UpgradeLogic = MSR.UpgradeLogic or {}
MSR.UpgradeLogic._loaded = true

local UpgradeLogic = MSR.UpgradeLogic
local TRANSACTION_TYPE_UPGRADE = "REFUGE_FEATURE_UPGRADE"

local function resolvePlayer(player)
    if not player then return nil end
    if type(player) == "number" and getSpecificPlayer then
        return getSpecificPlayer(player)
    end
    if (type(player) == "userdata" or type(player) == "table") and player.getPlayerNum then
        local ok, num = pcall(player.getPlayerNum, player)
        if ok and num ~= nil then
            return getSpecificPlayer(num) or player
        end
    end
    return player
end

function UpgradeLogic.getItemSources(player)
    return MSR.Transaction.GetItemSources(player)
end

function UpgradeLogic.getAvailableItemCount(player, requirement)
    if not requirement then return 0 end
    
    local total, _ = MSR.Transaction.GetSubstitutionCount(player, requirement)
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
    
    if not UpgradeLogic.hasRequiredItems(playerObj, levelData.requirements or {}) then
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
    
    local levelData = MSR.UpgradeData.getLevelData(upgradeId, targetLevel)
    local requirements = levelData.requirements or {}
    
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
        
        local currentTier = refugeData.tier or 0
        local nextTier = currentTier + 1
        local oldRadius = refugeData.radius or 1
        
        local expandSuccess = MSR.Shared.ExpandRefuge(refugeData, nextTier, player)
        if not expandSuccess then return false, "Expansion failed" end
        
        local relic = MSR.Shared.FindRelicInRefuge(
            refugeData.centerX, refugeData.centerY, refugeData.centerZ,
            oldRadius, refugeData.refugeId
        )
        if relic then
            local md = relic:getModData()
            if md and md.assignedCorner then
                local moveSuccess = MSR.Shared.MoveRelic(refugeData, md.assignedCornerDx or 0, md.assignedCornerDy or 0, md.assignedCorner, relic)
                if moveSuccess then
                    refugeData.relicX = refugeData.centerX + ((md.assignedCornerDx or 0) * refugeData.radius)
                    refugeData.relicY = refugeData.centerY + ((md.assignedCornerDy or 0) * refugeData.radius)
                    refugeData.relicZ = refugeData.centerZ
                end
            end
        end
        
        MSR.Data.SaveRefugeData(refugeData)
        if MSR.InvalidateBoundsCache then MSR.InvalidateBoundsCache(player) end
        
        local tierConfig = MSR.Config.TIERS[nextTier]
        if tierConfig and player.Say then
            player:Say(string.format(getText("IGUI_RefugeUpgradedTo"), tierConfig.displayName))
        end
    else
        MSR.UpgradeData.setPlayerUpgradeLevel(player, upgradeId, targetLevel)
        UpgradeLogic.applyUpgradeEffects(player, upgradeId, targetLevel)
    end
    
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    if player.Say then
        player:Say(string.format(getText("IGUI_UpgradedToLevel"), name, targetLevel))
    end
    
    return true, nil
end

function UpgradeLogic.purchaseUpgradeMP(player, upgradeId, targetLevel, requirements)
    local transaction, err = MSR.Transaction.Begin(player, TRANSACTION_TYPE_UPGRADE, requirements)
    if not transaction then
        return false, err or "Failed to start transaction"
    end
    
    sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_FEATURE_UPGRADE, {
        upgradeId = upgradeId,
        targetLevel = targetLevel,
        transactionId = transaction.id
    })
    
    if player.Say then player:Say(getText("IGUI_Upgrading")) end
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
    
    -- MP client: rollback local locks (server already consumed). SP: commit locally.
    if transactionId then
        if MSR.Env.isMultiplayerClient() then
            MSR.Transaction.Rollback(playerObj, transactionId)
        else
            MSR.Transaction.Commit(playerObj, transactionId)
        end
    end
    
    if upgradeId == "expand_refuge" then
        if MSR.InvalidateBoundsCache then MSR.InvalidateBoundsCache(playerObj) end
    else
        MSR.UpgradeData.setPlayerUpgradeLevel(playerObj, upgradeId, targetLevel)
        UpgradeLogic.applyUpgradeEffects(playerObj, upgradeId, targetLevel)
    end
    
    if MSR.InvalidateRelicContainerCache then MSR.InvalidateRelicContainerCache() end
    
    if MSR.Env.isClient() then
        if ISInventoryPage and ISInventoryPage.dirtyUI then ISInventoryPage.dirtyUI() end
        
        local MSR_UpgradeWindow = require "refuge/MSR_UpgradeWindow"
        if MSR_UpgradeWindow and MSR_UpgradeWindow.instance then
            MSR_UpgradeWindow.instance:refreshUpgradeList()
            MSR_UpgradeWindow.instance:refreshCurrentUpgrade()
        end
    end
    
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    if playerObj.Say then
        playerObj:Say(string.format(getText("IGUI_UpgradedToLevel"), name, targetLevel))
    end
end

function UpgradeLogic.onUpgradeError(player, transactionId, reason)
    local playerObj = resolvePlayer(player)
    if not playerObj then return end
    
    if transactionId then
        MSR.Transaction.Rollback(playerObj, transactionId)
    end
    
    if playerObj.Say then
        playerObj:Say(reason or getText("IGUI_UpgradeFailed"))
    end
end

return MSR.UpgradeLogic

