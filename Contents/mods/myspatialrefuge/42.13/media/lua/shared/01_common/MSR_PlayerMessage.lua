-- MSR_PlayerMessage - Unified player message system
-- Provides standardized, localized player.Say() wrapper with format argument support
--
-- Usage:
--   require "shared/01_common/MSR_PlayerMessage"
--   local PM = MSR.PlayerMessage
--   PM.Say(player, PM.ENTERED_REFUGE)
--   PM.Say(player, PM.COOLDOWN_REMAINING, 30)  -- with args
--   PM.SayRaw(player, "Already translated text")          -- bypass translation
--   PM.SayRandom(player, PM.PROTECTED_OBJECT)  -- random from pool

require "shared/00_core/00_MSR"

-- Prevent double-loading
if MSR.PlayerMessage and MSR.PlayerMessage._loaded then
    return MSR.PlayerMessage
end

MSR.PlayerMessage = MSR.PlayerMessage or {}
MSR.PlayerMessage._loaded = true

-- Short alias for internal use
local PM = MSR.PlayerMessage

-----------------------------------------------------------
-- Message Key Constants (enum-like)
-- Use these instead of hardcoded translation keys
-----------------------------------------------------------

-- Teleportation messages
PM.ENTERED_REFUGE = "ENTERED_REFUGE"
PM.EXITED_REFUGE = "EXITED_REFUGE"
PM.ALREADY_IN_REFUGE = "ALREADY_IN_REFUGE"
PM.GENERATING_REFUGE = "GENERATING_REFUGE"
PM.REFUGE_INITIALIZING = "REFUGE_INITIALIZING"
PM.FAILED_TO_GENERATE = "FAILED_TO_GENERATE"
PM.AREA_NOT_LOADED = "AREA_NOT_LOADED"
PM.FAILED_TO_LOAD_AREA = "FAILED_TO_LOAD_AREA"
PM.RETURN_POSITION_LOST = "RETURN_POSITION_LOST"
PM.CANNOT_EXIT_NO_DATA = "CANNOT_EXIT_NO_DATA"
PM.PORTAL_CHARGING = "PORTAL_CHARGING"
PM.CANNOT_TELEPORT_COMBAT = "CANNOT_TELEPORT_COMBAT"
PM.REFUGE_ACTION_NOT_AVAILABLE = "REFUGE_ACTION_NOT_AVAILABLE"
PM.REFUGE_EXIT_ACTION_NOT_AVAILABLE = "REFUGE_EXIT_ACTION_NOT_AVAILABLE"
PM.CANNOT_LEAVE_BOUNDARY = "CANNOT_LEAVE_BOUNDARY"
PM.ACTION_TIMEOUT_ITEMS_UNLOCKED = "ACTION_TIMEOUT_ITEMS_UNLOCKED"
PM.INHERITED_REFUGE_CONNECTION = "INHERITED_REFUGE_CONNECTION"
PM.ENCUMBRANCE_PENALTY = "ENCUMBRANCE_PENALTY"
PM.NOT_IN_REFUGE = "NOT_IN_REFUGE"
PM.COOLDOWN_REMAINING = "COOLDOWN_REMAINING"

-- Vehicle teleport messages
PM.VEHICLE_NOT_FOUND = "VEHICLE_NOT_FOUND"
PM.RETURNED_TO_VEHICLE = "RETURNED_TO_VEHICLE"
PM.VEHICLE_ENTRY_FAILED = "VEHICLE_ENTRY_FAILED"

-- Relic movement messages
PM.RELIC_MOVED_TO = "RELIC_MOVED_TO"
PM.WALLS_SYNCED = "WALLS_SYNCED"
PM.CANNOT_MOVE_RELIC_YET = "CANNOT_MOVE_RELIC_YET"
PM.MOVING_RELIC = "MOVING_RELIC"
PM.CANNOT_MOVE_RELIC = "CANNOT_MOVE_RELIC"

