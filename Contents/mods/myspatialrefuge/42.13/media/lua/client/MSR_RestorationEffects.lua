require "00_core/00_MSR"
require "00_core/EffectSystem"
require "MSR_UpgradeEffects"

if MSR and MSR.RestorationEffects and MSR.RestorationEffects._loaded then
    return MSR.RestorationEffects
end

MSR.RestorationEffects = MSR.RestorationEffects or {}
MSR.RestorationEffects._loaded = true

local EffectSystem = MSR.EffectSystem
local LOG = L.logger("RestorationEffects")
local CharacterStat = _G.CharacterStat

local tracking = {}

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

local function getTracking(player)
    local key = getPlayerKey(player)
    if not key then return nil end
    if not tracking[key] then
        tracking[key] = {
            fatigue = nil,
            stress = nil,
            panic = nil,
            boredom = nil,
            unhappiness = nil,
            stiffness = {},
            wounds = {},
            lastInRefuge = nil,
        }
    end
    return tracking[key]
end

local function logEffect(player, fmt, ...)
    if not LOG or not LOG.debug then return end
    local key = getPlayerKey(player) or "player"
    local ok, msg = pcall(string.format, fmt, ...)
    if ok then
        LOG.debug("%s | %s", key, msg)
    else
        LOG.debug("%s | effect update (format error)", key)
    end
end

local function updateBaseline(player, stats, bodyDamage, state)
    state.fatigue = stats:get(CharacterStat.FATIGUE)
    state.stress = stats:get(CharacterStat.STRESS)
    state.panic = stats:get(CharacterStat.PANIC)
    state.boredom = stats:get(CharacterStat.BOREDOM)
    state.unhappiness = stats:get(CharacterStat.UNHAPPINESS)

    local parts = bodyDamage and bodyDamage.getBodyParts and bodyDamage:getBodyParts()
    if K.isIterable(parts) then
        for i = 0, K.size(parts) - 1 do
            local bodyPart = parts:get(i)
            if bodyPart then
                state.stiffness[i] = bodyPart:getStiffness()
                state.wounds[i] = {
                    bleeding = bodyPart:getBleedingTime(),
                    scratch = bodyPart:getScratchTime(),
                    cut = bodyPart:getCutTime(),
                    bite = bodyPart:getBiteTime(),
                    burn = bodyPart:getBurnTime(),
                    deepWound = bodyPart:getDeepWoundTime(),
                    fracture = bodyPart:getFractureTime(),
                    stitch = bodyPart:getStitchTime(),
                }
            end
        end
    end
end

local function getScaledMultiplier(baseMultiplier)
    if not baseMultiplier or baseMultiplier <= 1.0 then
        return baseMultiplier or 1.0
    end
    local bonus = baseMultiplier - 1.0
    local scaledBonus = MSR.Utils.scalePositiveValue(bonus)
    return 1.0 + scaledBonus
end

local function logApplied(player, label, value, mult)
    if value <= 0 then return end
    if mult then
        logEffect(player, "%s: +%.5f (mult=%.2f)", label, value, mult)
    else
        logEffect(player, "%s: +%.5f", label, value)
    end
end

local function applySleepFatigue(player)
    if not player or not player:isAlive() then return end
    if player.isLocalPlayer and not player:isLocalPlayer() then return end

    local stats = player:getStats()
    if not stats then return end

    local state = getTracking(player)
    if not state then return end

    if not MSR.Utils.isPlayerInRefuge(player) then
        state.fatigue = stats:get(CharacterStat.FATIGUE)
        return
    end

    if not player:isAsleep() then
        state.fatigue = stats:get(CharacterStat.FATIGUE)
        return
    end

    EffectSystem.updatePlayer(player)
    local baseMultiplier = EffectSystem.getEffect(player, "refugeSleepFatigueMultiplier", 1.0)
    local multiplier = getScaledMultiplier(baseMultiplier)
    if multiplier <= 1.0 then
        state.fatigue = stats:get(CharacterStat.FATIGUE)
        return
    end

    local currentFatigue = stats:get(CharacterStat.FATIGUE)
    if state.fatigue ~= nil then
        local change = state.fatigue - currentFatigue
        if change > 0 then
            local extra = change * (multiplier - 1.0)
            local newValue = currentFatigue - extra
            if newValue < 0 then newValue = 0 end
            local appliedExtra = currentFatigue - newValue
            stats:set(CharacterStat.FATIGUE, newValue)
            currentFatigue = newValue
            logApplied(player, "Sleep fatigue extra", appliedExtra, multiplier)
        end
    end
    state.fatigue = currentFatigue
