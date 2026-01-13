-- MSR_02_Difficulty.lua - Unified Difficulty System
-- Global D table for difficulty scaling. Load order: after MSR_01_Logging, before MSR_Env

require "00_core/00_MSR"

if MSR and MSR.Difficulty and MSR.Difficulty._loaded then
    return MSR.Difficulty
end

-- Sandbox enum: 1=Very Easy, 2=Easy, 3=Normal, 4=Hard, 5=Very Hard
-- effectPower kept subtle (1.2/0.8 max) to avoid 99% effects at extremes
MSR.Difficulty = {
    _loaded = true,
    [1] = { -- Very Easy
        coreCost = 0.5,
        cooldown = 0.5,
        effectPower = 1.2
    },
    [2] = { -- Easy
        coreCost = 0.75,
        cooldown = 0.75,
        effectPower = 1.1
    },
    [3] = { -- Normal
        coreCost = 1.0,
        cooldown = 1.0,
        effectPower = 1.0
    },
    [4] = { -- Hard
        coreCost = 1.5,
        cooldown = 1.5,
        effectPower = 0.9
    },
    [5] = { -- Very Hard
        coreCost = 2.0,
        cooldown = 2.0,
        effectPower = 0.8
    }
}

--- @param category string "coreCost", "cooldown", or "effectPower"
--- @return number Multiplier (defaults to 1.0)
function MSR.GetDifficultyMultiplier(category)
    local difficultyIndex = SandboxVars and SandboxVars.MySpatialRefuge 
                            and SandboxVars.MySpatialRefuge.Difficulty or 3
    local multipliers = MSR.Difficulty[difficultyIndex]
    return multipliers and multipliers[category] or 1.0
end

--- @return number 1=Very Easy, 2=Easy, 3=Normal, 4=Hard, 5=Very Hard
function MSR.GetDifficultyLevel()
    return SandboxVars and SandboxVars.MySpatialRefuge 
           and SandboxVars.MySpatialRefuge.Difficulty or 3
end

--- @return string Difficulty name
function MSR.GetDifficultyName()
    local level = MSR.GetDifficultyLevel()
    local names = { [1] = "Very Easy", [2] = "Easy", [3] = "Normal", [4] = "Hard", [5] = "Very Hard" }
    return names[level] or "Normal"
end

-- D.* Utility API

D = D or {}

--- Scale core cost. Example: D.core(100) → 75/100/150
function D.core(baseValue)
    if type(baseValue) ~= "number" then return baseValue end
    return math.max(1, math.ceil(baseValue * MSR.GetDifficultyMultiplier("coreCost")))
end

--- Scale material cost (same as core). Example: D.material(5) → 3/5/8
D.material = D.core

--- Scale cooldown. Example: D.cooldown(10) → 7/10/15
function D.cooldown(baseValue)
    if type(baseValue) ~= "number" then return baseValue end
    return math.max(0, math.floor(baseValue * MSR.GetDifficultyMultiplier("cooldown")))
end

--- Scale beneficial multiplier where lower=better (e.g., readingSpeedMultiplier 0.25 = 75% faster)
function D.positiveEffect(baseMultiplier)
    if type(baseMultiplier) ~= "number" then return baseMultiplier end
    local power = MSR.GetDifficultyMultiplier("effectPower")
    local scaled = 1.0 + (baseMultiplier - 1.0) * power
    return math.max(0.01, math.min(1.0, scaled))
end

--- Scale beneficial flat value where higher=better (e.g., bonus capacity)
function D.positiveValue(baseValue)
    if type(baseValue) ~= "number" then return baseValue end
    local power = MSR.GetDifficultyMultiplier("effectPower")
    return baseValue * power
end

--- Scale penalty multiplier where higher=worse (e.g., cooldownPenalty 1.5 = 50% slower)
function D.negativeEffect(baseMultiplier)
    if type(baseMultiplier) ~= "number" then return baseMultiplier end
    local inversePower = 2.0 - MSR.GetDifficultyMultiplier("effectPower")
    return 1.0 + (baseMultiplier - 1.0) * inversePower
end

--- Scale penalty flat value where higher=worse (e.g., encumbrance penalty seconds)
function D.negativeValue(baseValue)
    if type(baseValue) ~= "number" then return baseValue end
    local inversePower = 2.0 - MSR.GetDifficultyMultiplier("effectPower")
    return math.max(0, baseValue * inversePower)
end

return MSR.Difficulty
