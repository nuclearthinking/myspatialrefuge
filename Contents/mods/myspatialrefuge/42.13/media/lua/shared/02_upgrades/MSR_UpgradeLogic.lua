require "shared/00_core/00_MSR"
require "shared/00_core/04_Env"
require "shared/02_upgrades/MSR_UpgradeData"
require "shared/01_common/MSR_Transaction"
require "shared/00_core/05_Config"
require "shared/01_common/MSR_Shared"
require "shared/00_core/06_Data"
require "shared/04_features/MSR_RefugeExpansion"
require "shared/01_common/MSR_PlayerMessage"
local PM = MSR.PlayerMessage
if MSR.UpgradeLogic and MSR.UpgradeLogic._loaded then
    return MSR.UpgradeLogic
end

MSR.UpgradeLogic = MSR.UpgradeLogic or {}
MSR.UpgradeLogic._loaded = true

local UpgradeLogic = MSR.UpgradeLogic
local TRANSACTION_TYPE_UPGRADE = "REFUGE_FEATURE_UPGRADE"

local function resolvePlayer(player)
    return MSR.resolvePlayer(player)
end

--- Sync IsoObject to clients after modifying container properties
---@param object IsoObject
---@param syncModData boolean|nil (default: true)
function UpgradeLogic.syncObjectToClients(object, syncModData)
    if not object then return end
    if not MSR.Env.needsClientSync() then return end
    if object.sendObjectChange then
        object:sendObjectChange("containers")
        L.debug("UpgradeLogic", "Synced object container")
    end

    if syncModData ~= false and object.transmitModData then
        object:transmitModData()
    end
end

local UpgradeHandlers = {} -- { apply(player, level) -> success, error, extraData }

--- Register upgrade handler
---@param upgradeId string
---@param handler table { apply, getResponseData?, onSuccess?, invalidatesCache? }
function UpgradeLogic.registerHandler(upgradeId, handler)
    if not handler or type(handler.apply) ~= "function" then
        L.log("UpgradeLogic", "ERROR: Handler for " .. upgradeId .. " must have apply function")
        return
    end
    UpgradeHandlers[upgradeId] = handler
    L.debug("UpgradeLogic", "Registered handler: " .. upgradeId)
end

---@param upgradeId string
---@return table|nil
function UpgradeLogic.getHandler(upgradeId)
    return UpgradeHandlers[upgradeId]
end

---@param upgradeId string
---@return boolean
function UpgradeLogic.hasHandler(upgradeId)
    return UpgradeHandlers[upgradeId] ~= nil
end

function UpgradeLogic.getItemSources(player)
    return MSR.Transaction.GetItemSources(player)
end

