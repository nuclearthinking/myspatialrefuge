-- MSR_AdminCommands - Server Admin Debug Functions
-- Provides functions for refuge management and recovery
--
-- RECOVERY (auto-detects player and tier from walls):
--   msrGoto()          - Teleport to slot 0 (1000,1000) to load chunk
--   msrGoto(slot)      - Teleport to specific slot
--   msrScan()          - Scan slot 0 and show info (does not modify)
--   msrScan(slot)      - Scan specific slot (0-99)
--   msrAssignHere()    - Find closest relic, assign that refuge to you
--   msrAssignHere(s)   - Assign slot s (auto-detect tier)
--   msrAssignHere(s,t) - Assign slot s with manual tier t
--
-- ADVANCED (manual control):
--   msrList()                         - List all refuges in registry
--   msrInfo("username")               - Show refuge info for a player
--   msrAssign("username", x, y, tier) - Assign refuge at coords to player
--   msrDelete("username")             - Delete a player's refuge entry
--   msrCoords()                       - Show refuge coordinate grid layout
--   msrHelp()                         - Show available commands
--
-- Note: These are Lua functions. Access via debug console (press ~ with debug mode).

require "shared/core/MSR"
require "shared/core/MSR_00_KahluaCompat"
require "shared/core/MSR_01_Logging"
require "shared/MSR_Config"
require "shared/MSR_Data"

local Config = MSR.Config
local Data = MSR.Data

-----------------------------------------------------------
-- Command Handlers
-----------------------------------------------------------

local function cmdList()
    local registry = Data.GetRefugeRegistry()
    if not registry then
        print("[MSR] Error: Registry not available")
        return
    end
    
    local count = 0
    print("[MSR] === Refuge Registry ===")
    for username, data in pairs(registry) do
        count = count + 1
        local coords = data.centerX .. "," .. data.centerY
        local tier = data.tier or 0
        local upgrades = data.upgrades and K.count(data.upgrades) or 0
        print("  " .. username .. ": coords=" .. coords .. " tier=" .. tier .. " upgrades=" .. upgrades)
    end
    print("[MSR] Total: " .. count .. " refuges")
end

local function cmdInfo(username)
    if not username or username == "" then
        print("[MSR] Usage: MSR.Admin.info(\"username\") or msrInfo(\"username\")")
        return
    end
    
    local data = Data.GetRefugeDataByUsername(username)
    if not data then
        print("[MSR] No refuge found for: " .. username)
        return
    end
    
    print("[MSR] === Refuge: " .. username .. " ===")
    print("  refugeId: " .. tostring(data.refugeId))
    print("  coords: " .. data.centerX .. "," .. data.centerY .. "," .. (data.centerZ or 0))
    print("  tier: " .. tostring(data.tier))
    print("  radius: " .. tostring(data.radius))
    print("  relic: " .. (data.relicX or data.centerX) .. "," .. (data.relicY or data.centerY))
    print("  dataVersion: " .. tostring(data.dataVersion))
    print("  createdTime: " .. tostring(data.createdTime))
    
    if data.upgrades then
        print("  upgrades:")
        for name, level in pairs(data.upgrades) do
            print("    " .. name .. ": " .. level)
        end
    end
    
    if data.inheritedFrom then
        print("  inheritedFrom: " .. data.inheritedFrom)
    end
end