end

local function updateRefugeState(player)
    if not player or not player:isAlive() then return end
    if player.isLocalPlayer and not player:isLocalPlayer() then return end

    local state = getTracking(player)
    if not state then return end

    local inRefuge = MSR.Utils.isPlayerInRefuge(player)
    if state.lastInRefuge == nil then
        state.lastInRefuge = inRefuge
        return
    end

    if inRefuge ~= state.lastInRefuge then
        logEffect(player, inRefuge and "Entered refuge" or "Left refuge")
        state.lastInRefuge = inRefuge
    end
end

local function applyPeriodicEffects(player)
    if not player or not player:isAlive() then return end
    if player.isLocalPlayer and not player:isLocalPlayer() then return end

    local stats = player:getStats()
    local bodyDamage = player:getBodyDamage()
    if not stats or not bodyDamage then return end

    local state = getTracking(player)
    if not state then return end

    if not MSR.Utils.isPlayerInRefuge(player) then
        updateBaseline(player, stats, bodyDamage, state)
        return
    end

    EffectSystem.updatePlayer(player)

    -- Wound recovery only (no direct general health heal)
    local baseWoundMultiplier = EffectSystem.getEffect(player, "refugeWoundRecoveryMultiplier", 1.0)

    -- Wound recovery acceleration (bleeding / bandaged / unbandaged)
    local woundMultiplier = getScaledMultiplier(baseWoundMultiplier)
    if woundMultiplier > 1.0 then
        local parts = bodyDamage and bodyDamage.getBodyParts and bodyDamage:getBodyParts()
        if woundMultiplier > 1.0 and K.isIterable(parts) then
            local expectedTotal = 0
            local appliedTotal = 0
            local totalWoundTime = 0
            for i = 0, K.size(parts) - 1 do
                local bodyPart = parts:get(i)
                local previous = state.wounds[i]
                if bodyPart then
                    local current = {
                        bleeding = bodyPart:getBleedingTime(),
                        scratch = bodyPart:getScratchTime(),
                        cut = bodyPart:getCutTime(),
                        bite = bodyPart:getBiteTime(),
                        burn = bodyPart:getBurnTime(),
                        deepWound = bodyPart:getDeepWoundTime(),
                        fracture = bodyPart:getFractureTime(),
                        stitch = bodyPart:getStitchTime(),
                    }

                    for _, v in pairs(current) do
                        if v and v > 0 then
                            totalWoundTime = totalWoundTime + v
                        end
                    end

                    if previous then
                        local function applyExtra(field, setter)
                            local prevVal = previous[field]
                            local curVal = current[field]
                            if prevVal ~= nil and curVal ~= nil then
                                local change = prevVal - curVal
                                if change > 0 then
                                    local extra = change * (woundMultiplier - 1.0)
                                    local newValue = curVal - extra
                                    if newValue < 0 then newValue = 0 end
                                    local appliedExtra = curVal - newValue
                                    setter(bodyPart, newValue)
                                    expectedTotal = expectedTotal + change
                                    appliedTotal = appliedTotal + (change + appliedExtra)
                                end
                            end
                        end

                        applyExtra("bleeding", function(p, v) p:setBleedingTime(v) end)
                        applyExtra("scratch", function(p, v) p:setScratchTime(v) end)
                        applyExtra("cut", function(p, v) p:setCutTime(v) end)
                        applyExtra("bite", function(p, v) p:setBiteTime(v) end)
                        applyExtra("burn", function(p, v) p:setBurnTime(v) end)
                        applyExtra("deepWound", function(p, v) p:setDeepWoundTime(v) end)
                        applyExtra("fracture", function(p, v) p:setFractureTime(v) end)
                        applyExtra("stitch", function(p, v) p:setStitchTime(v) end)
                    end
                end
            end

            if appliedTotal > 0 then
                logApplied(player, "Wound recovery extra", appliedTotal - expectedTotal, woundMultiplier)
            elseif totalWoundTime > 0 then
                logEffect(
                    player,
                    "Wound recovery: no decay this tick (mult=%.2f, totalWoundTime=%.5f)",
                    woundMultiplier,
                    totalWoundTime
                )
            end
        end
    end

    -- Mental recovery (stress, panic, boredom, unhappiness)
    local mentalMultiplier = getScaledMultiplier(EffectSystem.getEffect(player, "refugeMentalRecoveryMultiplier", 1.0))
    if mentalMultiplier > 1.0 then
        local currentStress = stats:get(CharacterStat.STRESS)
        local currentPanic = stats:get(CharacterStat.PANIC)
        local currentBoredom = stats:get(CharacterStat.BOREDOM)
        local currentUnhappy = stats:get(CharacterStat.UNHAPPINESS)

        if state.stress ~= nil then
            local change = state.stress - currentStress
            if change > 0 then
                local extra = change * (mentalMultiplier - 1.0)
                local appliedExtra = extra
                stats:set(CharacterStat.STRESS, currentStress - extra)
                logApplied(player, "Mental recovery stress extra", appliedExtra, mentalMultiplier)
            end
        end
        if state.panic ~= nil then
            local change = state.panic - currentPanic
            if change > 0 then
                local extra = change * (mentalMultiplier - 1.0)
                local appliedExtra = extra
                stats:set(CharacterStat.PANIC, currentPanic - extra)
                logApplied(player, "Mental recovery panic extra", appliedExtra, mentalMultiplier)
            end
        end
        if state.boredom ~= nil then
            local change = state.boredom - currentBoredom
            if change > 0 then
                local extra = change * (mentalMultiplier - 1.0)
                local appliedExtra = extra
                stats:set(CharacterStat.BOREDOM, currentBoredom - extra)
                logApplied(player, "Mental recovery boredom extra", appliedExtra, mentalMultiplier)
            end
        end
        if state.unhappiness ~= nil then
            local change = state.unhappiness - currentUnhappy
            if change > 0 then
                local extra = change * (mentalMultiplier - 1.0)
                local appliedExtra = extra
                stats:set(CharacterStat.UNHAPPINESS, currentUnhappy - extra)
                logApplied(player, "Mental recovery unhappiness extra", appliedExtra, mentalMultiplier)
            end
        end
    end

    -- Muscle stiffness recovery
    local stiffnessMultiplier = getScaledMultiplier(EffectSystem.getEffect(player, "refugeStiffnessRecoveryMultiplier", 1.0))
    local parts = bodyDamage and bodyDamage.getBodyParts and bodyDamage:getBodyParts()
    if stiffnessMultiplier > 1.0 and K.isIterable(parts) then
        local expectedTotal = 0
        local appliedTotal = 0
        local totalStiffness = 0
        local directDecay = 0.001 * (stiffnessMultiplier - 1.0)
        for i = 0, K.size(parts) - 1 do
            local bodyPart = parts:get(i)
            if bodyPart then
                local current = bodyPart:getStiffness()
                if current and current > 0 then
                    totalStiffness = totalStiffness + current
                end
                local previous = state.stiffness[i]
                if previous ~= nil then
                    local change = previous - current
                    if change > 0 then
                        local extra = change * (stiffnessMultiplier - 1.0)
                        local newValue = current - extra
                        if newValue < 0 then newValue = 0 end
                        local appliedExtra = current - newValue
                        bodyPart:setStiffness(newValue)
                        current = newValue
                        expectedTotal = expectedTotal + change
                        appliedTotal = appliedTotal + (change + appliedExtra)
                    end
                end
                if directDecay > 0 and current > 0 then
                    local newValue = current - directDecay
                    if newValue < 0 then newValue = 0 end
                    local appliedExtra = current - newValue
                    if appliedExtra > 0 then
                        bodyPart:setStiffness(newValue)
                        current = newValue
                        appliedTotal = appliedTotal + appliedExtra
                    end
                end
                state.stiffness[i] = current
            end
        end
        if appliedTotal > 0 then
            logApplied(player, "Muscle recovery extra", appliedTotal - expectedTotal, stiffnessMultiplier)
        elseif totalStiffness > 0 then
            logEffect(
                player,
                "Muscle recovery: no decay this tick (mult=%.2f, totalStiffness=%.5f)",
                stiffnessMultiplier,
                totalStiffness
            )
        end
    elseif stiffnessMultiplier > 1.0 then
        logEffect(player, "Muscle recovery: no body parts found (mult=%.2f)", stiffnessMultiplier)
    end

    updateBaseline(player, stats, bodyDamage, state)
end

Events.EveryOneMinute.Add(function()
    local numPlayers = getNumActivePlayers()
    for i = 0, numPlayers - 1 do
        local player = getSpecificPlayer(i)
        if player then
            applySleepFatigue(player)
            applyPeriodicEffects(player)
        end
    end
end)

Events.OnPlayerUpdate.Add(updateRefugeState)

LOG.debug("Restoration effects initialized")

return MSR.RestorationEffects
