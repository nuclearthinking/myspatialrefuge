# Technical Notes - Workarounds & Solutions

This document records tricky solutions and workarounds used in the Spatial Refuge mod. Use as reference for improvements or when similar problems arise.

---

## 1. Object Protection (Indestructible Walls/Relic)

### Problem

Players could destroy refuge walls with sledgehammer and disassemble the Sacred Relic.

### Solution

Multi-layer protection approach:

**Layer 1: Object Properties (SpatialRefugeGeneration.lua)**

```lua
relic:setIsThumpable(false)
relic:setIsDismantable(false)
relic:setMaxHealth(999999)
relic:setHealth(999999)
```

**Layer 2: ModData Flags**

```lua
md.isSacredRelic = true
md.isRefugeBoundary = true
md.isProtectedRefugeObject = true
```

**Layer 3: Action Hooks (SpatialRefugeContext.lua)**

- Hook `ISDestroyStuffAction.isValid` - return false for protected objects
- Hook `ISMoveablesAction.isValid` - return false for protected objects
- Hook `IsoThumpable.Thump` - block thump damage entirely

**Why multiple layers:**

- Object properties alone aren't enough - game has multiple paths to destruction
- `.new` hooks can't return nil (crashes action queue)
- `.isValid` hooks run before `.start`, so show message there
- Use `_refugeMessageShown` flag to prevent message spam

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

- `CreateFloorTile()` - returns false if chunk not loaded
- `createRelicObject()` - errors if chunk not loaded (critical)
- `createWallObject()` - returns nil if chunk not loaded

**In teleport code:**

- Check both `centerSquare ~= nil` AND `centerSquare:getChunk() ~= nil`
- Wall creation checks each perimeter square's chunk before creating

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

Top edge (north-facing walls):
  y = centerY - radius - 1
  x from minX to maxX
  Use WALL_NORTH sprite

Bottom edge:
  y = centerY + radius + 1
  x from minX to maxX
  Use WALL_NORTH sprite

Left edge (west-facing walls):
  x = centerX - radius - 1
  y from minY to maxY
  Use WALL_WEST sprite

Right edge:
  x = centerX + radius + 1
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

local function doTeleport()
    tickCount = tickCount + 1
    
    local centerSquare = cell:getGridSquare(x, y, z)
    local chunk = centerSquare and centerSquare:getChunk()
    
    if centerSquare and chunk then
        -- Safe to generate
        SpatialRefuge.EnsureRefugeFloor(...)
        SpatialRefuge.CreateBoundaryWalls(...)
        Events.OnTick.Remove(doTeleport)
    elseif tickCount >= maxTicks then
        player:Say("Refuge area not loaded.")
        Events.OnTick.Remove(doTeleport)
    end
end

Events.OnTick.Add(doTeleport)
```

---

## 6. Zombie Clearing

### Problem

Zombies or corpses inside refuge area when player enters.

### Solution

After floor is prepared, clear zombies in radius + buffer:

```lua
function SpatialRefuge.ClearZombiesFromArea(centerX, centerY, z, radius)
    local BUFFER = 3  -- Extra tiles beyond refuge
    
    for x = centerX - radius - BUFFER, centerX + radius + BUFFER do
        for y = centerY - radius - BUFFER, centerY + radius + BUFFER do
            local square = cell:getGridSquare(x, y, z)
            if square then
                -- Remove living zombies
                local movingObjects = square:getMovingObjects()
                for i = movingObjects:size() - 1, 0, -1 do
                    local obj = movingObjects:get(i)
                    if instanceof(obj, "IsoZombie") then
                        obj:removeFromSquare()
                        obj:removeFromWorld()
                    end
                end
                
                -- Remove corpses
                local deadBody = square:getDeadBody()
                if deadBody then
                    deadBody:removeFromSquare()
                    deadBody:removeFromWorld()
                end
            end
        end
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

After upgrade, recalculate position:

```lua
local targetX = centerX + (cornerDx * newRadius)
local targetY = centerY + (cornerDy * newRadius)
```

Move relic to new position using `transmitRemoveItemFromSquare` and `AddSpecialObject`.

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

## Future Improvements

1. **Menu option removal** - Find proper hook to remove Disassemble before it's added
2. **Multiplayer sync** - Server-side generation for wall/floor objects
3. **Corner sprites** - Find tileset with all 4 corners, or use different wall style
4. **Better chunk loading** - Pre-load chunks before teleport using `loadChunkAtPosition`

---

*Last Updated: December 2024*


