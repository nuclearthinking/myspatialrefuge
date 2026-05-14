-- MSR_XPRetention - Souls-like XP retention system
-- Server-authoritative XP tracking and essence recovery for SP/coop/dedicated.

require "00_core/00_MSR"
require "00_core/Env"
require "00_core/Config"
require "helpers/Inventory"
require "helpers/World"
require "MSR_PlayerMessage"

local XPR = MSR.register("XPRetention")
local LOG = L.logger("XPRetention")
if not XPR then
    return MSR.XPRetention
end

local PM = MSR.PlayerMessage
local Config = MSR.Config

PM.Register("ESSENCE_ABSORBED", "IGUI_MSR_EssenceAbsorbed")
PM.Register("ESSENCE_NOT_YOURS", "IGUI_MSR_EssenceNotYours")
PM.Register("ESSENCE_EMPTY", "IGUI_MSR_EssenceEmpty")

local ESSENCE_VERSION = 2
local TRACKING_GATE_TICKS = 10

local earnedByUsername = {}
local suppressXpRecording = 0

-----------------------------------------------------------
-- XP map helpers
-----------------------------------------------------------

local function summarizeXpMap(xpMap)
    local count = 0
    local total = 0
    for _, amount in pairs(xpMap or {}) do
        if type(amount) == "number" then
            count = count + 1
            total = total + amount
        end
    end
    return count, total
end

local function copyPositiveXpMap(source)
    local xpMap = {}
    local total = 0

    for perkName, amount in pairs(source or {}) do
        if type(perkName) == "string" and type(amount) == "number" and amount > 0 then
            xpMap[perkName] = amount
            total = total + amount
        end
    end

    return xpMap, total
end

local function getPlayerUsername(player)
    local username = MSR.safePlayerCall(player, "getUsername")
    if username and username ~= "" then
        return username
    end
    return nil
end

-----------------------------------------------------------
-- Perk utilities
-----------------------------------------------------------

local perkCache = {}

local function getPerkName(perk)
    if not perk then return nil end
    if type(perk) == "string" then return perk end

    if perk.getName then
        local ok, name = pcall(perk.getName, perk)
        if ok and name then return name end
    end

    if perk.getType then
        local ok, perkType = pcall(perk.getType, perk)
        if ok and perkType then return tostring(perkType) end
    end

    return tostring(perk)
end

local function getPerkFromName(perkName)
    if not perkName then return nil end

    if perkCache[perkName] then
        return perkCache[perkName]
    end

    local foundPerk = nil

    if Perks and Perks[perkName] then
        foundPerk = Perks[perkName]
    elseif PerkFactory and PerkFactory.getPerkFromName then
        local ok, perk = pcall(PerkFactory.getPerkFromName, perkName)
        if ok and perk then foundPerk = perk end
    end

    if not foundPerk and PerkFactory and PerkFactory.PerkList then
        for _, perk in xpairs(PerkFactory.PerkList) do
            if perk and getPerkName(perk) == perkName then
                foundPerk = perk
                break
            end
        end
    end

    if foundPerk then
        perkCache[perkName] = foundPerk
    end

    return foundPerk
end

local function getLocalizedPerkName(perkName)
    local perk = getPerkFromName(perkName)
    if perk and perk.getName then
        local ok, name = pcall(perk.getName, perk)
        if ok and name then return tostring(name) end
    end
    return perkName
end

-----------------------------------------------------------
-- Authority XP tracking
-----------------------------------------------------------

local function ensureAuthority()
    return MSR.Env and MSR.Env.hasServerAuthority and MSR.Env.hasServerAuthority()
end

local function enableTrackingFor(username, generation, reason)
    local record = earnedByUsername[username]
    if not record or record.generation ~= generation then return end

    record.ready = true
    LOG.info("XP tracking enabled for %s (%s)", tostring(username), tostring(reason or "unknown"))
end

