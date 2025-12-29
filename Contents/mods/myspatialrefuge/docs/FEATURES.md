# My Spatial Refuge - Features

A personal pocket dimension mod for Project Zomboid. Escape the apocalypse to a safe, upgradeable refuge space.

## Overview

Players can teleport to a personal "Spatial Refuge" - a small outdoor sanctuary generated at the edge of the world map. The refuge can be upgraded by collecting Strange Zombie Cores from zombies.

**Requires:** MySpatialCore (provides Strange Zombie Core item and drop mechanics)

---

## Core Features

### 1. Personal Refuge Space

Each player gets their own isolated refuge:
- Located at map edge (coordinates ~1000,1000) - far from any game content
- Multiple players have separate refuges spaced 50 tiles apart
- Persists across game sessions via ModData and map save
- Walls and Sacred Relic are server-authoritative objects that persist in the map save

### 2. Teleportation System

**Entry:**
- Hold `Q` (social/emote radial) and choose **Enter Spatial Refuge**
- 3-second cast time (interruptible)
- 10-second cooldown between teleports
- Blocked for 10 seconds after taking damage
- Cannot teleport while: in vehicle, climbing, falling, or over-encumbered

**Exit:**
- Hold `Q` while inside refuge and choose **Exit Spatial Refuge** (or use Sacred Relic context menu)
- Teleports back to original entry location
- Same 10-second cooldown applies

### 3. Tier Progression System

Refuge starts at 3x3 and expands up to 15x15 through upgrades:

| Tier | Size | Cores Required | Total Cores |
|------|------|----------------|-------------|
| 0 | 3x3 | 0 (initial) | 0 |
| 1 | 5x5 | 5 | 5 |
| 2 | 7x7 | 10 | 15 |
| 3 | 9x9 | 20 | 35 |
| 4 | 11x11 | 35 | 70 |
| 5 | 13x13 | 50 | 120 |
| 6 | 15x15 | 75 | 195 |

### 4. Sacred Relic

Central object in the refuge:
- Angel gravestone statue (cemetery tileset)
- Provides context menu for Exit and Upgrade
- Has 20-unit storage container
- Can be moved to different corners (30s cooldown)
- Completely indestructible
- Position is saved in ModData and persists across sessions

### 5. Boundary Walls

Solid walls surround the refuge:
- Exterior house wall tileset
- Automatically expand when tier increases
- Completely indestructible (immune to sledgehammer)
- Block zombie pathfinding
- Natural terrain (grass/dirt) remains inside - no floor tiles generated

### 6. Zombie Clearing

When entering the refuge:
- All zombies within refuge area + 3 tiles are removed
- Zombie corpses are also cleared
- In multiplayer, zombie removal is synchronized to clients
- Optimized: skips clearing in remote areas (coords < 2000) unless forced

---

## Player Experience

### First Time Use
1. Kill zombies to collect Strange Zombie Cores (30% drop rate)
2. Hold `Q` and select **Enter Spatial Refuge** to teleport to your new refuge
3. A small 3x3 area with the Sacred Relic is generated with natural terrain

### Upgrading
1. Collect more cores from zombies
2. Right-click Sacred Relic -> "Upgrade Refuge"
3. Cores are consumed, walls expand, floor area increases
4. Sacred Relic repositions to assigned corner (if previously moved)

### Moving the Sacred Relic
1. Right-click Sacred Relic -> "Move Relic to..."
2. Choose a corner: Up, Down, Left, Right, or Center
3. 30-second cooldown between moves
4. After upgrade, relic automatically moves to maintain its corner assignment

### Daily Use
- Store items in Sacred Relic container (20 capacity)
- Use as safe logout location
- Return to exact exit point when leaving

---

## Multiplayer Support

### Server-Authoritative Design
- Server manages all refuge data (coordinates, tier, return positions)
- Server generates walls and relic (persists in map save)
- Server validates cooldowns (prevents client manipulation)
- Transaction system prevents item duplication/loss during upgrades

