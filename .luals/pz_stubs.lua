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
---@field getFloor fun(self: IsoGridSquare): IsoObject|nil
---@field Is fun(self: IsoGridSquare, flag: IsoFlagType): boolean
---@field transmitRemoveItemFromSquare fun(self: IsoGridSquare, item: IsoObject)
---@field AddSpecialObject fun(self: IsoGridSquare, obj: IsoObject)
IsoGridSquare = {}

---@class IsoChunk
IsoChunk = {}

---@class IsoCell
---@field getGridSquare fun(self: IsoCell, x: integer, y: integer, z: integer): IsoGridSquare|nil
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
