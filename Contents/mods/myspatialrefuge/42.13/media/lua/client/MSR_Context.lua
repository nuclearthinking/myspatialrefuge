-- Context menu for Sacred Relic and refuge protection hooks

require "MSR_Transaction"
require "MSR_Integrity"
require "MSR_PlayerMessage"
require "00_core/04_Env"

local PM = MSR.PlayerMessage




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

function MSR.MoveRelicToPosition(player, relic, refugeData, cornerDx, cornerDy, cornerName)
    if not player or not refugeData then return false end
    
    local lastMove = MSR.GetLastRelicMoveTime(player)
    local now = K.time()
    local cooldown = MSR.Config.RELIC_MOVE_COOLDOWN or 120
    local remaining = cooldown - (now - lastMove)
    
    if remaining > 0 then
        PM.Say(player, PM.CANNOT_MOVE_RELIC_YET, math.ceil(remaining))
        return false
    end
    
    if MSR.Env.isMultiplayerClient() then
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, MSR.Config.COMMANDS.REQUEST_MOVE_RELIC, {
            cornerDx = cornerDx,
            cornerDy = cornerDy,
            cornerName = cornerName
        })
        PM.Say(player, PM.MOVING_RELIC)
        
        L.debug("Context", "Sent RequestMoveRelic to server: " .. cornerName)
        
        return true
    else
        if not relic then return false end
        
        local success, errorCode = MSR.Shared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName)
        
        if success then
            MSR.UpdateRelicMoveTime(player)
            local translatedCornerName = MSR.TranslateCornerName(cornerName)
            PM.Say(player, PM.RELIC_MOVED_TO, translatedCornerName)
        else
            PM.SayMoveRelicError(player, errorCode)
        end
        
        return success
    end
end

local function isSpriteRefugeCore(obj)
    if not obj then return false end
    if not obj.getSprite then return false end

    local sprite = obj:getSprite()
    if not sprite then return false end

    local spriteName = sprite:getName()
    if not spriteName then return false end

    local validSprites = {
        MSR.Config.SPRITES.SACRED_RELIC,
        MSR.Config.SPRITES.SACRED_RELIC_FALLBACK
    }
    for _, validName in ipairs(validSprites) do
        if validName and spriteName == validName then
            return true
        end
    end
    return false
end

local function isSacredRelicObject(obj)
    if not obj then return false end
    
    if obj.getModData then
        local md = obj:getModData()
        if md and md.isSacredRelic then
            return true
        end
    end
    
    if isSpriteRefugeCore(obj) then
        return true
    end

    return false
end

local function OnFillWorldObjectContextMenu(player, context, worldObjects, test)
    if not context then return end

    local playerObj = player
    if type(player) == "number" then
        playerObj = getSpecificPlayer(player)
    end
    if not playerObj then return end
    
    local sacredRelic = nil
    for i = 1, #worldObjects do
        local obj = worldObjects[i]
        if obj and isSacredRelicObject(obj) then
            sacredRelic = obj
            break
        end
    end
    
    if not sacredRelic then return end
    
    local refugeData = MSR.GetRefugeData and MSR.GetRefugeData(playerObj)
    if not refugeData then return end
    
    local moveSubmenu = context:getNew(context)
    local moveOptionText = getText("IGUI_MoveSacredRelic")
    local moveOption = context:addOption(moveOptionText, playerObj, nil)
    context:addSubMenu(moveOption, moveSubmenu)
    
    local moveIcon = getTexture("media/ui/MoveRelic_24x24.png")
    if moveIcon then
        moveOption.iconTexture = moveIcon
    end
    
    -- PZ isometric: -X/-Y = up-left, +X/+Y = down-right
    local corners = {
        { name = "Up", key = "IGUI_RelicDirection_Up", dx = -1, dy = -1, icon = "DirectionUp" },
        { name = "Right", key = "IGUI_RelicDirection_Right", dx = 1, dy = -1, icon = "DirectionRight" },
        { name = "Left", key = "IGUI_RelicDirection_Left", dx = -1, dy = 1, icon = "DirectionLeft" },
        { name = "Down", key = "IGUI_RelicDirection_Down", dx = 1, dy = 1, icon = "DirectionDown" },
        { name = "Center", key = "IGUI_RelicDirection_Center", dx = 0, dy = 0, icon = "DirectionCenter" },
    }
    
    for _, corner in ipairs(corners) do
        local cornerText = getText(corner.key)
        local function moveToCorner()
            MSR.MoveRelicToPosition(playerObj, sacredRelic, refugeData, corner.dx, corner.dy, corner.name)
        end
        local cornerOption = moveSubmenu:addOption(cornerText, playerObj, moveToCorner)
        local dirIcon = getTexture("media/ui/" .. corner.icon .. "_32x32.png")
        if dirIcon then
            cornerOption.iconTexture = dirIcon
        end
    end
    
    local function openUpgradeWindow()
        local MSR_UpgradeWindow = require "MSR_UpgradeWindow"
        MSR_UpgradeWindow.Open(playerObj, sacredRelic)
    end
    
    local upgradeOptionText = getText("IGUI_UpgradeRefuge")
    local upgradeOption = context:addOption(upgradeOptionText, playerObj, openUpgradeWindow)
    local upgradeIcon = getTexture("media/ui/UpgradeArrow_24x24.png")
    if upgradeIcon then
        upgradeOption.iconTexture = upgradeIcon
    end
