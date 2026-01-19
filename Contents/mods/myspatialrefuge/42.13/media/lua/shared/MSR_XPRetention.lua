-- MSR_XPRetention - Souls-like XP retention system
-- Tracks naturally earned XP and creates an "Experience Essence" on death
-- that can be absorbed by the next character to recover a portion of the XP.

require "00_core/00_MSR"
require "00_core/Env"
require "00_core/Config"
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

-----------------------------------------------------------
-- Perk Utilities
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
-- Essence Utilities
-----------------------------------------------------------

local function transmitModData()
    if MSR.Data and MSR.Data.TransmitModData then
        MSR.Data.TransmitModData()
    end
end

-----------------------------------------------------------
-- XP Tracking
-----------------------------------------------------------

local function onAddXP(player, perk, amount)
    if not player or not perk or type(amount) ~= "number" then return end

    local localPlayer = getPlayer()
    if not localPlayer or player ~= localPlayer then return end

    local pmd = player:getModData()
    if not pmd or not pmd.MSR_XPTrackingReady then return end

    pmd.MSR_XPEarnedXp = pmd.MSR_XPEarnedXp or {}

    local perkName = getPerkName(perk)
    if not perkName then return end

    local current = pmd.MSR_XPEarnedXp[perkName] or 0
    pmd.MSR_XPEarnedXp[perkName] = math.max(0, current + amount)

    LOG.debug( string.format("Tracked XP: %s %+.3f (total: %.3f)",
        perkName, amount, pmd.MSR_XPEarnedXp[perkName]))
end

local function enableXPTracking(player)
    if not player then return end

    local pmd = player:getModData()
    if not pmd or pmd.MSR_XPTrackingReady then return end

    pmd.MSR_XPTrackingReady = true
    pmd.MSR_XPEarnedXp = pmd.MSR_XPEarnedXp or {}

    LOG.debug( "XP tracking enabled for " .. (player:getUsername() or "unknown"))
end

local function setupTrackingGate(player)
    if not player then return end

    local localPlayer = getPlayer()
    if not localPlayer or player ~= localPlayer then return end

    local pmd = player:getModData()
    if not pmd then return end
    if pmd.MSR_XPTrackingGateStarted then return end
    pmd.MSR_XPTrackingGateStarted = true

    MSR.delayWithPlayer(10, player, enableXPTracking)
end

-----------------------------------------------------------
-- Essence Creation
-----------------------------------------------------------

local function buildXpMap(earnedXp)
    local xpMap = {}
    local total = 0

    for perkName, amount in pairs(earnedXp or {}) do
        if type(amount) == "number" and amount > 0 then
            xpMap[perkName] = amount
            total = total + amount
        end
    end

    return xpMap, total
end

local function createEssenceItem(corpse, x, y, z)
    x = x or 0
    y = y or 0
    z = z or 0

    if corpse and corpse.getContainer then
        local container = corpse:getContainer()
        if container and container.AddItem then
            local essence = container:AddItem(Config.ESSENCE_ITEM)
            if essence then
                return essence, "corpse inventory"
            end
        end
    end

    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, z)

    if square then
        local essence = square:AddWorldInventoryItem(Config.ESSENCE_ITEM, 0.5, 0.5, 0)
        if essence then
            return essence, string.format("ground at (%d, %d, %d)", x, y, z)
        end
    end

    return nil, nil
end

local function createEssenceOnCorpseFound(args)
    if not MSR.Env.hasServerAuthority() then return end

    local corpse = args.corpse
    local username = args.username
    local earnedXp = args.earnedXp

    if not username then return end

    local xpMap, totalXp = buildXpMap(earnedXp)
    if totalXp <= 0 then
        LOG.debug( "No earned XP to preserve for " .. username)
        return
    end

    local essence, location = createEssenceItem(corpse, args.x, args.y, args.z)
    if not essence then return end

    local itemMd = essence:getModData()
    itemMd.msrXpEssence = true
    itemMd.ownerUsername = username
    itemMd.createdTs = K.time()
    itemMd.xp = xpMap

    transmitModData()

    LOG.debug( string.format("Created essence with %.1f XP for %s at %s",
        totalXp, username, location))

    MSR.Events.Custom.Fire("MSR_EssenceCreated", {
        username = username,
        essence = essence,
        location = location
    })
end

-----------------------------------------------------------
-- Essence Absorption
-----------------------------------------------------------

local function showAbsorptionFeedback(player, appliedPerks)
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
                if appliedAmount > 0 then
                    sendAddXp(player, perk, appliedAmount, true)
                    appliedTotal = appliedTotal + appliedAmount
                    appliedPerks[perkName] = appliedAmount
                end
            end
        end
    end

    return appliedTotal, appliedPerks
end

local function removeEssenceItem(item)
    local container = item:getContainer()
    if container then
        container:DoRemoveItem(item)
        if MSR.Env.isServer() then
            sendRemoveItemFromContainer(container, item)
        end
    end
end

XPR.RemoveEssenceItem = removeEssenceItem

