-- Spatial Refuge Upgrade Data
-- Data loader and query API for the upgrade system
-- Tries YAML first, falls back to Lua definitions

require "shared/CUI_YamlParser"
require "shared/SpatialRefugeData"

-- Prevent double-loading
if SpatialRefugeUpgradeData and SpatialRefugeUpgradeData._loaded then
    return SpatialRefugeUpgradeData
end

SpatialRefugeUpgradeData = {
    _loaded = true,
    _upgrades = {},      -- All upgrade definitions by ID
    _categories = {},    -- Upgrades grouped by category
    _initialized = false
}

-----------------------------------------------------------
-- Upgrade Definitions (Lua)
-- Primary source - more reliable than YAML in PZ
-----------------------------------------------------------

local UPGRADE_DEFINITIONS = {
    -- EXPAND REFUGE AREA - Increases refuge size (synced with refuge tier)
    expand_refuge = {
        id = "expand_refuge",
        name = "UI_Upgrade_ExpandRefuge",
        icon = "media/textures/expand_refuge_64x64.png",
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
    if SpatialRefugeData and SpatialRefugeData.GetRefugeDataByUsername then
        refugeData = SpatialRefugeData.GetRefugeDataByUsername(username)
    end
    
    if not refugeData then return nil, nil end
    
    -- Ensure upgrades table exists (for existing refuges created before upgrade system)
    -- Must explicitly save to GlobalModData as PZ doesn't track nested table additions automatically
    if not refugeData.upgrades then
        print("[SpatialRefugeUpgradeData] Initializing missing upgrades table for " .. username)
        refugeData.upgrades = {}
        -- Save to persist the new upgrades field to GlobalModData
        if SpatialRefugeData and SpatialRefugeData.SaveRefugeData then
            SpatialRefugeData.SaveRefugeData(refugeData)
            print("[SpatialRefugeUpgradeData] Saved initialized upgrades table to GlobalModData")
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
    local isOverride = SpatialRefugeUpgradeData._upgrades[id] ~= nil
    
    -- Store upgrade
    SpatialRefugeUpgradeData._upgrades[id] = upgrade
    
    -- Index by category (only if not already indexed)
    local cat = upgrade.category
    if not SpatialRefugeUpgradeData._categories[cat] then
        SpatialRefugeUpgradeData._categories[cat] = {}
    end
    
    -- Check if already in category list
    if not isOverride then
        table.insert(SpatialRefugeUpgradeData._categories[cat], id)
    end
    
    return isOverride
end

-- Load upgrades: Lua definitions first, then extend with YAML
function SpatialRefugeUpgradeData.initialize()
    if SpatialRefugeUpgradeData._initialized then
        return true
    end
    
    print("[SpatialRefugeUpgradeData] ========================================")
    print("[SpatialRefugeUpgradeData] Initializing upgrade data...")
    
    local luaCount = 0
    local yamlCount = 0
    local yamlOverrides = 0
    
    -- Step 1: Load Lua definitions (primary/base upgrades)
    print("[SpatialRefugeUpgradeData] Loading Lua definitions...")
    for id, upgrade in pairs(UPGRADE_DEFINITIONS) do
        processUpgrade(id, upgrade, "Lua")
        luaCount = luaCount + 1
        print("[SpatialRefugeUpgradeData]   Lua upgrade: " .. tostring(id))
    end
    print("[SpatialRefugeUpgradeData] Loaded " .. luaCount .. " upgrades from Lua")
    
    -- Step 2: Try to extend with YAML upgrades (optional/additional)
    print("[SpatialRefugeUpgradeData] Attempting to load YAML extensions...")
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
                print("[SpatialRefugeUpgradeData]   YAML override: " .. tostring(id))
            else
                print("[SpatialRefugeUpgradeData]   YAML extension: " .. tostring(id))
            end
        end
        print("[SpatialRefugeUpgradeData] Loaded " .. yamlCount .. " upgrades from YAML (" .. yamlOverrides .. " overrides)")
    else
        if ok then
            print("[SpatialRefugeUpgradeData] No YAML upgrades found (file missing or empty)")
        else
            print("[SpatialRefugeUpgradeData] YAML parse failed: " .. tostring(result))
        end
    end
    
    SpatialRefugeUpgradeData._initialized = true
    
    local totalCount = 0
    for _ in pairs(SpatialRefugeUpgradeData._upgrades) do
        totalCount = totalCount + 1
    end
    print("[SpatialRefugeUpgradeData] Total upgrades loaded: " .. totalCount)
    print("[SpatialRefugeUpgradeData] ========================================")
    
    return true
end

-- Reload upgrades (for development/debugging)
function SpatialRefugeUpgradeData.reload()
    SpatialRefugeUpgradeData._upgrades = {}
    SpatialRefugeUpgradeData._categories = {}
    SpatialRefugeUpgradeData._initialized = false
    return SpatialRefugeUpgradeData.initialize()
end

-----------------------------------------------------------
-- Query API
-----------------------------------------------------------

-- Get a single upgrade by ID
function SpatialRefugeUpgradeData.getUpgrade(id)
    SpatialRefugeUpgradeData.initialize()
    return SpatialRefugeUpgradeData._upgrades[id]
end

-- Get all upgrades as a table
function SpatialRefugeUpgradeData.getAllUpgrades()
    SpatialRefugeUpgradeData.initialize()
    return SpatialRefugeUpgradeData._upgrades
end

-- Get all upgrade IDs as an array (for iteration)
function SpatialRefugeUpgradeData.getAllUpgradeIds()
    SpatialRefugeUpgradeData.initialize()
    local ids = {}
    for id, _ in pairs(SpatialRefugeUpgradeData._upgrades) do
        table.insert(ids, id)
    end
    -- Sort alphabetically for consistent ordering
    table.sort(ids)
    return ids
end

-- Get upgrades by category
function SpatialRefugeUpgradeData.getUpgradesByCategory(category)
    SpatialRefugeUpgradeData.initialize()
    local ids = SpatialRefugeUpgradeData._categories[category] or {}
    local upgrades = {}
    for _, id in ipairs(ids) do
        table.insert(upgrades, SpatialRefugeUpgradeData._upgrades[id])
    end
    return upgrades
end

-- Get all category names
function SpatialRefugeUpgradeData.getCategories()
    SpatialRefugeUpgradeData.initialize()
    local categories = {}
    for cat, _ in pairs(SpatialRefugeUpgradeData._categories) do
        table.insert(categories, cat)
    end
    table.sort(categories)
    return categories
end

-- Get level data for an upgrade
function SpatialRefugeUpgradeData.getLevelData(upgradeId, level)
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
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
function SpatialRefugeUpgradeData.getPlayerUpgradeLevel(player, upgradeId)
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
function SpatialRefugeUpgradeData.setPlayerUpgradeLevel(player, upgradeId, level)
    local playerObj = resolvePlayer(player)
    if not playerObj then 
        return false 
    end
    
    -- expand_refuge level is determined by refuge tier, not stored separately
    if upgradeId == "expand_refuge" then
        -- Tier is updated by SpatialRefugeShared.ExpandRefuge, not here
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
        print("[SpatialRefugeUpgradeData] setPlayerUpgradeLevel: " .. upgradeId .. "=" .. tostring(level) .. 
              " | Current: " .. SpatialRefugeData.FormatUpgradesTable(upgradeData))
    end
    
    -- Save refugeData to persist the change (only works on server/SP)
    if SpatialRefugeData and SpatialRefugeData.SaveRefugeData then
        SpatialRefugeData.SaveRefugeData(refugeData)
    end
    
    return true
end

-- Check if an upgrade is unlocked (dependencies met)
function SpatialRefugeUpgradeData.isUpgradeUnlocked(player, upgradeId)
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    if not upgrade then return false end
    
    -- Check all dependencies
    if upgrade.dependencies and #upgrade.dependencies > 0 then
        for _, depId in ipairs(upgrade.dependencies) do
            local depUpgrade = SpatialRefugeUpgradeData.getUpgrade(depId)
            if depUpgrade then
                -- Dependency must be at max level
                local playerLevel = SpatialRefugeUpgradeData.getPlayerUpgradeLevel(player, depId)
                if playerLevel < (depUpgrade.maxLevel or 1) then
                    return false
                end
            end
        end
    end
    
    return true
end

-- Check if player can purchase next level of an upgrade
function SpatialRefugeUpgradeData.canUpgrade(player, upgradeId)
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    if not upgrade then return false, "Unknown upgrade" end
    
    -- Check if upgrade is unlocked
    if not SpatialRefugeUpgradeData.isUpgradeUnlocked(player, upgradeId) then
        return false, "Dependencies not met"
    end
    
    -- Check if already at max level
    local currentLevel = SpatialRefugeUpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    if currentLevel >= upgrade.maxLevel then
        return false, "Already at max level"
    end
    
    return true, nil
end

-- Get requirements for the next level of an upgrade
function SpatialRefugeUpgradeData.getNextLevelRequirements(player, upgradeId)
    local upgrade = SpatialRefugeUpgradeData.getUpgrade(upgradeId)
    if not upgrade then return nil end
    
    local currentLevel = SpatialRefugeUpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    local nextLevel = currentLevel + 1
    
    if nextLevel > upgrade.maxLevel then
        return nil
    end
    
    local levelData = SpatialRefugeUpgradeData.getLevelData(upgradeId, nextLevel)
    if not levelData then return nil end
    
    return levelData.requirements or {}
end

-- Get effects for a specific level
function SpatialRefugeUpgradeData.getLevelEffects(upgradeId, level)
    local levelData = SpatialRefugeUpgradeData.getLevelData(upgradeId, level)
    if not levelData then return {} end
    return levelData.effects or {}
end

-- Get all active effects for a player (sum of all purchased upgrades)
function SpatialRefugeUpgradeData.getPlayerActiveEffects(player)
    SpatialRefugeUpgradeData.initialize()
    
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
    
    for id, _ in pairs(SpatialRefugeUpgradeData._upgrades) do
        local playerLevel = SpatialRefugeUpgradeData.getPlayerUpgradeLevel(playerObj, id)
        
        -- Accumulate effects from all purchased levels (with per-effect aggregation)
        for level = 1, playerLevel do
            local levelEffects = SpatialRefugeUpgradeData.getLevelEffects(id, level)
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
    SpatialRefugeUpgradeData.initialize()
end

Events.OnGameStart.Add(onGameStart)

print("[SpatialRefugeUpgradeData] Upgrade data module loaded")

return SpatialRefugeUpgradeData

