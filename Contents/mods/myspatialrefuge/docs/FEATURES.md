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
- Persists across game sessions via ModData

### 2. Teleportation System

**Entry:**
- Hold `Q` (social/emote radial) and choose **Enter Spatial Refuge**
- 3-second cast time (interruptible)
- 10-second cooldown between teleports
- Blocked for 10 seconds after taking damage

**Exit:**
- Hold `Q` while inside refuge and choose **Exit Spatial Refuge** (or use Sacred Relic context menu)
- Teleports back to original entry location

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

### 5. Boundary Walls

Solid walls surround the refuge:
- Exterior house wall tileset
- Automatically expand when tier increases
- Completely indestructible (immune to sledgehammer)
- Block zombie pathfinding

### 6. Zombie Clearing

When entering the refuge:
- All zombies within refuge area + 3 tiles are removed
- Zombie corpses are also cleared
- Prevents unfair zombie spawns inside the refuge

---

## Player Experience

### First Time Use
1. Kill zombies to collect Strange Zombie Cores (30% drop rate)
2. Hold `Q` and select **Enter Spatial Refuge** to teleport to your new refuge
3. A small 3x3 area with the Sacred Relic is generated

### Upgrading
1. Collect more cores from zombies
2. Right-click Sacred Relic -> "Upgrade Refuge"
3. Walls expand, floor area increases
4. Sacred Relic repositions to assigned corner (if moved)

### Daily Use
- Store items in Sacred Relic container (20 capacity)
- Use as safe logout location
- Return to exact exit point when leaving

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
├── client/
│   └── refuge/
│       ├── SpatialRefugeMain.lua        # Entry point, data
│       ├── SpatialRefugeUI.lua          # Cast bar UI
│       ├── SpatialRefugeTeleport.lua    # Teleport logic
│       ├── SpatialRefugeGeneration.lua  # Floor/wall/relic creation
│       ├── SpatialRefugeContext.lua     # Context menu, protection hooks
│       ├── SpatialRefugeRadialMenu.lua  # Social (Q) radial integration
│       ├── SpatialRefugeCast.lua        # Timed actions setup
│       └── ISExitRefugeAction.lua       # Exit action handler
└── shared/
    └── SpatialRefugeConfig.lua          # Configuration
```

---

## Known Limitations

- **Client-side generation:** Walls/floors are created client-side after teleport. Multiplayer sync not fully implemented.
- **Corner sprites:** Only NW and SE corner overlays exist in the wall tileset.
- **Chunk loading:** Generation waits for chunks to load, which can take a moment.

---

*Last Updated: December 2024*



