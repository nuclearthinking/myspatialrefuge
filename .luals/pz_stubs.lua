---@meta
-- PZ API stubs missing from Umbrella
-- Reference: zombie/Lua/LuaManager.java (decompiled source)

-- Standard Lua (may be shadowed by Umbrella)
---@param modname string
---@return any
function require(modname) end

-- Time functions
---Returns current Unix timestamp in seconds
---@return integer
function getTimestamp() end

---Returns current Unix timestamp in milliseconds
---@return integer
function getTimestampMs() end

-- World/Game state
---@return boolean
function isClient() end

---@return boolean
function isServer() end

---@return boolean
function isCoopHost() end

---@return boolean
function isSinglePlayer() end

---@return boolean
function isDebugEnabled() end

---@return boolean
function isAdmin() end

-- Type checking
---Check if object is instance of a class
---@param obj any Object to check
---@param className string Class name (e.g., "IsoThumpable", "IsoWindow", "IsoDoor")
---@return boolean
function instanceof(obj, className) end

-- Player functions
---@class IsoPlayer
---@field getUsername fun(self: IsoPlayer): string
---@field getPlayerNum fun(self: IsoPlayer): integer
---@field getX fun(self: IsoPlayer): number
---@field getY fun(self: IsoPlayer): number
---@field getZ fun(self: IsoPlayer): number
---@field teleportTo fun(self: IsoPlayer, x: number, y: number, z: number)
---@field Say fun(self: IsoPlayer, text: string)
---@field setDir fun(self: IsoPlayer, dir: integer)
---@field getSquare fun(self: IsoPlayer): IsoGridSquare|nil
---@field getModData fun(self: IsoPlayer): table
---@field isLocalPlayer fun(self: IsoPlayer): boolean
IsoPlayer = {}

---@param playerNum? integer
---@return IsoPlayer|nil
function getPlayer(playerNum) end

---@return IsoPlayer|nil
function getSpecificPlayer(playerNum) end

---@return integer
function getNumActivePlayers() end

-- World access
---@return IsoWorld
function getWorld() end

---@class IsoGridSquare
---@field getChunk fun(self: IsoGridSquare): IsoChunk|nil
---@field getX fun(self: IsoGridSquare): integer
---@field getY fun(self: IsoGridSquare): integer
---@field getZ fun(self: IsoGridSquare): integer
---@field getObjects fun(self: IsoGridSquare): ArrayList
---@field getMovingObjects fun(self: IsoGridSquare): ArrayList Get moving objects (characters, vehicles, etc.) on this square
---@field getTree fun(self: IsoGridSquare): IsoObject|nil Get tree object on this square
---@field getDeadBodys fun(self: IsoGridSquare): ArrayList Get dead bodies on this square
---@field getFloor fun(self: IsoGridSquare): IsoObject|nil
---@field Is fun(self: IsoGridSquare, flag: IsoFlagType): boolean
---@field transmitRemoveItemFromSquare fun(self: IsoGridSquare, item: IsoObject)
---@field transmitAddObjectToSquare fun(self: IsoGridSquare, obj: IsoObject, index: integer) Add object to square and transmit to clients
---@field removeCorpse fun(self: IsoGridSquare, corpse: IsoObject, b: boolean) Remove corpse from square
---@field RecalcAllWithNeighbours fun(self: IsoGridSquare, b: boolean) Recalculate all with neighbours
---@field AddSpecialObject fun(self: IsoGridSquare, obj: IsoObject)
IsoGridSquare = {}

---@class IsoChunk
IsoChunk = {}

---@class IsoCell
---@field getGridSquare fun(self: IsoCell, x: integer, y: integer, z: integer): IsoGridSquare|nil
---@field getZombieList fun(self: IsoCell): ArrayList Get list of zombies in this cell
IsoCell = {}

---@return IsoCell
function getCell() end

---@return GameTime
function getGameTime() end

---@return ClimateManager
function getClimateManager() end

-- Script/Item access
---@param fullType string
---@return Item|nil
function getScriptManager() end

---@param fullType string
---@return InventoryItem|nil
function instanceItem(fullType) end

-- Mod functions
---@return ArrayList
function getActivatedMods() end

