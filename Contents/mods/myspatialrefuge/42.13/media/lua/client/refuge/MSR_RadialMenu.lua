-- Spatial Refuge Social (Emote) Radial Menu Integration
-- Adds Enter/Exit slices to the social radial (hold Q)

require "ISUI/ISEmoteRadialMenu"
require "refuge/MSR_Teleport"
require "refuge/MSR_Cast"




-- Custom refuge icons (fallback to vanilla emote icons if missing)
local ENTER_ICON = getTexture("media/ui/emotes/enter_refuge_51x96.png") or getTexture("media/ui/emotes/gears.png")
local EXIT_ICON = getTexture("media/ui/emotes/exit_refuge_60x96.png") or getTexture("media/ui/emotes/back.png")

local function getTextOrDefault(key, fallback)
    if getText then
        local value = getText(key)
        if value and value ~= key then
            return value
        end
    end
    return fallback
end

local function tryEnterRefuge(player)
    if not player or not MSR.CanEnterRefuge then return end

    -- Hide the radial menu immediately to avoid overlapping the feedback text
    local rm = getPlayerRadialMenu(player:getPlayerNum())
    if rm then rm:undisplay() end

    local canEnter, reason = MSR.CanEnterRefuge(player)
    if not canEnter then
        player:Say(reason or getTextOrDefault("IGUI_SpatialRefuge_OnCooldown", "Cannot enter refuge"))
        return
    end
    if MSR.BeginTeleportCast then
        MSR.BeginTeleportCast(player)
    end
end

local function tryExitRefuge(player)
    if not player then return end

    local rm = getPlayerRadialMenu(player:getPlayerNum())
    if rm then rm:undisplay() end

    if MSR.IsPlayerInRefuge and not MSR.IsPlayerInRefuge(player) then
        player:Say(getTextOrDefault("IGUI_SpatialRefuge_Exit", "Exit Spatial Refuge"))
        return
    end
    if MSR.BeginExitCast then
        MSR.BeginExitCast(player)
    end
end

-- Chain the emote radial menu construction to add our slices
if not MSR._originalEmoteFillMenu then
    MSR._originalEmoteFillMenu = ISEmoteRadialMenu.fillMenu
end

function ISEmoteRadialMenu:fillMenu(submenu)
    -- Build vanilla emote entries first
    MSR._originalEmoteFillMenu(self, submenu)

    -- Only inject on top-level ring
    if submenu then return end

    local player = self.character
    if not player then return end
    local menu = getPlayerRadialMenu(self.playerNum)
    if not menu then return end

    -- Inside refuge - show exit option
    if MSR.IsPlayerInRefuge and MSR.IsPlayerInRefuge(player) then
        menu:addSlice(
            getTextOrDefault("IGUI_SpatialRefuge_Exit", "Exit Spatial Refuge"),
            EXIT_ICON,
            tryExitRefuge,
            player
        )
        return
    end

    -- Otherwise offer entry (conditions enforced in handler)
    menu:addSlice(
        getTextOrDefault("IGUI_SpatialRefuge_Enter", "Enter Spatial Refuge"),
        ENTER_ICON,
        tryEnterRefuge,
        player
    )
end

return MSR
