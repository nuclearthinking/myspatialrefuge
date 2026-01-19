require "00_core/00_MSR"
require "00_core/EffectSystem"
require "00_core/EffectProvider"
require "00_core/EffectRegistry"
require "MSR_UpgradeData"

if MSR and MSR.UpgradeEffects and MSR.UpgradeEffects._loaded then
    return MSR.UpgradeEffects
end

MSR.UpgradeEffects = MSR.UpgradeEffects or {}
MSR.UpgradeEffects._loaded = true

local EffectSystem = MSR.EffectSystem
local EffectProvider = MSR.EffectProvider
local EffectRegistry = MSR.EffectRegistry
local LOG = L.logger("UpgradeEffects")

local provider = EffectProvider.create({
    sourceName = "UpgradeEffects",
    calculateEffects = function(player)
        local ok, effects = pcall(MSR.UpgradeData.getPlayerActiveEffects, player)
        if not ok or not effects then
            return {}
        end

        local result = {}
        for _, def in pairs(EffectRegistry.EFFECT_TYPES) do
            local value = effects[def.name]
            if value ~= nil then
                table.insert(result, EffectProvider.makeEffect(def.name, value, { source = "upgrade" }))
            end
        end
        return result
    end
})

EffectSystem.registerProvider(provider)
LOG.debug("Upgrade effect provider registered")

return MSR.UpgradeEffects
