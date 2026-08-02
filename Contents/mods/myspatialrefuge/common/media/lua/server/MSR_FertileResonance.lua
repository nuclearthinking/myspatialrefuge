-- MSR_FertileResonance - server-authoritative crop growth scheduling.
-- Adjusts SPlantGlobalObject.nextGrowing, which is persisted by the vanilla
-- farming GlobalObjectSystem even while the plant's chunk is unloaded.

require "00_core/00_MSR"
require "MSR_UpgradeData"
require "Farming/SFarmingSystem"
require "Farming/farming_vegetableconf"

local FertileResonance = MSR.register("FertileResonance")
if not FertileResonance then
    return MSR.FertileResonance
end

local LOG = L.logger("FertileResonance")
local UPGRADE_ID = MSR.Config.UPGRADES.FERTILE_RESONANCE
local EFFECT_NAME = "refugeCropGrowthTimeMultiplier"
local MIN_STAGE_HOURS = 1

local function isDebugFastGrowEnabled()
    if not getCore or not getDebugOptions then return false end
    local core = getCore()
    return core and core:getDebug() and getDebugOptions():getBoolean("Cheat.Farming.FastGrow")
end

---@param refugeData table
---@return number multiplier
---@return number level
local function getGrowthMultiplier(refugeData)
    local upgrades = refugeData and refugeData.upgrades
    local level = tonumber(upgrades and upgrades[UPGRADE_ID]) or 0
    if level <= 0 then return 1, 0 end

    local effects = MSR.UpgradeData.getLevelEffects(UPGRADE_ID, level)
    local multiplier = tonumber(effects and effects[EFFECT_NAME]) or 1
    multiplier = D.positiveEffect(multiplier)
    return math.max(0.05, math.min(1, multiplier)), level
end

---@param plant SPlantGlobalObject
---@param props table
---@return boolean
local function isHealthyGrowthStage(plant, props)
    local stage = tonumber(plant.nbOfGrow)
    if not stage or not props or not props.fullGrown or stage >= props.fullGrown then
        return false -- Do not accelerate seed-bearing decay or rotting.
    end

    local water = farming_vegetableconf.calcWater(plant.waterNeeded, plant.waterLvl)
    local waterMax = farming_vegetableconf.calcWater(plant.waterLvl, plant.waterNeededMax)
    local disease = farming_vegetableconf.calcDisease(tonumber(plant.mildewLvl) or 0)
    return water >= 0 and waterMax >= 0 and disease >= 0
end

local function getFarmingTimeFactor()
    if type(calcNextTimeFactor) ~= "function" then return 1 end
    local factor = tonumber(calcNextTimeFactor())
    if not factor or factor <= 0 then return 1 end
    return factor
end

---@param plant SPlantGlobalObject
---@param nextGrowing number|nil
---@return table|nil
local function getScheduleAdjustment(plant, nextGrowing)
    -- Existing schedules are intentionally left unchanged. The current upgrade
    -- level is applied when vanilla schedules the plant's next growth stage.
    if nextGrowing ~= nil or not plant or plant.state ~= "seeded" then return nil end
    if isDebugFastGrowEnabled() then return nil end

    local x, y, z = tonumber(plant.x), tonumber(plant.y), tonumber(plant.z)
    if not x or not y then return nil end

    local refugeData = MSR.Data.GetRefugeDataAtPosition(x, y, z)
    if not refugeData then return nil end

    local multiplier, level = getGrowthMultiplier(refugeData)
    if multiplier >= 1 then return nil end

    local props = farming_vegetableconf.props[plant.typeOfSeed]
    if not props or not isHealthyGrowthStage(plant, props) then return nil end

    local baseHours = tonumber(props.timeToGrow)
    if not baseHours or baseHours <= 0 then return nil end

    return {
        x = x,
        y = y,
        z = z,
        level = level,
        multiplier = multiplier,
        reductionHours = baseHours * getFarmingTimeFactor() * (1 - multiplier),
        previousNextGrowing = tonumber(plant.nextGrowing),
    }
end

---@param system SFarmingSystem
---@param plant SPlantGlobalObject
---@param adjustment table
local function applyScheduleAdjustment(system, plant, adjustment)
    local now = tonumber(system.hoursElapsed)
    local scheduled = tonumber(plant.nextGrowing)
    if not now or not scheduled or scheduled <= now then return end
    if adjustment.previousNextGrowing == scheduled then return end

    local adjusted = math.max(now + MIN_STAGE_HOURS, scheduled - adjustment.reductionHours)
    if adjusted >= scheduled then return end

    plant.nextGrowing = adjusted
    LOG.debug(
        "Crop resonance level %d adjusted %s at %d,%d,%s: %.2f -> %.2f",
        adjustment.level,
        tostring(plant.typeOfSeed),
        adjustment.x,
        adjustment.y,
        tostring(adjustment.z),
        scheduled,
        adjusted
    )
end

function FertileResonance.install()
    if FertileResonance._installed then return true end
    if not SFarmingSystem or type(SFarmingSystem.growPlant) ~= "function" then
        LOG.warning("Vanilla SFarmingSystem.growPlant is unavailable")
        return false
    end

    ---@type fun(self: SFarmingSystem, plant: SPlantGlobalObject, nextGrowing: number|nil, updateNbOfGrow: boolean): any
    local originalGrowPlant = SFarmingSystem.growPlant

    ---@param system SFarmingSystem
    ---@param plant SPlantGlobalObject
    ---@param nextGrowing number|nil
    ---@param updateNbOfGrow boolean
    local function wrappedGrowPlant(system, plant, nextGrowing, updateNbOfGrow)
        local adjustment = getScheduleAdjustment(plant, nextGrowing)
        local result = originalGrowPlant(system, plant, nextGrowing, updateNbOfGrow)
        if adjustment then
            applyScheduleAdjustment(system, plant, adjustment)
        end
        return result
    end
    ---@diagnostic disable-next-line: assign-type-mismatch -- Runtime method value includes the implicit self parameter.
    SFarmingSystem.growPlant = wrappedGrowPlant

    FertileResonance._installed = true
    LOG.info("Installed chunk-independent crop growth scheduling")
    return true
end

MSR.Events.OnServerReady.Add(FertileResonance.install)

return MSR.FertileResonance