### Data Synchronization
- ModData is transmitted to clients on connect
- Walls/relic use `transmitAddObjectToSquare` for instant client sync
- Zombie clearing is synchronized via online IDs
- Upgrade transactions use commit/rollback pattern

### Death in Refuge
- Corpse is moved to original world location (where you entered)
- Refuge data is cleared from ModData
- Physical structures remain (can be cleaned by admin if needed)

---

## Configuration

All settings in `media/lua/shared/SpatialRefugeConfig.lua`:

```lua
-- Coordinates
REFUGE_BASE_X = 1000      -- World X position
REFUGE_BASE_Y = 1000      -- World Y position
REFUGE_SPACING = 50       -- Tiles between player refuges

-- Timers
TELEPORT_COOLDOWN = 10     -- Seconds between teleports
COMBAT_TELEPORT_BLOCK = 10 -- Block after taking damage
TELEPORT_CAST_TIME = 3     -- Cast duration

-- Sacred Relic
RELIC_STORAGE_CAPACITY = 20
RELIC_MOVE_COOLDOWN = 30

-- Sprites (tilesets)
FLOOR = "blends_natural_01_16"
WALL_WEST = "walls_exterior_house_01_0"
WALL_NORTH = "walls_exterior_house_01_1"
SACRED_RELIC = "location_community_cemetary_01_11"
```

---

## File Structure

```
media/lua/
├── client/refuge/
│   ├── SpatialRefugeMain.lua        # Entry point, client data access
│   ├── SpatialRefugeUI.lua          # Cast bar UI
│   ├── SpatialRefugeTeleport.lua    # Teleport logic, server response handlers
│   ├── SpatialRefugeGeneration.lua  # Client-side generation (SP only)
│   ├── SpatialRefugeContext.lua     # Context menu, protection hooks
│   ├── SpatialRefugeRadialMenu.lua  # Social (Q) radial integration
│   ├── SpatialRefugeCast.lua        # Timed actions setup
│   ├── SpatialRefugeBoundary.lua    # Boundary detection
│   ├── SpatialRefugeUpgrade.lua     # Upgrade transaction handling
│   ├── SpatialRefugeDeath.lua       # Death handling
│   ├── ISEnterRefugeAction.lua      # Enter action handler
│   └── ISExitRefugeAction.lua       # Exit action handler
├── server/refuge/
│   └── SpatialRefugeServer.lua      # Server command handlers, generation
└── shared/
    ├── SpatialRefugeConfig.lua      # Configuration, constants
    ├── SpatialRefugeData.lua        # ModData management
    ├── SpatialRefugeShared.lua      # Shared generation (walls, relic, zombies)
    ├── SpatialRefugeValidation.lua  # Shared validation logic
    └── SpatialRefugeTransaction.lua # Transaction system for upgrades
```

---

## Technical Notes

### Persistence
- Walls and Sacred Relic are `IsoThumpable` objects created by server
- They persist in the server's map save file
- No regeneration needed on server restart
- ModData stores refuge metadata (coordinates, tier, relic position)

### Natural Terrain
- Floor tiles are NOT generated
- Natural grass/dirt terrain remains
- Walls are added to existing squares after chunks load

### Protection Layers
1. Object properties (`isThumpable=false`, `health=999999`)
2. ModData flags (`isProtectedRefugeObject`)
3. Action hooks (block destroy/disassemble)
4. Property repair on enter (re-apply protection after map load)

---

## Known Limitations

- **Corner sprites:** Only NW and SE corner overlays exist in the wall tileset.
- **Chunk loading:** Generation waits for chunks to load, which can take a moment (~0.5-5 seconds).
- **Menu options:** "Disassemble" option still appears but action is blocked.
- **Container persistence:** Items in Sacred Relic container should persist, but backup important items.

---

*Last Updated: December 2024*