function UpgradeLogic.getAvailableItemCount(player, requirement)
    if not requirement then return 0 end
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
    local handler = UpgradeLogic.getHandler(upgradeId)
    if handler then
        local success, errorMsg, resultData = handler.apply(player, targetLevel)
        if not success then
            return false, errorMsg or "Upgrade failed"
        end
        if handler.onSuccess then
            handler.onSuccess(player, targetLevel, resultData)
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

    local lockedItemIds = {}
    for itemType, data in pairs(transaction.lockedItems) do
        lockedItemIds[itemType] = data.itemIds
    end

    L.debug("Upgrade", "Transaction " .. transaction.id .. " with " .. K.count(lockedItemIds) .. " item types")
    sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_FEATURE_UPGRADE, {
        upgradeId = upgradeId,
        targetLevel = targetLevel,
        transactionId = transaction.id,
        lockedItemIds = lockedItemIds
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
                    if item and item:getFullType() == itemType and MSR.Transaction.IsItemAvailable(item, container) then
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

---@param player IsoPlayer|number
---@param level number
---@return boolean, string|nil
function UpgradeLogic.applyStorageUpgrade(player, level)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false, "Invalid player" end

    MSR.UpgradeData.setPlayerUpgradeLevel(playerObj, MSR.Config.UPGRADES.CORE_STORAGE, level) -- must set before capacity calc

    local refugeData = MSR.Data.GetRefugeData(playerObj)
    if not refugeData then return false, "Refuge data not found" end
    local relic = MSR.Integrity and MSR.Integrity.FindRelic and MSR.Integrity.FindRelic(refugeData)
    if not relic then
        L.log("UpgradeLogic", "Relic not found, capacity will apply on next creation")
        return true, nil
    end

    local container = relic:getContainer()
    if not container then return false, "Relic container not found" end

    local newCapacity = MSR.Config.getRelicStorageCapacity(refugeData)
    local currentItems = container:getItems():size()
    if currentItems > newCapacity then
        return false, "Cannot reduce capacity below current item count (" .. currentItems .. " items)"
    end

    container:setCapacity(newCapacity)
    local md = relic:getModData()
    md.storageUpgradeLevel = level
    UpgradeLogic.syncObjectToClients(relic, true)

    L.log("UpgradeLogic", "Updated relic storage capacity to " .. newCapacity)
    return true, nil
end

local function registerBuiltinHandlers() -- deferred: Config not available at file load
    -- Guard against duplicate registration
    if UpgradeHandlers[MSR.Config.UPGRADES.CORE_STORAGE] then
        L.debug("UpgradeLogic", "Handlers already registered, skipping")
        return
    end

    UpgradeLogic.registerHandler(MSR.Config.UPGRADES.CORE_STORAGE, {
        apply = function(player, level)
            return UpgradeLogic.applyStorageUpgrade(player, level)
        end,
        invalidatesCache = true
    })

    UpgradeLogic.registerHandler(MSR.Config.UPGRADES.EXPAND_REFUGE, {
        apply = function(player, level)
            local refugeData = MSR.Data.GetRefugeData(player)
            if not refugeData then return false, "Refuge data not found" end

            local success, errorMsg, resultData = MSR.RefugeExpansion.Execute(player, refugeData)
            return success, errorMsg, resultData
        end,
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

    L.debug("UpgradeLogic", "Built-in handlers registered")
end

function UpgradeLogic.getPlayerEffect(player, effectName)
    local effects = MSR.UpgradeData.getPlayerActiveEffects(player)
    return effects[effectName] or 0
end

function UpgradeLogic.onUpgradeComplete(player, upgradeId, targetLevel, transactionId)
    local playerObj = resolvePlayer(player)
    if not playerObj then return end

    if transactionId then
        if MSR.Env.isMultiplayerClient() then
            MSR.Transaction.Finalize(playerObj, transactionId) -- MP: clear locks (server consumed items)
        else
            MSR.Transaction.Commit(playerObj, transactionId) -- SP: consume items
        end
    end
    
    if upgradeId == MSR.Config.UPGRADES.EXPAND_REFUGE then
        if MSR.InvalidateBoundsCache then MSR.InvalidateBoundsCache(playerObj) end
    end

    local handler = UpgradeLogic.getHandler(upgradeId)
    if not handler then
        UpgradeLogic.applyUpgradeEffects(playerObj, upgradeId, targetLevel)
    end
    MSR.UpgradeData.setPlayerUpgradeLevel(playerObj, upgradeId, targetLevel)

    local shouldInvalidateCache = not handler or handler.invalidatesCache ~= false
    if shouldInvalidateCache and MSR.InvalidateRelicContainerCache then
        MSR.InvalidateRelicContainerCache()
    end

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

    if MSR.Env.isClient() then
        local MSR_UpgradeWindow = require "MSR_UpgradeWindow"
        if MSR_UpgradeWindow and MSR_UpgradeWindow.instance then
            MSR_UpgradeWindow.instance:setUpgradePending(false)
        end
    end

    if reason then
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

-- Register handlers on server authority (SP, Coop host, Dedicated server)
-- Uses MSR.Events wrapper to handle environment differences automatically
require "shared/00_core/07_Events"
MSR.Events.OnServerReady.Add(registerBuiltinHandlers)

return MSR.UpgradeLogic
