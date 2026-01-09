-- MSR_UpgradeData - Upgrade definitions and query API

require "shared/00_core/00_MSR"
require "shared/CUI_YamlParser"
require "shared/00_core/05_Config"
require "shared/00_core/06_Data"

if MSR.UpgradeData and MSR.UpgradeData._loaded then
    return MSR.UpgradeData
end

MSR.UpgradeData = {
    _loaded = true,
    _upgrades = {},
    _categories = {},
    _initialized = false
}

local UpgradeData = MSR.UpgradeData

-- Upgrade Definitions (Lua primary, YAML extends)

local UPGRADE_DEFINITIONS = {
    expand_refuge = { -- synced with refuge tier
        id = "expand_refuge",
        name = "UI_Upgrade_ExpandRefuge",
        icon = "media/textures/Item_Map.png",
        category = "shelter",
        maxLevel = 8,
        dependencies = {},
        levels = {
            [1] = {
                description = "UI_Upgrade_ExpandRefuge_L1",
                effects = { refugeSize = 5 },
                requirements = {
                    { type = "Base.MagicalCore", count = 5 }
                }
            },
            [2] = {
                description = "UI_Upgrade_ExpandRefuge_L2",
                effects = { refugeSize = 7 },
                requirements = {
                    { type = "Base.MagicalCore", count = 10 }
                }
            },
            [3] = {
                description = "UI_Upgrade_ExpandRefuge_L3",
                effects = { refugeSize = 9 },
                requirements = {
                    { type = "Base.MagicalCore", count = 20 }
                }
            },
            [4] = {
                description = "UI_Upgrade_ExpandRefuge_L4",
                effects = { refugeSize = 11 },
                requirements = {
                    { type = "Base.MagicalCore", count = 35 }
                }
            },
            [5] = {
                description = "UI_Upgrade_ExpandRefuge_L5",
                effects = { refugeSize = 13 },
                requirements = {
                    { type = "Base.MagicalCore", count = 50 }
                }
            },
            [6] = {
                description = "UI_Upgrade_ExpandRefuge_L6",
                effects = { refugeSize = 15 },
                requirements = {
                    { type = "Base.MagicalCore", count = 75 }
                }
            },
            [7] = {
                description = "UI_Upgrade_ExpandRefuge_L7",
                effects = { refugeSize = 17 },
                requirements = {
                    { type = "Base.MagicalCore", count = 100 }
                }
            },
            [8] = {
                description = "UI_Upgrade_ExpandRefuge_L8",
                effects = { refugeSize = 19 },
                requirements = {
                    { type = "Base.MagicalCore", count = 150 }
                }
            }
        }
    },
}

-- Helpers