local function createTrackingRecord(player, username, reason, resetExisting)
    local previous = earnedByUsername[username]
    if previous and not resetExisting then
        LOG.debug("EnsureTracking skipped for %s (reason=%s ready=%s generation=%s)",
            tostring(username), tostring(reason or "unknown"), tostring(previous.ready), tostring(previous.generation))
        return true
    end

    local generation = ((previous and previous.generation) or 0) + 1
    earnedByUsername[username] = {
        ready = false,
        xp = {},
        generation = generation,
        createdReason = reason
    }

    if resetExisting then
        LOG.info("StartTracking reset for %s (reason=%s generation=%d)",
            tostring(username), tostring(reason or "unknown"), generation)
    else
        LOG.info("EnsureTracking created for %s (reason=%s generation=%d)",
            tostring(username), tostring(reason or "unknown"), generation)
    end

    MSR.delayWithPlayer(TRACKING_GATE_TICKS, player, function()
        enableTrackingFor(username, generation, reason)
    end)

    return true
end

function XPR.EnsureTracking(player, reason)
    if not ensureAuthority() then return false end
    if not Config.getEssenceEnabled() then return false end

    local username = getPlayerUsername(player)
    if not username then return false end

    return createTrackingRecord(player, username, reason, false)
end

function XPR.StartTracking(player, reason)
    if not ensureAuthority() then return false end
    if not Config.getEssenceEnabled() then return false end

    local username = getPlayerUsername(player)
    if not username then return false end

    return createTrackingRecord(player, username, reason, true)
end

function XPR.RecordXp(player, perk, amount)
    if not ensureAuthority() then return false end
    if suppressXpRecording > 0 then return false end
    if not player or not perk or type(amount) ~= "number" then return false end

    local username = getPlayerUsername(player)
    if not username then return false end

    local record = earnedByUsername[username]
    if not record then
        XPR.EnsureTracking(player, "addxp")
        record = earnedByUsername[username]
    end

    if not record then
        LOG.debug("RecordXp ignored: tracking missing for %s", tostring(username))
        return false
    end

    if not record.ready then
        LOG.debug("RecordXp ignored: tracking gate queued for %s (reason=%s generation=%s)",
            tostring(username), tostring(record.createdReason or "unknown"), tostring(record.generation))
        return false
    end

    local perkName = getPerkName(perk)
    if not perkName then return false end

    local current = record.xp[perkName] or 0
    local nextAmount = math.max(0, current + amount)
    record.xp[perkName] = nextAmount

    LOG.debug(string.format("Tracked XP: %s %+.3f (total: %.3f)",
        perkName, amount, nextAmount))

    return true
end

function XPR.ConsumeEarnedXpSnapshot(player, deathArgs)
    if not ensureAuthority() then return {} end

    local username = (deathArgs and deathArgs.username) or getPlayerUsername(player)
    if not username then return {} end

    local record = earnedByUsername[username]
    earnedByUsername[username] = nil

    if not record then
        LOG.debug("No XP tracking record to consume for %s", tostring(username))
        return {}
    end

    local xpMap, total = copyPositiveXpMap(record.xp)
    local count = K.count(xpMap)

    LOG.debug("Consumed XP snapshot for %s: perks=%d total=%.3f ready=%s generation=%s",
        tostring(username), count, total, tostring(record.ready), tostring(record.generation))

    return xpMap
end

local function onAddXP(player, perk, amount)
    XPR.RecordXp(player, perk, amount)
end

-----------------------------------------------------------
-- Essence creation
-----------------------------------------------------------

local function prepareEssenceItem(username, xpMap)
    local essence = instanceItem and instanceItem(Config.ESSENCE_ITEM)
    if not essence then return nil end

    local itemMd = MSR.World.getModData(essence)
    if not itemMd then return nil end

    itemMd.msrXpEssence = true
    itemMd.msrXpEssenceVersion = ESSENCE_VERSION
    itemMd.ownerUsername = username
    itemMd.createdTs = K.time()
    itemMd.xp = xpMap

    return essence
end

local function placeEssenceItem(corpse, x, y, z, essence)
    x = x or 0
    y = y or 0
    z = z or 0

    if corpse and corpse.getContainer then
        local container = corpse:getContainer()
        if container and container.AddItem then
            local added = container:AddItem(essence)
            if added then
                if MSR.Env.isServer() and sendAddItemToContainer then
                    sendAddItemToContainer(container, added)
                end
                return added, "corpse inventory"
            end
        end
    end

    local square = MSR.World.getSquare(x, y, z)
    if square then
        local added = square:AddWorldInventoryItem(essence, 0.5, 0.5, 0, true)
        if added then
            return added, string.format("ground at (%d, %d, %d)", x, y, z)
        end
    end

    return nil, nil
end

