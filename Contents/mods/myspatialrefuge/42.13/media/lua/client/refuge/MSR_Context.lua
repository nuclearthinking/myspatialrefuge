-- Spatial Refuge Context Menu

require "shared/MSR_Transaction"
require "shared/MSR_Integrity"
-- Uses global L for logging (loaded early by MSR.lua)




function MSR.TranslateCornerName(canonicalName)
    if not canonicalName then return canonicalName end
    
    local translationKeys = {
        Up = "IGUI_RelicDirection_Up",
        Right = "IGUI_RelicDirection_Right",
        Left = "IGUI_RelicDirection_Left",
        Down = "IGUI_RelicDirection_Down",
        Center = "IGUI_RelicDirection_Center",
    }
    
    local key = translationKeys[canonicalName]
    if key then
        return getText(key)
    end
    
    -- Fallback to canonical name if translation key not found
    return canonicalName
end

function MSR.GetLastRelicMoveTime(player)
    if not player then return 0 end
    local pmd = player:getModData()
    return pmd.spatialRefuge_lastRelicMove or 0
end

function MSR.UpdateRelicMoveTime(player)
    if not player then return end
    local pmd = player:getModData()
    pmd.spatialRefuge_lastRelicMove = K.time()
end

local _cachedIsMPClient = nil
local function isMultiplayerClient()
    if _cachedIsMPClient == nil then
        _cachedIsMPClient = isClient() and not isServer()
    end
    return _cachedIsMPClient
end

function MSR.MoveRelicToPosition(player, relic, refugeData, cornerDx, cornerDy, cornerName)
    if not player or not refugeData then return false end
    
    local lastMove = MSR.GetLastRelicMoveTime(player)
    local now = K.time()
    local cooldown = MSR.Config.RELIC_MOVE_COOLDOWN or 120
    local remaining = cooldown - (now - lastMove)
    
    if remaining > 0 then
        local message = string.format(getText("IGUI_CannotMoveRelicYet"), math.ceil(remaining))
        player:Say(message)
        return false
    end
    
    if isMultiplayerClient() then
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_MOVE_RELIC, {
            cornerDx = cornerDx,
            cornerDy = cornerDy,
            cornerName = cornerName
        })
        player:Say(getText("IGUI_MovingSacredRelic"))
        
        L.debug("Context", "Sent RequestMoveRelic to server: " .. cornerName)
        
        return true
    else
        if not relic then return false end
        
        local success, errorCode = MSR.Shared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName)
        
        if success then
            MSR.UpdateRelicMoveTime(player)
            local translatedCornerName = MSR.TranslateCornerName(cornerName)
            local successMsg = string.format(getText("IGUI_SacredRelicMovedTo"), translatedCornerName)
            player:Say(successMsg)
        else
            local translationKey = MSR.Shared.GetMoveRelicTranslationKey(errorCode)
            player:Say(getText(translationKey))
        end
        
        return success
    end
end
local function isSacredRelicObject(obj)
    if not obj then return false end
    
    -- Primary check: ModData - this persists correctly in normal gameplay
    if obj.getModData then
        local md = obj:getModData()
        if md and md.isSacredRelic then
            return true
        end
    end
    
    -- Fallback: Check sprite name (for unsynced MP clients or old saves)
    -- This allows context menu to work even if ModData hasn't synced yet
    -- Also recognizes old fallback sprite for migration
    if obj.getSprite and MSR.Config and MSR.Config.SPRITES then
        local sprite = obj:getSprite()
        if sprite then
            local spriteName = sprite:getName()
            local currentSprite = MSR.Config.SPRITES.SACRED_RELIC
            local oldFallbackSprite = MSR.Config.SPRITES.SACRED_RELIC_FALLBACK
            
            if spriteName == currentSprite or (oldFallbackSprite and spriteName == oldFallbackSprite) then
                -- Attempt client-side repair if integrity system is available
                -- This will migrate old fallback sprite to new one
                if MSR.Integrity and MSR.Integrity.ClientSpriteRepair then
                    MSR.Integrity.ClientSpriteRepair(obj)
                end
                return true
            end
        end
    end
    
    return false
end

