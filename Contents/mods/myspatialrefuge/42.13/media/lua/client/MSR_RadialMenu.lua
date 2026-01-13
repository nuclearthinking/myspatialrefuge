-- Radial menu integration: emote menu (on foot) and vehicle menu (with upgrade)

require "ISUI/ISEmoteRadialMenu"
require "Vehicles/ISUI/ISVehicleMenu"
require "MSR_Teleport"
require "MSR_Cast"
require "MSR_PlayerMessage"
require "MSR_Validation"
local PM = MSR.PlayerMessage

local ENTER_ICON = getTexture("media/ui/emotes/enter_refuge_51x96.png") or getTexture("media/ui/emotes/gears.png")
local EXIT_ICON = getTexture("media/ui/emotes/exit_refuge_60x96.png") or getTexture("media/ui/emotes/back.png")

local function getTextOrDefault(key, fallback)
    local value = getText(key)
    if value and value ~= key then return value end
    return fallback
end

local function tryEnterRefuge(player)
    if not player or not MSR.CanEnterRefuge then return end

    local rm = getPlayerRadialMenu(player:getPlayerNum())
    if rm then rm:undisplay() end

    local canEnter, reason = MSR.CanEnterRefuge(player)
    if not canEnter then
        PM.SayRaw(player, reason)
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
        PM.Say(player, PM.NOT_IN_REFUGE)
        return
    end
    if MSR.BeginExitCast then
        MSR.BeginExitCast(player)
    end
end

-- Emote radial menu
if not MSR._originalEmoteFillMenu then
    MSR._originalEmoteFillMenu = ISEmoteRadialMenu.fillMenu
end

function ISEmoteRadialMenu:fillMenu(submenu)
    MSR._originalEmoteFillMenu(self, submenu)
    if submenu then return end  -- only inject on top-level ring

    local player = self.character
    if not player then return end
    local menu = getPlayerRadialMenu(self.playerNum)
    if not menu then return end

    if MSR.IsPlayerInRefuge and MSR.IsPlayerInRefuge(player) then
        menu:addSlice(
            getTextOrDefault("IGUI_SpatialRefuge_Exit", "Exit Spatial Refuge"),
            EXIT_ICON,
            tryExitRefuge,
            player
        )
        return
    end

    menu:addSlice(
        getTextOrDefault("IGUI_SpatialRefuge_Enter", "Enter Spatial Refuge"),
        ENTER_ICON,
        tryEnterRefuge,
        player
    )
end

-- Vehicle radial menu
local MSR_originalVehicleShowRadialMenu = ISVehicleMenu.showRadialMenu

function ISVehicleMenu.showRadialMenu(playerObj, ...)
    MSR_originalVehicleShowRadialMenu(playerObj, ...)
    
    local vehicle = ISVehicleMenu.getVehicleToInteractWith(playerObj)
    if not vehicle then return end
    if not playerObj:isSeatedInVehicle() then return end  -- must be seated
    
    local hasUpgrade = MSR.Validation and MSR.Validation.HasVehicleTeleportUpgrade 
        and MSR.Validation.HasVehicleTeleportUpgrade(playerObj)
    if not hasUpgrade then return end
    
    local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
    if not menu then return end
    
    local isMoving = MSR.Validation and MSR.Validation.IsVehicleMoving 
        and MSR.Validation.IsVehicleMoving(playerObj)
    
    if MSR.IsPlayerInRefuge and MSR.IsPlayerInRefuge(playerObj) then
        menu:addSlice(
            getTextOrDefault("IGUI_SpatialRefuge_Exit", "Exit Spatial Refuge"),
            EXIT_ICON,
            tryExitRefuge,
            playerObj
        )
    else
        if isMoving then
            menu:addSlice(
                getTextOrDefault("IGUI_CannotTeleportInMovingVehicle", "Vehicle must be stopped"),
                ENTER_ICON,
                nil,  -- No callback = disabled
                playerObj
            )
        else
            menu:addSlice(
                getTextOrDefault("IGUI_SpatialRefuge_Enter", "Enter Spatial Refuge"),
                ENTER_ICON,
                tryEnterRefuge,
                playerObj
            )
        end
    end
end

return MSR
