require "00_core/00_MSR"

local EffectProvider = MSR.register("EffectProvider")
if not EffectProvider then
    return MSR.EffectProvider
end

MSR.EffectProvider = EffectProvider

function EffectProvider.create(config)
    local provider = {
        sourceName = config.sourceName or "UnknownProvider",
        calculateEffects = config.calculateEffects,
        shouldApply = config.shouldApply or function() return true end,
        onEffectsChanged = config.onEffectsChanged or function() end,
        priority = config.priority or 0,
    }

    if not provider.calculateEffects or type(provider.calculateEffects) ~= "function" then
        error("[EffectProvider] calculateEffects must be a function")
    end

    return provider
end

function EffectProvider.registerEffects(provider, player, registry)
    if not provider.shouldApply(player) then
        registry.unregister(player, provider.sourceName)
        return
    end

    local effects = provider.calculateEffects(player)
    if not effects or type(effects) ~= "table" then
        registry.unregister(player, provider.sourceName)
        return
    end

    registry.unregister(player, provider.sourceName)

    for _, effect in ipairs(effects) do
        if effect.name and effect.value ~= nil then
            local priority = effect.priority or provider.priority
            local metadata = effect.metadata or {}

            registry.register(
                player,
                effect.name,
                effect.value,
                provider.sourceName,
                metadata,
                priority
            )
        end
    end
end

function EffectProvider.makeEffect(name, value, metadata, priority)
    return {
        name = name,
        value = value,
        metadata = metadata or {},
        priority = priority or 0,
    }
end

function EffectProvider.makeEffects(effects)
    local result = {}
    for _, e in ipairs(effects) do
        table.insert(result, EffectProvider.makeEffect(e.name or e[1], e.value or e[2], e.metadata or e[3], e.priority or e[4]))
    end
    return result
end

return EffectProvider
