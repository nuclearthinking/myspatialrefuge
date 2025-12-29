# Spatial Refuge - Multiplayer Architecture

This document describes the client-server communication flow for refuge teleportation in multiplayer.

## Overview

The Spatial Refuge mod uses a **two-phase server-authoritative** architecture for multiplayer:

- **Server:** Manages data (ModData, coordinates), generates structures, broadcasts to clients
- **Client:** Handles teleportation, waits for chunks, notifies server when ready
- **Persistence:** Server creates `IsoThumpable` objects which are saved in the server's map data

### Why Two-Phase?

1. Server cannot load chunks at remote coordinates (1000, 1000) when no player is there
2. Client must teleport first, which triggers chunk loading on both client AND server
3. Once chunks are loaded, server generates structures that persist in the map save

---

## Enter Refuge Flow

```
CLIENT                              SERVER
   |                                   |
   |-- RequestEnter (returnPos) ------>|
   |                                   | Validate player state
   |                                   | Check server-side teleport cooldown
   |                                   | Store return position in ModData
   |                                   | Get/create refugeData
   |                                   | Update cooldown timestamp
   |<-------- TeleportTo (coords) -----|
   |                                   |
   | teleportTo(coords)                |
   | [player now at refuge coords]     |
   | [CLIENT chunks loading]           | [SERVER chunks loading around player]
   | Rotate player to load chunks      |
   | wait for chunks via OnTick...     |
   |                                   |
   |-- ChunksReady ------------------>|
   |                                   | wait for SERVER chunks via OnTick...
   |                                   | Check all corners (center + radius) loaded
   |                                   | [chunks loaded!]
   |                                   | EnsureRefugeStructures():
   |                                   |   - CreateBoundaryWalls()
   |                                   |   - CreateSacredRelicAtPosition()
   |                                   |   - ClearZombiesFromArea()
   |                                   | transmitAddObjectToSquare() → clients
   |                                   | transmitModData() → clients
   |<---- GenerationComplete ---------|
   |                                   |
   | "Entered Spatial Refuge"          |
   | RepairRefugeProperties()          |
   | [structures now visible]          |
```

---

## Exit Refuge Flow

```
CLIENT                              SERVER
   |                                   |
   |-- RequestExit ------------------>|
   |                                   | Check server-side teleport cooldown
   |                                   | Get return position from ModData
   |                                   | Clear return position
   |                                   | Update cooldown timestamp
   |<-------- ExitReady (coords) -----|
   |                                   |
   | teleportTo(returnCoords)          |
   | "Exited Spatial Refuge"           |
```

---

## Upgrade Refuge Flow

```
CLIENT                              SERVER
   |                                   |
   | BeginTransaction()                |
   | (lock cores in inventory)         |
   |                                   |
   |-- RequestUpgrade (transactionId,  |
   |     coreCost) ------------------->|
   |                                   | Validate player state
   |                                   | Check tier prerequisites
   |                                   | Verify ALL chunks for new radius loaded
   |                                   | RemoveAllRefugeWalls() (old perimeter)
   |                                   | ExpandRefuge() → creates new walls
   |                                   | Reposition relic to assigned corner
   |                                   | Save updated refugeData
   |<----- UpgradeComplete ------------|
   |       (transactionId, refugeData) |
   |                                   |
   | CommitTransaction()               |
   | (consume locked cores)            |
   | Update local ModData              |
   | Client-side wall cleanup          |
   | "Refuge upgraded to Tier X"       |
```

**On Error:**
```
CLIENT                              SERVER
   |                                   |
   |<-------- Error (transactionId) ---|
   |                                   |
   | RollbackTransaction()             |
   | (unlock cores, return to inv)     |
   | Display error message             |
```

---

## Move Relic Flow

```
CLIENT                              SERVER
   |                                   |
   |-- RequestMoveRelic (corner) ----->|
   |                                   | Check server-side relic move cooldown
   |                                   | Validate corner offset values
   |                                   | Get refuge data
   |                                   | MoveRelic() → transmit remove/add
   |                                   | Store corner assignment in ModData
   |                                   | Update cooldown timestamp
   |<---- MoveRelicComplete -----------|
   |       (cornerName, refugeData)    |
   |                                   |
   | Update local ModData              |
   | Update local cooldown             |
   | "Sacred Relic moved to corner"    |
```

