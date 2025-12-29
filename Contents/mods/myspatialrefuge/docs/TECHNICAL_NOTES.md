# Technical Notes - Workarounds & Solutions

This document records tricky solutions and workarounds used in the Spatial Refuge mod. Use as reference for improvements or when similar problems arise.

---

## 1. Object Protection (Indestructible Walls/Relic)

### Problem

Players could destroy refuge walls with sledgehammer and disassemble the Sacred Relic.

### Solution

Multi-layer protection approach:

**Layer 1: Object Properties (SpatialRefugeShared.lua)**

```lua
wall:setMaxHealth(999999)
wall:setHealth(999999)
wall:setIsThumpable(false)
wall:setIsDismantable(false)
wall:setCanBarricade(false)
wall:setBreakSound("none")
wall:setCanBePlastered(false)
wall:setIsHoppable(false)
```

**Layer 2: ModData Flags**

```lua
md.isSacredRelic = true
md.isRefugeBoundary = true
md.isProtectedRefugeObject = true
md.canBeDisassembled = false
```

**Layer 3: Action Hooks (SpatialRefugeContext.lua)**

- Hook `ISDestroyStuffAction.isValid` - return false for protected objects
- Hook `ISMoveablesAction.isValid` - return false for protected objects
- Hook `IsoThumpable.Thump` - block thump damage entirely

**Layer 4: Property Repair on Load**

PZ map save doesn't preserve all `IsoThumpable` properties. Use `RepairRefugeProperties()`:

```lua
function SpatialRefugeShared.RepairRefugeProperties(refugeData)
    -- Scan refuge area and re-apply:
    if obj.setIsThumpable then obj:setIsThumpable(false) end
    if obj.setIsHoppable then obj:setIsHoppable(false) end
    -- ... etc
end
```

Called after:
- `GenerationComplete` received (entering refuge)
- Reconnecting while in refuge

**Why multiple layers:**

- Object properties alone aren't enough - game has multiple paths to destruction
- `.new` hooks can't return nil (crashes action queue)
- `.isValid` hooks run before `.start`, so show message there
- Use `_refugeMessageShown` flag to prevent message spam
- Properties may not survive map save/load cycle

**Player Messages:**
When blocked, player says random immersive message like "I don't want to do that..." or "Better leave it alone."

---

## 2. Chunk Loading Before Generation

### Problem

```
java.lang.NullPointerException: Cannot read field "loadedBits" because "square.chunk" is null
```

Adding floor tiles or objects to squares whose chunks aren't loaded causes crash.

### Solution

Check chunk existence before any square modification:

```lua
local chunk = square:getChunk()
if not chunk then
    -- Skip this tile, try again later
    return false
end
```

**Applied to:**

- `createWallObject()` - returns nil if chunk not loaded
- `createRelicObject()` - errors if chunk not loaded (critical)
- `MoveRelic()` - checks both source and target chunks

**In server teleport code:**

Server waits for ALL corners of refuge to be loaded (not just center):

```lua
local cornerOffsets = {
    {0, 0},              -- Center
    {-radius, -radius},  -- NW corner
    {radius, -radius},   -- NE corner  
    {-radius, radius},   -- SW corner
    {radius, radius}     -- SE corner
}

for _, offset in ipairs(cornerOffsets) do
    local square = cell:getGridSquare(centerX + offset[1], centerY + offset[2], centerZ)
    if not square or not square:getChunk() then
        allChunksLoaded = false
        break
    end
end
```

This is critical because relic may be at a corner position in a different chunk than center.

---

## 3. Action Hooks - Don't Return Nil

### Problem

```
java.lang.RuntimeException: attempted index: ignoreAction of non-table: null
```

Returning `nil` from action `.new` hooks breaks the action queue.

### Solution

**Wrong approach (crashes):**

```lua
ISDestroyStuffAction.new = function(self, ...)
    if isProtectedObject(item) then
        return nil  -- CRASH! Action queue expects an object
    end
end
```

**Correct approach:**

- Let action be created normally
- Block it in `.isValid` by returning `false`
- Show player message with spam prevention flag

```lua
ISDestroyStuffAction.isValid = function(self)
    if isProtectedObject(self.item) then
        if not self._refugeMessageShown then
            self.character:Say(getProtectedObjectMessage())
            self._refugeMessageShown = true
        end
        return false
    end
    return originalIsValid(self)
end
```

---

## 4. Isometric Wall Placement

### Problem

PZ uses isometric coordinates. Wall placement isn't intuitive with standard X/Y thinking.

