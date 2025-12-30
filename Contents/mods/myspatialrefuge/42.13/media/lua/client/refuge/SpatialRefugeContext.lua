-- Spatial Refuge Context Menu
-- Adds right-click menu options for Sacred Relic (exit and upgrade)

require "shared/SpatialRefugeTransaction"

-- Assume dependencies are already loaded
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}
SpatialRefugeShared = SpatialRefugeShared or {}

-- Count how many cores player has in inventory (total, including locked)
function SpatialRefuge.CountCores(player)
    if not player then return 0 end
    
    local inv = player:getInventory()
    if not inv then return 0 end
    
    return inv:getCountType(SpatialRefugeConfig.CORE_ITEM)
end

-- Count how many cores are AVAILABLE (not locked in pending transactions)
function SpatialRefuge.CountAvailableCores(player)
    if not player then return 0 end
    
    return SpatialRefugeTransaction.GetAvailableCount(player, SpatialRefugeConfig.CORE_ITEM)
end

-- Consume cores from player inventory
-- Returns: true if successful, false otherwise
function SpatialRefuge.ConsumeCores(player, amount)
    if not player then return false end
    
    local inv = player:getInventory()
    if not inv then return false end
    
    local coreCount = SpatialRefuge.CountCores(player)
    if coreCount < amount then
        return false
    end
    
    -- Remove cores
    local removed = 0
    local items = inv:getItems()
    for i = items:size()-1, 0, -1 do
        if removed >= amount then break end
        
        local item = items:get(i)
        if item and item:getFullType() == SpatialRefugeConfig.CORE_ITEM then
            inv:Remove(item)
            removed = removed + 1
        end
    end
    
    return removed == amount
end

-- Check if a square can have furniture/objects placed on it
-- Returns: isBlocked (boolean), reason (string if blocked)
local function squareHasBlockingContent(square)
    if not square then return true, "Invalid destination" end
    
    -- Check for world items on the ground
    local worldObjects = square:getWorldObjects()
    if worldObjects and worldObjects:size() > 0 then
        return true, "Items on the ground"
    end
    
    -- Use game's built-in isFree check
    if not square:isFree(false) then
        if square:has(IsoObjectType.tree) then
            return true, "Tree blocking destination"
        end
        return true, "Tile is blocked"
    end
    
    return false, nil
end

-- Clean vegetation/objects from a tile for relic placement
local function cleanTileForPlacement(square)
    if not square then return end
    
    local objects = square:getObjects()
    if not objects then return end
    
    local objectsToRemove = {}
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj then
            local md = obj:getModData()
            
            -- Don't remove our own objects or player-placed items
            if md and (md.isSacredRelic or md.isRefugeBoundary or md.refugeInvisibleWall or md.playerPlaced) then
                -- Skip
            elseif obj:getType() == IsoObjectType.tree then
                table.insert(objectsToRemove, obj)
            else
                local sprite = obj:getSprite()
                if sprite then
                    local spriteName = sprite:getName()
                    if spriteName and type(spriteName) == "string" then
                        -- Remove vegetation but not floors
                        if not spriteName:find("^blends_") and not spriteName:find("^floors_") then
                            if spriteName:find("vegetation_") or spriteName:find("e_newgrass_") or
                               spriteName:find("f_bushes_") or spriteName:find("f_flowers_") or
                               spriteName:find("d_plants_") or spriteName:find("_trees_") then
                                table.insert(objectsToRemove, obj)
                            end
                        end
                    end
                end
            end
        end
    end
    
    for _, obj in ipairs(objectsToRemove) do
        square:transmitRemoveItemFromSquare(obj)
    end
end

-- Get last relic move timestamp
function SpatialRefuge.GetLastRelicMoveTime(player)
    if not player then return 0 end
    local pmd = player:getModData()
    return pmd.spatialRefuge_lastRelicMove or 0
end

-- Update last relic move timestamp
function SpatialRefuge.UpdateRelicMoveTime(player)
    if not player then return end
    local pmd = player:getModData()
    pmd.spatialRefuge_lastRelicMove = getTimestamp()
end

-- Check if running as MP client (cached for performance)
local _cachedIsMPClient = nil
local function isMultiplayerClient()
    if _cachedIsMPClient == nil then
        _cachedIsMPClient = isClient() and not isServer()
    end
    return _cachedIsMPClient
end

