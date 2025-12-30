-- Spatial Refuge Upgrade Mechanics
-- Handles tier upgrades with core consumption and expansion
-- Supports both multiplayer (server-authoritative) and singleplayer (client-side) paths
-- Uses transaction system for safe item consumption in multiplayer

require "shared/SpatialRefugeConfig"
require "shared/SpatialRefugeTransaction"

-- Dependencies are loaded by main loader - assert they exist
SpatialRefuge = SpatialRefuge or {}
SpatialRefugeConfig = SpatialRefugeConfig or {}

-----------------------------------------------------------
-- Environment Detection (cached - cannot change during session)
-----------------------------------------------------------

local _cachedIsMPClient = nil

-- Check if we're in multiplayer client mode (not host/SP) - cached for performance
local function isMultiplayerClient()
    if _cachedIsMPClient == nil then
        _cachedIsMPClient = isClient() and not isServer()
    end
    return _cachedIsMPClient
end

-- Resolve a player argument to a live IsoPlayer instance
-- Accepts player index, IsoPlayer, or nil; re-resolves by playerNum to avoid stale references
local function resolvePlayer(playerArg)
    if not playerArg then return nil end
    if type(playerArg) == "number" then
        return getSpecificPlayer(playerArg)
    end
    if playerArg.getPlayerNum then
        local ok, num = pcall(function() return playerArg:getPlayerNum() end)
        if ok and num ~= nil then
            local resolved = getSpecificPlayer(num)
            if resolved then
                return resolved
            end
        end
    end
    return playerArg
end

-- Safely read username (guards against null IsoPlayer references)
local function getSafeUsername(player)
    if not player or not player.getUsername then return nil end
    local ok, username = pcall(function() return player:getUsername() end)
    if not ok or not username or username == "" then
        return nil
    end
    return username
end

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

-- Find Sacred Relic in the refuge area
local function findSacredRelicInRefuge(refugeData)
    if not refugeData then return nil end
    
    local cell = getCell()
    if not cell then return nil end
    
    local centerX = refugeData.centerX
    local centerY = refugeData.centerY
    local centerZ = refugeData.centerZ
    local radius = refugeData.radius or 2
    
    -- Search the refuge area for the relic
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(centerX + dx, centerY + dy, centerZ)
            if square then
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj and obj.getModData then
                            local md = obj:getModData()
                            if md and md.isSacredRelic then
                                return obj
                            end
                        end
                    end
                end
            end
        end
    end
    
    return nil
end

-----------------------------------------------------------
-- Singleplayer Upgrade Logic
-----------------------------------------------------------

-- Perform refuge upgrade (singleplayer only)
-- Returns: true if successful, false otherwise
function SpatialRefuge.PerformUpgrade(player, refugeData, newTier)
    if not player or not refugeData then return false end
    
    local tierConfig = SpatialRefugeConfig.TIERS[newTier]
    if not tierConfig then return false end
    
    -- Find the Sacred Relic before expansion (to reposition after)
    local relic = findSacredRelicInRefuge(refugeData)
    
    -- Expand the refuge (creates new floor tiles and walls)
    local success = SpatialRefuge.ExpandRefuge(refugeData, newTier)
    
    if not success then
        player:Say("Failed to expand refuge!")
        return false
    end
    
    -- Invalidate cached boundary data so player can move in expanded area
    if SpatialRefuge.InvalidateBoundsCache then
        SpatialRefuge.InvalidateBoundsCache(player)
    end
    
    -- Reposition relic to assigned corner if it has one
    if relic and SpatialRefuge.RepositionRelicToAssignedCorner then
        SpatialRefuge.RepositionRelicToAssignedCorner(relic, refugeData)
    end
    
    return true
end

-----------------------------------------------------------
-- Transaction Type Constants
-----------------------------------------------------------

local TRANSACTION_TYPE_UPGRADE = "REFUGE_UPGRADE"

-----------------------------------------------------------
-- Main Upgrade Entry Point
-----------------------------------------------------------

