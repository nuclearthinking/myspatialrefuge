require "00_core/00_MSR"
require "00_core/Env"
require "MSR_UpgradeData"
require "MSR_Transaction"
require "00_core/Config"
require "MSR_Shared"
require "00_core/Data"
require "MSR_RefugeExpansion"
require "MSR_BasementGeneration"
require "helpers/World"
require "MSR_PlayerMessage"
require "MSR_InventoryAuthority"
require "MSR_RefugeGeometry"
local PM = MSR.PlayerMessage
if MSR and MSR.UpgradeLogic and MSR.UpgradeLogic._loaded then
    return MSR.UpgradeLogic
end

MSR.UpgradeLogic = MSR.UpgradeLogic or {}
MSR.UpgradeLogic._loaded = true

local UpgradeLogic = MSR.UpgradeLogic
local TRANSACTION_TYPE_UPGRADE = "REFUGE_FEATURE_UPGRADE"
local LOG = L.logger("UpgradeLogic")

local function invalidateItemCountCaches(player)
    local ok, Cache = pcall(require, "MSR_UpgradeItemCache")
    if ok and Cache and Cache.invalidate then
        Cache.invalidate(player)
    end
end

local function onUpgradeLevelChanged(player)
    invalidateItemCountCaches(player)
    if MSR.EffectSystem and MSR.EffectSystem.markDirty then
        MSR.EffectSystem.markDirty(player)
    end
end

MSR.UpgradeEvents.OnLevelChanged.Add(onUpgradeLevelChanged)

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
        LOG.debug("Synced object container")
    end

    if syncModData ~= false and object.transmitModData then
        object:transmitModData()
    end
end

local UpgradeHandlers = {}

--- Register upgrade handler
---@param upgradeId string
---@param handler table { prepare?, commit?, reconcile?, validate?, getResponseData?, onSuccess?, invalidatesCache? }
function UpgradeLogic.registerHandler(upgradeId, handler)
    if not handler or type(handler.commit) ~= "function" then
        LOG.error("Handler for " .. upgradeId .. " must have commit function")
        return
    end
    UpgradeHandlers[upgradeId] = handler
    LOG.debug("Registered handler: " .. upgradeId)
end

--- Pre-validate upgrade before consuming items (for handlers with validation logic)
---@param player IsoPlayer|number
---@param upgradeId string
---@param targetLevel number
---@return boolean success, string|nil errorMsg
function UpgradeLogic.validateUpgrade(player, upgradeId, targetLevel)
    local handler = UpgradeHandlers[upgradeId]
    if handler and handler.validate then
        local callOk, valid, validationError = pcall(handler.validate, player, targetLevel)
        if not callOk then return false, "Upgrade validation failed: " .. tostring(valid) end
        return valid == true, validationError
    end
    return true, nil
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

local function allocationFromTransaction(transaction)
    local allocation = {}
    for itemType, data in pairs(transaction and transaction.lockedItems or {}) do
        allocation[itemType] = data.itemIds
    end
    return allocation
end

