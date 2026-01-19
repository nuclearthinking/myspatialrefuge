-- Radial menu integration: emote menu (on foot) and vehicle menu (with upgrade)

require "00_core/00_MSR"
require "ISUI/ISEmoteRadialMenu"
require "Vehicles/ISUI/ISVehicleMenu"
require "MSR_Teleport"
require "MSR_Cast"
require "MSR_PlayerMessage"
require "MSR_Validation"
local PM = MSR.PlayerMessage

local ENTER_ICON = getTexture("media/ui/emotes/enter_refuge_51x96.png") or getTexture("media/ui/emotes/gears.png")
local EXIT_ICON = getTexture("media/ui/emotes/exit_refuge_60x96.png") or getTexture("media/ui/emotes/back.png")
local DEBUG_ICON = getTexture("media/ui/emotes/gears.png") or ENTER_ICON
local BACK_ICON = getTexture("media/ui/emotes/back.png") or EXIT_ICON

local function getTextOrDefault(key, fallback)
    local value = getText(key)
    if value and value ~= key then return value end
    return fallback
end

local function isDebugMode()
    return MSR.Env.isDebugEnabled()
end

local function showEmoteMenu(player)
    local menu = ISEmoteRadialMenu:new(player)
    menu:display()
end

local function teleportDebugBasement(player, toBasement)
    if not player then return end
    if not MSR.Data or not MSR.Data.IsPlayerInRefugeCoords or not MSR.Data.IsPlayerInRefugeCoords(player) then
        if PM and PM.Say then PM.Say(player, PM.NOT_IN_REFUGE) end
        return
    end
    local refugeData = MSR.Data.GetRefugeData(player)
    if not refugeData then return end

    local targetZ = toBasement and (refugeData.centerZ - 1) or refugeData.centerZ
    local x, y = player:getX(), player:getY()
    player:teleportTo(x, y, targetZ)
    player:setLastZ(targetZ)
end

local function addDebugMagicalCores(player)
    if not player or not MSR.Config then return end

    if MSR.Env and not MSR.Env.hasServerAuthority() then
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.DEBUG_ADD_CORES, {})
        if PM and PM.SayRaw then
            PM.SayRaw(player, "Requested 1000 Magical Cores (server).")
        end
        return
    end

    local inv = MSR.safePlayerCall and MSR.safePlayerCall(player, "getInventory") or nil
    if not inv then return end

    local itemType = MSR.Config.CORE_ITEM or "Base.MagicalCore"
    local count = 1000
    if inv.AddItems then
        inv:AddItems(itemType, count)
    else
        for _ = 1, count do
            inv:AddItem(itemType)
        end
    end

    if PM and PM.SayRaw then
        PM.SayRaw(player, "Added " .. tostring(count) .. " Magical Cores.")
    end
end

local function openDebugRadial(player)
    if not player then return end
    local menu = getPlayerRadialMenu(player:getPlayerNum())
    if not menu then return end
    menu:undisplay()
    menu:clear()

    menu:addSlice(
        getTextOrDefault("IGUI_SpatialRefuge_Debug_ToBasement", "Teleport to Basement"),
        DEBUG_ICON,
        teleportDebugBasement,
        player,
        true
    )
    menu:addSlice(
        getTextOrDefault("IGUI_SpatialRefuge_Debug_ToFloor", "Teleport to Floor"),
        DEBUG_ICON,
        teleportDebugBasement,
        player,
        false
    )
    menu:addSlice(
        getTextOrDefault("IGUI_SpatialRefuge_Debug_AddCores", "Add 1000 Magical Cores"),
        DEBUG_ICON,
        addDebugMagicalCores,
        player
    )
    menu:addSlice(
        getTextOrDefault("IGUI_SpatialRefuge_Debug_Back", "Back"),
        BACK_ICON,
        showEmoteMenu,
        player
    )

    menu:center()
    menu:addToUIManager()
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
        if isDebugMode() then
            menu:addSlice(
                getTextOrDefault("IGUI_SpatialRefuge_Debug", "Refuge Debug"),
                DEBUG_ICON,
                openDebugRadial,
                player
            )
        end
        return
    end

    menu:addSlice(
        getTextOrDefault("IGUI_SpatialRefuge_Enter", "Enter Spatial Refuge"),
        ENTER_ICON,
        tryEnterRefuge,
        player
    )
    if isDebugMode() then
        menu:addSlice(
            getTextOrDefault("IGUI_SpatialRefuge_Debug", "Refuge Debug"),
            DEBUG_ICON,
            openDebugRadial,
            player
        )
    end
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
