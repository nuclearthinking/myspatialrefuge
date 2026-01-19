require "00_core/00_MSR"
require "MSR_UpgradeLogic"
require "MSR_Transaction"

if MSR and MSR.UpgradeItemCache and MSR.UpgradeItemCache._loaded then
    return MSR.UpgradeItemCache
end

MSR.UpgradeItemCache = MSR.UpgradeItemCache or {}
MSR.UpgradeItemCache._loaded = true

local Cache = MSR.UpgradeItemCache

local _state = {
    player = nil,
    username = nil,
    dirty = true,
    counts = {},
    samples = {},
    meta = {}
}

local function resolvePlayer(player)
    return MSR.resolvePlayer(player)
end

local function getUsername(playerObj)
    if not playerObj then return nil end
    if playerObj.getUsername then
        local ok, name = pcall(function() return playerObj:getUsername() end)
        if ok and name then return name end
    end
    return nil
end

local function rebuildCounts()
    _state.counts = {}
    _state.samples = {}
    _state.dirty = false
    
    if not _state.player then return end
    
    local sources = MSR.UpgradeLogic.getItemSources(_state.player)
    for _, container in ipairs(sources) do
        local items = container and container.getItems and container:getItems()
        if K.isIterable(items) then
            for _, item in K.iter(items) do
                if item then
                    local itemType = item:getFullType()
                    if itemType then
                        local available, _ = MSR.Transaction.IsItemAvailable(item, container)
                        if available then
                            _state.counts[itemType] = (_state.counts[itemType] or 0) + 1
                            if not _state.samples[itemType] then
                                _state.samples[itemType] = item
                            end
                        end
                    end
                end
            end
        end
    end
    
    if MSR.Transaction and MSR.Transaction.GetLockedItemCounts then
        local lockedCounts = MSR.Transaction.GetLockedItemCounts(_state.player)
        if lockedCounts then
            for itemType, count in pairs(lockedCounts) do
                local current = _state.counts[itemType] or 0
                local adjusted = current - count
                _state.counts[itemType] = math.max(0, adjusted)
            end
        end
    end
end

function Cache.setPlayer(player)
    local playerObj = resolvePlayer(player)
    if not playerObj then return end
    
    local username = getUsername(playerObj)
    if _state.player ~= playerObj or _state.username ~= username then
        _state.player = playerObj
        _state.username = username
        Cache.invalidate(playerObj)
    end
end

function Cache.invalidate(player)
    if player then
        local playerObj = resolvePlayer(player)
        if playerObj and _state.player ~= playerObj then
            return
        end
    end
    _state.dirty = true
    _state.counts = {}
    _state.samples = {}
end

function Cache.ensureBuilt(player)
    if player then Cache.setPlayer(player) end
    if _state.dirty then
        rebuildCounts()
    end
end

function Cache.getCount(itemType, player)
    Cache.ensureBuilt(player)
    return _state.counts[itemType] or 0
end

function Cache.getCountForRequirement(requirement, player)
    Cache.ensureBuilt(player)
    if not requirement or not requirement.type then return 0 end
    
    local total = _state.counts[requirement.type] or 0
    local seen = {}
    seen[requirement.type] = true
    
    if requirement.substitutes then
        for _, subType in ipairs(requirement.substitutes) do
            if not seen[subType] then
                total = total + (_state.counts[subType] or 0)
                seen[subType] = true
            end
        end
    end
    
    return total
end

function Cache.getItemMeta(itemType, player)
    Cache.ensureBuilt(player)
    if not itemType then return itemType, nil, nil end
    
    local cached = _state.meta[itemType]
    if cached then
        return cached.displayName, cached.texture, cached.script
    end
    
    local script = ScriptManager.instance:getItem(itemType)
    local displayName = itemType
    local texture = nil
    
    if script then
        displayName = script:getDisplayName()
        texture = script:getNormalTexture()
    else
        local sample = _state.samples[itemType]
        if sample then
            displayName = sample:getDisplayName()
            texture = sample:getTexture()
        end
    end
    
    _state.meta[itemType] = {
        displayName = displayName,
        texture = texture,
        script = script
    }
    
    return displayName, texture, script
end

return MSR.UpgradeItemCache