-- Add context menu for Sacred Relic
local function OnFillWorldObjectContextMenu(player, context, worldObjects, test)
    if not context then return end

    local playerObj = player
    if type(player) == "number" then
        playerObj = getSpecificPlayer(player)
    end
    if not playerObj then return end
    
    -- Check if any of the world objects is a Sacred Relic
    local sacredRelic = nil
    for i = 1, #worldObjects do
        local obj = worldObjects[i]
        if obj and isSacredRelicObject(obj) then
            sacredRelic = obj
            break
        end
    end
    
    if not sacredRelic then return end
    
    -- Get player's refuge data
    local refugeData = MSR.GetRefugeData and MSR.GetRefugeData(playerObj)
    if not refugeData then return end
    
    -- Add "Move Sacred Relic" submenu
    local moveSubmenu = context:getNew(context)
    local moveOptionText = getText("IGUI_MoveSacredRelic")
    local moveOption = context:addOption(moveOptionText, playerObj, nil)
    context:addSubMenu(moveOption, moveSubmenu)
    
    -- Define corner positions relative to refuge center (isometric view)
    -- In PZ isometric: decreasing X/Y = up-left, increasing X/Y = down-right
    local corners = {
        { name = "Up", key = "IGUI_RelicDirection_Up", dx = -1, dy = -1 },      -- Top of isometric diamond
        { name = "Right", key = "IGUI_RelicDirection_Right", dx = 1, dy = -1 },    -- Right side
        { name = "Left", key = "IGUI_RelicDirection_Left", dx = -1, dy = 1 },     -- Left side
        { name = "Down", key = "IGUI_RelicDirection_Down", dx = 1, dy = 1 },      -- Bottom of isometric diamond
        { name = "Center", key = "IGUI_RelicDirection_Center", dx = 0, dy = 0 },
    }
    
    for _, corner in ipairs(corners) do
        local cornerText = getText(corner.key)
        local function moveToCorner()
            -- Pass canonical name (corner.name) for server communication and storage
            -- Translation will be applied at display time
            MSR.MoveRelicToPosition(playerObj, sacredRelic, refugeData, corner.dx, corner.dy, corner.name)
        end
        moveSubmenu:addOption(cornerText, playerObj, moveToCorner)
    end
    
    -- Show Upgrade Refuge option (opens the upgrade window)
    local function openUpgradeWindow()
        local MSR_UpgradeWindow = require "refuge/MSR_UpgradeWindow"
        MSR_UpgradeWindow.Open(playerObj)
    end
    
    local upgradeOptionText = getText("IGUI_UpgradeRefuge")
    local upgradeOption = context:addOption(upgradeOptionText, playerObj, openUpgradeWindow)
    
    -- Add icon to the option
    local upgradeIcon = getTexture("media/textures/upgrade_spatial_refuge_64x64.png")
    if upgradeIcon then
        upgradeOption.iconTexture = upgradeIcon
    end
    
    -- Add tooltip
    local upgradeTooltip = ISInventoryPaneContextMenu.addToolTip()
    upgradeTooltip:setName(getText("IGUI_UpgradeRefuge"))
    upgradeTooltip:setDescription(getText("IGUI_UpgradeRefuge_Tooltip"))
    upgradeOption.toolTip = upgradeTooltip
end

-- Register context menu hook
Events.OnFillWorldObjectContextMenu.Add(OnFillWorldObjectContextMenu)


-- Check if an object is protected (Sacred Relic or boundary wall)
local function isProtectedObject(obj)
    if not obj then return false end
    if obj.getModData then
        local md = obj:getModData()
        if md and (md.isSacredRelic or md.isRefugeBoundary) then
            return true
        end
    end
    return false
end

-- Random messages when player tries to interact with protected objects
-- Makes it seem like the player instinctively knows not to do this
local protectedObjectMessageKeys = {
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
}