---@param modId string
---@return ModInfo|nil
function getModInfoByID(modId) end

---@param modId string
---@param path string
---@param createIfNull boolean
---@return BufferedReader|nil
function getModFileReader(modId, path, createIfNull) end

-- File I/O (Lua cache directory)
---@param filename string
---@param createIfNull boolean
---@return BufferedReader|nil
function getFileReader(filename, createIfNull) end

---@param filename string
---@param createIfNull boolean
---@param append boolean
---@return BufferedWriter|nil
function getFileWriter(filename, createIfNull, append) end

-- UI/Core
---@return Core
function getCore() end

---@return UIManager
function getUIManager() end

---@return SoundManager
function getSoundManager() end

-- Math (PZMath)
---@param a number
---@param b number
---@param t number
---@return number
function lerp(a, b, t) end

---@param value number
---@param min number
---@param max number
---@return number
function clamp(value, min, max) end

-- Texture loading
---@param path string
---@return Texture|nil
function getTexture(path) end

-- Sprite loading
---Get sprite by name. Returns nil if sprite not found.
---@param spriteName string Sprite name/path (e.g., "blends_natural_01_64", "location_01_1")
---@return IsoSprite|nil
function getSprite(spriteName) end

---@class IsoSprite
---@field getName fun(self: IsoSprite): string|nil Get sprite name
---@field newInstance fun(self: IsoSprite): IsoSprite Create a new instance of this sprite
---@field getProperties fun(self: IsoSprite): SpriteProperties Get sprite properties
---@field getSpriteGrid fun(self: IsoSprite): IsoSpriteGrid|nil Get sprite grid if this is a multi-sprite
---@field getParentSprite fun(self: IsoSprite): IsoSprite|nil Get parent sprite
IsoSprite = {}

---@class SpriteProperties
---@field has fun(self: SpriteProperties, flag: IsoFlagType|string): boolean Check if property/flag exists
---@field get fun(self: SpriteProperties, key: string): any Get property value by key
SpriteProperties = {}

---@class IsoSpriteGrid
---@field getAnchorSprite fun(self: IsoSpriteGrid): IsoSprite|nil Get anchor sprite
IsoSpriteGrid = {}

-- Translation
---@param key string
---@return string
function getText(key) end

---@param key string
---@param ... any
---@return string
function getTextOrNull(key, ...) end

-- Logging
---@param ... any
function print(...) end

-- ModData (persistent data storage)
---@class ModData
---@field getOrCreate fun(key: string): table
---@field get fun(key: string): table|nil
---@field transmit fun(key: string)
ModData = {}

-- Sandbox vars (global table)
---@type table<string, table<string, any>>
SandboxVars = {}

-- Events (global table)
---@type table<string, { Add: fun(callback: function), Remove: fun(callback: function) }>
Events = {}

-- LuaEventManager
---@type table
LuaEventManager = {}

---@param event string
---@param callback function
function LuaEventManager.AddEvent(event, callback) end

-- Timed Actions
---@class ISBaseTimedAction
---@field character IsoPlayer
---@field maxTime integer
---@field stopOnWalk boolean
---@field stopOnRun boolean
ISBaseTimedAction = {}

---@param player IsoPlayer
---@return ISBaseTimedAction
function ISBaseTimedAction.new(self, player) end

---@param name string
---@return ISBaseTimedAction
function ISBaseTimedAction:derive(name) end

---@param self ISBaseTimedAction
function ISBaseTimedAction.stop(self) end

---@param self ISBaseTimedAction
function ISBaseTimedAction.perform(self) end

---@param anim string
function ISBaseTimedAction:setActionAnim(anim) end

---@param left string|nil
---@param right string|nil
function ISBaseTimedAction:setOverrideHandModels(left, right) end

---@class ISReadABook : ISBaseTimedAction
---@field character IsoPlayer
---@field item InventoryItem
---@field playerNum integer
---@field minutesPerPage number
---@field maxMultiplier number|nil
---@field startPage integer|nil
---@field pageTimer number|nil
---@field getDuration fun(self: ISReadABook): number Get reading duration in game time units
ISReadABook = {}