-- Override the upgrade callback from context menu
function SpatialRefuge.OnUpgradeRefuge(player)
    if not player then return end
    
    -- Resolve and validate player
    local playerObj = resolvePlayer(player)
    if not playerObj then return end
    if not getSafeUsername(playerObj) then return end
    
    -- Get refuge data
    local refugeData = SpatialRefuge.GetRefugeData(playerObj)
    if not refugeData then
        playerObj:Say("Refuge data not found!")
        return
    end
    
    -- Calculate upgrade
    local currentTier = refugeData.tier
    local nextTier = currentTier + 1
    
    if nextTier > SpatialRefugeConfig.MAX_TIER then
        playerObj:Say("Already at max tier!")
        return
    end
    
    local tierConfig = SpatialRefugeConfig.TIERS[nextTier]
    if not tierConfig then return end
    local coreCost = tierConfig.cores
    
    -- Get core item type
    local coreItemType = SpatialRefugeConfig.CORE_ITEM
    if not coreItemType then
        playerObj:Say("Upgrade failed - configuration error")
        return
    end
    
    -- Check available cores
    local availableCores = SpatialRefugeTransaction.GetAvailableCount(playerObj, coreItemType)
    if availableCores < coreCost then
        playerObj:Say("Not enough cores!")
        return
    end
    
    if isMultiplayerClient() then
        -- ========== MULTIPLAYER PATH ==========
        local transaction, err = SpatialRefugeTransaction.Begin(playerObj, TRANSACTION_TYPE_UPGRADE, {
            [coreItemType] = coreCost
        })
        
        if not transaction then
            playerObj:Say(err or "Failed to start upgrade")
            return
        end
        
        -- Send to server
        local args = {
            newTier = nextTier,
            coreCost = coreCost,
            transactionId = transaction.id
        }
        
        sendClientCommand(SpatialRefugeConfig.COMMAND_NAMESPACE, SpatialRefugeConfig.COMMANDS.REQUEST_UPGRADE, args)
        playerObj:Say("Upgrading refuge...")
        
    else
        -- ========== SINGLEPLAYER PATH ==========
        -- No transaction needed - consume directly
        
        if SpatialRefuge.ConsumeCores and not SpatialRefuge.ConsumeCores(playerObj, coreCost) then
            playerObj:Say("Failed to consume cores!")
            return
        end
        
        if SpatialRefuge.PerformUpgrade(playerObj, refugeData, nextTier) then
            playerObj:Say("Refuge upgraded to " .. tierConfig.displayName .. "!")
        else
            -- Refund cores if upgrade failed
            local inv = playerObj:getInventory()
            if inv then
                for i = 1, coreCost do
                    inv:AddItem(coreItemType)
                end
            end
            playerObj:Say("Upgrade failed - cores refunded")
        end
    end
end

-----------------------------------------------------------
-- Transaction Commit/Rollback Handlers
-- Called from SpatialRefugeTeleport.lua OnServerCommand
-----------------------------------------------------------

-- Commit upgrade transaction (called on UpgradeComplete)
function SpatialRefuge.CommitUpgradeTransaction(player, transactionId)
    if not player or not transactionId then return false end
    
    local success = SpatialRefugeTransaction.Commit(player, transactionId)
    
    if getDebug() then
        print("[SpatialRefuge] CommitUpgradeTransaction: " .. transactionId .. " = " .. tostring(success))
    end
    
    return success
end

-- Rollback upgrade transaction (called on Error response)
function SpatialRefuge.RollbackUpgradeTransaction(player, transactionId)
    if not player then return false end
    
    -- Try by transaction ID first, fall back to transaction type
    local success = false
    if transactionId then
        success = SpatialRefugeTransaction.Rollback(player, transactionId)
    end
    
    if not success then
        -- Fallback: rollback by type (in case ID wasn't preserved in error)
        success = SpatialRefugeTransaction.Rollback(player, nil, TRANSACTION_TYPE_UPGRADE)
    end
    
    if getDebug() then
        print("[SpatialRefuge] RollbackUpgradeTransaction: " .. tostring(transactionId) .. " = " .. tostring(success))
    end
    
    return success
end

return SpatialRefuge
