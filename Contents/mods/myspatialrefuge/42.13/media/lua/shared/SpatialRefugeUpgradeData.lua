-- Spatial Refuge Upgrade Data
-- Data loader and query API for the upgrade system
-- Tries YAML first, falls back to Lua definitions

require "shared/CUI_YamlParser"

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
    -- TEST UPGRADE - Simple test with zombie cores
    test_upgrade = {
        id = "test_upgrade",
        name = "UI_Upgrade_TestUpgrade",
        icon = "media/textures/sacred_core.png",
        category = "test",
        maxLevel = 3,
        dependencies = {},
        levels = {
            [1] = {
                description = "UI_Upgrade_TestUpgrade_L1",
                effects = { testBonus = 0.1 },
                requirements = {
                    { type = "Base.MagicalCore", count = 1 }
                }
            },
            [2] = {
                description = "UI_Upgrade_TestUpgrade_L2",
                effects = { testBonus = 0.2 },
                requirements = {
                    { type = "Base.MagicalCore", count = 2 }
                }
            },
            [3] = {
                description = "UI_Upgrade_TestUpgrade_L3",
                effects = { testBonus = 0.3 },
                requirements = {
                    { type = "Base.MagicalCore", count = 3 }
                }
            }
        }
    },
    
    -- EXPENSIVE TEST - Requires many cores
    test_expensive = {
        id = "test_expensive",
        name = "UI_Upgrade_TestExpensive",
        icon = "media/textures/sacred_core.png",
        category = "test",
        maxLevel = 2,
        dependencies = {},
        levels = {
            [1] = {
                description = "UI_Upgrade_TestExpensive_L1",
                effects = { expensiveBonus = 0.5 },
                requirements = {
                    { type = "Base.MagicalCore", count = 50 }
                }
            },
            [2] = {
                description = "UI_Upgrade_TestExpensive_L2",
                effects = { expensiveBonus = 1.0 },
                requirements = {
                    { type = "Base.MagicalCore", count = 100 }
                }
            }
        }
    },
    
    -- MULTI-ITEM TEST - Requires various items
    test_multi = {
        id = "test_multi",
        name = "UI_Upgrade_TestMulti",
        icon = "media/textures/sacred_core.png",
        category = "test",
        maxLevel = 1,
        dependencies = {},
        levels = {
            [1] = {
                description = "UI_Upgrade_TestMulti_L1",
                effects = { multiBonus = 0.25 },
                requirements = {
                    { type = "Base.MagicalCore", count = 5 },
                    { type = "Base.Plank", count = 20 },
                    { type = "Base.Nails", count = 50 },
                    { type = "Base.Axe", count = 1, substitutes = { "Base.HandAxe", "Base.WoodAxe" } }
                }
            }
        }
    },
    
    -- LOCKED TEST - Requires test_upgrade to be maxed first
    test_locked = {
        id = "test_locked",
        name = "UI_Upgrade_TestLocked",
        icon = "media/textures/sacred_core.png",
        category = "test",
        maxLevel = 1,
        dependencies = { "test_upgrade" },
        levels = {
            [1] = {
                description = "UI_Upgrade_TestLocked_L1",
                effects = { lockedBonus = 1.0 },
                requirements = {
                    { type = "Base.MagicalCore", count = 10 }
                }
            }
        }
    },
    
    -- RARE ITEMS TEST - Requires rare/hard to find items
    test_rare = {
        id = "test_rare",
        name = "UI_Upgrade_TestRare",
        icon = "media/textures/sacred_core.png",
        category = "test",
        maxLevel = 1,
        dependencies = {},
        levels = {
            [1] = {
                description = "UI_Upgrade_TestRare_L1",
                effects = { rareBonus = 0.5 },
                requirements = {
                    { type = "Base.Generator", count = 2 },
                    { type = "Base.PropaneTank", count = 5 },
                    { type = "Base.Sledgehammer", count = 1, substitutes = { "Base.Sledgehammer2" } }
                }
            }
        }
    },
    
    -- FREE TEST - No requirements
    test_free = {
        id = "test_free",
        name = "UI_Upgrade_TestFree",
        icon = "media/textures/sacred_core.png",
        category = "test",
        maxLevel = 1,
        dependencies = {},
        levels = {
            [1] = {
                description = "UI_Upgrade_TestFree_L1",
                effects = { freeBonus = 0.1 },
                requirements = {}
            }
        }
    },
}

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

-- Get player's upgrade data from ModData
local function getPlayerUpgradeData(player)
    if not player or not player.getModData then return nil end
    
    local ok, pmd = pcall(function() return player:getModData() end)
    if not ok or not pmd then return nil end
    
    if not pmd.SpatialRefugeUpgrades then
        pmd.SpatialRefugeUpgrades = {}
    end
    
    return pmd.SpatialRefugeUpgrades
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