-- Relic movement errors (mapped from MoveRelicError)
PM.MOVE_NO_REFUGE_DATA = "MOVE_NO_REFUGE_DATA"
PM.MOVE_RELIC_NOT_FOUND = "MOVE_RELIC_NOT_FOUND"
PM.MOVE_ALREADY_AT_POSITION = "MOVE_ALREADY_AT_POSITION"
PM.MOVE_WORLD_NOT_READY = "MOVE_WORLD_NOT_READY"
PM.MOVE_DESTINATION_NOT_LOADED = "MOVE_DESTINATION_NOT_LOADED"
PM.MOVE_CURRENT_NOT_LOADED = "MOVE_CURRENT_NOT_LOADED"
PM.MOVE_BLOCKED_BY_TREE = "MOVE_BLOCKED_BY_TREE"
PM.MOVE_BLOCKED_BY_WALL = "MOVE_BLOCKED_BY_WALL"
PM.MOVE_BLOCKED_BY_STAIRS = "MOVE_BLOCKED_BY_STAIRS"
PM.MOVE_BLOCKED_BY_FURNITURE = "MOVE_BLOCKED_BY_FURNITURE"
PM.MOVE_BLOCKED_BY_CONTAINER = "MOVE_BLOCKED_BY_CONTAINER"
PM.MOVE_BLOCKED_BY_ENTITY = "MOVE_BLOCKED_BY_ENTITY"
PM.MOVE_DESTINATION_BLOCKED = "MOVE_DESTINATION_BLOCKED"

-- Upgrade messages
PM.REFUGE_UPGRADED_TO = "REFUGE_UPGRADED_TO"
PM.UPGRADED_TO_LEVEL = "UPGRADED_TO_LEVEL"
PM.UPGRADING = "UPGRADING"
PM.UPGRADE_FAILED = "UPGRADE_FAILED"
PM.UPGRADE_COOLDOWN = "UPGRADE_COOLDOWN"
PM.UPGRADE_ALREADY_PROCESSING = "UPGRADE_ALREADY_PROCESSING"
PM.REFUGE_ERROR = "REFUGE_ERROR"

-- Protected object messages (pool for random selection)
PM.PROTECTED_OBJECT = "PROTECTED_OBJECT"

-----------------------------------------------------------
-- Internal: Translation Key Mapping
-- Maps message keys to IGUI translation keys
-----------------------------------------------------------