local function cmdAssign(username, x, y, tier)
    if not username or username == "" or not x or not y then
        print("[MSR] Usage: msrAssign(\"username\", x, y, tier)")
        print("[MSR] Example: msrAssign(\"PlayerName\", 1050, 1050, 5)")
        return
    end
    
    local centerX = tonumber(x)
    local centerY = tonumber(y)
    local tierNum = tonumber(tier) or 0
    
    if not centerX or not centerY then
        print("[MSR] Error: x and y must be numbers")
        return
    end
    
    if tierNum < 0 or tierNum > Config.MAX_TIER then
        print("[MSR] Warning: tier " .. tierNum .. " out of range (0-" .. Config.MAX_TIER .. "), using " .. math.max(0, math.min(tierNum, Config.MAX_TIER)))
        tierNum = math.max(0, math.min(tierNum, Config.MAX_TIER))
    end
    
    local tierConfig = Config.TIERS[tierNum] or Config.TIERS[0]
    
    -- Check if there's existing data
    local existing = Data.GetRefugeDataByUsername(username)
    local preserveUpgrades = existing and existing.upgrades or {}
    
    -- Create refuge data
    local refugeData = {
        refugeId = "refuge_" .. username,
        username = username,
        centerX = centerX,
        centerY = centerY,
        centerZ = 0,
        tier = tierNum,
        radius = tierConfig.radius,
        relicX = centerX,
        relicY = centerY,
        relicZ = 0,
        createdTime = existing and existing.createdTime or K.time(),
        lastExpanded = K.time(),
        dataVersion = Config.CURRENT_DATA_VERSION,
        upgrades = preserveUpgrades,
        adminAssigned = true,
        adminAssignedTime = K.time()
    }
    
    -- Save to registry
    local registry = Data.GetRefugeRegistry()
    if not registry then
        print("[MSR] Error: Cannot access registry")
        return
    end
    
    registry[username] = refugeData
    Data.TransmitModData()
    
    print("[MSR] SUCCESS: Assigned refuge to " .. username)
    print("[MSR]   coords: " .. centerX .. "," .. centerY)
    print("[MSR]   tier: " .. tierNum .. " (radius " .. tierConfig.radius .. ")")
    if existing then
        print("[MSR]   (Replaced existing refuge, preserved " .. K.count(preserveUpgrades) .. " upgrades)")
    end
end

-- Helper: Calculate slot number from coordinates
local function slotFromCoords(x, y)
    local col = math.floor((x - Config.REFUGE_BASE_X) / Config.REFUGE_SPACING + 0.5)
    local row = math.floor((y - Config.REFUGE_BASE_Y) / Config.REFUGE_SPACING + 0.5)
    if col < 0 or col > 9 or row < 0 or row > 9 then
        return nil
    end
    return row * 10 + col
end

-- Helper: Find relic near a position
local function findRelicAt(x, y, z, searchRadius)
    local cell = getCell()
    if not cell then return nil end
    
    searchRadius = searchRadius or 5
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            if square then
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if obj and obj.getModData then
                            local md = obj:getModData()
                            if md and md.isSacredRelic then
                                return obj, md, x + dx, y + dy
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Helper: Find wall distance from center (determines radius/tier)
local function measureRefugeRadius(centerX, centerY, centerZ)
    local cell = getCell()
    if not cell then return nil end
    
    -- Search east from center for wall
    for dist = 1, 15 do
        local square = cell:getGridSquare(centerX + dist, centerY, centerZ)
        if square then
            local objects = square:getObjects()
            if objects then
                for i = 0, objects:size() - 1 do
                    local obj = objects:get(i)
                    if obj and obj.getModData then
                        local md = obj:getModData()
                        if md and md.isRefugeBoundary then
                            -- Wall found at distance 'dist'
                            -- Radius = dist - 1 (wall is at radius + 1)
                            return dist - 1
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Helper: Lookup tier from radius
local function tierFromRadius(radius)
    for tier, data in pairs(Config.TIERS) do
        if data.radius == radius then
            return tier
        end
    end
    return nil
end

