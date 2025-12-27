# MySpatialRefuge - Implementation TODO

> **Generated from GitHub Issues** - Repository: nuclearthinking/myspatialrefuge  
> **Last Updated:** December 27, 2025

This document organizes all open GitHub issues into a logical implementation order based on dependencies, priority, and difficulty.

---

## 📊 Implementation Overview

| Phase | Issues | Est. Time | Focus Area |
|-------|--------|-----------|------------|
| Phase 1 | 2 issues | 2-3 hours | Quick wins & foundations |
| Phase 2 | 2 issues | 35-50 hours | Core progression systems |
| Phase 3 | 2 issues | 50-70 hours | Talent tree & effects |
| Phase 4 | 2 issues | 30-45 hours | Utility features |
| Phase 5 | 2 issues | 55-80 hours | Advanced systems |
| **Total** | **10 issues** | **172-248 hours** | |

---

## Phase 1: Foundation & Quick Fixes

These are quick wins that improve immediate UX and set up visual foundations.

### ✅ Issue #1: Fix Encumbered Teleport Error Message ✅ COMPLETED
- **GitHub:** [#1](https://github.com/nuclearthinking/myspatialrefuge/issues/1)
- **Priority:** 🔥 High
- **Difficulty:** ⭐ Very Easy
- **Time Estimate:** 30 minutes
- **Value:** ⭐⭐ Low-Medium
- **Status:** ✅ **COMPLETED** - December 27, 2025

**Problem:** Encumbered players see 'in combat' message instead of proper encumbrance warning.

**Implementation (COMPLETED):**
- ✅ Added encumbrance check in `SpatialRefugeTeleport.lua` (line 30-33)
- ✅ Check occurs before cooldown and combat checks
- ✅ Displays clear error message: "Cannot teleport while encumbered"

**Files modified:**
- `media/lua/client/refuge/SpatialRefugeTeleport.lua`

---

### ✅ Issue #2: Replace Sacred Relic Sprite
- **GitHub:** [#2](https://github.com/nuclearthinking/myspatialrefuge/issues/2)
- **Priority:** 🔥 High
- **Difficulty:** ⭐ Very Easy
- **Time Estimate:** 1-2 hours
- **Value:** ⭐⭐⭐ Medium

**Current State:** Using angel gravestone (`location_community_cemetary_01_11`)

**Implementation:**
- Create or source mystical portal/dimensional anchor sprite
- Update `SPRITES.SACRED_RELIC` in `SpatialRefugeConfig.lua`
- Test rendering and hitbox compatibility
- Ensure existing ModData compatibility

**Optional Enhancement:** Tier-based sprite evolution

**Files to modify:**
- `media/lua/shared/SpatialRefugeConfig.lua`

---

## Phase 2: Core Progression Systems

Foundation for long-term engagement. XP/leveling must come before talents.

### ✅ Issue #4: XP and Leveling System
- **GitHub:** [#4](https://github.com/nuclearthinking/myspatialrefuge/issues/4)
- **Priority:** 🔥🔥 Very High
- **Difficulty:** ⭐⭐⭐ Moderate
- **Time Estimate:** 15-20 hours
- **Value:** ⭐⭐⭐⭐⭐ Very High

**Description:** Separate XP/leveling system independent of tier upgrades. Foundation for talent trees.

**Data Structure:**
```lua
refugeData = {
    tier = 3,           -- Existing tier (size)
    level = 25,         -- NEW: Refuge level
    xp = 15420,         -- NEW: Current XP
    xpToNext = 20000,   -- NEW: XP required for next level
    talentPoints = 8    -- NEW: Unspent talent points
}
```

**XP Curve:**
- Level 1-10: 1000 XP per level (linear)
- Level 11-30: 1000 + (level-10) × 100
- Level 31-50: Exponential (1.15× multiplier)
- Level 51+: Diminishing (1.05× multiplier)

**Features:**
- Award 1 talent point per level
- Bonus points at milestones (10, 25, 50, 100)
- XP bar in UI or context menu
- Level cap: 100 or unlimited

**Files to create/modify:**
- NEW: `media/lua/client/refuge/SpatialRefugeProgression.lua`
- Extend: `media/lua/client/refuge/SpatialRefugeMain.lua`
- Update: `media/lua/client/refuge/SpatialRefugeUpgrade.lua`

**Dependencies:** Foundation for Issue #5 (Talent Tree)

---

### ✅ Issue #3: Multi-Material Consumption System
- **GitHub:** [#3](https://github.com/nuclearthinking/myspatialrefuge/issues/3)
- **Priority:** 🔥🔥 Very High
- **Difficulty:** ⭐⭐⭐ Moderate
- **Time Estimate:** 20-30 hours
- **Value:** ⭐⭐⭐⭐ High

**Description:** Consume various items beyond zombie cores for XP/progression.

**Item Categories:**

| Category | Examples | XP Value |
|----------|----------|----------|
| Physical Matter | Plank (5), ScrapMetal (8) | Low |
| Metaphysical | Photo (50), TeddyBear (40), Book (30) | Medium |
| Rare Materials | Necklace (100), Ring (80) | High |

**Implementation:**
- Create consumption logic and item value mapping
- Add "Consume Items" to Sacred Relic context menu
- UI for showing XP gain
- Balance to prevent exploitation (diminishing returns?)
- Multiplayer synchronization

**Files to create/modify:**
- NEW: `media/lua/client/refuge/SpatialRefugeConsumption.lua`
- Update: `media/lua/client/refuge/SpatialRefugeContext.lua`

**Dependencies:** Works with Issue #4 (XP System)

---

## Phase 3: Talent System & Initial Talents

Core feature that unlocks all future talent-based upgrades.

### ✅ Issue #5: Talent Tree System
- **GitHub:** [#5](https://github.com/nuclearthinking/myspatialrefuge/issues/5)
- **Priority:** 🔥🔥🔥 Critical
- **Difficulty:** ⭐⭐⭐⭐ Hard
- **Time Estimate:** 40-60 hours
- **Value:** ⭐⭐⭐⭐⭐ Very High

**Description:** Comprehensive talent tree for refuge customization and progression.

**Talent Branches:**

**A. Growth Enhancement**
- Accelerated Growth I-III: +25%/+50%/+100% crop growth
- Eternal Harvest: Crops never wilt
- Abundant Yield: +1/+2/+3 items per harvest

**B. Restoration**
- Sanctuary I-III: +0.01/+0.02/+0.05 HP regen per minute
- Mental Clarity: Faster stress/panic reduction
- Restful Sleep: Better sleep quality

**C. Utility**
- Spatial Efficiency: +50 storage capacity
- Quick Access: -1s/-2s teleport cast time
- Dimensional Anchor: Multiple exit points

**D. Self-Sufficiency**
- Ethereal Power I-III: Virtual electricity system
- Dimensional Wellspring: Water generation
- Climate Control: Temperature regulation

**Implementation Phases:**

**Phase 3A: Backend (30-40 hours)**
- Talent data structure in ModData
- Effect application hooks
- Hook farming growth for crop talents
- Hook health/moodle for restoration talents
- Hook container capacity for storage talents
- Performance optimization & caching

**Phase 3B: UI (20-30 hours)**
- Context menu: "Manage Talents" on Sacred Relic
- OR custom ISPanel-based talent tree (advanced)
- Display available talent points
- Preview talent effects
- Lock/unlock mechanics

**Files to create/modify:**
- NEW: `media/lua/client/refuge/SpatialRefugeTalents.lua`
- NEW: `media/lua/client/refuge/SpatialRefugeTalentsUI.lua` (optional)
- Extend: `media/lua/client/refuge/SpatialRefugeContext.lua`

**Dependencies:** 
- REQUIRES Issue #4 (XP & Leveling)
- Integrates with Issue #3 (Multi-Material Consumption)

---

### ✅ Issue #9: Healing and Restoration Buffs
- **GitHub:** [#9](https://github.com/nuclearthinking/myspatialrefuge/issues/9)
- **Priority:** 🔥 Medium
- **Difficulty:** ⭐⭐ Easy
- **Time Estimate:** 10 hours
- **Value:** ⭐⭐⭐⭐ High

**Description:** Passive healing and restoration when in refuge.

**Talent Implementation:**

| Talent | Cost | Effect |
|--------|------|--------|
| Sanctuary I | 1 pt | +0.01 HP/min |
| Sanctuary II | 1 pt | +0.02 HP/min (total: 0.03) |
| Sanctuary III | 2 pts | +0.05 HP/min (total: 0.08) |
| Mental Clarity | 1 pt | -50% stress/panic faster |
| Restful Sleep | 1 pt | -25% sleep need |

**Technical Implementation:**
```lua
-- Hook: Events.EveryTenMinutes
-- Check if player in refuge
-- Apply restoration effects based on talents
-- Don't heal if in combat
```

**Features:**
- Subtle "Sanctuary" moodle visual feedback
- Multiplayer-safe talent checks
- Performance optimized (every 10 min check)

**Files to modify:**
- Integrate with `media/lua/client/refuge/SpatialRefugeTalents.lua`

**Dependencies:** REQUIRES Issue #5 (Talent Tree)

---

## Phase 4: Utility Features

Quality-of-life features that enhance refuge functionality.

### ✅ Issue #10: Spatial Storage Nodes
- **GitHub:** [#10](https://github.com/nuclearthinking/myspatialrefuge/issues/10)
- **Priority:** 🔥 Medium
- **Difficulty:** ⭐⭐ Easy
- **Time Estimate:** 5-10 hours
- **Value:** ⭐⭐⭐⭐ High

**Description:** Craftable storage containers with massive capacity.

**Storage Tiers:**

| Tier | Capacity | Unlock Method |
|------|----------|---------------|
| Basic | 100 slots | Craftable (10 cores + materials) |
| Enhanced | 250 slots | Talent: "Expanded Storage" |
| Master | 500 slots | Talent: "Master Storage" |

**Talent Bonuses:**
- Spatial Efficiency I-III: +50/+100/+200 capacity to all nodes

**Features:**
- Indestructible (like Sacred Relic)
- Moveable within refuge
- Retains contents when moved
- Optional: Limit max nodes per refuge (5?)

**Crafting Recipe:**
```
Recipe: Spatial Storage Node
- Strange Zombie Core x10
- Plank x20
- Scrap Metal x10
- Nails x20
Time: 300 ticks
```

**Files to create/modify:**
- NEW: `media/lua/client/refuge/SpatialRefugeStorage.lua`
- NEW: `media/scripts/recipes_SpatialRefuge.txt`
- Update: `media/lua/client/refuge/SpatialRefugeContext.lua`
- Integrate: `media/lua/client/refuge/SpatialRefugeTalents.lua`

---

### ✅ Issue #7: Spatial Water Storage with Rain Collection
- **GitHub:** [#7](https://github.com/nuclearthinking/myspatialrefuge/issues/7)
- **Priority:** 🔥🔥 High
- **Difficulty:** ⭐⭐⭐⭐ Hard
- **Time Estimate:** 25-35 hours
- **Value:** ⭐⭐⭐⭐⭐ Very High

**Description:** Magical water container with huge capacity and rain collection.

**Features:**
- **Capacity:** 10,000 units (vs normal barrel ~400)
- **Rain Collection:** 10 units/hour automatically
- **Manual Fill:** Compatible with any water source
- **Sink Connection:** Virtual plumbing to refuge sinks

**Implementation Phases:**

**Phase 4A: Water Vessel Object (15 hours)**
- Custom IsoThumpable with container
- Water storage in ModData
- Craftable or talent-unlocked
- Placeable anywhere in refuge

**Phase 4B: Rain Collection (5 hours)**
```lua
-- Hook: Events.EveryOneMinute
-- Check ClimateManager for rain
-- Add water to all vessels in refuge
```

**Phase 4C: Sink Connection (10-15 hours)**
```lua
-- Hook: Events.OnFillContainer
-- Override sink water checks in refuge
-- Draw from nearest water vessel
-- Deduct from vessel ModData
```

**Files to create/modify:**
- NEW: `media/lua/client/refuge/SpatialRefugeWaterVessel.lua`
- Update: `media/lua/client/refuge/SpatialRefugeGeneration.lua`

**Balance Considerations:**
- How to obtain? (Craftable vs talent)
- Limit one or multiple per refuge?
- Rain collection rate balance

---

## Phase 5: Advanced Systems

Complex systems that require most other features to be in place.

### ✅ Issue #8: Crop Growth Acceleration System
- **GitHub:** [#8](https://github.com/nuclearthinking/myspatialrefuge/issues/8)
- **Priority:** 🔥🔥 High
- **Difficulty:** ⭐⭐⭐ Moderate
- **Time Estimate:** 15-20 hours
- **Value:** ⭐⭐⭐⭐ High

**Description:** Faster crop growth in refuge via talents.

**Talent Tiers:**

| Talent | Cost | Effect | Total Multiplier |
|--------|------|--------|------------------|
| Accelerated Growth I | 1 pt | +25% | 1.25× |
| Accelerated Growth II | 1 pt | +50% | 1.75× |
| Accelerated Growth III | 2 pts | +100% | 2.75× |
| Eternal Harvest | 3 pts | Never wilt | - |
| Abundant Yield I-III | 2 pts each | +1/+2/+3 per harvest | - |

**Technical Implementation:**
```lua
-- Hook: SFarmingSystem.updateCrop
local originalUpdateCrop = SFarmingSystem.updateCrop
SFarmingSystem.updateCrop = function(plant, ...)
    if SpatialRefuge.IsSquareInAnyRefuge(square) then
        local refugeData = SpatialRefuge.GetRefugeDataForSquare(square)
        local multiplier = CalculateGrowthMultiplier(refugeData.talents)
        -- Apply bonus growth
    end
end
```

**Helper Functions Needed:**
- `SpatialRefuge.IsSquareInAnyRefuge(square)`
- `SpatialRefuge.GetRefugeDataForSquare(square)`

**Files to modify:**
- Integrate with `media/lua/client/refuge/SpatialRefugeTalents.lua`
- NEW: Helper functions in `SpatialRefugeMain.lua`

**Dependencies:** REQUIRES Issue #5 (Talent Tree)

---

### ✅ Issue #6: Electricity System - Core-Powered Virtual Grid
- **GitHub:** [#6](https://github.com/nuclearthinking/myspatialrefuge/issues/6)
- **Priority:** 🔥🔥🔥 Critical
- **Difficulty:** ⭐⭐⭐⭐⭐ Very Hard
- **Time Estimate:** 40-60 hours
- **Value:** ⭐⭐⭐⭐⭐ Very High

**Description:** Consume zombie cores to power refuge appliances.

**Implementation Approach:**

**Option A: Virtual Electricity (Recommended)**
```lua
refugeData.virtualPower = true
refugeData.powerCoreReserve = 50  -- Each core = 1 hour

-- Override appliance power requirement checks in refuge
```

**Pros:** Easier, no map conflicts, multiplayer-safe  
**Cons:** Workaround, not "true" electricity

**Option B: True Electricity (Advanced)**
Modify GridSquare `haveElectricity` property.

**Pros:** Authentic integration  
**Cons:** Complex, potential conflicts, harder to debug

**Consumption Rate:**
- 1 core = 1-2 hours constant power
- Passive drain (appliances off): Minimal
- Active drain (appliances on): Higher

**Features:**
- Consume cores from Sacred Relic or inventory
- UI showing remaining power time
- Low power warning
- Talent unlocks: "Ethereal Power I-III"

**Files to create/modify:**
- NEW: `media/lua/client/refuge/SpatialRefugePower.lua`
- Integrate: `media/lua/client/refuge/SpatialRefugeTalents.lua`
- Hook: Appliance activation events

**Dependencies:** REQUIRES Issue #5 (Talent Tree)

---

## 📋 Implementation Checklist

### Phase 1: Foundation (2-3 hours)
- [x] #1: Fix encumbered teleport message ✅
- [ ] #2: Replace Sacred Relic sprite

### Phase 2: Progression (35-50 hours)
- [ ] #4: XP and Leveling System
- [ ] #3: Multi-Material Consumption

### Phase 3: Talents (50-70 hours)
- [ ] #5: Talent Tree System (Backend + UI)
- [ ] #9: Healing & Restoration Buffs

### Phase 4: Utility (30-45 hours)
- [ ] #10: Spatial Storage Nodes
- [ ] #7: Water Storage with Rain Collection

### Phase 5: Advanced (55-80 hours)
- [ ] #8: Crop Growth Acceleration
- [ ] #6: Electricity System

---

## 🎯 Quick Reference

**Immediate Priorities:**
1. Issue #1 (30 min) - Bug fix
2. Issue #2 (1-2 hours) - Visual improvement
3. Issue #4 (15-20 hours) - XP foundation
4. Issue #3 (20-30 hours) - Consumption system
5. Issue #5 (40-60 hours) - Talent tree (CRITICAL PATH)

**High Value, Lower Effort:**
- Issue #9: Healing buffs (10 hours)
- Issue #10: Storage nodes (5-10 hours)

**Most Complex:**
- Issue #5: Talent tree (40-60 hours)
- Issue #6: Electricity (40-60 hours)

**Dependencies:**
- Issues #8, #9 depend on #5 (Talent Tree)
- Issue #5 depends on #4 (XP System)
- Issue #3 works with #4

---

## 📝 Notes

- **Total Estimated Work:** 172-248 hours (4-6 months solo)
- **Critical Path:** Issues #4 → #5 → (enables #8, #9, #6)
- **Quick Wins:** Issues #1, #2, #10
- **Multiplayer:** All systems must handle multiplayer sync
- **Performance:** Cache lookups, optimize hooks
- **Balance:** Extensive testing needed for XP curves and talent effects

---

*Generated from GitHub CLI on December 27, 2025*