--- Get upgrades from refugeData (per-refuge, not per-player for future coop)
local function getRefugeUpgradeData(player)
    if not player then return nil, nil end
    local username = nil
    if type(player) == "userdata" or type(player) == "table" then
        if player.getUsername then
            local ok, name = pcall(function() return player:getUsername() end)
            if ok and name then
                username = name
            end
        end
    end
    
    if not username then return nil, nil end
    
    local refugeData = MSR.Data and MSR.Data.GetRefugeDataByUsername and MSR.Data.GetRefugeDataByUsername(username)
    if not refugeData then return nil, nil end
    
    -- Init upgrades table for legacy refuges (PZ doesn't auto-track nested additions)
    if not refugeData.upgrades then
        refugeData.upgrades = {}
        if MSR.Data and MSR.Data.SaveRefugeData then MSR.Data.SaveRefugeData(refugeData) end
    end
    
    return refugeData.upgrades, refugeData
end

local function resolvePlayer(player)
    if not player then return nil end
    if type(player) == "number" and getSpecificPlayer then return getSpecificPlayer(player) end
    
    -- Re-resolve to avoid stale references
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

-- Initialization

local function processUpgrade(id, upgrade, source)
    upgrade.id = id
    upgrade.name = upgrade.name or ("Upgrade_" .. id)
    upgrade.icon = upgrade.icon or "media/ui/upgrades/default.png"
    upgrade.category = upgrade.category or "general"
    upgrade.maxLevel = upgrade.maxLevel or 1
    upgrade.dependencies = upgrade.dependencies or {}
    upgrade.levels = upgrade.levels or {}
    
    local isOverride = UpgradeData._upgrades[id] ~= nil
    UpgradeData._upgrades[id] = upgrade
    
    local cat = upgrade.category
    if not UpgradeData._categories[cat] then UpgradeData._categories[cat] = {} end
    if not isOverride then
        table.insert(UpgradeData._categories[cat], id)
    end
    
    return isOverride
end

function UpgradeData.initialize()
    if UpgradeData._initialized then
        return true
    end
    
    print("[UpgradeData] ========================================")
    print("[UpgradeData] Initializing upgrade data...")
    
    local luaCount = 0
    local yamlCount = 0
    local yamlOverrides = 0
    
    print("[UpgradeData] Loading Lua definitions...")
    for id, upgrade in pairs(UPGRADE_DEFINITIONS) do
        processUpgrade(id, upgrade, "Lua")
        luaCount = luaCount + 1
        print("[UpgradeData]   Lua upgrade: " .. tostring(id))
    end
    print("[UpgradeData] Loaded " .. luaCount .. " upgrades from Lua")
    
    print("[UpgradeData] Attempting to load YAML extensions...")
    local ok, result = pcall(function()
        return CUI_YamlParser.parseFile("myspatialrefuge", "media/lua/shared/upgrades.yaml", {
            expandGroups = true,
            groupsKey = "itemGroups",
            refPrefixes = { "$", "*" },
        })
    end)
    
    if ok and result and result.upgrades then
        for id, upgrade in pairs(result.upgrades) do
            local isOverride = processUpgrade(id, upgrade, "YAML")
            yamlCount = yamlCount + 1
            if isOverride then
                yamlOverrides = yamlOverrides + 1
                print("[UpgradeData]   YAML override: " .. tostring(id))
            else
                print("[UpgradeData]   YAML extension: " .. tostring(id))
            end
        end
        print("[UpgradeData] Loaded " .. yamlCount .. " upgrades from YAML (" .. yamlOverrides .. " overrides)")
    else
        if ok then
            print("[UpgradeData] No YAML upgrades found (file missing or empty)")
        else
            print("[UpgradeData] YAML parse failed: " .. tostring(result))
        end
    end
    
    UpgradeData._initialized = true
    
    local totalCount = 0
    for _ in pairs(UpgradeData._upgrades) do
        totalCount = totalCount + 1
    end
    print("[UpgradeData] Total upgrades loaded: " .. totalCount)
    print("[UpgradeData] ========================================")
    
    return true
end

function UpgradeData.reload()
    UpgradeData._upgrades = {}
    UpgradeData._categories = {}
    UpgradeData._initialized = false
    return MSR.UpgradeData.initialize()
end

-- Query API

function UpgradeData.getUpgrade(id)
    UpgradeData.initialize()
    return MSR.UpgradeData._upgrades[id]
end

function UpgradeData.getAllUpgrades()
    UpgradeData.initialize()
    return MSR.UpgradeData._upgrades
end

function UpgradeData.getAllUpgradeIds()
    UpgradeData.initialize()
    local ids = {}
    for id, _ in pairs(UpgradeData._upgrades) do table.insert(ids, id) end
    table.sort(ids)
    return ids
end

function UpgradeData.getUpgradesByCategory(category)
    UpgradeData.initialize()
    local ids = UpgradeData._categories[category] or {}
    local upgrades = {}
    for _, id in ipairs(ids) do
        table.insert(upgrades, UpgradeData._upgrades[id])
    end
    return upgrades
end

function UpgradeData.getCategories()
    UpgradeData.initialize()
    local categories = {}
    for cat, _ in pairs(UpgradeData._categories) do
        table.insert(categories, cat)
    end
    table.sort(categories)
    return categories
end

function UpgradeData.getLevelData(upgradeId, level)
    local upgrade = UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return nil end
    return upgrade.levels[level] or upgrade.levels[tostring(level)]
end

-- Player Progress API (stored in GlobalModData for future coop)

function UpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    local playerObj = resolvePlayer(player)
    if not playerObj then return 0 end
    
    local upgradeData, refugeData = getRefugeUpgradeData(playerObj)
    
    if upgradeId == MSR.Config.UPGRADES.EXPAND_REFUGE then -- synced with tier
        if refugeData and refugeData.tier then
            return refugeData.tier
        end
        return 0
    end
    
    if not upgradeData then return 0 end
    return upgradeData[upgradeId] or 0
end

--- Only server/SP can modify GlobalModData
function UpgradeData.setPlayerUpgradeLevel(player, upgradeId, level)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false end
    
    if upgradeId == MSR.Config.UPGRADES.EXPAND_REFUGE then return true end -- tier managed by ExpandRefuge
    
    local upgradeData, refugeData = getRefugeUpgradeData(playerObj)
    if not upgradeData or not refugeData then return false end
    
    upgradeData[upgradeId] = level
    
    L.debug("UpgradeData", "setPlayerUpgradeLevel: " .. upgradeId .. "=" .. tostring(level))
    if MSR.Data and MSR.Data.SaveRefugeData then MSR.Data.SaveRefugeData(refugeData) end
    
    return true
end

function UpgradeData.isUpgradeUnlocked(player, upgradeId)
    local upgrade = UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return false end
    
    if upgrade.dependencies and #upgrade.dependencies > 0 then
        for _, depId in ipairs(upgrade.dependencies) do
            local depUpgrade = UpgradeData.getUpgrade(depId)
            if depUpgrade then
                local playerLevel = UpgradeData.getPlayerUpgradeLevel(player, depId)
                if playerLevel < (depUpgrade.maxLevel or 1) then
                    return false
                end
            end
        end
    end
    
    return true
end

function UpgradeData.canUpgrade(player, upgradeId)
    local upgrade = UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return false, "Unknown upgrade" end
    if not UpgradeData.isUpgradeUnlocked(player, upgradeId) then return false, "Dependencies not met" end
    if UpgradeData.getPlayerUpgradeLevel(player, upgradeId) >= upgrade.maxLevel then return false, "Already at max level" end
    return true, nil
end

--- Requirements scaled by D.core() for difficulty
function UpgradeData.getNextLevelRequirements(player, upgradeId)
    local upgrade = UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return nil end
    
    local currentLevel = UpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    local nextLevel = currentLevel + 1
    
    if nextLevel > upgrade.maxLevel then
        return nil
    end
    
    local levelData = UpgradeData.getLevelData(upgradeId, nextLevel)
    if not levelData then return nil end
    
    local requirements = levelData.requirements or {}
    local scaledRequirements = {}
    for _, req in ipairs(requirements) do
        local scaledReq = { type = req.type, count = req.count }
        if req.substitutes then scaledReq.substitutes = req.substitutes end
        -- Scale costs by difficulty
        if req.type == MSR.Config.CORE_ITEM then
            scaledReq.count = D.core(req.count)
        else
            scaledReq.count = D.material(req.count)
        end
        table.insert(scaledRequirements, scaledReq)
    end
    
    return scaledRequirements
end

function UpgradeData.getLevelEffects(upgradeId, level)
    local levelData = UpgradeData.getLevelData(upgradeId, level)
    if not levelData then return {} end
    return levelData.effects or {}
end

--- Aggregated effects: add (default), max (absolute), min (time multipliers)
function UpgradeData.getPlayerActiveEffects(player)
    UpgradeData.initialize()
    local playerObj = resolvePlayer(player)
    if not playerObj then return {} end
    
    local AGGREGATORS = {
        refugeSize = "max",
        readingSpeedMultiplier = "min",
        refugeCastTimeMultiplier = "min",
        relicStorageCapacity = "max",
    }
    
    local function applyEffect(effects, effectName, effectValue)
        if effectName == nil or effectValue == nil then return end
        local mode = AGGREGATORS[effectName] or "add"
        
        if mode == "add" then
            effects[effectName] = (effects[effectName] or 0) + effectValue
        elseif mode == "max" then
            effects[effectName] = math.max(effects[effectName] or effectValue, effectValue)
        elseif mode == "min" then
            effectValue = D.positiveEffect(effectValue) -- difficulty scaling
            effects[effectName] = math.min(effects[effectName] or effectValue, effectValue)
        else
            effects[effectName] = (effects[effectName] or 0) + effectValue
        end
    end
    
    local effects = {}
    
    for id, _ in pairs(UpgradeData._upgrades) do
        local playerLevel = UpgradeData.getPlayerUpgradeLevel(playerObj, id)
        for level = 1, playerLevel do
            local levelEffects = UpgradeData.getLevelEffects(id, level)
            for effectName, effectValue in pairs(levelEffects) do
                applyEffect(effects, effectName, effectValue)
            end
        end
    end
    
    return effects
end

local function onGameStart()
    UpgradeData.initialize()
end

Events.OnGameStart.Add(onGameStart)

print("[UpgradeData] Upgrade data module loaded")

return MSR.UpgradeData