local MessageToTranslationKey = {
    -- Teleportation
    [PM.ENTERED_REFUGE] = "IGUI_EnteredRefuge",
    [PM.EXITED_REFUGE] = "IGUI_ExitedRefuge",
    [PM.ALREADY_IN_REFUGE] = "IGUI_AlreadyInRefuge",
    [PM.GENERATING_REFUGE] = "IGUI_GeneratingRefuge",
    [PM.REFUGE_INITIALIZING] = "IGUI_RefugeInitializing",
    [PM.FAILED_TO_GENERATE] = "IGUI_FailedToGenerateRefuge",
    [PM.AREA_NOT_LOADED] = "IGUI_RefugeAreaNotLoaded",
    [PM.FAILED_TO_LOAD_AREA] = "IGUI_FailedToLoadRefugeArea",
    [PM.RETURN_POSITION_LOST] = "IGUI_ReturnPositionLost",
    [PM.CANNOT_EXIT_NO_DATA] = "IGUI_CannotExitNoData",
    [PM.PORTAL_CHARGING] = "IGUI_PortalCharging",
    [PM.CANNOT_TELEPORT_COMBAT] = "IGUI_CannotTeleportCombat",
    [PM.REFUGE_ACTION_NOT_AVAILABLE] = "IGUI_RefugeActionNotAvailable",
    [PM.REFUGE_EXIT_ACTION_NOT_AVAILABLE] = "IGUI_RefugeExitActionNotAvailable",
    [PM.CANNOT_LEAVE_BOUNDARY] = "IGUI_CannotLeaveBoundary",
    [PM.ACTION_TIMEOUT_ITEMS_UNLOCKED] = "IGUI_ActionTimeoutItemsUnlocked",
    [PM.INHERITED_REFUGE_CONNECTION] = "IGUI_InheritedRefugeConnection",
    [PM.ENCUMBRANCE_PENALTY] = "IGUI_EncumbrancePenalty",
    [PM.NOT_IN_REFUGE] = "IGUI_NotInRefuge",
    [PM.COOLDOWN_REMAINING] = "IGUI_PortalCharging",
    
    -- Vehicle teleport
    [PM.VEHICLE_NOT_FOUND] = "IGUI_VehicleNotFound",
    [PM.RETURNED_TO_VEHICLE] = "IGUI_ReturnedToVehicle",
    [PM.VEHICLE_ENTRY_FAILED] = "IGUI_VehicleEntryFailed",
    
    -- Relic movement
    [PM.RELIC_MOVED_TO] = "IGUI_SacredRelicMovedTo",
    [PM.WALLS_SYNCED] = "IGUI_RefugeWallsSynced",
    [PM.CANNOT_MOVE_RELIC_YET] = "IGUI_CannotMoveRelicYet",
    [PM.MOVING_RELIC] = "IGUI_MovingSacredRelic",
    [PM.CANNOT_MOVE_RELIC] = "IGUI_CannotMoveRelic",
    
    -- Relic movement errors
    [PM.MOVE_NO_REFUGE_DATA] = "IGUI_MoveRelic_NoRefugeData",
    [PM.MOVE_RELIC_NOT_FOUND] = "IGUI_MoveRelic_RelicNotFound",
    [PM.MOVE_ALREADY_AT_POSITION] = "IGUI_MoveRelic_AlreadyAtPosition",
    [PM.MOVE_WORLD_NOT_READY] = "IGUI_MoveRelic_WorldNotReady",
    [PM.MOVE_DESTINATION_NOT_LOADED] = "IGUI_MoveRelic_DestinationNotLoaded",
    [PM.MOVE_CURRENT_NOT_LOADED] = "IGUI_MoveRelic_CurrentLocationNotLoaded",
    [PM.MOVE_BLOCKED_BY_TREE] = "IGUI_MoveRelic_BlockedByTree",
    [PM.MOVE_BLOCKED_BY_WALL] = "IGUI_MoveRelic_BlockedByWall",
    [PM.MOVE_BLOCKED_BY_STAIRS] = "IGUI_MoveRelic_BlockedByStairs",
    [PM.MOVE_BLOCKED_BY_FURNITURE] = "IGUI_MoveRelic_BlockedByFurniture",
    [PM.MOVE_BLOCKED_BY_CONTAINER] = "IGUI_MoveRelic_BlockedByContainer",
    [PM.MOVE_BLOCKED_BY_ENTITY] = "IGUI_MoveRelic_BlockedByEntity",
    [PM.MOVE_DESTINATION_BLOCKED] = "IGUI_MoveRelic_DestinationBlocked",
    
    -- Upgrades
    [PM.REFUGE_UPGRADED_TO] = "IGUI_RefugeUpgradedTo",
    [PM.UPGRADED_TO_LEVEL] = "IGUI_UpgradedToLevel",
    [PM.UPGRADING] = "IGUI_Upgrading",
    [PM.UPGRADE_FAILED] = "IGUI_UpgradeFailed",
    [PM.UPGRADE_COOLDOWN] = "IGUI_UpgradeCooldown",
    [PM.UPGRADE_ALREADY_PROCESSING] = "IGUI_UpgradeAlreadyProcessing",
    [PM.REFUGE_ERROR] = "IGUI_RefugeError",
}

-----------------------------------------------------------
-- Internal: Message Pools for Random Selection
-----------------------------------------------------------

