-- Spatial Refuge Radial Menu Integration
-- Adds enter/exit refuge options to:
-- 1. Social (Emote) radial menu (when on foot)
-- 2. Vehicle radial menu (when in vehicle, requires vehicle_teleport upgrade)

require "ISUI/ISEmoteRadialMenu"
require "Vehicles/ISUI/ISVehicleMenu"
require "MSR_Teleport"
require "MSR_Cast"
require "shared/MSR_PlayerMessage"
require "shared/MSR_Validation"
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

-----------------------------------------------------------
-- Social (Emote) Radial Menu Integration
-----------------------------------------------------------

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

-----------------------------------------------------------
-- Vehicle Radial Menu Integration
-----------------------------------------------------------

-- Store original function
local MSR_originalVehicleShowRadialMenu = ISVehicleMenu.showRadialMenu

function ISVehicleMenu.showRadialMenu(playerObj, ...)
    -- Call original first to build the menu
    MSR_originalVehicleShowRadialMenu(playerObj, ...)
    
    local vehicle = ISVehicleMenu.getVehicleToInteractWith(playerObj)
    if not vehicle then return end
    
    -- Must be seated in the vehicle to use vehicle teleport
    if not playerObj:isSeatedInVehicle() then return end
    
    -- Check if player has the vehicle_teleport upgrade unlocked
    local hasUpgrade = MSR.Validation and MSR.Validation.HasVehicleTeleportUpgrade 
        and MSR.Validation.HasVehicleTeleportUpgrade(playerObj)
    
    if not hasUpgrade then return end
    
    -- Get the radial menu
    local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
    if not menu then return end
    
    -- Check if vehicle is moving
    local isMoving = MSR.Validation and MSR.Validation.IsVehicleMoving 
        and MSR.Validation.IsVehicleMoving(playerObj)
    
    -- Add refuge enter/exit option
    if MSR.IsPlayerInRefuge and MSR.IsPlayerInRefuge(playerObj) then
        menu:addSlice(
            getTextOrDefault("IGUI_SpatialRefuge_Exit", "Exit Spatial Refuge"),
            EXIT_ICON,
            tryExitRefuge,
            playerObj
        )
    else
        -- Show enter option (grayed out if vehicle moving)
        if isMoving then
            -- Add disabled slice with tooltip
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
