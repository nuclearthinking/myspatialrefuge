-- MSR_UpgradeLogic - Upgrade Logic

require "shared/00_core/00_MSR"
require "shared/00_core/04_Env"
require "shared/MSR_UpgradeData"
require "shared/MSR_Transaction"
require "shared/00_core/05_Config"
require "shared/MSR_Shared"
require "shared/00_core/06_Data"
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

--------------------------------------------------------------------------------
-- IsoObject Sync Utilities (for MP container/property sync)
--------------------------------------------------------------------------------

--- Sync IsoObject container properties to all clients
--- Use after modifying container capacity, type, etc.
---@param object IsoObject The object to sync
---@param syncModData boolean|nil Also sync ModData (default: true)
function UpgradeLogic.syncObjectToClients(object, syncModData)
    if not object then return end
    if not MSR.Env.needsClientSync() then return end
    
    -- sendObjectChange("containers") syncs container properties including capacity
    if object.sendObjectChange then
        object:sendObjectChange("containers")
        L.debug("UpgradeLogic", "Synced object container via sendObjectChange('containers')")
    end
    
    -- Sync ModData if requested (default: true)
    if syncModData ~= false and object.transmitModData then
        object:transmitModData()
    end
end

--------------------------------------------------------------------------------
-- Upgrade Handler Registry (extensible pattern for custom upgrades)
--------------------------------------------------------------------------------

-- Registry of upgrade handlers for upgrades that need special server-side logic
-- Each handler: { apply = function(player, level) -> success, error, extraData }
local UpgradeHandlers = {}

--- Register a custom upgrade handler
--- Handler fields:
---   apply(player, level) -> success, errorMsg, resultData (required)
---   getResponseData(refugeData, resultData) -> table (optional, extra data for client response)
---   invalidatesCache: boolean (optional, default true - invalidate relic cache after upgrade)
---@param upgradeId string The upgrade ID
---@param handler table Handler with apply function
function UpgradeLogic.registerHandler(upgradeId, handler)
    if not handler or type(handler.apply) ~= "function" then
        L.log("UpgradeLogic", "ERROR: Handler for " .. upgradeId .. " must have apply function")
        return
    end
    UpgradeHandlers[upgradeId] = handler
    L.debug("UpgradeLogic", "Registered handler for upgrade: " .. upgradeId)
end

--- Get registered handler for an upgrade
---@param upgradeId string The upgrade ID
---@return table|nil handler The registered handler or nil
function UpgradeLogic.getHandler(upgradeId)
    return UpgradeHandlers[upgradeId]
end

--- Check if upgrade has a custom handler
---@param upgradeId string The upgrade ID
---@return boolean hasHandler
function UpgradeLogic.hasHandler(upgradeId)
    return UpgradeHandlers[upgradeId] ~= nil
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
    
    -- Check for custom handler (storage, expand, etc.)
    local handler = UpgradeLogic.getHandler(upgradeId)
    if handler then
        local success, errorMsg, resultData = handler.apply(player, targetLevel)
        if not success then
            return false, errorMsg or "Upgrade failed"
        end
        
        -- Handler provides its own success message via onSuccess callback
        if handler.onSuccess then
            handler.onSuccess(player, targetLevel, resultData)
        end
    else
        -- Generic upgrade: just set level and apply effects
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

--- Apply storage upgrade to existing relic
---@param player IsoPlayer|number Player or player number
---@param level number Target upgrade level
---@return boolean success Whether the upgrade was applied
---@return string|nil errorMsg Error message if failed
function UpgradeLogic.applyStorageUpgrade(player, level)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false, "Invalid player" end
    
    -- Set level first (needed for capacity calculation)
    MSR.UpgradeData.setPlayerUpgradeLevel(playerObj, MSR.Config.UPGRADES.CORE_STORAGE, level)
    
    local refugeData = MSR.Data.GetRefugeData(playerObj)
    if not refugeData then return false, "Refuge data not found" end
    
    -- Find the relic
    local relic = MSR.Integrity and MSR.Integrity.FindRelic and MSR.Integrity.FindRelic(refugeData)
    if not relic then
        L.log("UpgradeLogic", "WARNING: Relic not found, capacity will apply on next creation")
        return true, nil
    end
    
    local container = relic:getContainer()
    if not container then return false, "Relic container not found" end
    
    local newCapacity = MSR.Config.getRelicStorageCapacity(refugeData)
    
    -- Downgrade safety: prevent reducing capacity below current items
    local currentItems = container:getItems():size()
    if currentItems > newCapacity then
        return false, "Cannot reduce capacity below current item count (" .. currentItems .. " items)"
    end
    
    container:setCapacity(newCapacity)
    
    -- Store level in relic ModData for integrity verification
    local md = relic:getModData()
    md.storageUpgradeLevel = level
    
    -- Sync to clients (handles both container properties and ModData)
    UpgradeLogic.syncObjectToClients(relic, true)
    
    L.log("UpgradeLogic", "Updated relic storage capacity to " .. newCapacity)
    return true, nil
