-- Custom event for UI reactivity (must register before listeners added)
LuaEventManager.AddEvent("MSR_OnInventoryChange")

local DEBOUNCE_MS = 100  -- fires after inactivity to batch rapid operations
local pendingEvent = nil
local lastEventTime = 0
local tickListenerActive = false

local function checkDebounce()
    if not pendingEvent then
        Events.OnTick.Remove(checkDebounce)
        tickListenerActive = false
        return
    end
    
    local now = K.timeMs()
    if (now - lastEventTime) >= DEBOUNCE_MS then
        triggerEvent("MSR_OnInventoryChange", pendingEvent.action, pendingEvent.item, pendingEvent.state)
        pendingEvent = nil
        Events.OnTick.Remove(checkDebounce)
        tickListenerActive = false
    end
end

local function deferEvent(action, item, state)
    pendingEvent = { action = action, item = item, state = state }
    lastEventTime = K.timeMs()
    
    if not tickListenerActive then
        tickListenerActive = true
        Events.OnTick.Add(checkDebounce)
    end
end

local function onClothingUpdated(character)
    if character and character:isLocalPlayer() then
        deferEvent("clothing", nil, nil)
    end
end

local function initHooks()
    -- Clean up orphaned state from previous session/reload
    Events.OnTick.Remove(checkDebounce)
    tickListenerActive = false
    pendingEvent = nil
    
    Events.OnClothingUpdated.Add(onClothingUpdated)
    
    -- Favorites: instant
    if ISInventoryPaneContextMenu then
        local originalOnFavorite = ISInventoryPaneContextMenu.onFavorite
        ISInventoryPaneContextMenu.onFavorite = function(items, item2, fav)
            if originalOnFavorite then originalOnFavorite(items, item2, fav) end
            triggerEvent("MSR_OnInventoryChange", "favorite", items, fav)
        end
    end
    
    -- Transfers/pickups: deferred
    if ISInventoryTransferAction then
        local originalTransferPerform = ISInventoryTransferAction.perform
        ISInventoryTransferAction.perform = function(self)
            if originalTransferPerform then originalTransferPerform(self) end
            deferEvent("transfer", self.item)
        end
    end
    
    if ISGrabItemAction then
        local originalGrabPerform = ISGrabItemAction.perform
        ISGrabItemAction.perform = function(self)
            if originalGrabPerform then originalGrabPerform(self) end
            deferEvent("grab", self.item)
        end
    end
end

Events.OnGameStart.Add(initHooks)