local function canAbsorbEssence(player, itemMd)
    if MSR.Env.isSingleplayer() then return true end
    if not itemMd.ownerUsername then return true end

    local username = player:getUsername()
    return username and itemMd.ownerUsername == username
end

function XPR.ApplyEssence(player, item)
    if not player or not item then return false, "Invalid arguments" end

    local username = player:getUsername()
    if not username then return false, "Invalid player" end

    local itemMd = item:getModData()
    if not itemMd or not itemMd.msrXpEssence then
        return false, "Not a valid essence"
    end

    if not canAbsorbEssence(player, itemMd) then
        return false, "Not your essence"
    end

    local xpMap = itemMd.xp
    if not xpMap or K.isEmpty(xpMap) then
        return false, "Empty essence"
    end

    local xpSystem = player:getXp()
    if not xpSystem then return false, "No XP system" end

    local retentionPercent = Config.getEssenceRetentionPercent()
    local retentionFactor = retentionPercent / 100

    local appliedTotal, appliedPerks = applyXpMapToPlayer(player, xpMap, retentionFactor)

    if appliedTotal > 0 then
        showAbsorptionFeedback(player, appliedPerks)
    end

    removeEssenceItem(item)

    LOG.debug( string.format("Absorbed %.1f total XP for %s", appliedTotal, username))
    return true, appliedTotal
end

function XPR.AbsorbEssence(player, item)
    if not player or not item then return end

    local itemMd = item:getModData()
    if not itemMd or not itemMd.msrXpEssence then
        PM.Say(player, "ESSENCE_EMPTY")
        return
    end

    if not canAbsorbEssence(player, itemMd) then
        PM.Say(player, "ESSENCE_NOT_YOURS")
        return
    end

    if not itemMd.xp or K.isEmpty(itemMd.xp) then
        PM.Say(player, "ESSENCE_EMPTY")
        return
    end

    local playerInventory = player:getInventory()
    local itemContainer = item:getContainer()

    if itemContainer ~= playerInventory then
        ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, item, itemContainer,
            playerInventory))
    end

    ISTimedActionQueue.add(ISAbsorbEssenceAction:new(player, item))
end

function XPR.DoAbsorb(player, item)
    if not player or not item then return end

    local playerInventory = player:getInventory()
    if not playerInventory then return end

    local inInventory
    if isClient() then
        inInventory = playerInventory:containsID(item:getID())
    else
        inInventory = playerInventory:contains(item)
    end

    if not inInventory then return end

    if MSR.Env.isSingleplayer() then
        local success = XPR.ApplyEssence(player, item)
        if success then
            PM.Say(player, "ESSENCE_ABSORBED")
        end
    else
        sendClientCommand(Config.COMMAND_NAMESPACE, Config.COMMANDS.XP_ESSENCE_ABSORB, {
            itemId = item:getID()
        })
    end
end

-----------------------------------------------------------
-- Context Menu
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
-- Event Registration
-----------------------------------------------------------

require "00_core/Events"

local clientRegistered = false
local serverRegistered = false

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
            LOG.warning( "Sandbox settings not ready; skipping %s registration", tag)
        end)
        return
    end

    callback()
end

local function onServerCommand(module, command, args)
    if module ~= Config.COMMAND_NAMESPACE then return end
    if command ~= Config.COMMANDS.XP_ESSENCE_APPLY then return end

    local player = getPlayer()
    if not player then return end

    local xpMap = args.xpMap
    if not xpMap then return end

    local appliedTotal, appliedPerks = applyXpMapToPlayer(player, xpMap, 1)

    if appliedTotal > 0 then
        showAbsorptionFeedback(player, appliedPerks)
        PM.Say(player, "ESSENCE_ABSORBED")
        LOG.debug( string.format("Client absorbed %.1f total XP", appliedTotal))
    end
end

local function onCreatePlayer(_, player)
    if player then setupTrackingGate(player) end
end

local function registerClientHandlers()
    if clientRegistered then return end
    if not Config.getEssenceEnabled() then
        LOG.debug( "XP essence disabled - skipping client registration")
        return
    end

    clientRegistered = true

    if Events.AddXP then
        Events.AddXP.Add(onAddXP)
    end

    if Events.OnFillInventoryObjectContextMenu then
        Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
    end

    if Events.OnServerCommand then
        Events.OnServerCommand.Add(onServerCommand)
    end

    if Events.OnCreatePlayer then
        Events.OnCreatePlayer.Add(onCreatePlayer)
    end

    local player = getPlayer()
    if player then
        setupTrackingGate(player)
    end
end

local function registerServerHandlers()
    if serverRegistered then return end
    if not Config.getEssenceEnabled() then
        LOG.debug( "XP essence disabled - skipping server registration")
        return
    end

    serverRegistered = true
    MSR.Events.Custom.Add("MSR_CorpseFound", createEssenceOnCorpseFound)
end

MSR.Events.OnClientReady.Add(function()
    withSandboxReady("client", registerClientHandlers)
end)

MSR.Events.OnServerReady.Add(function()
    withSandboxReady("server", registerServerHandlers)
end)

return MSR.XPRetention