function UpgradeLogic.validateAllocationForRequirements(requirements, allocation)
    requirements = requirements or {}
    allocation = allocation or {}
    if type(requirements) ~= "table" or type(allocation) ~= "table" then
        return false, "Invalid item allocation"
    end

    local allocatedTypes = {}
    local totalAllocated = 0
    for itemType, itemIds in pairs(allocation) do
        if type(itemType) ~= "string" or type(itemIds) ~= "table" then
            return false, "Invalid item allocation"
        end
        local itemCount = #itemIds
        local visited = 0
        for index, itemId in pairs(itemIds) do
            if type(index) ~= "number" or index < 1 or index > itemCount or index ~= math.floor(index)
                or type(itemId) ~= "number" or itemId ~= math.floor(itemId)
            then
                return false, "Invalid item allocation"
            end
            visited = visited + 1
        end
        if visited ~= itemCount then return false, "Invalid item allocation" end
        table.insert(allocatedTypes, { itemType = itemType, count = itemCount })
        totalAllocated = totalAllocated + itemCount
    end

    local normalizedRequirements = {}
    local totalRequired = 0
    for _, requirement in ipairs(requirements) do
        if type(requirement) ~= "table" or type(requirement.type) ~= "string" then
            return false, "Invalid upgrade recipe"
        end
        local rawCount = tonumber(requirement.count) or 1
        if rawCount < 0 or rawCount ~= math.floor(rawCount) then return false, "Invalid upgrade recipe" end
        local count = math.floor(rawCount)
        local allowed = { [requirement.type] = true }
        for _, substitute in ipairs(requirement.substitutes or {}) do
            if type(substitute) ~= "string" then return false, "Invalid upgrade recipe" end
            allowed[substitute] = true
        end
        table.insert(normalizedRequirements, { count = count, allowed = allowed })
        totalRequired = totalRequired + count
    end

    if totalAllocated ~= totalRequired then
        return false, "Item allocation does not satisfy the upgrade recipe"
    end

    -- Small max-flow graph: allocated item types -> recipe requirements.
    -- This handles overlapping substitutions without depending on recipe order.
    local typeCount = #allocatedTypes
    local requirementCount = #normalizedRequirements
    local source = 1
    local firstType = 2
    local firstRequirement = firstType + typeCount
    local sink = firstRequirement + requirementCount
    ---@type table<number, { to: integer, capacity: number, reverse: integer }[]>
    local graph = {}
    for node = source, sink do graph[node] = {} end

    local function addEdge(from, to, capacity)
        local forward = { to = to, capacity = capacity, reverse = #graph[to] + 1 }
        local reverse = { to = from, capacity = 0, reverse = #graph[from] + 1 }
        table.insert(graph[from], forward)
        table.insert(graph[to], reverse)
    end

    for typeIndex, allocated in ipairs(allocatedTypes) do
        local typeNode = firstType + typeIndex - 1
        addEdge(source, typeNode, allocated.count)
        for requirementIndex, requirement in ipairs(normalizedRequirements) do
            if requirement.allowed[allocated.itemType] then
                addEdge(typeNode, firstRequirement + requirementIndex - 1, allocated.count)
            end
        end
    end
    for requirementIndex, requirement in ipairs(normalizedRequirements) do
        addEdge(firstRequirement + requirementIndex - 1, sink, requirement.count)
    end

    ---@type number
    local flow = 0
    while true do
        ---@type table<integer, integer>
        local parentNode, parentEdge = {}, {}
        local queue, head = { source }, 1
        parentNode[source] = source
        while head <= #queue and not parentNode[sink] do
            local node = queue[head]
            head = head + 1
            for edgeIndex, edge in ipairs(graph[node]) do
                if edge.capacity > 0 and not parentNode[edge.to] then
                    parentNode[edge.to] = node
                    parentEdge[edge.to] = edgeIndex
                    table.insert(queue, edge.to)
                    if edge.to == sink then break end
                end
            end
        end
        if not parentNode[sink] then break end

        ---@type number
        local amount = totalRequired
        local node = sink
        while node ~= source do
            local previous = parentNode[node]
            local edgeIndex = parentEdge[node]
            local edges = previous and graph[previous] or nil
            local edge = edges and edgeIndex and edges[edgeIndex] or nil
            if not previous or not edge then return false, "Invalid allocation flow" end
            amount = math.min(amount, edge.capacity)
            node = previous
        end
        node = sink
        while node ~= source do
            local previous = parentNode[node]
            local edgeIndex = parentEdge[node]
            local edges = previous and graph[previous] or nil
            local edge = edges and edgeIndex and edges[edgeIndex] or nil
            if not previous or not edge then return false, "Invalid allocation flow" end
            local reverseEdge = graph[node] and graph[node][edge.reverse] or nil
            if not reverseEdge then return false, "Invalid allocation flow" end
            edge.capacity = edge.capacity - amount
            reverseEdge.capacity = reverseEdge.capacity + amount
            node = previous
        end
        flow = flow + amount
    end

    if flow ~= totalRequired then
        return false, "Item allocation does not satisfy the upgrade recipe"
    end
    return true, nil
end

function UpgradeLogic.executeAuthoritative(player, upgradeId, targetLevel, requirements, allocation)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false, "Invalid player", nil end

    local valid, validationError = UpgradeLogic.validateUpgrade(playerObj, upgradeId, targetLevel)
    if not valid then return false, validationError, nil end

    requirements = requirements or {}
    allocation = allocation or {}
    local allocationOk, allocationError = UpgradeLogic.validateAllocationForRequirements(requirements, allocation)
    if not allocationOk then return false, allocationError, nil end

    local handler = UpgradeHandlers[upgradeId]
    local operation = { upgradeId = upgradeId, targetLevel = targetLevel }
    if handler and handler.prepare then
        local callOk, prepared, prepareError = pcall(handler.prepare, playerObj, targetLevel)
        if not callOk then return false, "Upgrade preparation failed: " .. tostring(prepared), nil end
        if not prepared then return false, prepareError or "Upgrade preparation failed", nil end
        operation = prepared
    end

    local receipt = nil
    if #requirements > 0 then
        local sources = MSR.Transaction.GetItemSources(playerObj)
        local consumeError = nil
        receipt, consumeError = MSR.InventoryAuthority.consumeWithReceipt(
            playerObj,
            sources,
            allocation,
            MSR.Transaction.IsItemAvailable
        )
        if not receipt then return false, consumeError or "Failed to consume upgrade requirements", nil end
    end

    local commitCallOk, committed, resultOrError
    if handler then
        commitCallOk, committed, resultOrError = pcall(handler.commit, playerObj, targetLevel, operation)
    else
        commitCallOk, committed = pcall(
            MSR.UpgradeData.setPlayerUpgradeLevel,
            playerObj,
            upgradeId,
            targetLevel
        )
        resultOrError = committed and operation or "Failed to save upgrade level"
    end

    if not commitCallOk then
        resultOrError = "Upgrade commit failed: " .. tostring(committed)
        committed = false
    end

    if not committed and MSR.UpgradeData.getPlayerUpgradeLevel(playerObj, upgradeId) == targetLevel then
        LOG.warning("Upgrade commit reported failure after authoritative state was saved; continuing roll-forward")
        committed = true
        resultOrError = operation
    end

    if not committed then
        if receipt then MSR.InventoryAuthority.refundReceipt(playerObj, receipt) end
        return false, resultOrError or "Upgrade commit failed", nil
    end
    if receipt then MSR.InventoryAuthority.finalizeReceipt(receipt) end

    local resultData = resultOrError or operation
    if handler and handler.reconcile then
        local reconcileCallOk, reconciled, reconcileError = pcall(
            handler.reconcile,
            playerObj,
            targetLevel,
            operation,
            resultData
        )
        if not reconcileCallOk then
            reconcileError = reconciled
            reconciled = false
        end
        if not reconciled then
            LOG.warning("Committed upgrade %s requires roll-forward repair: %s", upgradeId, tostring(reconcileError))
        end
    else
        UpgradeLogic.applyUpgradeEffects(playerObj, upgradeId, targetLevel)
    end

    if handler and handler.onSuccess then
        local callbackOk, callbackError = pcall(handler.onSuccess, playerObj, targetLevel, resultData)
        if not callbackOk then
            LOG.warning("Upgrade success callback failed for %s: %s", upgradeId, tostring(callbackError))
        end
    end

    return true, nil, resultData
end

function UpgradeLogic.canPurchaseUpgrade(player, upgradeId, targetLevel)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false, "Invalid player" end

    local refugeData = MSR.Data and MSR.Data.GetRefugeData and MSR.Data.GetRefugeData(playerObj)
    if not refugeData then return false, "Refuge data unavailable" end

    local upgrade = MSR.UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return false, "Unknown upgrade" end
    if upgrade.debugOnly and not (MSR.Env and MSR.Env.isDebugEnabled and MSR.Env.isDebugEnabled()) then
        return false, "Debug-only upgrade"
    end
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

    LOG.debug("purchaseUpgrade: " .. tostring(upgradeId) .. " level " .. tostring(targetLevel))

    local canPurchase, err = UpgradeLogic.canPurchaseUpgrade(playerObj, upgradeId, targetLevel)
    if not canPurchase then
        LOG.debug("CANNOT purchase - " .. tostring(err))
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
    local transaction = nil
    if requirements and #requirements > 0 then
        local err = nil
        transaction, err = MSR.Transaction.Begin(player, TRANSACTION_TYPE_UPGRADE, requirements)
        if not transaction then
            return false, err or "Failed to start transaction"
        end
    end

    local allocation = allocationFromTransaction(transaction)
    local success, errorMsg = UpgradeLogic.executeAuthoritative(
        player, upgradeId, targetLevel, requirements, allocation
    )
    if not success then
        if transaction then MSR.Transaction.Rollback(player, transaction.id) end
        return false, errorMsg or "Upgrade failed"
    end

    if transaction then MSR.Transaction.Finalize(player, transaction.id) end
    UpgradeLogic.onUpgradeComplete(player, upgradeId, targetLevel, nil)
    return true, nil
end

function UpgradeLogic.purchaseUpgradeMP(player, upgradeId, targetLevel, requirements)
    local transaction = nil
    if requirements and #requirements > 0 then
        local err = nil
        transaction, err = MSR.Transaction.Begin(player, TRANSACTION_TYPE_UPGRADE, requirements)
        if not transaction then
            return false, err or "Failed to start transaction"
        end
    end

    local lockedItemIds = allocationFromTransaction(transaction)

    LOG.debug("Upgrade request with " .. K.count(lockedItemIds) .. " locked item types")
    sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_FEATURE_UPGRADE, {
        upgradeId = upgradeId,
        targetLevel = targetLevel,
        transactionId = transaction and transaction.id or nil,
        lockedItemIds = lockedItemIds
    })

    PM.Say(player, PM.UPGRADING)
    return true, nil
end

function UpgradeLogic.applyUpgradeEffects(_player, upgradeId, level)
    local effects = MSR.UpgradeData.getLevelEffects(upgradeId, level)
    if not effects then return end

    LOG.debug("Applied effects for " .. upgradeId .. " level " .. level)
end

--- Calculate storage capacity for a given level (without modifying saved data)
---@param level number
---@return number capacity
local function getStorageCapacityForLevel(level)
    local effects = MSR.UpgradeData and MSR.UpgradeData.getLevelEffects and
                    MSR.UpgradeData.getLevelEffects(MSR.Config.UPGRADES.CORE_STORAGE, level)
    if effects and effects.relicStorageCapacity then
        return effects.relicStorageCapacity
    end
    return MSR.Config.RELIC_STORAGE_CAPACITY
end

--- Validate storage upgrade can be applied (called BEFORE consuming items in MP)
---@param player IsoPlayer|number
---@param level number
---@return boolean, string|nil
function UpgradeLogic.validateStorageUpgrade(player, level)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false, "Invalid player" end

    local refugeData = MSR.Data.GetRefugeData(playerObj)
    if not refugeData then return false, "Refuge data not found" end

    local relic = MSR.Integrity and MSR.Integrity.FindRelic and MSR.Integrity.FindRelic(refugeData)
    if not relic then
        -- No relic exists - validation passes, capacity will apply on creation
        return true, nil
    end

    local container = relic:getContainer()
    if not container then return false, "Relic container not found" end

    local newCapacity = getStorageCapacityForLevel(level)
    local currentWeight = container:getCapacityWeight()
    if currentWeight > newCapacity then
        return false, "Cannot reduce capacity below current weight (" .. round(currentWeight, 1) .. " units)"
    end

    return true, nil
end

local function registerBuiltinHandlers()
    -- Guard against duplicate registration
    if UpgradeHandlers[MSR.Config.UPGRADES.CORE_STORAGE] then
        LOG.debug("Handlers already registered, skipping")
        return
    end
    UpgradeLogic.registerHandler(MSR.Config.UPGRADES.CORE_STORAGE, {
        validate = function(player, level)
            return UpgradeLogic.validateStorageUpgrade(player, level)
        end,
        prepare = function(_player, level)
            return { level = level }, nil
        end,
        commit = function(player, level, operation)
            if not MSR.UpgradeData.setPlayerUpgradeLevel(player, MSR.Config.UPGRADES.CORE_STORAGE, level) then
                return false, "Failed to save storage upgrade level"
            end
            return true, operation
        end,
        reconcile = function(player, level)
            local refugeData = MSR.Data.GetRefugeData(player)
            local relic = refugeData and MSR.Integrity.FindRelic(refugeData) or nil
            if not relic then return true, nil end
            local container = relic:getContainer()
            if not container then return false, "Relic container not found" end
            container:setCapacity(getStorageCapacityForLevel(level))
            relic:getModData().storageUpgradeLevel = level
            UpgradeLogic.syncObjectToClients(relic, true)
            return true, nil
        end,
        invalidatesCache = true
    })

    UpgradeLogic.registerHandler(MSR.Config.UPGRADES.REFUGE_BASEMENT, {
        validate = function(player, level)
            local playerObj = resolvePlayer(player)
            if not playerObj then return false, "Invalid player" end

            local refugeData = MSR.Data.GetRefugeData(playerObj)
            if not refugeData then return false, "Refuge data not found" end

            LOG.debug("Basement validate: user=%s tier=%s level=%s center=%s,%s,%s radius=%s",
                tostring(playerObj:getUsername()),
                tostring(refugeData.tier), tostring(level),
                tostring(refugeData.centerX), tostring(refugeData.centerY), tostring(refugeData.centerZ),
                tostring(refugeData.radius))

            if (refugeData.tier or 0) < MSR.Config.MAX_TIER then
                return false, "Requires maximum refuge expansion"
            end

            local currentLevel = MSR.UpgradeData.getPlayerUpgradeLevel(playerObj, MSR.Config.UPGRADES.REFUGE_BASEMENT)
            if currentLevel >= (level or 1) then
                return false, "Already at this level"
            end

            local extent = MSR.RefugeGeometry.GetMaximumDirectionalExtent()
            local upperLoaded = MSR.World.areAreaChunksLoaded(refugeData.centerX, refugeData.centerY, refugeData.centerZ, extent)
            LOG.debug("Basement surface chunk check: upperLoaded=%s", tostring(upperLoaded))
            if not upperLoaded then
                return false, "Refuge area not fully loaded. Move around and try again."
            end

            local stairsOk, available = MSR.BasementGeneration.CheckStairwellAvailability(refugeData)
            if not stairsOk then
                LOG.debug("Basement validate failed: no clear stairwell (available=%s)", tostring(available))
                return false, PM.BASEMENT_STAIRS_BLOCKED
            end

            return true, nil
        end,
        prepare = function(player, level)
            local playerObj = resolvePlayer(player)
            if not playerObj then return nil, "Invalid player" end

            local refugeData = MSR.Data.GetRefugeData(playerObj)
            if not refugeData then return nil, "Refuge data not found" end
            return { refugeData = refugeData, level = level }, nil
        end,
        commit = function(player, level, operation)
            if not MSR.UpgradeData.setPlayerUpgradeLevel(player, MSR.Config.UPGRADES.REFUGE_BASEMENT, level) then
                return false, "Failed to save basement upgrade level"
            end
            return true, operation
        end,
        reconcile = function(player, _level, operation)
            local success, errorMsg = MSR.BasementGeneration.Generate(operation.refugeData, player)
            if not success then return false, errorMsg or "Basement generation failed" end
            if MSR.RoomPersistence then
                MSR.RoomPersistence.Save(operation.refugeData)
                MSR.RoomPersistence.Restore(operation.refugeData)
            end
            return true, nil
        end,
        invalidatesCache = true
    })

    UpgradeLogic.registerHandler(MSR.Config.UPGRADES.EXPAND_REFUGE, {
        prepare = function(player, _level)
            local refugeData = MSR.Data.GetRefugeData(player)
            if not refugeData then return nil, "Refuge data not found" end
            return MSR.RefugeExpansion.Prepare(player, refugeData)
        end,
        commit = function(player, _level, operation)
            return MSR.RefugeExpansion.Commit(player, operation)
        end,
        reconcile = function(player, _level, operation)
            return MSR.RefugeExpansion.Reconcile(player, operation)
        end,
        getResponseData = function(refugeData, resultData)
            if not resultData then return nil end
            local centerX, centerY = MSR.RefugeGeometry.GetAreaCenter(refugeData)
            return {
                centerX = centerX,
                centerY = centerY,
                centerZ = refugeData.centerZ,
                oldRadius = resultData.oldRadius,
                newRadius = resultData.newRadius,
                newTier = resultData.newTier
            }
        end,
        onSuccess = function(player, _level, resultData)
            if resultData and resultData.tierConfig then
                PM.Say(player, PM.REFUGE_UPGRADED_TO, resultData.tierConfig.displayName)
            end
        end,
        invalidatesCache = true
    })

    UpgradeLogic.registerHandler(MSR.Config.UPGRADES.DEBUG_FAIL_UPGRADE, {
        prepare = function(_player, level)
            return { level = level }, nil
        end,
        commit = function(_player, _level, _operation)
            return false, "Debug upgrade failed intentionally"
        end,
        invalidatesCache = false
    })

    LOG.debug("Built-in handlers registered")
end

function UpgradeLogic.getPlayerEffect(player, effectName)
    local effects = MSR.UpgradeData.getPlayerActiveEffects(player)
    return effects[effectName] or 0
end

function UpgradeLogic.onUpgradeComplete(player, upgradeId, targetLevel, transactionId)
    local playerObj = resolvePlayer(player)
    if not playerObj then return end

    if transactionId then
        MSR.Transaction.Finalize(playerObj, transactionId)
    end
    
    if upgradeId == MSR.Config.UPGRADES.EXPAND_REFUGE then
        invalidateItemCountCaches(playerObj)
        if MSR.InvalidateBoundsCache then MSR.InvalidateBoundsCache(playerObj) end
    end

    local handler = UpgradeLogic.getHandler(upgradeId)

    if upgradeId == MSR.Config.UPGRADES.EXPAND_REFUGE
        and MSR.EffectSystem
        and MSR.EffectSystem.markDirty
    then
        MSR.EffectSystem.markDirty(playerObj)
    end

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
        if reason == PM.BASEMENT_STAIRS_BLOCKED then
            UpgradeLogic.showBasementStairsBlockedAlert()
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

function UpgradeLogic.showBasementStairsBlockedAlert()
    if MSR._basementStairsAlertShown then return end
    if not ISModalRichText then return end

    MSR._basementStairsAlertShown = true
    local defaultMsg = " <CENTRE> <SIZE:large> <RGB:1,0.85,0.4> Basement Access Blocked <LINE> <LINE> " ..
        "<SIZE:medium> <RGB:1,1,1> Clear the surface of your refuge for at least one stairwell. <LINE> <LINE> " ..
        "<SIZE:small> <LEFT> Remove solid objects from the stairwell area (top corner of refuge), then try the upgrade again. <LINE> " ..
        "At least one stairwell must be clear to excavate a basement. "
    local message = getTextOrNull("IGUI_BasementStairsBlocked") or defaultMsg
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local width, height = 520, 280
    local modal = ISModalRichText:new((screenW - width) / 2, (screenH - height) / 2, width, height, message, false)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
end

-- Register handlers on server authority (SP, Coop host, Dedicated server)
-- Uses MSR.Events wrapper to handle environment differences automatically
require "00_core/Events"
MSR.Events.OnServerReady.Add(registerBuiltinHandlers)

return MSR.UpgradeLogic