### Solution

Wall placement rules based on isometric grid:

```
For a refuge with centerX, centerY and radius:

Interior usable area: from (minX, minY) to (maxX, maxY)
  where minX = centerX - radius
        maxX = centerX + radius
        minY = centerY - radius
        maxY = centerY + radius

North row (y = minY) - North-facing walls:
  x from minX to maxX
  Use WALL_NORTH sprite

South row (y = maxY + 1) - North-facing walls:
  x from minX to maxX
  Use WALL_NORTH sprite

West column (x = minX) - West-facing walls:
  y from minY to maxY
  Use WALL_WEST sprite

East column (x = maxX + 1) - West-facing walls:
  y from minY to maxY
  Use WALL_WEST sprite
```

**Note:** Only NW and SE corner overlays exist in `walls_exterior_house_01` tileset.

---

## 5. Generation Timing

### Problem

Player teleports to coordinates, but squares/chunks don't exist yet.

### Solution

Use `Events.OnTick` with polling:

```lua
local tickCount = 0
local maxTicks = 300  -- ~5 seconds timeout

local function waitForChunks()
    tickCount = tickCount + 1
    
    local centerSquare = cell:getGridSquare(x, y, z)
    local chunk = centerSquare and centerSquare:getChunk()
    
    if centerSquare and chunk then
        -- Safe to generate
        SpatialRefugeShared.CreateBoundaryWalls(...)
        SpatialRefugeShared.CreateSacredRelic(...)
        Events.OnTick.Remove(waitForChunks)
    elseif tickCount >= maxTicks then
        player:Say("Refuge area not loaded.")
        Events.OnTick.Remove(waitForChunks)
    end
end

Events.OnTick.Add(waitForChunks)
```

---

## 6. Zombie Clearing

### Problem

Zombies or corpses inside refuge area when player enters.

### Solution

After structures are generated, clear zombies in radius + buffer:

```lua
function SpatialRefugeShared.ClearZombiesFromArea(centerX, centerY, z, radius, forceClean, player)
    local BUFFER = 3  -- Extra tiles beyond refuge
    
    -- OPTIMIZATION: Skip for remote areas (coords < 2000)
    if not forceClean and centerX < 2000 and centerY < 2000 then
        return 0  -- No natural zombie spawns in remote areas
    end
    
    local zombieList = cell:getZombieList()
    local zombieOnlineIDs = {}  -- For MP sync
    
    for i = zombieList:size() - 1, 0, -1 do
        local zombie = zombieList:get(i)
        if isInArea(zombie, centerX, centerY, z, radius + BUFFER) then
            -- Collect ID for client sync (MP only)
            if isServer() and zombie.getOnlineID then
                table.insert(zombieOnlineIDs, zombie:getOnlineID())
            end
            zombie:removeFromSquare()
            zombie:removeFromWorld()
        end
    end
    
    -- Also remove corpses (IsoDeadBody objects)
    -- ... scan squares and remove dead bodies
    
    -- MP: Send zombie IDs to client for synced removal
    if isServer() and player and #zombieOnlineIDs > 0 then
        sendServerCommand(player, namespace, "ClearZombies", {
            zombieIDs = zombieOnlineIDs
        })
    end
end
```

---

## 7. Sacred Relic Corner Repositioning

### Problem

When refuge expands, Sacred Relic should move to its assigned corner at the new radius.

### Solution

Store corner assignment in ModData:

```lua
md.assignedCorner = "Up"  -- or "Down", "Left", "Right", "Center"
md.assignedCornerDx = -1  -- Offset from center (-1, 0, or 1)
md.assignedCornerDy = -1
```

**Critical:** When upgrading, search for relic at OLD radius, then reposition to NEW radius:

```lua
-- Capture old radius BEFORE expansion
local oldRadius = refugeData.radius

-- Perform expansion (updates refugeData.radius)
SpatialRefugeShared.ExpandRefuge(refugeData, newTier, player)

-- Find relic at OLD position
local relic = SpatialRefugeShared.FindRelicInRefuge(
    centerX, centerY, centerZ,
    oldRadius,  -- Use OLD radius - relic is at old corner position
    refugeId
)

-- Move to new position
if relic and md.assignedCorner then
    local targetX = centerX + (cornerDx * refugeData.radius)  -- NEW radius
    local targetY = centerY + (cornerDy * refugeData.radius)
    SpatialRefugeShared.MoveRelic(refugeData, cornerDx, cornerDy, md.assignedCorner)
end
```

---

## 8. Context Menu Protection

