-- MSR_UpgradeLogic - Upgrade Logic
-- Business logic for the upgrade system
-- Handles item checking, purchase flow, and transaction management

require "shared/MSR"
require "shared/MSR_UpgradeData"
require "shared/MSR_Transaction"
require "shared/MSR_Config"
require "shared/MSR_Shared"
require "shared/MSR_Data"

-- Prevent double-loading
if MSR.UpgradeLogic and MSR.UpgradeLogic._loaded then
    return MSR.UpgradeLogic
end

MSR.UpgradeLogic = MSR.UpgradeLogic or {}
MSR.UpgradeLogic._loaded = true

-- Local alias
local UpgradeLogic = MSR.UpgradeLogic

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

local TRANSACTION_TYPE_UPGRADE = "REFUGE_FEATURE_UPGRADE"

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

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

function UpgradeLogic.getItemSources(player)
    return MSR.Transaction.GetItemSources(player)
end

function UpgradeLogic.getAvailableItemCount(player, requirement)
    if not requirement then return 0 end
    
    local total, _ = MSR.Transaction.GetSubstitutionCount(player, requirement)
    return total
end

function UpgradeLogic.hasRequiredItems(player, requirements)
    if not requirements or #requirements == 0 then
        return true
    end
    
    for _, req in ipairs(requirements) do
        local available = UpgradeLogic.getAvailableItemCount(player, req)
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

function UpgradeLogic.canPurchaseUpgrade(player, upgradeId, targetLevel)
    local playerObj = resolvePlayer(player)
    if not playerObj then
        return false, "Invalid player"
    end
    
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    if not upgrade then
        return false, "Unknown upgrade"
    end
    
    if not MSR.UpgradeData.isUpgradeUnlocked(playerObj, upgradeId) then
        return false, "Dependencies not met"
    end
    
    local currentLevel = MSR.UpgradeData.getPlayerUpgradeLevel(playerObj, upgradeId)
    
    if not targetLevel then
        targetLevel = currentLevel + 1
    end
    
    if targetLevel <= currentLevel then
        return false, "Already at this level"
    end
    
    if targetLevel > upgrade.maxLevel then
        return false, "Exceeds max level"
    end
    
    if targetLevel > currentLevel + 1 then
        return false, "Must upgrade one level at a time"
    end
    
    local levelData = MSR.UpgradeData.getLevelData(upgradeId, targetLevel)
    if not levelData then
        return false, "Invalid level data"
    end
    
    local requirements = levelData.requirements or {}
    if not UpgradeLogic.hasRequiredItems(playerObj, requirements) then
        return false, "Missing required items"
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Upgrade Purchase
-----------------------------------------------------------

