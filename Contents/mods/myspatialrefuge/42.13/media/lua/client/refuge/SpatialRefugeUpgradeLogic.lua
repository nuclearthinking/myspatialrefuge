-- Spatial Refuge Upgrade Logic
-- Business logic for the upgrade system
-- Handles item checking, purchase flow, and transaction management

require "shared/SpatialRefugeUpgradeData"
require "shared/SpatialRefugeTransaction"
require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeShared"
require "shared/SpatialRefugeData"

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

function SpatialRefugeUpgradeLogic.getItemSources(player)
    return SpatialRefugeTransaction.GetItemSources(player)
end

function SpatialRefugeUpgradeLogic.getAvailableItemCount(player, requirement)
    if not requirement then return 0 end
    
    local total, _ = SpatialRefugeTransaction.GetSubstitutionCount(player, requirement)
    return total
end

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

function SpatialRefugeUpgradeLogic.canPurchaseUpgrade(player, upgradeId, targetLevel)
    local playerObj = resolvePlayer(player)
    if not playerObj then
        return false, "Invalid player"
    end
    
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    if not upgrade then
        return false, "Unknown upgrade"
    end
    
    if not SpatialRefugeUpgradeData.isUpgradeUnlocked(playerObj, upgradeId) then
        return false, "Dependencies not met"
    end
    
    local currentLevel = SpatialRefugeUpgradeData.getPlayerUpgradeLevel(playerObj, upgradeId)
    
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
    
    local levelData = SpatialRefugeUpgradeData.getLevelData(upgradeId, targetLevel)
    if not levelData then
        return false, "Invalid level data"
    end
    
    local requirements = levelData.requirements or {}
    if not SpatialRefugeUpgradeLogic.hasRequiredItems(playerObj, requirements) then
        return false, "Missing required items"
    end
    
    return true, nil
end

-----------------------------------------------------------
-- Upgrade Purchase
-----------------------------------------------------------

function SpatialRefugeUpgradeLogic.purchaseUpgrade(player, upgradeId, targetLevel)
    local playerObj = resolvePlayer(player)
    if not playerObj then
        print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Invalid player")
        return false, "Invalid player"
    end
    
    print("[SpatialRefugeUpgradeLogic] ========================================")
    print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: " .. tostring(upgradeId) .. " level " .. tostring(targetLevel))
    
    local canPurchase, err = SpatialRefugeUpgradeLogic.canPurchaseUpgrade(playerObj, upgradeId, targetLevel)
    if not canPurchase then
        print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: CANNOT purchase - " .. tostring(err))
        return false, err
    end
    print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Validation passed")
    
    local levelData = SpatialRefugeUpgradeData.getLevelData(upgradeId, targetLevel)
    local requirements = levelData.requirements or {}
    
    print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Requirements count = " .. #requirements)
    for i, req in ipairs(requirements) do
        print("[SpatialRefugeUpgradeLogic]   Req " .. i .. ": " .. tostring(req.type) .. " x" .. tostring(req.count))
    end
    
    if isMultiplayerClient() then
        print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Using MP flow")
        return SpatialRefugeUpgradeLogic.purchaseUpgradeMP(playerObj, upgradeId, targetLevel, requirements)
    else
        print("[SpatialRefugeUpgradeLogic] purchaseUpgrade: Using SP flow")
        return SpatialRefugeUpgradeLogic.purchaseUpgradeSP(playerObj, upgradeId, targetLevel, requirements)
    end
end