-- Assign current player to refuge at slot (auto-detects tier from walls)
-- If no slot specified, finds closest relic and uses that slot
local function cmdAssignHere(slotNum, overrideTier)
    local player = getPlayer and getPlayer()
    if not player then
        print("[MSR] Error: No player found.")
        return
    end
    
    local username = player:getUsername()
    if not username then
        print("[MSR] Error: Could not get player username")
        return
    end
    
    local slot, centerX, centerY
    
    if slotNum then
        -- Explicit slot provided
        slot = tonumber(slotNum)
        local col = slot % 10
        local row = math.floor(slot / 10)
        centerX = Config.REFUGE_BASE_X + (col * Config.REFUGE_SPACING)
        centerY = Config.REFUGE_BASE_Y + (row * Config.REFUGE_SPACING)
    else
        -- No slot provided - find closest relic from current position
        local playerX = math.floor(player:getX())
        local playerY = math.floor(player:getY())
        local playerZ = math.floor(player:getZ())
        
        print("[MSR] Searching for closest relic near " .. playerX .. "," .. playerY .. "...")
        
        -- Search in wider radius since player might be anywhere in the refuge (max ~19x19 tiles)
        local relic, relicMd, relicX, relicY = findRelicAt(playerX, playerY, playerZ, 25)
        
        if relic then
            print("[MSR] Found relic at " .. relicX .. "," .. relicY)
            -- Calculate which slot this relic belongs to
            slot = slotFromCoords(relicX, relicY)
            if slot then
                local col = slot % 10
                local row = math.floor(slot / 10)
                centerX = Config.REFUGE_BASE_X + (col * Config.REFUGE_SPACING)
                centerY = Config.REFUGE_BASE_Y + (row * Config.REFUGE_SPACING)
                print("[MSR] Relic belongs to slot " .. slot .. " (center: " .. centerX .. "," .. centerY .. ")")
            else
                print("[MSR] Error: Relic at " .. relicX .. "," .. relicY .. " is not in valid slot range")
                return
            end
        else
            print("[MSR] No relic found nearby. Make sure you're inside a refuge.")
            print("[MSR] Use msrGoto() first to teleport to a refuge slot.")
            return
        end
    end
    
    -- Try to auto-detect tier from walls
    local detectedTier = nil
    local radius = measureRefugeRadius(centerX, centerY, 0)
    if radius then
        detectedTier = tierFromRadius(radius)
        if detectedTier then
            print("[MSR] Auto-detected tier " .. detectedTier .. " (radius " .. radius .. ") from walls")
        end
    end
    
    -- Use override if provided, otherwise use detected, otherwise default to 5
    local tierNum
    if overrideTier then
        tierNum = tonumber(overrideTier)
        print("[MSR] Using specified tier: " .. tierNum)
    elseif detectedTier then
        tierNum = detectedTier
    else
        tierNum = 5
        print("[MSR] Could not detect tier from walls, using default: " .. tierNum)
    end
    
    if tierNum < 0 or tierNum > Config.MAX_TIER then
        tierNum = math.max(0, math.min(tierNum, Config.MAX_TIER))
    end
    
    print("[MSR] Assigning refuge to " .. username .. " at slot " .. slot .. " (" .. centerX .. "," .. centerY .. ") tier " .. tierNum)
    cmdAssign(username, centerX, centerY, tierNum)
end

local function cmdDelete(username)
    if not username or username == "" then
        print("[MSR] Usage: msrDelete(\"username\")")
        return
    end
    
    local existing = Data.GetRefugeDataByUsername(username)
    if not existing then
        print("[MSR] No refuge found for: " .. username)
        return
    end
    
    local registry = Data.GetRefugeRegistry()
    if not registry then
        print("[MSR] Error: Cannot access registry")
        return
    end
    
    registry[username] = nil
    Data.TransmitModData()
    
    print("[MSR] Deleted refuge for: " .. username)
    print("[MSR]   Was at: " .. existing.centerX .. "," .. existing.centerY .. " tier " .. existing.tier)
end