function UpgradeLogic.purchaseUpgrade(player, upgradeId, targetLevel)
    local playerObj = resolvePlayer(player)
    if not playerObj then
        print("[MSR_UpgradeLogic] purchaseUpgrade: Invalid player")
        return false, "Invalid player"
    end
    
    print("[MSR_UpgradeLogic] ========================================")
    print("[MSR_UpgradeLogic] purchaseUpgrade: " .. tostring(upgradeId) .. " level " .. tostring(targetLevel))
    
    local canPurchase, err = UpgradeLogic.canPurchaseUpgrade(playerObj, upgradeId, targetLevel)
    if not canPurchase then
        print("[MSR_UpgradeLogic] purchaseUpgrade: CANNOT purchase - " .. tostring(err))
        return false, err
    end
    print("[MSR_UpgradeLogic] purchaseUpgrade: Validation passed")
    
    local levelData = MSR.UpgradeData.getLevelData(upgradeId, targetLevel)
    local requirements = levelData.requirements or {}
    
    print("[MSR_UpgradeLogic] purchaseUpgrade: Requirements count = " .. #requirements)
    for i, req in ipairs(requirements) do
        print("[MSR_UpgradeLogic]   Req " .. i .. ": " .. tostring(req.type) .. " x" .. tostring(req.count))
    end
    
    if isMultiplayerClient() then
        print("[MSR_UpgradeLogic] purchaseUpgrade: Using MP flow")
        return UpgradeLogic.purchaseUpgradeMP(playerObj, upgradeId, targetLevel, requirements)
    else
        print("[MSR_UpgradeLogic] purchaseUpgrade: Using SP flow")
        return UpgradeLogic.purchaseUpgradeSP(playerObj, upgradeId, targetLevel, requirements)
    end
end

function UpgradeLogic.purchaseUpgradeSP(player, upgradeId, targetLevel, requirements)
    print("[MSR_UpgradeLogic] SP: Starting singleplayer purchase")
    
    local success = UpgradeLogic.consumeItems(player, requirements)
    if not success then
        print("[MSR_UpgradeLogic] SP: FAILED to consume items")
        return false, "Failed to consume items"
    end
    print("[MSR_UpgradeLogic] SP: Items consumed successfully")
    
    if upgradeId == "expand_refuge" then
        print("[MSR_UpgradeLogic] SP: Processing expand_refuge")
        
        local refugeData = MSR.Data.GetRefugeData(player)
        if not refugeData then
            print("[MSR_UpgradeLogic] SP: ERROR - No refuge data found")
            return false, "Refuge data not found"
        end
        
        local currentTier = refugeData.tier or 0
        local nextTier = currentTier + 1
        local oldRadius = refugeData.radius or 1
        print("[MSR_UpgradeLogic] SP: Tier " .. currentTier .. " -> " .. nextTier)
        
        -- Perform expansion using shared module
        local expandSuccess = MSR.Shared.ExpandRefuge(refugeData, nextTier, player)
        
        if expandSuccess then
            print("[MSR_UpgradeLogic] SP: ExpandRefuge SUCCESS")
            
            -- Handle relic repositioning after expansion (same as server does)
            local relic = MSR.Shared.FindRelicInRefuge(
                refugeData.centerX, refugeData.centerY, refugeData.centerZ,
                oldRadius, -- Use OLD radius - relic is at old corner position
                refugeData.refugeId
            )
            if relic then
                local md = relic:getModData()
                if md and md.assignedCorner then
                    local cornerDx = md.assignedCornerDx or 0
                    local cornerDy = md.assignedCornerDy or 0
                    local moveSuccess, moveMessage = MSR.Shared.MoveRelic(refugeData, cornerDx, cornerDy, md.assignedCorner, relic)
                    
                    if moveSuccess then
                        -- Update relic position in ModData
                        local newRelicX = refugeData.centerX + (cornerDx * refugeData.radius)
                        local newRelicY = refugeData.centerY + (cornerDy * refugeData.radius)
                        refugeData.relicX = newRelicX
                        refugeData.relicY = newRelicY
                        refugeData.relicZ = refugeData.centerZ
                        print("[MSR_UpgradeLogic] SP: Repositioned relic to " .. md.assignedCorner)
                    else
                        print("[MSR_UpgradeLogic] SP: WARNING - Failed to reposition relic: " .. tostring(moveMessage))
                    end
                end
            end
            
            -- Save updated refuge data
            MSR.Data.SaveRefugeData(refugeData)
            
            -- Invalidate cached boundary bounds
            if MSR and MSR.InvalidateBoundsCache then
                MSR.InvalidateBoundsCache(player)
            end
            
            local tierConfig = MSR.Config.TIERS[nextTier]
            if tierConfig and player and player.Say then
                local message = string.format(getText("IGUI_RefugeUpgradedTo"), tierConfig.displayName)
                player:Say(message)
            end
        else
            print("[MSR_UpgradeLogic] SP: ExpandRefuge FAILED")
            return false, "Expansion failed"
        end
    else
        print("[MSR_UpgradeLogic] SP: Setting upgrade level")
        MSR.UpgradeData.setPlayerUpgradeLevel(player, upgradeId, targetLevel)
        UpgradeLogic.applyUpgradeEffects(player, upgradeId, targetLevel)
    end
    
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    if player and player.Say then
        local message = string.format(getText("IGUI_UpgradedToLevel"), name, targetLevel)
        player:Say(message)
    end
    
    print("[MSR_UpgradeLogic] SP: Purchase complete")
    return true, nil
end

function UpgradeLogic.purchaseUpgradeMP(player, upgradeId, targetLevel, requirements)
    local transaction, err = MSR.Transaction.BeginWithSubstitutions(
        player,
        TRANSACTION_TYPE_UPGRADE,
        requirements
    )
    
    if not transaction then
        return false, err or "Failed to start transaction"
    end
    
    local args = {
        upgradeId = upgradeId,
        targetLevel = targetLevel,
        transactionId = transaction.id
    }
    
    sendClientCommand(
        MSR.Config.COMMAND_NAMESPACE,
        MSR.Config.COMMANDS.REQUEST_FEATURE_UPGRADE,
        args
    )
    
    if player and player.Say then
        player:Say(getText("IGUI_Upgrading"))
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Item Consumption
-----------------------------------------------------------

function UpgradeLogic.consumeItems(player, requirements)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false end
    
    local resolved, err = MSR.Transaction.ResolveSubstitutions(playerObj, requirements)
    if not resolved then
        return false
    end
    
    local sources = MSR.Transaction.GetItemSources(playerObj)
    if not sources or #sources == 0 then return false end
    
    for itemType, count in pairs(resolved) do
        local remaining = count
        
        for _, container in ipairs(sources) do
            if remaining <= 0 then break end
            if not container then
            else
                local items = container:getItems()
                if items then
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
            print("[MSR_UpgradeLogic] consumeItems: Failed to consume " .. tostring(remaining) .. " of " .. tostring(itemType))
            return false
        end
    end
    
    return true
end

-----------------------------------------------------------
-- Effect Application
-----------------------------------------------------------

function UpgradeLogic.applyUpgradeEffects(player, upgradeId, level)
    local effects = MSR.UpgradeData.getLevelEffects(upgradeId, level)
    if not effects then return end
    
    -- Log effects for debugging
    if getDebug and getDebug() then
        print("[MSR_UpgradeLogic] Applied effects for " .. upgradeId .. " level " .. level .. ":")
        for name, value in pairs(effects) do
            print("  - " .. name .. ": " .. tostring(value))
        end
    end
end

function UpgradeLogic.getPlayerEffect(player, effectName)
    local effects = MSR.UpgradeData.getPlayerActiveEffects(player)
    return effects[effectName] or 0
end

-----------------------------------------------------------
-- Transaction Callbacks (for multiplayer)
-----------------------------------------------------------

function UpgradeLogic.onUpgradeComplete(player, upgradeId, targetLevel, transactionId)
    print("[MSR_UpgradeLogic] onUpgradeComplete: ========================================")
    print("[MSR_UpgradeLogic] onUpgradeComplete: upgradeId=" .. tostring(upgradeId))
    print("[MSR_UpgradeLogic] onUpgradeComplete: targetLevel=" .. tostring(targetLevel))
    print("[MSR_UpgradeLogic] onUpgradeComplete: transactionId=" .. tostring(transactionId))
    
    local playerObj = resolvePlayer(player)
    if not playerObj then 
        print("[MSR_UpgradeLogic] onUpgradeComplete: ERROR - No player")
        return 
    end
    
    if transactionId then
        print("[MSR_UpgradeLogic] onUpgradeComplete: Committing transaction")
        MSR.Transaction.Commit(playerObj, transactionId)
    end
    
    if upgradeId == "expand_refuge" then
        print("[MSR_UpgradeLogic] onUpgradeComplete: expand_refuge - server handled expansion")
        
        if MSR and MSR.InvalidateBoundsCache then
            print("[MSR_UpgradeLogic] onUpgradeComplete: Invalidating bounds cache for MP")
            MSR.InvalidateBoundsCache(playerObj)
        end
        
        -- Notify about the new tier
        local refugeData = MSR and MSR.GetRefugeData and MSR.GetRefugeData(playerObj)
        if refugeData then
            local tierConfig = MSR.Config.TIERS[refugeData.tier]
            if tierConfig then
                print("[MSR_UpgradeLogic] onUpgradeComplete: New tier=" .. tostring(refugeData.tier) .. " size=" .. tostring(tierConfig.size))
            end
        end
    else
        print("[MSR_UpgradeLogic] onUpgradeComplete: Setting upgrade level")
        MSR.UpgradeData.setPlayerUpgradeLevel(playerObj, upgradeId, targetLevel)
        UpgradeLogic.applyUpgradeEffects(playerObj, upgradeId, targetLevel)
    end
    
    local MSR_UpgradeWindow = require "refuge/MSR_UpgradeWindow"
    if MSR_UpgradeWindow.instance then
        MSR_UpgradeWindow.instance:refreshUpgradeList()
        MSR_UpgradeWindow.instance:refreshCurrentUpgrade()
    end
    
    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    if playerObj and playerObj.Say then
        local message = string.format(getText("IGUI_UpgradedToLevel"), name, targetLevel)
        playerObj:Say(message)
    end
    print("[MSR_UpgradeLogic] onUpgradeComplete: Done")
end

function UpgradeLogic.onUpgradeError(player, transactionId, reason)
    print("[MSR_UpgradeLogic] onUpgradeError: ========================================")
    print("[MSR_UpgradeLogic] onUpgradeError: transactionId=" .. tostring(transactionId))
    print("[MSR_UpgradeLogic] onUpgradeError: reason=" .. tostring(reason))
    
    local playerObj = resolvePlayer(player)
    if not playerObj then 
        print("[MSR_UpgradeLogic] onUpgradeError: ERROR - No player")
        return 
    end
    
    if transactionId then
        print("[MSR_UpgradeLogic] onUpgradeError: Rolling back transaction")
        local success = MSR.Transaction.Rollback(playerObj, transactionId)
        if success then
            print("[MSR_UpgradeLogic] onUpgradeError: Rollback SUCCESS - items unlocked")
        else
            print("[MSR_UpgradeLogic] onUpgradeError: Rollback FAILED - transaction not found or already committed")
        end
    end
    
    if playerObj and playerObj.Say then
        playerObj:Say(reason or getText("IGUI_UpgradeFailed"))
    end
    print("[MSR_UpgradeLogic] onUpgradeError: Done")
end

print("[MSR_UpgradeLogic] Upgrade logic loaded")

return MSR.UpgradeLogic