---

## Network Commands

### Client → Server

| Command | Description | Args |
|---------|-------------|------|
| `RequestModData` | Client requests their refuge data on connect | - |
| `RequestEnter` | Client wants to enter refuge | `returnX, returnY, returnZ` |
| `ChunksReady` | Client confirms chunks loaded after teleport | - |
| `RequestExit` | Client wants to exit refuge | - |
| `RequestUpgrade` | Client wants to upgrade refuge tier | `coreCost, transactionId` |
| `RequestMoveRelic` | Client wants to move relic to corner | `cornerDx, cornerDy, cornerName` |

### Server → Client

| Command | Description | Args |
|---------|-------------|------|
| `ModDataResponse` | Server sends player's refuge data | `refugeData, returnPosition` |
| `TeleportTo` | Phase 1: Teleport to coordinates | `centerX/Y/Z, tier, radius, refugeId` |
| `GenerationComplete` | Phase 2: Structures are ready | `centerX/Y/Z, tier, radius` |
| `ExitReady` | Exit approved with return coords | `returnX, returnY, returnZ` |
| `UpgradeComplete` | Upgrade finished | `newTier, newRadius, oldRadius, displayName, transactionId, refugeData` |
| `MoveRelicComplete` | Relic moved successfully | `cornerName, cornerDx, cornerDy, refugeData` |
| `ClearZombies` | Sync zombie removal to client | `zombieIDs[]` |
| `Error` | Operation failed | `message, transactionId, transactionType, coreRefund` |

---

## Server-Authoritative Features

### Cooldown Tracking

The server maintains its own cooldown state to prevent client manipulation:

```lua
-- Server-side cooldown storage (not in ModData - prevents tampering)
local serverCooldowns = {
    teleport = {},     -- username -> timestamp
    relicMove = {}     -- username -> timestamp
}
```

Cooldowns checked:
- **Teleport cooldown:** 10 seconds between enter/exit
- **Relic move cooldown:** 30 seconds between moves (configurable)

### Transaction System

Upgrade operations use a transaction pattern to prevent item duplication/loss:

1. **Begin:** Client locks items in inventory, gets transaction ID
2. **Request:** Client sends request with transaction ID
3. **Success:** Client commits transaction (items consumed)
4. **Failure:** Client rolls back transaction (items unlocked)
5. **Timeout:** Auto-rollback after 5 seconds if no response

### Input Validation

Server validates all client input using `SpatialRefugeValidation`:

- Corner offsets are clamped to valid range (-1, 0, 1)
- Tier values are validated against config
- Refuge access is verified (player owns the refuge)
- Return coordinates are blocked if they're in refuge space

---

## Key Technical Details

### Object Creation (Server-Side)

```lua
-- Add object to square and broadcast to clients
if isServer() then
    square:transmitAddObjectToSquare(obj, -1)
else
    square:AddSpecialObject(obj)
end

-- Sync ModData to clients (required for context menu detection)
if isServer() and obj.transmitModData then
    obj:transmitModData()
end

-- For complete property sync (isThumpable, health, etc.)
if isServer() and obj.transmitCompleteItemToClients then
    obj:transmitCompleteItemToClients()
end
```

### Chunk Loading

Client and Server have **separate chunk systems**:
- `IsoCell` - Client's local chunks
- `ServerMap` - Server's chunk management

Server waits for chunks at ALL corners of the refuge (not just center):

```lua
local cornerOffsets = {
    {0, 0},              -- Center
    {-radius, -radius},  -- NW corner
    {radius, -radius},   -- NE corner  
    {-radius, radius},   -- SW corner
    {radius, radius}     -- SE corner
}
```

This ensures relic movement to corners works correctly.

### Rate Limiting

Server rate-limits client commands (2 second cooldown) to prevent spam.

**Exempt commands:**
- `ChunksReady` - Part of enter flow
- `RequestModData` - Connection initialization

### Property Repair

PZ map save doesn't preserve all `IsoThumpable` properties. Client calls `RepairRefugeProperties()` after:
- `GenerationComplete` received
- Reconnecting while in refuge

This re-applies `isThumpable=false`, `isHoppable=false`, etc.

### Zombie Sync