-- Move Sacred Relic to a new position within the refuge
-- In MP: sends command to server; In SP: moves locally
function SpatialRefuge.MoveRelicToPosition(player, relic, refugeData, cornerDx, cornerDy, cornerName)
    if not player or not refugeData then return false end
    
    -- Check cooldown (client-side validation, server also validates)
    local lastMove = SpatialRefuge.GetLastRelicMoveTime(player)
    local now = getTimestamp()
    local cooldown = SpatialRefugeConfig.RELIC_MOVE_COOLDOWN or 120
    local remaining = cooldown - (now - lastMove)
    
    if remaining > 0 then
        player:Say("Cannot move relic yet. Wait " .. math.ceil(remaining) .. " seconds.")
        return false
    end
    
    if isMultiplayerClient() then
        -- ========== MULTIPLAYER PATH ==========
        -- Send request to server, server moves the relic
        sendClientCommand(SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.REQUEST_MOVE_RELIC, {
            cornerDx = cornerDx,
            cornerDy = cornerDy,
            cornerName = cornerName
        })
        player:Say("Moving Sacred Relic...")
        
        if getDebug() then
            print("[SpatialRefuge] Sent RequestMoveRelic to server: " .. cornerName)
        end
        
        return true
    else
        -- ========== SINGLEPLAYER PATH ==========
        -- Move locally using shared function
        if not relic then return false end
        
        local success, message = SpatialRefugeShared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName)
        
        if success then
            SpatialRefuge.UpdateRelicMoveTime(player)
            player:Say("Sacred Relic moved to " .. cornerName .. ".")
        else
            player:Say(message or "Cannot move relic.")
        end
        
        return success
    end
end

-- Reposition relic to its assigned corner (called after refuge upgrade)
-- This is called server-side after expand, so just uses the shared function
function SpatialRefuge.RepositionRelicToAssignedCorner(relic, refugeData)
    if not relic or not refugeData then return false end
    
    local md = relic:getModData()
    if not md.assignedCorner then
        -- No corner assigned, relic stays at current position
        return false
    end
    
    local cornerDx = md.assignedCornerDx or 0
    local cornerDy = md.assignedCornerDy or 0
    local cornerName = md.assignedCorner
    
    -- Use shared function for the actual move
    local success, message = SpatialRefugeShared.MoveRelic(refugeData, cornerDx, cornerDy, cornerName)
    
    if getDebug() and success then
        print("[SpatialRefuge] Repositioned relic to " .. cornerName)
    end
    
    return success
end