function XPR.CreateEssenceFromSnapshot(args)
    if not ensureAuthority() then
        LOG.info("Skipping essence creation: no server authority")
        return
    end
    if not args then
        LOG.warning("MSR_CorpseFound received without args")
        return
    end

    local corpse = args.corpse
    local username = args.username
    local earnedXp = args.earnedXp
    local earnedXpCount, earnedXpTotal = summarizeXpMap(earnedXp)

    LOG.info("MSR_CorpseFound: user=%s pos=%s,%s,%s corpse=%s earnedXpEntries=%d rawTotal=%.3f",
        tostring(username), tostring(args.x), tostring(args.y), tostring(args.z),
        tostring(corpse ~= nil), earnedXpCount, earnedXpTotal)

    if not username then
        LOG.warning("Skipping essence creation: missing username")
        return
    end

    local xpMap, totalXp = copyPositiveXpMap(earnedXp)
    local xpCount = K.count(xpMap)
    if totalXp <= 0 then
        LOG.info("No earned XP to preserve for %s (entries=%d rawTotal=%.3f)",
            username, earnedXpCount, earnedXpTotal)
        return
    end

    local essence = prepareEssenceItem(username, xpMap)
    if not essence then
        LOG.warning("Failed to create essence item instance for %s", tostring(username))
        return
    end

    local placedEssence, location = placeEssenceItem(corpse, args.x, args.y, args.z, essence)
    if not placedEssence then
        LOG.warning("Failed to place essence item for %s at %s,%s,%s", username,
            tostring(args.x), tostring(args.y), tostring(args.z))
        return
    end

    LOG.info("Created essence with %.1f XP (%d perks) for %s at %s",
        totalXp, xpCount, username, location)

    MSR.Events.Custom.Fire("MSR_EssenceCreated", {
        username = username,
        essence = placedEssence,
        location = location
    })
end

-----------------------------------------------------------
-- Essence absorption
-----------------------------------------------------------

local function showAbsorptionFeedback(player, appliedPerks)
    if not player or not appliedPerks then return end

    player:getEmitter():playSound("GainExperienceLevel")

    local lines = {}
    for perkName, xpAmount in pairs(appliedPerks) do
        local displayName = getLocalizedPerkName(perkName)
        table.insert(lines, string.format("+%.1f %s XP", xpAmount, displayName))
    end

    if #lines > 0 then
        local text = table.concat(lines, " [br/] ")
        HaloTextHelper.addText(player, text, " [br/] ", HaloTextHelper.getColorGreen())
    end
end

local function grantRecoveredXp(player, perk, amount)
    -- Recovery semantics: no XP multiplier, and recovered XP is not tracked as newly earned.
    if not addXpNoMultiplier then return false end

    suppressXpRecording = suppressXpRecording + 1
    local ok, err = pcall(addXpNoMultiplier, player, perk, amount)
    suppressXpRecording = math.max(0, suppressXpRecording - 1)

    if not ok then
        LOG.warning("Failed to grant recovered XP: %s", tostring(err))
        return false
    end

    return true
end

local function applyXpMapToPlayer(player, xpMap, retentionFactor)
    if not player or not xpMap then return 0, {} end
    if type(retentionFactor) ~= "number" then retentionFactor = 1 end

    local appliedTotal = 0
    local appliedPerks = {}

    for perkName, amount in pairs(xpMap) do
        if type(amount) == "number" and amount > 0 then
            local perk = getPerkFromName(perkName)
            if perk then
                local appliedAmount = amount * retentionFactor
                if appliedAmount > 0 and grantRecoveredXp(player, perk, appliedAmount) then
                    appliedTotal = appliedTotal + appliedAmount
                    appliedPerks[perkName] = appliedAmount
                end
            else
                LOG.warning("Unknown perk in essence: %s", tostring(perkName))
            end
        end
    end

    return appliedTotal, appliedPerks
end

local function removeEssenceItem(item)
    if not item then return end

    local container = item:getContainer()
    if container then
        container:DoRemoveItem(item)
        if MSR.Env.isServer() and sendRemoveItemFromContainer then
            sendRemoveItemFromContainer(container, item)
        end
    end
end

local function canAbsorbEssence(player, itemMd)
    if MSR.Env.isSingleplayer() then return true end
    if not itemMd.ownerUsername then return true end

    local username = getPlayerUsername(player)
    return username and itemMd.ownerUsername == username
end