local MessagePools = {
    [PM.PROTECTED_OBJECT] = {
        "IGUI_ProtectedObject_1",
        "IGUI_ProtectedObject_2",
        "IGUI_ProtectedObject_3",
        "IGUI_ProtectedObject_4",
        "IGUI_ProtectedObject_5",
        "IGUI_ProtectedObject_6",
        "IGUI_ProtectedObject_7",
        "IGUI_ProtectedObject_8",
        "IGUI_ProtectedObject_9",
        "IGUI_ProtectedObject_10",
        "IGUI_ProtectedObject_11",
        "IGUI_ProtectedObject_12",
        "IGUI_ProtectedObject_13",
        "IGUI_ProtectedObject_14",
        "IGUI_ProtectedObject_15",
    },
}

-----------------------------------------------------------
-- Internal: Direction Name Translation
-- Maps canonical direction names to translation keys
-----------------------------------------------------------

local DirectionToTranslationKey = {
    Up = "IGUI_RelicDirection_Up",
    Right = "IGUI_RelicDirection_Right",
    Left = "IGUI_RelicDirection_Left",
    Down = "IGUI_RelicDirection_Down",
    Center = "IGUI_RelicDirection_Center",
}

-----------------------------------------------------------
-- Internal: MoveRelicError to PlayerMessage Key Mapping
-----------------------------------------------------------

local MoveRelicErrorToMessageKey = nil  -- Lazy-initialized

local function getMoveRelicErrorMapping()
    if MoveRelicErrorToMessageKey then
        return MoveRelicErrorToMessageKey
    end
    
    -- Build mapping from MSR.Shared.MoveRelicError if available
    if MSR.Shared and MSR.Shared.MoveRelicError then
        local E = MSR.Shared.MoveRelicError
        MoveRelicErrorToMessageKey = {
            [E.SUCCESS] = PM.RELIC_MOVED_TO,
            [E.NO_REFUGE_DATA] = PM.MOVE_NO_REFUGE_DATA,
            [E.RELIC_NOT_FOUND] = PM.MOVE_RELIC_NOT_FOUND,
            [E.ALREADY_AT_POSITION] = PM.MOVE_ALREADY_AT_POSITION,
            [E.WORLD_NOT_READY] = PM.MOVE_WORLD_NOT_READY,
            [E.DESTINATION_NOT_LOADED] = PM.MOVE_DESTINATION_NOT_LOADED,
            [E.CURRENT_LOCATION_NOT_LOADED] = PM.MOVE_CURRENT_NOT_LOADED,
            [E.BLOCKED_BY_TREE] = PM.MOVE_BLOCKED_BY_TREE,
            [E.BLOCKED_BY_WALL] = PM.MOVE_BLOCKED_BY_WALL,
            [E.BLOCKED_BY_STAIRS] = PM.MOVE_BLOCKED_BY_STAIRS,
            [E.BLOCKED_BY_FURNITURE] = PM.MOVE_BLOCKED_BY_FURNITURE,
            [E.BLOCKED_BY_CONTAINER] = PM.MOVE_BLOCKED_BY_CONTAINER,
            [E.BLOCKED_BY_ENTITY] = PM.MOVE_BLOCKED_BY_ENTITY,
            [E.DESTINATION_BLOCKED] = PM.MOVE_DESTINATION_BLOCKED,
        }
    else
        MoveRelicErrorToMessageKey = {}
    end
    
    return MoveRelicErrorToMessageKey
end

-----------------------------------------------------------
-- Public API
-----------------------------------------------------------

--- Get the translation key for a message key
-- @param messageKey string - one of PM.* constants
-- @return string - the IGUI translation key
function PM.GetTranslationKey(messageKey)
    return MessageToTranslationKey[messageKey]
end

--- Get translated text for a message key (no formatting)
-- @param messageKey string - one of PM.* constants
-- @return string - translated text, or messageKey if not found
function PM.GetText(messageKey)
    local translationKey = MessageToTranslationKey[messageKey]
    if translationKey and getText then
        return getText(translationKey)
    end
    return messageKey
end