function SpatialRefugeUpgradeLogic.purchaseUpgradeSP(player, upgradeId, targetLevel, requirements)
    print("[SpatialRefugeUpgradeLogic] SP: Starting singleplayer purchase")
    
    local success = SpatialRefugeUpgradeLogic.consumeItems(player, requirements)
    if not success then
        print("[SpatialRefugeUpgradeLogic] SP: FAILED to consume items")
        return false, "Failed to consume items"
    end
    print("[SpatialRefugeUpgradeLogic] SP: Items consumed successfully")
    
    if upgradeId == "expand_refuge" then
        print("[SpatialRefugeUpgradeLogic] SP: Processing expand_refuge")
        
        local refugeData = SpatialRefugeData.GetRefugeData(player)
        if not refugeData then
            print("[SpatialRefugeUpgradeLogic] SP: ERROR - No refuge data found")
            return false, "Refuge data not found"
        end
        
        local currentTier = refugeData.tier or 0
        local nextTier = currentTier + 1
        local oldRadius = refugeData.radius or 1
        print("[SpatialRefugeUpgradeLogic] SP: Tier " .. currentTier .. " -> " .. nextTier)
        
        -- Perform expansion using shared module
        local expandSuccess = SpatialRefugeShared.ExpandRefuge(refugeData, nextTier, player)
        
        if expandSuccess then
            print("[SpatialRefugeUpgradeLogic] SP: ExpandRefuge SUCCESS")
            
            -- Handle relic repositioning after expansion (same as server does)
            local relic = SpatialRefugeShared.FindRelicInRefuge(
                refugeData.centerX, refugeData.centerY, refugeData.centerZ,
                oldRadius, -- Use OLD radius - relic is at old corner position
                refugeData.refugeId
            )
            if relic then
                local md = relic:getModData()
                if md and md.assignedCorner then
                    local cornerDx = md.assignedCornerDx or 0
                    local cornerDy = md.assignedCornerDy or 0
                    local moveSuccess, moveMessage = SpatialRefugeShared.MoveRelic(refugeData, cornerDx, cornerDy, md.assignedCorner, relic)
                    
                    if moveSuccess then
                        -- Update relic position in ModData
                        local newRelicX = refugeData.centerX + (cornerDx * refugeData.radius)
                        local newRelicY = refugeData.centerY + (cornerDy * refugeData.radius)
                        refugeData.relicX = newRelicX
                        refugeData.relicY = newRelicY
                        refugeData.relicZ = refugeData.centerZ
                        print("[SpatialRefugeUpgradeLogic] SP: Repositioned relic to " .. md.assignedCorner)
                    else
                        print("[SpatialRefugeUpgradeLogic] SP: WARNING - Failed to reposition relic: " .. tostring(moveMessage))
                    end
                end
            end
            
            -- Save updated refuge data
            SpatialRefugeData.SaveRefugeData(refugeData)
            
            -- Invalidate cached boundary bounds
            if SpatialRefuge and SpatialRefuge.InvalidateBoundsCache then
                SpatialRefuge.InvalidateBoundsCache(player)
            end
            
            local tierConfig = SpatialRefugeConfig.TIERS[nextTier]
            if tierConfig and player and player.Say then
                local message = string.format(getText("IGUI_RefugeUpgradedTo"), tierConfig.displayName)
                player:Say(message)
            end
        else
            print("[SpatialRefugeUpgradeLogic] SP: ExpandRefuge FAILED")
            return false, "Expansion failed"
        end
    else
        print("[SpatialRefugeUpgradeLogic] SP: Setting upgrade level")
        SpatialRefugeUpgradeData.setPlayerUpgradeLevel(player, upgradeId, targetLevel)
        SpatialRefugeUpgradeLogic.applyUpgradeEffects(player, upgradeId, targetLevel)
    end
    
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    if player and player.Say then
        local message = string.format(getText("IGUI_UpgradedToLevel"), name, targetLevel)
        player:Say(message)
    end
    
    print("[SpatialRefugeUpgradeLogic] SP: Purchase complete")
    return true, nil
end