end

Events.OnFillWorldObjectContextMenu.Add(OnFillWorldObjectContextMenu)

-- Protected objects: Sacred Relic and boundary walls
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

-- Block disassembly/destruction/pickup of protected refuge objects
local function BlockDisassembleAction()
    if ISWorldObjectContextMenu and ISWorldObjectContextMenu.onDisassemble then
        local originalOnDisassemble = ISWorldObjectContextMenu.onDisassemble
        ISWorldObjectContextMenu.onDisassemble = function(worldobjects, object, player)
            -- Check if this is a protected object
            if isProtectedObject(object) then
                if player then
                    PM.SayRandom(player, PM.PROTECTED_OBJECT)
                end
                return  -- Block the action
            end
            -- Allow original function to proceed
            return originalOnDisassemble(worldobjects, object, player)
        end
    end
    
    -- Furniture disassembly
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
    
    -- Furniture pickup
    if ISMoveableSpriteProps and ISMoveableSpriteProps.isMoveable then
        local originalIsMoveable = ISMoveableSpriteProps.isMoveable
        ISMoveableSpriteProps.isMoveable = function(self, obj, player)
            if isProtectedObject(obj) then
                return false
            end
            return originalIsMoveable(self, obj, player)
        end
    end
    
    -- Thumpable pickup/disassembly
    if ISMoveableDefinitions then
        if ISMoveableDefinitions.onPickupThumpable then
            local originalPickupThumpable = ISMoveableDefinitions.onPickupThumpable
            ISMoveableDefinitions.onPickupThumpable = function(playerObj, thump)
                if isProtectedObject(thump) then
                    PM.SayRandom(playerObj, PM.PROTECTED_OBJECT)
                    return
                end
                return originalPickupThumpable(playerObj, thump)
            end
        end
        
        if ISMoveableDefinitions.onDisassembleThumpable then
            local originalDisassembleThumpable = ISMoveableDefinitions.onDisassembleThumpable
            ISMoveableDefinitions.onDisassembleThumpable = function(playerObj, thump)
                if isProtectedObject(thump) then
                    PM.SayRandom(playerObj, PM.PROTECTED_OBJECT)
                    return
                end
                return originalDisassembleThumpable(playerObj, thump)
            end
        end
    end
    
    -- General moveable actions
    if ISMoveablesAction and ISMoveablesAction.isValid then
        local originalMoveablesIsValid = ISMoveablesAction.isValid
        ISMoveablesAction.isValid = function(self)
            local function blockWithMessage()
                if not self._refugeMessageShown and self.character then
                    PM.SayRandom(self.character, PM.PROTECTED_OBJECT)
                    self._refugeMessageShown = true
                end
                return false
            end
            
            if self.moveProps and self.moveProps.object and isProtectedObject(self.moveProps.object) then
                return blockWithMessage()
            end
            if self.origSprite then
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
    
    -- Sledgehammer destruction
    if ISDestroyStuffAction and ISDestroyStuffAction.isValid then
        local originalIsValid = ISDestroyStuffAction.isValid
        ISDestroyStuffAction.isValid = function(self)
            local function blockWithMessage()
                if not self._refugeMessageShown and self.character then
                    PM.SayRandom(self.character, PM.PROTECTED_OBJECT)
                    self._refugeMessageShown = true
                end
                return false
            end
            
            if self.item and isProtectedObject(self.item) then
                return blockWithMessage()
            end
            if self.object and isProtectedObject(self.object) then
                return blockWithMessage()
            end
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
    
    -- Wall destruction menu option
    if ISWorldObjectContextMenu and ISWorldObjectContextMenu.onDestroyWall then
        local originalOnDestroyWall = ISWorldObjectContextMenu.onDestroyWall
        ISWorldObjectContextMenu.onDestroyWall = function(worldobjects, wall, player)
            if isProtectedObject(wall) then
                if player then
                    PM.SayRandom(player, PM.PROTECTED_OBJECT)
                end
                return
            end
            return originalOnDestroyWall(worldobjects, wall, player)
        end
    end
    
    -- Zombie thump damage
    if IsoThumpable and IsoThumpable.Thump then
        local originalThump = IsoThumpable.Thump
        IsoThumpable.Thump = function(self, source)
            if isProtectedObject(self) then return end
            return originalThump(self, source)
        end
    end
end

Events.OnGameStart.Add(BlockDisassembleAction)

return MSR

