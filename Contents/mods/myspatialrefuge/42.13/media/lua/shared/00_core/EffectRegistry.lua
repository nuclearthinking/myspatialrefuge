require "00_core/00_MSR"

local EffectRegistry = MSR.register("EffectRegistry")
if not EffectRegistry then
    return MSR.EffectRegistry
end

MSR.EffectRegistry = EffectRegistry

local LOG = L.logger("EffectRegistry")

EffectRegistry.STACKING_RULES = {
    ADDITIVE = "additive",
    MAXIMUM = "maximum",
}

EffectRegistry.EFFECT_TYPES = {
    REFUGE_WOUND_RECOVERY_MULT = { name = "refugeWoundRecoveryMultiplier", stacking = EffectRegistry.STACKING_RULES.MAXIMUM, default = 1.0 },
    REFUGE_SLEEP_FATIGUE_MULT = { name = "refugeSleepFatigueMultiplier", stacking = EffectRegistry.STACKING_RULES.MAXIMUM, default = 1.0 },
    REFUGE_MENTAL_RECOVERY_MULT = { name = "refugeMentalRecoveryMultiplier", stacking = EffectRegistry.STACKING_RULES.MAXIMUM, default = 1.0 },
    REFUGE_STIFFNESS_RECOVERY_MULT = { name = "refugeStiffnessRecoveryMultiplier", stacking = EffectRegistry.STACKING_RULES.MAXIMUM, default = 1.0 },
}

EffectRegistry._defsByName = {}
for _, def in pairs(EffectRegistry.EFFECT_TYPES) do
    EffectRegistry._defsByName[def.name] = def
end

local playerRegistry = {}

local function getPlayerKey(player)
    if not player then return nil end

    local ok, onlineId = pcall(function() return player:getOnlineID() end)
    if ok and onlineId and onlineId >= 0 then
        return "player_" .. tostring(onlineId)
    end

    local ok2, username = pcall(function() return player:getUsername() end)
    if ok2 and username then
        return "player_" .. username
    end

    return "player_" .. tostring(player)
end

local function getPlayerRegistry(player)
    local playerKey = getPlayerKey(player)
    if not playerKey then
        return nil
    end

    if not playerRegistry[playerKey] then
        playerRegistry[playerKey] = {
            effects = {},
            isDirty = true,
            lastUpdated = 0,
        }
    end
    return playerRegistry[playerKey]
end

local function combineEffects(sources, stackingRule)
    if not sources or #sources == 0 then return 0 end
    if #sources == 1 then return sources[1].value end

    if stackingRule == EffectRegistry.STACKING_RULES.ADDITIVE then
        local sum = 0
        for _, source in ipairs(sources) do
            sum = sum + source.value
        end
        return sum
    end

    if stackingRule == EffectRegistry.STACKING_RULES.MAXIMUM then
        local maxValue = sources[1].value
        for i = 2, #sources do
            if sources[i].value > maxValue then
                maxValue = sources[i].value
            end
        end
        return maxValue
    end

    return sources[1].value
end

function EffectRegistry.getDefinition(effectName)
    return EffectRegistry._defsByName and EffectRegistry._defsByName[effectName] or nil
end

function EffectRegistry.register(player, effectName, value, source, metadata, priority)
    if not player or not effectName or value == nil or not source then
        LOG.warning("register: missing required parameters")
        return false
    end

    if type(value) ~= "number" then
        LOG.warning("register: value must be number, got %s", type(value))
        return false
    end

    local registry = getPlayerRegistry(player)
    if not registry then return false end

    if not registry.effects[effectName] then
        local def = EffectRegistry.getDefinition(effectName)
        registry.effects[effectName] = {
            sources = {},
            total = def and def.default or 0,
            stackingRule = def and def.stacking or EffectRegistry.STACKING_RULES.ADDITIVE,
        }
    end

    local effect = registry.effects[effectName]
    local sourceEntry = nil
    for _, src in ipairs(effect.sources) do
        if src.source == source then
            sourceEntry = src
            break
        end
    end

    if not sourceEntry then
        sourceEntry = {
            source = source,
            value = value,
            priority = priority or 0,
            metadata = metadata or {},
        }
        table.insert(effect.sources, sourceEntry)
    else
        sourceEntry.value = value
        sourceEntry.priority = priority or sourceEntry.priority
        sourceEntry.metadata = metadata or sourceEntry.metadata
    end

    registry.isDirty = true
    return true
end

function EffectRegistry.unregister(player, source)
    local registry = getPlayerRegistry(player)
    if not registry then return end

    for effectName, effect in pairs(registry.effects) do
        for i = #effect.sources, 1, -1 do
            if effect.sources[i].source == source then
                table.remove(effect.sources, i)
            end
        end

        if #effect.sources == 0 then
            registry.effects[effectName] = nil
        end
    end

    registry.isDirty = true
end

function EffectRegistry.clear(player)
    local registry = getPlayerRegistry(player)
    if not registry then return end
    registry.effects = {}
    registry.isDirty = true
end

function EffectRegistry.recalculate(player)
    local registry = getPlayerRegistry(player)
    if not registry or not registry.isDirty then return end

    for effectName, effect in pairs(registry.effects) do
        if #effect.sources > 0 then
            effect.total = combineEffects(effect.sources, effect.stackingRule)
        else
            local def = EffectRegistry.getDefinition(effectName)
            effect.total = def and def.default or 0
        end
    end

    registry.isDirty = false
    registry.lastUpdated = getTimestampMs()
end

function EffectRegistry.get(player, effectName, defaultValue)
    local registry = getPlayerRegistry(player)
    if not registry then
        if defaultValue ~= nil then return defaultValue end
        local def = EffectRegistry.getDefinition(effectName)
        return def and def.default or 0
    end

    if registry.isDirty then
        EffectRegistry.recalculate(player)
    end

    local effect = registry.effects[effectName]
    if effect and effect.total ~= nil then
        return effect.total
    end

    if defaultValue ~= nil then return defaultValue end
    local def = EffectRegistry.getDefinition(effectName)
    return def and def.default or 0
end

function EffectRegistry.getAll(player)
    local registry = getPlayerRegistry(player)
    if not registry then return {} end

    if registry.isDirty then
        EffectRegistry.recalculate(player)
    end

    local allEffects = {}
    for effectName, effect in pairs(registry.effects) do
        allEffects[effectName] = effect.total
    end
    return allEffects
end

function EffectRegistry.markDirty(player)
    local registry = getPlayerRegistry(player)
    if registry then
        registry.isDirty = true
    end
end

local function onLoad()
    playerRegistry = {}
end

Events.OnLoad.Add(onLoad)
Events.OnPlayerDeath.Add(function(player)
    local key = getPlayerKey(player)
    if key and playerRegistry[key] then
        playerRegistry[key] = nil
    end
end)

return EffectRegistry
