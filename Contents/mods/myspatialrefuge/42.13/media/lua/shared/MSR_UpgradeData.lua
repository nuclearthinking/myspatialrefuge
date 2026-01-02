-- MSR_UpgradeData - Upgrade Data
-- Data loader and query API for the upgrade system
-- Tries YAML first, falls back to Lua definitions

require "shared/MSR"
require "shared/CUI_YamlParser"
require "shared/MSR_Data"

-- Prevent double-loading
if MSR.UpgradeData and MSR.UpgradeData._loaded then
    return MSR.UpgradeData
end

MSR.UpgradeData = {
    _loaded = true,
    _upgrades = {},      -- All upgrade definitions by ID
    _categories = {},    -- Upgrades grouped by category
    _initialized = false
}

-- Local alias
local UpgradeData = MSR.UpgradeData

-----------------------------------------------------------
-- Upgrade Definitions (Lua)
-- Primary source - more reliable than YAML in PZ
-----------------------------------------------------------

local UPGRADE_DEFINITIONS = {
    -- EXPAND REFUGE AREA - Increases refuge size (synced with refuge tier)
    expand_refuge = {
        id = "expand_refuge",
        name = "UI_Upgrade_ExpandRefuge",
        icon = "media/textures/expand_icon_128.png",
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

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

-- Get refuge upgrade data from GlobalModData (refugeData.upgrades)
-- This stores upgrades per-refuge, not per-player, enabling future cooperative play
-- @param player: IsoPlayer or player index
-- @return: upgrades table from refugeData, or nil if not available
local function getRefugeUpgradeData(player)
    if not player then return nil, nil end
    
    -- Get username
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
    
    -- Get refugeData from GlobalModData
    local refugeData = nil
    if MSR.Data and MSR.Data.GetRefugeDataByUsername then
        refugeData = MSR.Data.GetRefugeDataByUsername(username)
    end
    
    if not refugeData then return nil, nil end
    
    -- Ensure upgrades table exists (for existing refuges created before upgrade system)
    -- Must explicitly save to GlobalModData as PZ doesn't track nested table additions automatically
    if not refugeData.upgrades then
        print("[UpgradeData] Initializing missing upgrades table for " .. username)
        refugeData.upgrades = {}
        -- Save to persist the new upgrades field to GlobalModData
        if MSR.Data and MSR.Data.SaveRefugeData then
            MSR.Data.SaveRefugeData(refugeData)
            print("[UpgradeData] Saved initialized upgrades table to GlobalModData")
        end
    end
    
    return refugeData.upgrades, refugeData
end

-- Resolve player reference (handle player index or IsoPlayer)
local function resolvePlayer(player)
    if not player then return nil end
    
    if type(player) == "number" and getSpecificPlayer then
        return getSpecificPlayer(player)
    end
    
    -- Re-resolve by playerNum to avoid stale references
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

-----------------------------------------------------------
-- Initialization
-----------------------------------------------------------
-- Helper to process and register an upgrade
local function processUpgrade(id, upgrade, source)
    -- Ensure ID is set
    upgrade.id = id
    
    -- Ensure required fields have defaults
    upgrade.name = upgrade.name or ("Upgrade_" .. id)
    upgrade.icon = upgrade.icon or "media/ui/upgrades/default.png"
    upgrade.category = upgrade.category or "general"
    upgrade.maxLevel = upgrade.maxLevel or 1
    upgrade.dependencies = upgrade.dependencies or {}
    upgrade.levels = upgrade.levels or {}
    
    -- Check if upgrade already exists (YAML overriding Lua)
    local isOverride = UpgradeData._upgrades[id] ~= nil
    
    -- Store upgrade
    UpgradeData._upgrades[id] = upgrade
    
    -- Index by category (only if not already indexed)
    local cat = upgrade.category
    if not UpgradeData._categories[cat] then
        UpgradeData._categories[cat] = {}
    end
    
    -- Check if already in category list
    if not isOverride then
        table.insert(UpgradeData._categories[cat], id)
    end
    
    return isOverride
end

-- Load upgrades: Lua definitions first, then extend with YAML
function UpgradeData.initialize()
    if UpgradeData._initialized then
        return true
    end
    
    print("[UpgradeData] ========================================")
    print("[UpgradeData] Initializing upgrade data...")
    
    local luaCount = 0
    local yamlCount = 0
    local yamlOverrides = 0
    
    -- Step 1: Load Lua definitions (primary/base upgrades)
    print("[UpgradeData] Loading Lua definitions...")
    for id, upgrade in pairs(UPGRADE_DEFINITIONS) do
        processUpgrade(id, upgrade, "Lua")
        luaCount = luaCount + 1
        print("[UpgradeData]   Lua upgrade: " .. tostring(id))
    end
    print("[UpgradeData] Loaded " .. luaCount .. " upgrades from Lua")
    
    -- Step 2: Try to extend with YAML upgrades (optional/additional)
    print("[UpgradeData] Attempting to load YAML extensions...")
    local yamlPath = "media/lua/shared/upgrades.yaml"
    
    local ok, result = pcall(function()
        -- Enable itemGroups expansion for this YAML
        return CUI_YamlParser.parseFile("myspatialrefuge", yamlPath, {
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

-- Reload upgrades (for development/debugging)
function UpgradeData.reload()
    UpgradeData._upgrades = {}
    UpgradeData._categories = {}
    UpgradeData._initialized = false
    return MSR.UpgradeData.initialize()
end

-----------------------------------------------------------
-- Query API
-----------------------------------------------------------

-- Get a single upgrade by ID
function UpgradeData.getUpgrade(id)
    UpgradeData.initialize()
    return MSR.UpgradeData._upgrades[id]
end

-- Get all upgrades as a table
function UpgradeData.getAllUpgrades()
    UpgradeData.initialize()
    return MSR.UpgradeData._upgrades
end

-- Get all upgrade IDs as an array (for iteration)
function UpgradeData.getAllUpgradeIds()
    UpgradeData.initialize()
    local ids = {}
    for id, _ in pairs(UpgradeData._upgrades) do
        table.insert(ids, id)
    end
    -- Sort alphabetically for consistent ordering
    table.sort(ids)
    return ids
end

-- Get upgrades by category
function UpgradeData.getUpgradesByCategory(category)
    UpgradeData.initialize()
    local ids = UpgradeData._categories[category] or {}
    local upgrades = {}
    for _, id in ipairs(ids) do
        table.insert(upgrades, UpgradeData._upgrades[id])
    end
    return upgrades
end

-- Get all category names
function UpgradeData.getCategories()
    UpgradeData.initialize()
    local categories = {}
    for cat, _ in pairs(UpgradeData._categories) do
        table.insert(categories, cat)
    end
    table.sort(categories)
    return categories
end

-- Get level data for an upgrade
function UpgradeData.getLevelData(upgradeId, level)
    local upgrade = UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return nil end
    
    -- Try numeric key first, then string
    return upgrade.levels[level] or upgrade.levels[tostring(level)]
end

-----------------------------------------------------------
-- Player Progress API
-- NOTE: Upgrade data is stored in GlobalModData (refugeData.upgrades)
-- This enables future cooperative play where multiple players share a refuge
-----------------------------------------------------------

-- Get player's current level for an upgrade (0 = not purchased)
function UpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    local playerObj = resolvePlayer(player)
    if not playerObj then return 0 end
    
    -- Get upgrade data from refugeData (GlobalModData)
    local upgradeData, refugeData = getRefugeUpgradeData(playerObj)
    
    -- Special case: expand_refuge level is synced with refuge tier
    if upgradeId == "expand_refuge" then
        if refugeData and refugeData.tier then
            return refugeData.tier
        end
        return 0
    end
    
    -- Standard upgrade: read from refugeData.upgrades
    if not upgradeData then return 0 end
    
    return upgradeData[upgradeId] or 0
end

-- Set player's upgrade level (used after successful purchase)
-- NOTE: Only server/singleplayer can modify GlobalModData
function UpgradeData.setPlayerUpgradeLevel(player, upgradeId, level)
    local playerObj = resolvePlayer(player)
    if not playerObj then 
        return false 
    end
    
    -- expand_refuge level is determined by refuge tier, not stored separately
    if upgradeId == "expand_refuge" then
        -- Tier is updated by MSR.Shared.ExpandRefuge, not here
        return true
    end
    
    -- Get upgrade data from refugeData (GlobalModData)
    local upgradeData, refugeData = getRefugeUpgradeData(playerObj)
    if not upgradeData or not refugeData then 
        return false 
    end
    
    -- Set the upgrade level
    upgradeData[upgradeId] = level
    
    if getDebug and getDebug() then
        print("[UpgradeData] setPlayerUpgradeLevel: " .. upgradeId .. "=" .. tostring(level) .. 
              " | Current: " .. MSR.Data.FormatUpgradesTable(upgradeData))
    end
    
    -- Save refugeData to persist the change (only works on server/SP)
    if MSR.Data and MSR.Data.SaveRefugeData then
        MSR.Data.SaveRefugeData(refugeData)
    end
    
    return true
end

-- Check if an upgrade is unlocked (dependencies met)
function UpgradeData.isUpgradeUnlocked(player, upgradeId)
    local upgrade = UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return false end
    
    -- Check all dependencies
    if upgrade.dependencies and #upgrade.dependencies > 0 then
        for _, depId in ipairs(upgrade.dependencies) do
            local depUpgrade = UpgradeData.getUpgrade(depId)
            if depUpgrade then
                -- Dependency must be at max level
                local playerLevel = UpgradeData.getPlayerUpgradeLevel(player, depId)
                if playerLevel < (depUpgrade.maxLevel or 1) then
                    return false
                end
            end
        end
    end
    
    return true
end

-- Check if player can purchase next level of an upgrade
function UpgradeData.canUpgrade(player, upgradeId)
    local upgrade = UpgradeData.getUpgrade(upgradeId)
    if not upgrade then return false, "Unknown upgrade" end
    
    -- Check if upgrade is unlocked
    if not UpgradeData.isUpgradeUnlocked(player, upgradeId) then
        return false, "Dependencies not met"
    end
    
    -- Check if already at max level
    local currentLevel = UpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    if currentLevel >= upgrade.maxLevel then
        return false, "Already at max level"
    end
    
    return true, nil
end

-- Get requirements for the next level of an upgrade
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
    
    return levelData.requirements or {}
end

-- Get effects for a specific level
function UpgradeData.getLevelEffects(upgradeId, level)
    local levelData = UpgradeData.getLevelData(upgradeId, level)
    if not levelData then return {} end
    return levelData.effects or {}
end

-- Get all active effects for a player (sum of all purchased upgrades)
function UpgradeData.getPlayerActiveEffects(player)
    UpgradeData.initialize()
    
    local playerObj = resolvePlayer(player)
    if not playerObj then return {} end
    
    -- Effect aggregation rules:
    -- - Most effects are additive (+) across levels.
    -- - Some effects represent an absolute value per level (take max).
    -- - Some effects represent a time multiplier where lower is better (take min).
    --
    -- NOTE: Keep this table small + explicit to avoid silently changing semantics.
    local AGGREGATORS = {
        refugeSize = "max",              -- expand_refuge defines absolute size per level
        readingSpeedMultiplier = "min",  -- faster_reading defines time multiplier per level (lower = faster)
        refugeCastTimeMultiplier = "min", -- faster_refuge_cast defines time multiplier per level (lower = faster)
    }
    
    local function applyEffect(effects, effectName, effectValue)
        if effectName == nil or effectValue == nil then return end
        
        local mode = AGGREGATORS[effectName] or "add"
        
        if mode == "add" then
            effects[effectName] = (effects[effectName] or 0) + effectValue
            return
        end
        
        if mode == "max" then
            if effects[effectName] == nil then
                effects[effectName] = effectValue
            else
                effects[effectName] = math.max(effects[effectName], effectValue)
            end
            return
        end
        
        if mode == "min" then
            if effects[effectName] == nil then
                effects[effectName] = effectValue
            else
                effects[effectName] = math.min(effects[effectName], effectValue)
            end
            return
        end
        
        -- Fallback: additive
        effects[effectName] = (effects[effectName] or 0) + effectValue
    end
    
    local effects = {}
    
    for id, _ in pairs(UpgradeData._upgrades) do
        local playerLevel = UpgradeData.getPlayerUpgradeLevel(playerObj, id)
        
        -- Accumulate effects from all purchased levels (with per-effect aggregation)
        for level = 1, playerLevel do
            local levelEffects = UpgradeData.getLevelEffects(id, level)
            for effectName, effectValue in pairs(levelEffects) do
                applyEffect(effects, effectName, effectValue)
            end
        end
    end
    
    return effects
end

-----------------------------------------------------------
-- Initialization on game start
-----------------------------------------------------------

local function onGameStart()
    UpgradeData.initialize()
end

Events.OnGameStart.Add(onGameStart)

print("[UpgradeData] Upgrade data module loaded")

return MSR.UpgradeData

