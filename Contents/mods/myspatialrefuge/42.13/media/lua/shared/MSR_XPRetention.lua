-- MSR_XPRetention - Souls-like XP retention system
-- Tracks naturally earned XP and creates an "Experience Essence" on death
-- that can be absorbed by the next character to recover a portion of the XP.

require "shared/00_core/00_MSR"
require "shared/00_core/04_Env"
require "shared/00_core/05_Config"
require "shared/MSR_PlayerMessage"

if MSR.XPRetention and MSR.XPRetention._loaded then
    return MSR.XPRetention
end

MSR.XPRetention = MSR.XPRetention or {}
MSR.XPRetention._loaded = true

local XPR = MSR.XPRetention
local PM = MSR.PlayerMessage
local Config = MSR.Config

PM.Register("ESSENCE_ABSORBED", "IGUI_MSR_EssenceAbsorbed")
PM.Register("ESSENCE_NOT_YOURS", "IGUI_MSR_EssenceNotYours")
PM.Register("ESSENCE_EMPTY", "IGUI_MSR_EssenceEmpty")

-----------------------------------------------------------
-- Perk Utilities
-----------------------------------------------------------

-- Cache for perk name → perk object lookups (cleared on game restart)
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
    
    -- Slow fallback for mod-added perks
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
    if not MSR.Env.hasServerAuthority() then return end
    if not Config.ESSENCE_ENABLED then return end
    if not player or not perk or type(amount) ~= "number" then return end
    
    local pmd = player:getModData()
    if not pmd or not pmd.MSR_XPTrackingReady then return end
    
    pmd.MSR_XPEarnedXp = pmd.MSR_XPEarnedXp or {}
    
    local perkName = getPerkName(perk)
    if not perkName then return end
    
    local current = pmd.MSR_XPEarnedXp[perkName] or 0
    pmd.MSR_XPEarnedXp[perkName] = math.max(0, current + amount)
    
    L.debug("XPRetention", string.format("Tracked XP: %s %+.3f (total: %.3f)", 
        perkName, amount, pmd.MSR_XPEarnedXp[perkName]))
end

local function enableXPTracking(player)
    if not player then return end
    
    local pmd = player:getModData()
    if not pmd or pmd.MSR_XPTrackingReady then return end
    
    pmd.MSR_XPTrackingReady = true
    pmd.MSR_XPEarnedXp = pmd.MSR_XPEarnedXp or {}
    
    L.debug("XPRetention", "XP tracking enabled for " .. (player:getUsername() or "unknown"))
end

-- Delays XP tracking to skip profession/starting XP applied during character creation
local function setupTrackingGate(player)
    if not player then return end
    if not MSR.Env.hasServerAuthority() then return end
    if not Config.ESSENCE_ENABLED then return end
    
    local tickCount = 0
    local playerRef = player
    
    local function delayedEnable()
        tickCount = tickCount + 1
        if tickCount < 10 then return end
        
        Events.OnTick.Remove(delayedEnable)
        local currentPlayer = MSR.resolvePlayer(playerRef)
        if currentPlayer then
            enableXPTracking(currentPlayer)
        end
    end
    
    Events.OnTick.Add(delayedEnable)
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

local function createEssenceItem(player)
    local inventory = player:getInventory()
    if inventory then
        local essence = inventory:AddItem(Config.ESSENCE_ITEM)
        if essence then
            return essence, "player inventory (will be in corpse)"
        end
    end
    
    -- Fallback to ground
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
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

local function createEssenceOnDeath(player)
    if not MSR.Env.hasServerAuthority() then return end
    if not Config.ESSENCE_ENABLED then return end
    if not player then return end
    
    local username = player:getUsername()
    local pmd = player:getModData()
    if not username or not pmd then return end
    
    local xpMap, totalXp = buildXpMap(pmd.MSR_XPEarnedXp)
    if totalXp <= 0 then
        L.debug("XPRetention", "No earned XP to preserve for " .. username)
        return
    end
    
    L.debug("XPRetention", string.format("Creating essence for %s: %.3f total XP", username, totalXp))
    
    local essence, location = createEssenceItem(player)
    if not essence then
        L.debug("XPRetention", "FAILED to create essence for " .. username)
        return
    end
    
    local itemMd = essence:getModData()
    itemMd.msrXpEssence = true
    itemMd.ownerUsername = username
    itemMd.createdTs = K.time()
    itemMd.xp = xpMap
    
    pmd.MSR_XPEarnedXp = {}
    transmitModData()
    
    L.debug("XPRetention", string.format("Created essence with %.3f XP for %s at %s", 
        totalXp, username, location))
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

local function removeEssenceItem(item)
    local container = item:getContainer()
    if container then
        container:DoRemoveItem(item)
        if MSR.Env.isServer() then
            sendRemoveItemFromContainer(container, item)
        end
    end
end

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
    L.debug("XPRetention", string.format("Absorbing essence with %.0f%% retention", retentionPercent))
    
    local appliedTotal = 0
    local appliedPerks = {}
    
    for perkName, amount in pairs(xpMap) do
        if type(amount) == "number" and amount > 0 then
            local perk = getPerkFromName(perkName)
            if perk then
                local retainedAmount = amount * retentionFactor
                xpSystem:AddXP(perk, retainedAmount)
                appliedTotal = appliedTotal + retainedAmount
                appliedPerks[perkName] = retainedAmount
                L.debug("XPRetention", string.format("Applied %.3f XP to %s (%.3f * %.0f%%)", 
                    retainedAmount, perkName, amount, retentionPercent))
            else
                L.debug("XPRetention", "Could not find perk: " .. perkName)
            end
        end
    end
    
    if appliedTotal > 0 then
        showAbsorptionFeedback(player, appliedPerks)
    end
    
    removeEssenceItem(item)
    
    L.debug("XPRetention", string.format("Absorbed %.3f total XP for %s", appliedTotal, username))
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
    
    if MSR.Env.isSingleplayer() or MSR.Env.isCoopHost() then
        local success, result = XPR.ApplyEssence(player, item)
        if success then
            PM.Say(player, "ESSENCE_ABSORBED")
        else
            L.debug("XPRetention", "Absorb failed: " .. tostring(result))
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

local function initializeXPRetention()
    L.debug("XPRetention", "Initializing XP Retention system...")
    
    if Events.AddXP then
        Events.AddXP.Add(onAddXP)
        L.debug("XPRetention", "Registered AddXP hook")
    end
    
    if Events.OnFillInventoryObjectContextMenu then
        Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
        L.debug("XPRetention", "Registered inventory context menu hook")
    end
end

Events.OnGameStart.Add(function()
    initializeXPRetention()
    local player = getPlayer()
    if player then
        setupTrackingGate(player)
    end
end)

if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(function(_, player)
        if player then setupTrackingGate(player) end
    end)
end

if Events.OnPlayerDeath then
    Events.OnPlayerDeath.Add(createEssenceOnDeath)
end

L.debug("XPRetention", "Module loaded")

return MSR.XPRetention