function SpatialRefugeUpgradeLogic.purchaseUpgradeMP(player, upgradeId, targetLevel, requirements)
    local transaction, err = SpatialRefugeTransaction.BeginWithSubstitutions(
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
        SpatialRefugeConfig.COMMAND_NAMESPACE,
        SpatialRefugeConfig.COMMANDS.REQUEST_FEATURE_UPGRADE,
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

function SpatialRefugeUpgradeLogic.consumeItems(player, requirements)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false end
    
    local resolved, err = SpatialRefugeTransaction.ResolveSubstitutions(playerObj, requirements)
    if not resolved then
        return false
    end
    
    local sources = SpatialRefugeTransaction.GetItemSources(playerObj)
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
            print("[SpatialRefugeUpgradeLogic] consumeItems: Failed to consume " .. tostring(remaining) .. " of " .. tostring(itemType))
            return false
        end
    end
    
    return true
end

-----------------------------------------------------------
-- Effect Application
-----------------------------------------------------------

function SpatialRefugeUpgradeLogic.applyUpgradeEffects(player, upgradeId, level)
    local effects = SpatialRefugeUpgradeData.getLevelEffects(upgradeId, level)
    if not effects then return end
    
    -- Log effects for debugging
    if getDebug and getDebug() then
        print("[SpatialRefugeUpgradeLogic] Applied effects for " .. upgradeId .. " level " .. level .. ":")
        for name, value in pairs(effects) do
            print("  - " .. name .. ": " .. tostring(value))
        end
    end
end

function SpatialRefugeUpgradeLogic.getPlayerEffect(player, effectName)
    local effects = SpatialRefugeUpgradeData.getPlayerActiveEffects(player)
    return effects[effectName] or 0
end

-----------------------------------------------------------
-- Transaction Callbacks (for multiplayer)
-----------------------------------------------------------

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
    
    if transactionId then
        print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: Committing transaction")
        SpatialRefugeTransaction.Commit(playerObj, transactionId)
    end
    
    if upgradeId == "expand_refuge" then
        print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: expand_refuge - server handled expansion")
        
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
        print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: Setting upgrade level")
        SpatialRefugeUpgradeData.setPlayerUpgradeLevel(playerObj, upgradeId, targetLevel)
        SpatialRefugeUpgradeLogic.applyUpgradeEffects(playerObj, upgradeId, targetLevel)
    end
    
    local SpatialRefugeUpgradeWindow = require "refuge/SpatialRefugeUpgradeWindow"
    if SpatialRefugeUpgradeWindow.instance then
        SpatialRefugeUpgradeWindow.instance:refreshUpgradeList()
        SpatialRefugeUpgradeWindow.instance:refreshCurrentUpgrade()
    end
    
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    local name = upgrade and (getText(upgrade.name) or upgrade.name) or upgradeId
    if playerObj and playerObj.Say then
        local message = string.format(getText("IGUI_UpgradedToLevel"), name, targetLevel)
        playerObj:Say(message)
    end
    print("[SpatialRefugeUpgradeLogic] onUpgradeComplete: Done")
end

function SpatialRefugeUpgradeLogic.onUpgradeError(player, transactionId, reason)
    print("[SpatialRefugeUpgradeLogic] onUpgradeError: ========================================")
    print("[SpatialRefugeUpgradeLogic] onUpgradeError: transactionId=" .. tostring(transactionId))
    print("[SpatialRefugeUpgradeLogic] onUpgradeError: reason=" .. tostring(reason))
    
    local playerObj = resolvePlayer(player)
    if not playerObj then 
        print("[SpatialRefugeUpgradeLogic] onUpgradeError: ERROR - No player")
        return 
    end
    
    if transactionId then
        print("[SpatialRefugeUpgradeLogic] onUpgradeError: Rolling back transaction")
        local success = SpatialRefugeTransaction.Rollback(playerObj, transactionId)
        if success then
            print("[SpatialRefugeUpgradeLogic] onUpgradeError: Rollback SUCCESS - items unlocked")
        else
            print("[SpatialRefugeUpgradeLogic] onUpgradeError: Rollback FAILED - transaction not found or already committed")
        end
    end
    
    if playerObj and playerObj.Say then
        playerObj:Say(reason or getText("IGUI_UpgradeFailed"))
    end
    print("[SpatialRefugeUpgradeLogic] onUpgradeError: Done")
end

print("[SpatialRefugeUpgradeLogic] Upgrade logic loaded")

return SpatialRefugeUpgradeLogic