### Problem

"Disassemble" and other options still appear even when blocked.

### Solution

**Attempted but failed:**

- `context:removeOptionByName()` - doesn't work reliably
- `table.remove(context.options, i)` - options get re-added

**Working approach:**
Accept that menu options appear, but block the action when performed. Player sees a useless option that fails with an immersive message.

This is less ideal but stable. Future improvement: find earlier hook point where menu is constructed.

---

## 9. Multiplayer Wall Cleanup After Upgrade

### Problem

After upgrade, old walls may persist on client due to chunk caching, even though server removed them.

### Solution

Two-phase client-side cleanup after receiving `UpgradeComplete`:

```lua
-- Phase 1: Immediate cleanup
doClientCleanup("immediate")

-- Phase 2: Delayed cleanup (~0.5s later)
local function delayedCleanup()
    if tickCount < 30 then return end
    Events.OnTick.Remove(delayedCleanup)
    doClientCleanup("delayed")
end
Events.OnTick.Add(delayedCleanup)
```

Cleanup function scans area and removes objects with `isRefugeBoundary` flag that are NOT on the new perimeter.

---

## 10. Transaction System for Upgrades

### Problem

In multiplayer, items could be consumed client-side before server confirms success, leading to item loss on failure. Or items could be duplicated if consumed after server already processed.

### Solution

Transactional item consumption pattern:

```lua
-- 1. Client: Lock items (can't be used elsewhere)
local transaction = SpatialRefugeTransaction.Begin(player, "REFUGE_UPGRADE", {
    [SpatialRefugeConfig.CORE_ITEM] = coreCost
})

-- 2. Client: Send request with transaction ID
sendClientCommand(namespace, "RequestUpgrade", {
    transactionId = transaction.id,
    coreCost = coreCost
})

-- 3. On success: Commit (consume locked items)
if command == "UpgradeComplete" then
    SpatialRefugeTransaction.Commit(player, args.transactionId)
end

-- 4. On failure: Rollback (unlock items)
if command == "Error" then
    SpatialRefugeTransaction.Rollback(player, args.transactionId)
end
```

Features:
- Items marked as "locked" can't be used in other transactions
- Auto-rollback after 5 second timeout (prevents permanently locked items)
- Transaction IDs prevent duplicate processing
- Weak table keys clean up on player disconnect

---

## 11. Only Use getGridSquare, Never getOrCreateGridSquare

### Problem

Using `getOrCreateGridSquare` in remote areas creates empty cells that replace natural terrain, resulting in void squares with no floor.

### Solution

Always use `getGridSquare` and check for nil:

```lua
-- CORRECT
local square = cell:getGridSquare(x, y, z)
if not square then
    return nil  -- Chunk not loaded, retry later
end

-- WRONG - can destroy terrain
local square = cell:getOrCreateGridSquare(x, y, z)
```

This is why floor generation was removed - we rely on natural terrain to already exist when chunks load.

---

## 12. Server-Side Cooldown Storage

### Problem

Client-side cooldowns in ModData could be manipulated by cheaters.

### Solution

Server maintains its own cooldown state in local variables (not ModData):

```lua
local serverCooldowns = {
    teleport = {},     -- username -> timestamp
    relicMove = {}     -- username -> timestamp
}

local function checkTeleportCooldown(username)
    local lastTeleport = serverCooldowns.teleport[username] or 0
    local now = getServerTimestamp()
    local remaining = cooldown - (now - lastTeleport)
    return remaining <= 0, math.ceil(remaining)
end
```

Client still tracks cooldowns for UI feedback, but server is authoritative.

---

## 13. Player Validation with pcall

### Problem

During tick handlers waiting for chunks, player may disconnect, causing errors when accessing player methods.

### Solution

Wrap player method calls in pcall:

```lua
local function waitForServerChunks()
    -- Check if player is still valid
    local playerValid = false
    if playerRef then
        local ok, result = pcall(function() return playerRef:getUsername() end)
        playerValid = ok and result ~= nil
    end
    
    if not playerValid then
        Events.OnTick.Remove(waitForServerChunks)
        return
    end
    
    -- Continue processing...
end
```

---

## Future Improvements

1. **Menu option removal** - Find proper hook to remove Disassemble before it's added
2. **Corner sprites** - Find tileset with all 4 corners, or use different wall style
3. **Better chunk pre-loading** - Investigate `loadChunkAtPosition` for faster chunk availability
4. **Relic container persistence** - Verify container contents survive all save/load scenarios

---

*Last Updated: December 2024*
