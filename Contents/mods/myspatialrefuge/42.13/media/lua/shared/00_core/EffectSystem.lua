require "00_core/00_MSR"
require "00_core/EffectRegistry"
require "00_core/EffectProvider"

local EffectSystem = MSR.register("EffectSystem")
if not EffectSystem then
    return MSR.EffectSystem
end

MSR.EffectSystem = EffectSystem

local EffectRegistry = MSR.EffectRegistry
local EffectProvider = MSR.EffectProvider
local LOG = L.logger("EffectSystem")

local providers = {}
local playerTracking = {}

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

local function getUpdateTracking(player)
    local key = getPlayerKey(player)
    if not key then return nil end

    if not playerTracking[key] then
        playerTracking[key] = {
            needsUpdate = true,
        }
    end
    return playerTracking[key]
end

function EffectSystem.registerProvider(provider)
    if not provider or not provider.sourceName then
        LOG.warning("registerProvider: invalid provider")
        return false
    end

    for _, p in ipairs(providers) do
        if p.sourceName == provider.sourceName then
            return false
        end
    end

    table.insert(providers, provider)
    return true
end

function EffectSystem.unregisterProvider(sourceName)
    for i, provider in ipairs(providers) do
        if provider.sourceName == sourceName then
            table.remove(providers, i)
            return true
        end
    end
    return false
end

function EffectSystem.getProviders()
    return providers
end

function EffectSystem.markDirty(player)
    local tracking = getUpdateTracking(player)
    if tracking then
        tracking.needsUpdate = true
    end
    EffectRegistry.markDirty(player)
end

function EffectSystem.updatePlayer(player, forceUpdate)
    if not player then return end

    local tracking = getUpdateTracking(player)
    if not tracking then return end

    if not forceUpdate and not tracking.needsUpdate then
        return
    end

    EffectRegistry.clear(player)
    for _, provider in ipairs(providers) do
        EffectProvider.registerEffects(provider, player, EffectRegistry)
    end
    EffectRegistry.recalculate(player)

    tracking.needsUpdate = false
end

function EffectSystem.updateAllPlayers(forceUpdate)
    local numPlayers = getNumActivePlayers()
    for i = 0, numPlayers - 1 do
        local player = getSpecificPlayer(i)
        if player then
            EffectSystem.updatePlayer(player, forceUpdate)
        end
    end
end

function EffectSystem.getEffect(player, effectName, defaultValue)
    return EffectRegistry.get(player, effectName, defaultValue)
end

function EffectSystem.getAll(player)
    return EffectRegistry.getAll(player)
end

Events.OnLoad.Add(function()
    playerTracking = {}
    LOG.debug("Player tracking reset")
end)

return EffectSystem