local function cmdCoords()
    print("[MSR] === Refuge Coordinate Grid ===")
    print("[MSR] Base: " .. Config.REFUGE_BASE_X .. "," .. Config.REFUGE_BASE_Y)
    print("[MSR] Spacing: " .. Config.REFUGE_SPACING)
    print("[MSR] Layout (row, col -> x, y):")
    
    for row = 0, 2 do
        local line = "  Row " .. row .. ": "
        for col = 0, 4 do
            local x = Config.REFUGE_BASE_X + (col * Config.REFUGE_SPACING)
            local y = Config.REFUGE_BASE_Y + (row * Config.REFUGE_SPACING)
            line = line .. "(" .. x .. "," .. y .. ") "
        end
        print("[MSR] " .. line)
    end
    print("[MSR]   ... (continues for 10x10 grid)")
end

-- Teleport player to refuge slot (for chunk loading before scan)
-- Saves return position so normal exit works afterwards
local function cmdGoto(slotNum)
    local player = getPlayer and getPlayer()
    if not player then
        print("[MSR] Error: No player found.")
        return
    end
    
    local username = player:getUsername()
    if not username then
        print("[MSR] Error: Could not get player username")
        return
    end
    
    -- Save current position as return position before teleporting
    local returnX = player:getX()
    local returnY = player:getY()
    local returnZ = player:getZ()
    
    local slot = tonumber(slotNum) or 0
    local col = slot % 10
    local row = math.floor(slot / 10)
    local x = Config.REFUGE_BASE_X + (col * Config.REFUGE_SPACING)
    local y = Config.REFUGE_BASE_Y + (row * Config.REFUGE_SPACING)
    
    -- Save return position so normal exit works
    Data.SaveReturnPositionByUsername(username, returnX, returnY, returnZ)
    
    -- Use teleportTo instead of setX/setY (setX/setY doesn't work properly)
    player:teleportTo(x, y, 0)
    player:setLastX(x)
    player:setLastY(y)
    player:setLastZ(0)
    
    print("[MSR] Teleported to refuge slot " .. slot .. " (" .. x .. "," .. y .. ")")
    print("[MSR] Return position saved: " .. math.floor(returnX) .. "," .. math.floor(returnY) .. "," .. math.floor(returnZ))
    print("[MSR] Wait a few seconds for chunk to load, then run msrScan() or msrAssignHere()")
end

-- Scan refuge at location and show info (does NOT modify registry)
local function cmdScan(slotNum)
    local slot = tonumber(slotNum) or 0
    local col = slot % 10
    local row = math.floor(slot / 10)
    local centerX = Config.REFUGE_BASE_X + (col * Config.REFUGE_SPACING)
    local centerY = Config.REFUGE_BASE_Y + (row * Config.REFUGE_SPACING)
    local centerZ = 0
    
    print("[MSR] === Scanning Refuge Slot " .. slot .. " ===")
    print("[MSR] Location: " .. centerX .. "," .. centerY)
    
    -- Check if chunk is loaded
    local cell = getCell()
    if not cell then
        print("[MSR] ERROR: Cell not available. Load the game first.")
        return nil
    end
    
    local square = cell:getGridSquare(centerX, centerY, centerZ)
    if not square then
        print("[MSR] WARNING: Chunk not loaded. Teleport to " .. centerX .. "," .. centerY .. " first.")
        print("[MSR] Use: /goto " .. centerX .. " " .. centerY .. " 0")
        return nil
    end
    
    -- Find relic
    local relic, relicMd, relicX, relicY = findRelicAt(centerX, centerY, centerZ, 5)
    if not relic then
        print("[MSR] No relic found at this location.")
        print("[MSR] This refuge slot may be empty or never used.")
        return nil
    end
    
    print("[MSR] RELIC FOUND at " .. relicX .. "," .. relicY)
    print("[MSR]   refugeId: " .. tostring(relicMd.refugeId))
    
    -- Extract username from refugeId ("refuge_PlayerName" -> "PlayerName")
    local username = nil
    if relicMd.refugeId and type(relicMd.refugeId) == "string" then
        username = relicMd.refugeId:gsub("^refuge_", "")
    end
    print("[MSR]   Owner (from refugeId): " .. tostring(username))
    
    -- Measure radius from walls
    local radius = measureRefugeRadius(centerX, centerY, centerZ)
    local tier = nil
    if radius then
        tier = tierFromRadius(radius)
        print("[MSR]   Detected radius: " .. radius .. " (tier " .. tostring(tier) .. ")")
    else
        print("[MSR]   Could not detect radius (walls not loaded or missing)")
    end
    
    -- Check registry
    local registered = username and Data.GetRefugeDataByUsername(username)
    if registered then
        print("[MSR]   Registry: REGISTERED at " .. registered.centerX .. "," .. registered.centerY)
    else
        print("[MSR]   Registry: NOT REGISTERED")
        if username and tier then
            print("[MSR]")
            print("[MSR] To recover this refuge, run:")
            print("[MSR]   msrAssign(\"" .. username .. "\", " .. centerX .. ", " .. centerY .. ", " .. tier .. ")")
        end
    end
    
    return { username = username, centerX = centerX, centerY = centerY, tier = tier, radius = radius }
end

local function cmdHelp()
    print("[MSR] === My Spatial Refuge Admin Functions ===")
    print("[MSR]")
    print("[MSR] RECOVERY (auto-detects player and tier):")
    print("[MSR]   msrGoto()         - Teleport to slot 0 (1000,1000)")
    print("[MSR]   msrGoto(slot)     - Teleport to specific slot")
    print("[MSR]   msrScan()         - Scan slot 0, show info")
    print("[MSR]   msrScan(slot)     - Scan specific slot (0-99)")
    print("[MSR]   msrAssignHere()   - Find closest relic, assign that refuge to you")
    print("[MSR]   msrAssignHere(s)  - Assign slot s (auto-detect tier)")
    print("[MSR]   msrAssignHere(s,t)- Assign slot s with manual tier t")
    print("[MSR]")
    print("[MSR] ADVANCED:")
    print("[MSR]   msrList()                       - List all refuges")
    print("[MSR]   msrInfo(\"username\")             - Show refuge details")
    print("[MSR]   msrAssign(\"user\", x, y, tier)   - Assign refuge at coords")
    print("[MSR]   msrDelete(\"username\")           - Delete refuge entry")
    print("[MSR]   msrCoords()                     - Show coordinate grid layout")
    print("[MSR]")
    print("[MSR] Alternative: MSR.Admin.scan(), MSR.Admin.assignHere(), etc.")
end

-----------------------------------------------------------
-- Global API Registration
-----------------------------------------------------------

-- Expose admin functions globally for debug console access
-- Admins can call these directly: MSR.Admin.list(), MSR.Admin.info("player"), etc.
MSR.Admin = MSR.Admin or {}
MSR.Admin.list = cmdList
MSR.Admin.info = cmdInfo
MSR.Admin.assign = cmdAssign
MSR.Admin.assignHere = cmdAssignHere
MSR.Admin.delete = cmdDelete
MSR.Admin.coords = cmdCoords
MSR.Admin.scan = cmdScan
MSR.Admin.goto = cmdGoto
MSR.Admin.help = cmdHelp

-- Convenience: also expose at top level for quick access
-- Usage: msrSmartRecover(), msrScan(), msrRecover(), etc.
if not _G.msrList then
    _G.msrList = cmdList
    _G.msrInfo = cmdInfo
    _G.msrAssign = cmdAssign
    _G.msrAssignHere = cmdAssignHere
    _G.msrDelete = cmdDelete
    _G.msrCoords = cmdCoords
    _G.msrScan = cmdScan
    _G.msrGoto = cmdGoto
    _G.msrHelp = cmdHelp
end

print("[MSR] Admin functions loaded. Use MSR.Admin.help() or msrHelp() from debug console.")