end

--------------------------------------------------------------------------------
-- Register Built-in Upgrade Handlers
--------------------------------------------------------------------------------

local UPGRADES = MSR.Config.UPGRADES

-- Storage upgrade handler
UpgradeLogic.registerHandler(UPGRADES.CORE_STORAGE, {
    apply = function(player, level)
        return UpgradeLogic.applyStorageUpgrade(player, level)
    end,
    invalidatesCache = true
})

-- Expansion handler (uses RefugeExpansion module)
UpgradeLogic.registerHandler(UPGRADES.EXPAND_REFUGE, {
    apply = function(player, level)
        local refugeData = MSR.Data.GetRefugeData(player)
        if not refugeData then return false, "Refuge data not found" end
        
        local success, errorMsg, resultData = MSR.RefugeExpansion.Execute(player, refugeData)
        return success, errorMsg, resultData
    end,
    -- Provide extra data for client response (needed for wall cleanup)
    getResponseData = function(refugeData, resultData)
        if not resultData then return nil end
        return {
            centerX = refugeData.centerX,
            centerY = refugeData.centerY,
            centerZ = refugeData.centerZ,
            oldRadius = resultData.oldRadius,
            newRadius = resultData.newRadius,
            newTier = resultData.newTier
        }
    end,
    onSuccess = function(player, level, resultData)
        if resultData and resultData.tierConfig then
            PM.Say(player, PM.REFUGE_UPGRADED_TO, resultData.tierConfig.displayName)
        end
    end,
    invalidatesCache = true
})

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
    
    -- Upgrade-specific post-completion handling
    if upgradeId == UPGRADES.EXPAND_REFUGE then
        if MSR.InvalidateBoundsCache then MSR.InvalidateBoundsCache(playerObj) end
    end
    
    -- Update local upgrade level state
    -- For upgrades with custom handlers (storage, expand), level is already saved server-side
    -- but we sync local state for immediate UI/effect access
    -- For generic upgrades, this also triggers SaveRefugeData (no-op on MP clients)
    local handler = UpgradeLogic.getHandler(upgradeId)
    if not handler then
        UpgradeLogic.applyUpgradeEffects(playerObj, upgradeId, targetLevel)
    end
    MSR.UpgradeData.setPlayerUpgradeLevel(playerObj, upgradeId, targetLevel)
    
    -- Invalidate caches if handler requires it (default: true for handlers, always for generic)
    local shouldInvalidateCache = not handler or handler.invalidatesCache ~= false
    if shouldInvalidateCache and MSR.InvalidateRelicContainerCache then
        MSR.InvalidateRelicContainerCache()
    end
    
    -- Refresh UI
    if MSR.Env.isClient() then
        if ISInventoryPage and ISInventoryPage.dirtyUI then ISInventoryPage.dirtyUI() end
        
        local MSR_UpgradeWindow = require "MSR_UpgradeWindow"
        if MSR_UpgradeWindow and MSR_UpgradeWindow.instance then
            MSR_UpgradeWindow.instance:setUpgradePending(false)
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
    
    -- Re-enable upgrade window if open
    if MSR.Env.isClient() then
        local MSR_UpgradeWindow = require "MSR_UpgradeWindow"
        if MSR_UpgradeWindow and MSR_UpgradeWindow.instance then
            MSR_UpgradeWindow.instance:setUpgradePending(false)
        end
    end
    
    if reason then
        -- Use PM key if available, else raw display
        local translationKey = PM.GetTranslationKey(reason)
        if translationKey then
            PM.Say(playerObj, reason)
        else
            PM.SayRaw(playerObj, reason)
        end
    else
        PM.Say(playerObj, PM.UPGRADE_FAILED)
    end
end

return MSR.UpgradeLogic