local function hasContainer(containers, target)
    if not target then return false end

    for _, container in ipairs(containers or {}) do
        if container == target then
            return true
        end
    end

    return false
end

local function resolveInventoryEssence(player, itemOrItemId)
    if not player or not itemOrItemId then return nil, "Invalid arguments" end

    local containers = MSR.Inventory.getPlayerContainers(player, true)
    if not containers or #containers == 0 then return nil, "No inventory" end

    local item = itemOrItemId
    local actualContainer = nil
    local foundById = false
    if type(itemOrItemId) == "number" then
        item, actualContainer = MSR.Inventory.findItemById(containers, itemOrItemId)
        foundById = item ~= nil
    elseif type(itemOrItemId) == "string" then
        local itemId = tonumber(itemOrItemId)
        if not itemId then return nil, "Invalid item id" end
        item, actualContainer = MSR.Inventory.findItemById(containers, itemId)
        foundById = item ~= nil
    elseif item and item.getContainer then
        actualContainer = item:getContainer()
    end

    if not item then return nil, "Item not in inventory" end
    if not item.getFullType or item:getFullType() ~= Config.ESSENCE_ITEM then return nil, "Not an essence item" end

    actualContainer = actualContainer or (item.getContainer and item:getContainer())
    if not actualContainer then return nil, "Item not in inventory" end
    if not foundById and not hasContainer(containers, actualContainer) then return nil, "Item not in inventory" end
    if actualContainer.contains and not actualContainer:contains(item) then return nil, "Item not in inventory" end

    return item, nil
end

function XPR.HandleAbsorbRequest(player, itemOrItemId)
    if not ensureAuthority() then return false, "No authority" end

    local username = getPlayerUsername(player)
    if not username then return false, "Invalid player" end

    local item, resolveErr = resolveInventoryEssence(player, itemOrItemId)
    if not item then
        LOG.debug("XPEssenceAbsorb: %s for %s", tostring(resolveErr), tostring(username))
        return false, "ESSENCE_EMPTY"
    end

    local itemMd = MSR.World.getModData(item)
    if not itemMd or not itemMd.msrXpEssence then
        LOG.debug("XPEssenceAbsorb: not a valid essence for %s", tostring(username))
        return false, "ESSENCE_EMPTY"
    end

    if not canAbsorbEssence(player, itemMd) then
        LOG.debug("XPEssenceAbsorb: essence belongs to %s, not %s",
            tostring(itemMd.ownerUsername), tostring(username))
        return false, "ESSENCE_NOT_YOURS"
    end

    local xpMap = itemMd.xp
    if not xpMap or K.isEmpty(xpMap) then
        LOG.debug("XPEssenceAbsorb: empty essence for %s", tostring(username))
        return false, "ESSENCE_EMPTY"
    end

    if not MSR.safePlayerCall(player, "getXp") then
        LOG.debug("XPEssenceAbsorb: no XP system for %s", tostring(username))
        return false, "ESSENCE_EMPTY"
    end

    local retentionFactor = Config.getEssenceRetentionPercent() / 100
    local appliedTotal, appliedPerks = applyXpMapToPlayer(player, xpMap, retentionFactor)

    if appliedTotal <= 0 then
        LOG.warning("XPEssenceAbsorb: failed to apply recovered XP for %s", tostring(username))
        return false, "ESSENCE_EMPTY"
    end

    removeEssenceItem(item)

    LOG.info(string.format("XPEssenceAbsorb: applied %.1f XP for %s", appliedTotal, username))
    return true, nil, appliedTotal, appliedPerks
end

function XPR.AbsorbEssence(player, item)
    if not player or not item then return end
    if item:getFullType() ~= Config.ESSENCE_ITEM then return end

    local playerInventory = MSR.safePlayerCall(player, "getInventory")
    if not playerInventory then return end

    local itemContainer = item:getContainer()

    if itemContainer ~= playerInventory then
        ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, item, itemContainer,
            playerInventory))
    end

    ISTimedActionQueue.add(ISAbsorbEssenceAction:new(player, item))
end

function XPR.DoAbsorb(player, item)
    if not player or not item then return end

    local resolvedItem = resolveInventoryEssence(player, item)
    if not resolvedItem then return end

    if ensureAuthority() then
        local success, message, _, appliedPerks = XPR.HandleAbsorbRequest(player, resolvedItem)
        if success then
            showAbsorptionFeedback(player, appliedPerks)
            PM.Say(player, "ESSENCE_ABSORBED")
        elseif message then
            PM.Say(player, message)
        end
    else
        sendClientCommand(Config.COMMAND_NAMESPACE, Config.COMMANDS.XP_ESSENCE_ABSORB, {
            itemId = resolvedItem:getID()
        })
    end