---@param character IsoPlayer
---@param item InventoryItem
---@return ISReadABook
function ISReadABook:new(character, item) end

---@class ISTimedActionQueue
ISTimedActionQueue = {}

---@param action ISBaseTimedAction
function ISTimedActionQueue.add(action) end

---@param player IsoPlayer
function ISTimedActionQueue.clear(player) end

---@param player IsoPlayer
---@return boolean
function ISTimedActionQueue.hasAction(player) end

-- Networking (Client -> Server)
---@overload fun(module: string, command: string, args: table)
---@param player IsoPlayer
---@param module string
---@param command string
---@param args table
function sendClientCommand(player, module, command, args) end

-- Networking (Server -> Client)
---@overload fun(module: string, command: string, args: table)
---@param player IsoPlayer
---@param module string
---@param command string
---@param args table
function sendServerCommand(player, module, command, args) end

-- Random
---@param max integer
---@return integer
function ZombRand(max) end

---@return boolean
function getDebug() end

-- Context Menu classes
---@type table
ISWorldObjectContextMenu = {}
---@type table
ISInventoryPaneContextMenu = {}

-- Moveable system
---@type table
ISMoveableSpriteProps = {}
---@type table
ISMoveableDefinitions = {}
---@type table
ISMoveablesAction = {}

-- Actions
---@type table
ISDestroyStuffAction = {}

-- Iso objects
---@type table
IsoThumpable = {}

-- Sound
---@param source IsoObject|IsoPlayer
---@param x integer
---@param y integer
---@param z integer
---@param radius integer
---@param volume integer
function addSound(source, x, y, z, radius, volume) end

-- Radial Menu
---@param playerNum integer
---@return table|nil
function getPlayerRadialMenu(playerNum) end

---@type table
ISEmoteRadialMenu = {}

-- Mod namespace (your mod)
---@type table
MSR = {}

-- IsoObject class (base class for world objects)
---@class IsoObject
---@field getSprite fun(self: IsoObject): IsoSprite|nil Get sprite object
---@field getSpriteName fun(self: IsoObject): string|nil Get sprite name as string
---@field setSprite fun(self: IsoObject, spriteName: string) Set sprite by name
---@field getModData fun(self: IsoObject): table Get mod data table
---@field toppleTree fun(self: IsoObject) Topple tree (if this is a tree object)
IsoObject = {}

-- Object type enum (global table)
---@type table<string, integer>
IsoObjectType = {
    FloorTile = 0,
    wall = 0,
    tree = 0,
    stairsTW = 0,
    stairsMW = 0,
    stairsNW = 0,
    stairsBN = 0,
    curtainN = 0,
    curtainS = 0,
    curtainW = 0,
    curtainE = 0,
    lightswitch = 0,
    doorFrW = 0,
    doorFrN = 0,
}

-- Java ArrayList (used for collections returned from Java)
---@class ArrayList
---@field size fun(self: ArrayList): integer Get number of elements (0-based indexing)
---@field get fun(self: ArrayList, index: integer): any Get element at index (0-based)
---@field isEmpty fun(self: ArrayList): boolean Check if list is empty
---@field indexOf fun(self: ArrayList, obj: any): integer Get index of object, returns -1 if not found
ArrayList = {}

-- Character traits enum (global table)
---@type table<string, integer>
CharacterTrait = {
    ILLITERATE = 0,
    FAST_READER = 0,
    SLOW_READER = 0,
    INSOMNIAC = 0,
    NEEDS_LESS_SLEEP = 0,
    NEEDS_MORE_SLEEP = 0,
    DEXTROUS = 0,
    ALL_THUMBS = 0,
    DESENSITIZED = 0,
    COWARDLY = 0,
    BRAVE = 0,
    HEMOPHOBIC = 0,
}

-- Skill book data (global table)
---@type table<string, { perk: any, maxMultiplier1: number, maxMultiplier2: number, maxMultiplier3: number, maxMultiplier4: number, maxMultiplier5: number }>
SkillBook = {}

-- Item synchronization function
---Synchronize item fields between character and item
---@param character IsoPlayer
---@param item InventoryItem
function syncItemFields(character, item) end