local function getProtectedObjectMessage()
    local key = protectedObjectMessageKeys[ZombRand(#protectedObjectMessageKeys) + 1]
    return getText(key)
end

-- Hook the actual disassemble function to block it for protected objects
local function BlockDisassembleAction()
    -- Hook ISWorldObjectContextMenu.onDisassemble if it exists
    if ISWorldObjectContextMenu and ISWorldObjectContextMenu.onDisassemble then
        local originalOnDisassemble = ISWorldObjectContextMenu.onDisassemble
        ISWorldObjectContextMenu.onDisassemble = function(worldobjects, object, player)
            -- Check if this is a protected object
            if isProtectedObject(object) then
                if player and player.Say then
                    player:Say(getProtectedObjectMessage())
                end
                return  -- Block the action
            end
            -- Allow original function to proceed
            return originalOnDisassemble(worldobjects, object, player)
        end
    end
    
    -- Hook ISMoveableSpriteProps if it exists (handles furniture disassembly)
    if ISMoveableSpriteProps and ISMoveableSpriteProps.canBeDisassembled then
        local originalCanBeDisassembled = ISMoveableSpriteProps.canBeDisassembled
        ISMoveableSpriteProps.canBeDisassembled = function(self, obj, player)
            -- Block disassembly for protected refuge objects
            if isProtectedObject(obj) then
                return false
            end
            -- Fall through to original
            return originalCanBeDisassembled(self, obj, player)
        end
    end
    
    -- Hook ISMoveableSpriteProps.isMoveable to block pickup
    if ISMoveableSpriteProps and ISMoveableSpriteProps.isMoveable then
        local originalIsMoveable = ISMoveableSpriteProps.isMoveable
        ISMoveableSpriteProps.isMoveable = function(self, obj, player)
            if isProtectedObject(obj) then
                return false
            end
            return originalIsMoveable(self, obj, player)
        end
    end
    
    -- Hook ISMoveableDefinitions functions
    if ISMoveableDefinitions then
        -- Block pickup for thumpables
        if ISMoveableDefinitions.onPickupThumpable then
            local originalPickupThumpable = ISMoveableDefinitions.onPickupThumpable
            ISMoveableDefinitions.onPickupThumpable = function(playerObj, thump)
                if isProtectedObject(thump) then
                    if playerObj and playerObj.Say then
                        playerObj:Say(getProtectedObjectMessage())
                    end
                    return
                end
                return originalPickupThumpable(playerObj, thump)
            end
        end
        
        -- Block disassemble for thumpables
        if ISMoveableDefinitions.onDisassembleThumpable then
            local originalDisassembleThumpable = ISMoveableDefinitions.onDisassembleThumpable
            ISMoveableDefinitions.onDisassembleThumpable = function(playerObj, thump)
                if isProtectedObject(thump) then
                    if playerObj and playerObj.Say then
                        playerObj:Say(getProtectedObjectMessage())
                    end
                    return
                end
                return originalDisassembleThumpable(playerObj, thump)
            end
        end
    end
    
    -- Hook ISMoveablesAction.isValid
    if ISMoveablesAction and ISMoveablesAction.isValid then
        local originalMoveablesIsValid = ISMoveablesAction.isValid
        ISMoveablesAction.isValid = function(self)
            -- Helper to show message once and return false
            local function blockWithMessage()
                if not self._refugeMessageShown and self.character and self.character.Say then
                    self.character:Say(getProtectedObjectMessage())
                    self._refugeMessageShown = true
                end
                return false
            end
            
            if self.moveProps and self.moveProps.object and isProtectedObject(self.moveProps.object) then
                return blockWithMessage()
            end
            if self.origSprite then
                -- Try to find the object by sprite
                local square = self.square or (self.character and self.character:getCurrentSquare())
                if square then
                    local objects = square:getObjects()
                    if K.isIterable(objects) then
                        for i = 0, objects:size() - 1 do
                            local obj = objects:get(i)
                            if isProtectedObject(obj) then
                                return blockWithMessage()
                            end
                        end
                    end
                end
            end
            return originalMoveablesIsValid(self)
        end
    end
    
    
    -- Hook ISDestroyStuffAction to block sledgehammer destruction
    if ISDestroyStuffAction and ISDestroyStuffAction.isValid then
        local originalIsValid = ISDestroyStuffAction.isValid
        ISDestroyStuffAction.isValid = function(self)
            -- Helper to show message once and return false
            local function blockWithMessage()
                if not self._refugeMessageShown and self.character and self.character.Say then
                    self.character:Say(getProtectedObjectMessage())
                    self._refugeMessageShown = true
                end
                return false
            end
            
            -- Check if target object is protected
            if self.item and isProtectedObject(self.item) then
                return blockWithMessage()
            end
            if self.object and isProtectedObject(self.object) then
                return blockWithMessage()
            end
            -- Check all objects on the target square
            if self.square then
                local objects = self.square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if isProtectedObject(obj) then
                            return blockWithMessage()
                        end
                    end
                end
            end
            return originalIsValid(self)
        end
    end
    
    -- Hook ISWorldObjectContextMenu.onDestroyWall/onDestroyCurtain for sledgehammer menu options
    if ISWorldObjectContextMenu and ISWorldObjectContextMenu.onDestroyWall then
        local originalOnDestroyWall = ISWorldObjectContextMenu.onDestroyWall
        ISWorldObjectContextMenu.onDestroyWall = function(worldobjects, wall, player)
            if isProtectedObject(wall) then
                if player and player.Say then
                    player:Say(getProtectedObjectMessage())
                end
                return
            end
            return originalOnDestroyWall(worldobjects, wall, player)
        end
    end
    
    -- Hook thump damage to make protected objects truly indestructible
    if IsoThumpable and IsoThumpable.Thump then
        local originalThump = IsoThumpable.Thump
        IsoThumpable.Thump = function(self, source)
            if isProtectedObject(self) then
                return -- Block all thump damage
            end
            return originalThump(self, source)
        end
    end
end

-- Register action blocking hooks on game start
Events.OnGameStart.Add(BlockDisassembleAction)

return MSR