end

-----------------------------------------------------------
-- Context menu
-----------------------------------------------------------

local function findEssenceInSelection(items)
    for _, itemOrTable in pairs(items) do
        local item = itemOrTable

        if type(itemOrTable) == "table" then
            if itemOrTable.items then
                item = itemOrTable.items[1]
            elseif not itemOrTable.getFullType then
                for _, subItem in pairs(itemOrTable) do
                    if subItem and subItem.getFullType then
                        item = subItem
                        break
                    end
                end
            end
        end

        if item and item.getFullType and item:getFullType() == Config.ESSENCE_ITEM then
            return item
        end
    end
    return nil
end

local function onFillInventoryObjectContextMenu(playerNum, context, items)
    if not context or not items then return end

    local player = getSpecificPlayer(playerNum)
    if not player then return end

    local essenceItem = findEssenceInSelection(items)
    if not essenceItem then return end

    context:addOption(getText("IGUI_MSR_AbsorbEssence"), player, function()
        XPR.AbsorbEssence(player, essenceItem)
    end)
end

-----------------------------------------------------------
-- Event registration
-----------------------------------------------------------

require "00_core/Events"

local clientRegistered = false
local authorityRegistered = false

local function isSandboxReady()
    return SandboxVars and SandboxVars.MySpatialRefuge ~= nil
end

local function withSandboxReady(tag, callback)
    if MSR.Env.isMultiplayerClient() and not isSandboxReady() then
        MSR.waitFor(function()
            return isSandboxReady()
        end, function()
            callback()
        end, 600, function()
            LOG.warning("Sandbox settings not ready; skipping %s registration", tag)
        end)
        return
    end

    callback()
end

local function onServerCommand(module, command, args)
    if module ~= Config.COMMAND_NAMESPACE then return end
    if command ~= Config.COMMANDS.XP_ESSENCE_APPLY then return end
    if not args then return end

    local player = getPlayer()
    if not player then return end

    local appliedPerks = args.appliedPerks
    if not appliedPerks then return end

    local appliedTotal = args.totalXp or 0
    if appliedTotal <= 0 then
        for _, amount in pairs(appliedPerks) do
            if type(amount) == "number" and amount > 0 then
                appliedTotal = appliedTotal + amount
            end
        end
    end

    if appliedTotal > 0 then
        showAbsorptionFeedback(player, appliedPerks)
        PM.Say(player, "ESSENCE_ABSORBED")
        LOG.info(string.format("Client displayed absorbed %.1f total XP", appliedTotal))
    end
end

local function registerClientHandlers()
    if clientRegistered then return end
    if not Config.getEssenceEnabled() then
        LOG.info("XP essence disabled - skipping client registration")
        return
    end

    clientRegistered = true

    if Events.OnFillInventoryObjectContextMenu then
        Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
    end

    if Events.OnServerCommand then
        Events.OnServerCommand.Add(onServerCommand)
    end
end

local function registerAuthorityHandlers()
    if authorityRegistered then return end
    if not ensureAuthority() then return end
    if not Config.getEssenceEnabled() then
        LOG.info("XP essence disabled - skipping authority registration")
        return
    end

    authorityRegistered = true

    if Events.AddXP then
        Events.AddXP.Add(onAddXP)
    end

    if Events.OnCreatePlayer then
        Events.OnCreatePlayer.Add(function(_, player)
            XPR.StartTracking(player, "create")
        end)
    end

    if Events.OnPlayerConnect then
        Events.OnPlayerConnect.Add(function(player)
            XPR.StartTracking(player, "connect")
        end)
    end

    MSR.Events.Custom.Add("MSR_CorpseFound", XPR.CreateEssenceFromSnapshot)

    local player = getPlayer and getPlayer()
    if player then
        XPR.StartTracking(player, "ready")
    end
end

MSR.Events.OnClientReady.Add(function()
    withSandboxReady("client", registerClientHandlers)
end)

MSR.Events.OnServerReady.Add(function()
    withSandboxReady("authority", registerAuthorityHandlers)
end)

return MSR.XPRetention