-- Check if an object is a Sacred Relic by examining its ModData
local function isSacredRelicObject(obj)
    if not obj then return false end
    
    -- Check ModData - this persists correctly in normal gameplay
    if obj.getModData then
        local md = obj:getModData()
        if md and md.isSacredRelic then
            return true
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
    
    -- Always show exit option (with cast time)
    context:addOption("Exit Refuge", playerObj, SpatialRefuge.BeginExitCast, sacredRelic)
    
    -- Show storage access if relic has a container
    local relicObj = sacredRelic
    -- Handle world item wrapper (get the actual IsoObject)
    if sacredRelic.getItem then
        local item = sacredRelic:getItem()
        if item and item.getWorldItem then
            relicObj = item:getWorldItem() or sacredRelic
        end
    end
    
    if relicObj and relicObj.getContainer then
        local container = relicObj:getContainer()
        if container then
            -- Create callback function that captures playerObj properly
            local function openRelicStorage()
                local lootWindow = getPlayerLoot(playerObj:getPlayerNum())
                if lootWindow then
                    lootWindow.inventoryPane.lastinventory = container
                    lootWindow:refreshBackpacks()
                end
            end
            
            local storageOption = context:addOption("Sacred Relic Storage", playerObj, openRelicStorage)
            
            -- Add tooltip showing current storage usage
            local tooltip = ISInventoryPaneContextMenu.addToolTip()
            local itemCount = container:getItems() and container:getItems():size() or 0
            local capacity = container:getCapacity() or 20
            tooltip:setName("Sacred Relic Storage")
            tooltip:setDescription("Items: " .. itemCount .. "\nCapacity: " .. capacity)
            storageOption.toolTip = tooltip
        end
    end
    
    -- Get player's refuge data
    local refugeData = SpatialRefuge.GetRefugeData and SpatialRefuge.GetRefugeData(playerObj)
    if not refugeData then return end
    
    -- Add "Move Sacred Relic" submenu
    local moveSubmenu = context:getNew(context)
    local moveOption = context:addOption("Move Sacred Relic", playerObj, nil)
    context:addSubMenu(moveOption, moveSubmenu)
    
    -- Define corner positions relative to refuge center (isometric view)
    -- In PZ isometric: decreasing X/Y = up-left, increasing X/Y = down-right
    local corners = {
        { name = "Up", dx = -1, dy = -1 },      -- Top of isometric diamond
        { name = "Right", dx = 1, dy = -1 },    -- Right side
        { name = "Left", dx = -1, dy = 1 },     -- Left side
        { name = "Down", dx = 1, dy = 1 },      -- Bottom of isometric diamond
        { name = "Center", dx = 0, dy = 0 },
    }
    
    for _, corner in ipairs(corners) do
        local function moveToCorner()
            SpatialRefuge.MoveRelicToPosition(playerObj, sacredRelic, refugeData, corner.dx, corner.dy, corner.name)
        end
        moveSubmenu:addOption(corner.name, playerObj, moveToCorner)
    end
    
    -- Show feature upgrades option
    local function openFeatureUpgrades()
        local SpatialRefugeUpgradeWindow = require "refuge/SpatialRefugeUpgradeWindow"
        SpatialRefugeUpgradeWindow.Open(playerObj)
    end
    
    local featureUpgradeOption = context:addOption("Feature Upgrades", playerObj, openFeatureUpgrades)
    local featureTooltip = ISInventoryPaneContextMenu.addToolTip()
    featureTooltip:setName("Refuge Feature Upgrades")
    featureTooltip:setDescription("Unlock and upgrade special features for your refuge")
    featureUpgradeOption.toolTip = featureTooltip
    
    -- Show upgrade option if not at max tier
    if refugeData.tier < SpatialRefugeConfig.MAX_TIER then
        local currentTier = refugeData.tier
        local nextTier = currentTier + 1
        local tierConfig = SpatialRefugeConfig.TIERS[nextTier]
        local coreCost = tierConfig.cores
        -- Use available count (excludes cores locked in pending transactions)
        local availableCores = SpatialRefuge.CountAvailableCores(playerObj)
        local totalCores = SpatialRefuge.CountCores(playerObj)
        
        local optionText = "Upgrade Refuge (Tier " .. currentTier .. " → " .. nextTier .. ")"
        local option = context:addOption(optionText, playerObj, SpatialRefuge.OnUpgradeRefuge)
        
        -- Check for pending upgrade transaction
        local pendingTransaction = SpatialRefugeTransaction.GetPending(playerObj, "REFUGE_UPGRADE")
        
        if pendingTransaction then
            -- Upgrade already in progress
            option.notAvailable = true
            local tooltip = ISInventoryPaneContextMenu.addToolTip()
            tooltip:setName("Upgrade in progress...")
            option.toolTip = tooltip
        elseif availableCores < coreCost then
            -- Not enough available cores
            option.notAvailable = true
            local tooltip = ISInventoryPaneContextMenu.addToolTip()
            local lockedCount = totalCores - availableCores
            if lockedCount > 0 then
                tooltip:setName("Need " .. coreCost .. " cores (have " .. availableCores .. " available, " .. lockedCount .. " locked)")
            else
                tooltip:setName("Need " .. coreCost .. " cores (have " .. availableCores .. ")")
            end
            option.toolTip = tooltip
        else
            -- Show info tooltip
            local tooltip = ISInventoryPaneContextMenu.addToolTip()
            tooltip:setName("Costs " .. coreCost .. " cores")
            tooltip:setDescription("New size: " .. tierConfig.displayName)
            option.toolTip = tooltip
        end
    else
        -- At max tier
        local option = context:addOption("Max Tier Reached", playerObj, nil)
        option.notAvailable = true
    end
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
local protectedObjectMessages = {
    "I don't want to do that...",
    "That seems unnecessary.",
    "Something tells me I shouldn't...",
    "This doesn't feel right.",
    "I have a bad feeling about this.",
    "Better leave it alone.",
    "No... I need this.",
    "Why would I do that?",
    "That would be a mistake.",
    "I'd rather not.",
    "This is important. I should leave it be.",
    "Destroying this would be foolish.",
    "Some things are better left untouched.",
    "I can't bring myself to do it.",
    "This gives me shelter. Why break it?",
}

local function getProtectedObjectMessage()
    return protectedObjectMessages[ZombRand(#protectedObjectMessages) + 1]
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
                    if objects then
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

return SpatialRefuge

