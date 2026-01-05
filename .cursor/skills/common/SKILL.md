---
name: common
description: Properly explore and understand Project Zomboid API and game internals
---

# PZ API Reference

## Reference Sources
- **Decompiled Java:** `C:\Users\onifent\Downloads\ZomboidDecompiler\ZomboidDecompiler\bin\output\source` - Search classes (`IsoPlayer`, `IsoCell`), check `@LuaMethod` annotations
- **Official Lua:** `D:\SteamLibrary\steamapps\common\ProjectZomboid\media\lua` - Check `shared/`, `client/`, `server/` for patterns

## Common API Patterns

### Player Access
```lua
local player = getPlayer() -- client
local player = getSpecificPlayer(num) -- server
-- Resolve safely:
if type(player) == "number" then player = getSpecificPlayer(player) end
if player and player.getPlayerNum then
    local ok, num = pcall(function() return player:getPlayerNum() end)
    if ok and num then player = getSpecificPlayer(num) end
end
```
**Methods:** `getPlayerNum()`, `getUsername()`, `getModData()`, `getX/Y/Z()`, `teleportTo()`, `getInventory()`, `getSquare()`

### Cell/World
```lua
local cell = getCell()
local square = cell:getGridSquare(x, y, z)
if square and square:getChunk() then -- check loaded
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
    end
end
```

### ModData
```lua
local pmd = player:getModData() -- persists
local md = obj:getModData() -- if obj.getModData exists
```

### Safe Calls
```lua
local ok, result = pcall(function() return player:method() end)
-- or: K.safeCall(player, "methodName", args)
```

### Client/Server
- **Client:** UI, local actions, visuals
- **Server:** State changes, MP sync, world mods
- **Shared:** Common utils, config, data

## Object Types
- **IsoPlayer:** `getPlayerNum()`, `getModData()`, `teleportTo()`
- **IsoCell:** `getGridSquare()`, `getObjectList()`
- **IsoObject:** `getModData()`, `getType()` (types: `IsoObjectType.wall`, `IsoObjectType.FloorTile`)
- **ItemContainer:** `getItems()`, `contains()`
- **InventoryItem:** `getType()`, `getModData()`

## Project Patterns
- **Transactions:** Lock items → server validates → commit/rollback
- **Player Resolution:** Always re-resolve via `getSpecificPlayer()` to avoid stale refs
- **ModData:** Use namespaced keys (`MSR.refugeData`)

## Pitfalls
1. Stale player refs → use `getSpecificPlayer()`
2. Unloaded chunks → check `square:getChunk()`
3. Java objects → use `:size()`, `:get(i)` not `#`, `[i]`
4. Nil checks → verify objects before methods
5. Context → don't mix client/server functions

## Debugging
- Search decompiled source for class/method names
- Reference official Lua for similar features
- Use `pcall` for risky operations
- Test SP and MP (behavior differs)