--- Get translated text with format arguments
-- @param messageKey string - one of PM.* constants  
-- @param ... - format arguments (passed to string.format)
-- @return string - formatted translated text
function PM.GetFormattedText(messageKey, ...)
    local translationKey = MessageToTranslationKey[messageKey]
    if not translationKey then
        return messageKey
    end
    
    local template = getText and getText(translationKey) or translationKey
    local args = {...}
    
    -- If no args, return as-is
    local hasArgs = false
    for _ in pairs(args) do
        hasArgs = true
        break
    end
    if not hasArgs then
        return template
    end
    
    -- Format with args
    local ok, result = pcall(string.format, template, ...)
    if ok then
        return result
    end
    
    -- Fallback on format error
    return template
end

--- Translate a canonical direction name to localized text
-- @param canonicalName string - "Up", "Right", "Left", "Down", "Center"
-- @return string - translated direction name
function PM.TranslateDirection(canonicalName)
    if not canonicalName then return canonicalName end
    
    local key = DirectionToTranslationKey[canonicalName]
    if key and getText then
        return getText(key)
    end
    
    return canonicalName
end

--- Convert MoveRelicError code to PM key
-- @param errorCode string - one of MSR.Shared.MoveRelicError constants
-- @return string - PM key constant
function PM.FromMoveRelicError(errorCode)
    local mapping = getMoveRelicErrorMapping()
    return mapping[errorCode] or PM.CANNOT_MOVE_RELIC
end

--- Make player say a localized message
-- @param player IsoPlayer - the player object
-- @param messageKey string - one of PM.* constants
-- @param ... - optional format arguments
-- @return boolean - true if message was said
function PM.Say(player, messageKey, ...)
    if not player or not player.Say then
        return false
    end
    
    local text = PM.GetFormattedText(messageKey, ...)
    player:Say(text)
    return true
end

--- Make player say a raw (already translated) message
-- Use when you have pre-translated text or dynamic content
-- @param player IsoPlayer - the player object
-- @param text string - the text to say
-- @return boolean - true if message was said
function PM.SayRaw(player, text)
    if not player or not player.Say or not text then
        return false
    end
    
    player:Say(text)
    return true
end

--- Make player say a random message from a pool
-- @param player IsoPlayer - the player object
-- @param poolKey string - one of PM.* pool constants (e.g., PROTECTED_OBJECT)
-- @return boolean - true if message was said
function PM.SayRandom(player, poolKey)
    if not player or not player.Say then
        return false
    end
    
    local pool = MessagePools[poolKey]
    if not pool then
        return false
    end
    
    -- Pick random from pool (1-based indexing)
    local index = ZombRand(#pool) + 1
    local translationKey = pool[index]
    local text = getText and getText(translationKey) or translationKey
    
    player:Say(text)
    return true
end

--- Make player say a move relic error message
-- Convenience function that converts error code and says the message
-- @param player IsoPlayer - the player object
-- @param errorCode string - one of MSR.Shared.MoveRelicError constants
-- @param ... - optional format arguments (e.g., corner name for SUCCESS)
-- @return boolean - true if message was said
function PM.SayMoveRelicError(player, errorCode, ...)
    local messageKey = PM.FromMoveRelicError(errorCode)
    return PM.Say(player, messageKey, ...)
end

-----------------------------------------------------------
-- Extension API: Register Custom Messages
-----------------------------------------------------------

--- Register a new message key with its translation key
-- @param messageKey string - unique message identifier
-- @param translationKey string - IGUI_* translation key
function PM.Register(messageKey, translationKey)
    MessageToTranslationKey[messageKey] = translationKey
end

--- Register a message pool for random selection
-- @param poolKey string - unique pool identifier
-- @param translationKeys table - array of IGUI_* translation keys
function PM.RegisterPool(poolKey, translationKeys)
    MessagePools[poolKey] = translationKeys
end

--- Get all registered message keys (for debugging/introspection)
-- @return table - copy of MessageToTranslationKey
function PM.GetAllMessages()
    local copy = {}
    for k, v in pairs(MessageToTranslationKey) do
        copy[k] = v
    end
    return copy
end

return MSR.PlayerMessage