-- Load upgrades from Lua definitions
function SpatialRefugeUpgradeData.initialize()
    if SpatialRefugeUpgradeData._initialized then
        return true
    end
    
    print("[SpatialRefugeUpgradeData] ========================================")
    print("[SpatialRefugeUpgradeData] Initializing upgrade data...")
    
    local data = nil
    local source = "none"
    
    -- Try YAML first using CUI_YamlParser from MySpatialCore
    print("[SpatialRefugeUpgradeData] Attempting to load YAML...")
    local yamlPath = "media/lua/shared/upgrades.yaml"
    
    local ok, result = pcall(function()
        return CUI_YamlParser.parseFile("myspatialrefuge", yamlPath)
    end)
    
    if ok and result then
        print("[SpatialRefugeUpgradeData] YAML parseFile returned a result")
        if result.upgrades then
            local count = 0
            for k, v in pairs(result.upgrades) do
                count = count + 1
                print("[SpatialRefugeUpgradeData]   YAML upgrade found: " .. tostring(k))
            end
            if count > 0 then
                data = result
                source = "YAML"
                print("[SpatialRefugeUpgradeData] SUCCESS: Loaded " .. count .. " upgrades from YAML")
            else
                print("[SpatialRefugeUpgradeData] YAML parsed but no upgrades found in result")
            end
        else
            print("[SpatialRefugeUpgradeData] YAML parsed but 'upgrades' key is nil")
            -- Debug: print what keys are in result
            for k, v in pairs(result) do
                print("[SpatialRefugeUpgradeData]   YAML has key: " .. tostring(k) .. " = " .. type(v))
            end
        end
    else
        print("[SpatialRefugeUpgradeData] YAML parse failed: " .. tostring(result))
    end
    
    -- Fall back to Lua definitions
    if not data then
        print("[SpatialRefugeUpgradeData] Falling back to Lua definitions...")
        local luaCount = 0
        for k, v in pairs(UPGRADE_DEFINITIONS) do
            luaCount = luaCount + 1
        end
        print("[SpatialRefugeUpgradeData] Lua has " .. luaCount .. " upgrade definitions")
        data = { upgrades = UPGRADE_DEFINITIONS }
        source = "Lua"
    end
    
    if not data or not data.upgrades then
        print("[SpatialRefugeUpgradeData] ERROR: No upgrade data available")
        SpatialRefugeUpgradeData._upgrades = {}
        SpatialRefugeUpgradeData._categories = {}
        SpatialRefugeUpgradeData._initialized = true
        return false
    end
    
    print("[SpatialRefugeUpgradeData] Using " .. source .. " as data source")
    
    -- Process upgrades
    if data.upgrades then
        for id, upgrade in pairs(data.upgrades) do
            -- Ensure ID is set
            upgrade.id = id
            
            -- Ensure required fields have defaults
            upgrade.name = upgrade.name or ("Upgrade_" .. id)
            upgrade.icon = upgrade.icon or "media/ui/upgrades/default.png"
            upgrade.category = upgrade.category or "general"
            upgrade.maxLevel = upgrade.maxLevel or 1
            upgrade.dependencies = upgrade.dependencies or {}
            upgrade.levels = upgrade.levels or {}
            
            -- Store upgrade
            SpatialRefugeUpgradeData._upgrades[id] = upgrade
            
            -- Index by category
            local cat = upgrade.category
            if not SpatialRefugeUpgradeData._categories[cat] then
                SpatialRefugeUpgradeData._categories[cat] = {}
            end
            table.insert(SpatialRefugeUpgradeData._categories[cat], id)
        end
    end
    
    SpatialRefugeUpgradeData._initialized = true
    
    local count = 0
    for _ in pairs(SpatialRefugeUpgradeData._upgrades) do
        count = count + 1
    end
    print("[SpatialRefugeUpgradeData] Loaded " .. count .. " upgrades")
    
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
-----------------------------------------------------------

-- Get player's current level for an upgrade (0 = not purchased)
function SpatialRefugeUpgradeData.getPlayerUpgradeLevel(player, upgradeId)
    local playerObj = resolvePlayer(player)
    if not playerObj then return 0 end
    
    local upgradeData = getPlayerUpgradeData(playerObj)
    if not upgradeData then return 0 end
    
    return upgradeData[upgradeId] or 0
end

-- Set player's upgrade level (used after successful purchase)
function SpatialRefugeUpgradeData.setPlayerUpgradeLevel(player, upgradeId, level)
    local playerObj = resolvePlayer(player)
    if not playerObj then return false end
    
    local upgradeData = getPlayerUpgradeData(playerObj)
    if not upgradeData then return false end
    
    upgradeData[upgradeId] = level
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
    
    local effects = {}
    
    for id, upgrade in pairs(SpatialRefugeUpgradeData._upgrades) do
        local playerLevel = SpatialRefugeUpgradeData.getPlayerUpgradeLevel(playerObj, id)
        
        -- Accumulate effects from all purchased levels
        for level = 1, playerLevel do
            local levelEffects = SpatialRefugeUpgradeData.getLevelEffects(id, level)
            for effectName, effectValue in pairs(levelEffects) do
                effects[effectName] = (effects[effectName] or 0) + effectValue
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