Server clears zombies and sends IDs to client for synchronized removal:

```lua
sendServerCommand(player, namespace, "ClearZombies", {
    zombieIDs = zombieOnlineIDs
})
```

Client receives IDs and removes matching zombies locally.

---

## File Structure

| File | Role |
|------|------|
| `SpatialRefugeServer.lua` | Server command handlers, generation orchestration, death handling |
| `SpatialRefugeTeleport.lua` | Client teleport logic, server command responses |
| `SpatialRefugeShared.lua` | Shared generation functions (walls, relic, zombie clearing) |
| `SpatialRefugeData.lua` | ModData management (refuge coords, return positions) |
| `SpatialRefugeValidation.lua` | Shared validation logic (player state, cooldowns, input sanitization) |
| `SpatialRefugeTransaction.lua` | Client-side transaction system for item consumption |
| `SpatialRefugeConfig.lua` | Configuration, command constants |

---

## ModData Structure

### Global ModData (`MySpatialRefuge`)

```lua
{
    Refuges = {
        ["username"] = {
            refugeId = "refuge_username",
            username = "username",
            centerX = 1000,
            centerY = 1000,
            centerZ = 0,
            tier = 0,
            radius = 1,
            relicX = 1000,
            relicY = 1000,
            relicZ = 0,
            createdTime = 1234567890,
            lastExpanded = 1234567890
        }
    },
    ReturnPositions = {
        ["username"] = { x = 10500, y = 9500, z = 0 }
    }
}
```

### Object ModData Flags

| Flag | Object | Purpose |
|------|--------|---------|
| `isSacredRelic` | Relic | Context menu detection |
| `isRefugeBoundary` | Walls | Protection hooks |
| `isProtectedRefugeObject` | Both | Sledgehammer protection |
| `refugeId` | Relic | Links relic to player's refuge |
| `refugeBoundarySprite` | Walls | Duplicate prevention |
| `assignedCorner` | Relic | Corner name for repositioning |
| `assignedCornerDx/Dy` | Relic | Corner offset for repositioning |

These flags must be transmitted via `transmitModData()` for clients to see them.

---

## Singleplayer Path

In singleplayer, the client handles everything locally:

```lua
local function isMultiplayerClient()
    return isClient() and not isServer()
end

if not isMultiplayerClient() then
    -- Singleplayer: direct generation
    doSingleplayerEnter(player, refugeData)
end
```

No network commands needed - client generates structures directly using `SpatialRefugeShared` functions.

---

## Special Cases

### Player Death in Refuge

Server handles death cleanup:
1. Move corpse to return position (original world location)
2. Delete refuge data from ModData
3. Clear return position
4. Clear server-side cooldowns

**Note:** Physical structures (walls, relic) are NOT deleted - they persist in map save.

### Player Reconnect

When player connects:
1. Server transmits ModData after short delay (~0.5s)
2. If player is at refuge coords, client repairs object properties after ModData sync

Stranded player recovery (regeneration on reconnect) is **DISABLED** - structures persist in map save and don't need regeneration.

### Client Disconnect During Operation

Transaction system handles this:
- `OnPlayerDeath` triggers rollback of pending transactions
- Weak table keys clean up transaction storage when player object is garbage collected

---

## Configuration

Command namespace and names are defined in `SpatialRefugeConfig.lua`:

```lua
COMMAND_NAMESPACE = "SpatialRefuge",
COMMANDS = {
    -- Client -> Server
    REQUEST_MODDATA = "RequestModData",
    REQUEST_ENTER = "RequestEnter",
    CHUNKS_READY = "ChunksReady",
    REQUEST_EXIT = "RequestExit",
    REQUEST_UPGRADE = "RequestUpgrade",
    REQUEST_MOVE_RELIC = "RequestMoveRelic",
    
    -- Server -> Client
    MODDATA_RESPONSE = "ModDataResponse",
    TELEPORT_TO = "TeleportTo",
    GENERATION_COMPLETE = "GenerationComplete",
    EXIT_READY = "ExitReady",
    UPGRADE_COMPLETE = "UpgradeComplete",
    MOVE_RELIC_COMPLETE = "MoveRelicComplete",
    CLEAR_ZOMBIES = "ClearZombies",
    ERROR = "Error"
}
```

---

*Last Updated: December 2024*
