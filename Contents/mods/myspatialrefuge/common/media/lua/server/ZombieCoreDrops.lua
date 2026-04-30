local ZombieCoreDrops = {}

-- Exposed for other mods
ZombieCoreDrops.ITEM_TYPE = "Base.MagicalCore"
ZombieCoreDrops.DEFAULT_DROP_CHANCE = 30

local dropChance
local alwaysDrop
local initialized = false

local function ensureInitialized()
    if initialized then return end
    initialized = true
    
    local sandboxVars = SandboxVars and SandboxVars.MySpatialCore or {}
    dropChance = sandboxVars.ZombieCoreDropChance or ZombieCoreDrops.DEFAULT_DROP_CHANCE
    
    -- Min 1% ensures cores drop for dependent mods
    if dropChance < 1 then dropChance = 1 end
    if dropChance > 100 then dropChance = 100 end
    
    alwaysDrop = dropChance >= 100
    
    print("[MySpatialCore] Zombie core drop system initialized (drop chance: " .. dropChance .. "%)")
end

---@param zombie IsoZombie
local function onZombieCreate(zombie)
    if not zombie then return end
    ensureInitialized()
    
    if alwaysDrop or ZombRand(100) < dropChance then
        local item = instanceItem(ZombieCoreDrops.ITEM_TYPE)
        if item then
            zombie:addItemToSpawnAtDeath(item)
        end
    end
end

-- Register handler immediately so it catches all zombies from start
-- MP clients: server handles drops
if isServer() or not isClient() then
    Events.OnZombieCreate.Add(onZombieCreate)
end

return ZombieCoreDrops
