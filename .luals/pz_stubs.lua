---@meta
-- PZ API stubs missing from Umbrella
-- Reference: zombie/Lua/LuaManager.java (decompiled source)

-- Standard Lua (may be shadowed by Umbrella)
---@param modname string
---@return any
function require(modname) end

-- Time functions
---Returns current Unix timestamp in seconds
---@return number
function getTimestamp() end

---Returns current Unix timestamp in milliseconds
---@return number
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
---@field DistToProper fun(self: IsoPlayer, other: IsoObject|IsoPlayer): number
---@field getInventory fun(self: IsoPlayer): ItemContainer Get player's inventory container
---@field getCurrentSquare fun(self: IsoPlayer): IsoGridSquare|nil
---@field getVehicle fun(self: IsoPlayer): BaseVehicle|nil
---@field isSeatedInVehicle fun(self: IsoPlayer): boolean
---@field setX fun(self: IsoPlayer, x: number)
---@field setLastX fun(self: IsoPlayer, x: number)
---@field setY fun(self: IsoPlayer, y: number)
---@field setLastY fun(self: IsoPlayer, y: number)
---@field setZ fun(self: IsoPlayer, z: number)
---@field setLastZ fun(self: IsoPlayer, z: number)
IsoPlayer = {}

---@param playerNum? integer
---@return IsoPlayer|nil
function getPlayer(playerNum) end

---@return IsoPlayer|nil
function getSpecificPlayer(playerNum) end

---@return integer
function getNumActivePlayers() end

---@return ArrayList
function getOnlinePlayers() end

-- World access
---@return IsoWorld
function getWorld() end

---@class IsoWorld
---@field getFrameNo fun(self: IsoWorld): integer Get current frame number
---@field getCell fun(self: IsoWorld): IsoCell Get the world cell
---@field isHydroPowerOn fun(self: IsoWorld): boolean Check if hydro power is on
---@field setHydroPowerOn fun(self: IsoWorld, on: boolean)
---@field getMetaGrid fun(self: IsoWorld): IsoMetaGrid
IsoWorld = {}

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
---@field has fun(self: IsoGridSquare, flag: IsoFlagType): boolean
---@field getRoomID fun(self: IsoGridSquare): number
---@field setRoomID fun(self: IsoGridSquare, roomId: number)
---@field setPlayerCutawayFlag fun(self: IsoGridSquare, playerIndex: number, value: number, timestamp: number)
---@field setSquareChanged fun(self: IsoGridSquare)
---@field invalidateRenderChunkLevel fun(self: IsoGridSquare, flags: integer)
---@field AddWorldInventoryItem fun(self: IsoGridSquare, item: InventoryItem|string, xoff: number, yoff: number, zoff: number, transmit?: boolean): InventoryItem|nil
---@field getVehicleContainer fun(self: IsoGridSquare): BaseVehicle|nil
---@field EnsureSurroundNotNull fun(self: IsoGridSquare)
---@field RecalcProperties fun(self: IsoGridSquare)
IsoGridSquare = {}

---@param cell IsoCell
---@param slice unknown
---@param x number
---@param y number
---@param z number
---@return IsoGridSquare
function IsoGridSquare.new(cell, slice, x, y, z) end

---@class IsoChunk
IsoChunk = {}

---@class IsoCell
---@field getGridSquare fun(self: IsoCell, x: number, y: number, z: number): IsoGridSquare|nil
---@field getZombieList fun(self: IsoCell): ArrayList Get list of zombies in this cell
---@field ConnectNewSquare fun(self: IsoCell, square: IsoGridSquare, recalc: boolean)
IsoCell = {}

---@return IsoCell
function getCell() end

---@return GameTime
function getGameTime() end

---@return ClimateManager
function getClimateManager() end

---@class IsoMetaGrid
---@field getRoomByID fun(self: IsoMetaGrid, roomId: number): IsoRoom|nil
IsoMetaGrid = {}

---@class IsoRoom
---@field addSquare fun(self: IsoRoom, square: IsoGridSquare)
---@field waterSources ArrayList
---@field lightSwitches ArrayList
IsoRoom = {}

-- Script/Item access
---@param fullType string
---@return Item|nil
function getScriptManager() end

---@param fullType string
---@return InventoryItem|nil
function instanceItem(fullType) end

-- Inventory Item class
---@class InventoryItem
---@field getID fun(self: InventoryItem): integer Get unique item ID
---@field getFullType fun(self: InventoryItem): string Get full item type (e.g., "Base.Axe")
---@field getType fun(self: InventoryItem): string Get item type name
---@field getName fun(self: InventoryItem): string Get display name
---@field getContainer fun(self: InventoryItem): ItemContainer|nil Get container this item is in
---@field getModData fun(self: InventoryItem): table Get mod data table
---@field setName fun(self: InventoryItem, name: string)
InventoryItem = {}

-- Item Container class
---@class ItemContainer
---@field getItems fun(self: ItemContainer): ArrayList Get all items in container
---@field contains fun(self: ItemContainer, item: InventoryItem): boolean Check if container has item
---@field containsID fun(self: ItemContainer, id: integer): boolean Check if container has item by ID
---@field AddItem fun(self: ItemContainer, item: InventoryItem|string): InventoryItem|nil Add item to container
---@field Remove fun(self: ItemContainer, item: InventoryItem) Remove item from container
---@field getItemCount fun(self: ItemContainer): integer Get total item count
---@field getItemsFromCategory fun(self: ItemContainer, category: string): ArrayList
---@field getCountType fun(self: ItemContainer, itemType: string): integer
---@field getItemById fun(self: ItemContainer, itemId: number): InventoryItem|nil
---@field getItemWithIDRecursiv fun(self: ItemContainer, itemId: number): InventoryItem|nil
---@field DoRemoveItem fun(self: ItemContainer, item: InventoryItem)
---@field hasRoomFor fun(self: ItemContainer, character: IsoPlayer, item: InventoryItem): boolean
ItemContainer = {}

---@param container ItemContainer
---@param item InventoryItem
function sendAddItemToContainer(container, item) end

---@param container ItemContainer
---@param item InventoryItem
function sendRemoveItemFromContainer(container, item) end

-- Mod functions
---@return ArrayList
function getActivatedMods() end

---@param modId string
---@return ModInfo|nil
function getModInfoByID(modId) end

---@class ModInfo
---@field getModVersion fun(self: ModInfo): string
---@field getName fun(self: ModInfo): string
---@field getDir fun(self: ModInfo): string
---@field getVersionDir fun(self: ModInfo): string
---@field getCommonDir fun(self: ModInfo): string
ModInfo = {}

---@class BufferedReader
---@field readLine fun(self: BufferedReader): string|nil
---@field close fun(self: BufferedReader)
BufferedReader = {}

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
---@class Core
---@field getScreenWidth fun(self: Core): integer
---@field getScreenHeight fun(self: Core): integer
---@field getOptionFontSize fun(self: Core): integer
---@field getKey fun(self: Core, name: string): integer
---@field getDebug fun(self: Core): boolean
Core = {}

---@return Core
function getCore() end

---@return UIManager
function getUIManager() end

---@return SoundManager
function getSoundManager() end

---@class SoundManager
---@field playUISound fun(self: SoundManager, name: string)
SoundManager = {}

---@return TextManager
function getTextManager() end

---@return integer
function getScreenWidth() end

---@return integer
function getScreenHeight() end

---@return number
function getMouseY() end

---@param button integer
---@return boolean
function isMouseButtonDown(button) end

-- UI Font enum
---@class UIFont
---@field Small any
---@field Medium any
---@field Large any
---@field Title any
---@field Massive any
---@field MainMenu1 any
---@field MainMenu2 any
---@field Handwritten any
---@field Dialogue any
---@field Intro any
---@field NewSmall any
---@field NewMedium any
---@field NewLarge any
---@field Code any
---@field MediumNew any
---@field AutoNormSmall any
---@field AutoNormMedium any
---@field AutoNormLarge any
UIFont = {}

-- TextManager
---@class TextManager
---@field getFontHeight fun(self: TextManager, font: UIFont): integer
---@field MeasureStringX fun(self: TextManager, font: UIFont, text: string): integer
---@field MeasureStringY fun(self: TextManager, font: UIFont, text: string): integer
TextManager = {}

---@class Texture
---@field javaObject unknown
---@field getWidth fun(self: Texture): integer
---@field getHeight fun(self: Texture): integer
Texture = {}

---@class NinePatchTexture
---@field getSharedTexture fun(path: string): NinePatchTexture|nil
---@field render fun(self: NinePatchTexture, x: number, y: number, width: number, height: number, r: number, g: number, b: number, a: number)
NinePatchTexture = {}

-- UI Base Classes
---@class ISUIElement
---@field x number
---@field y number
---@field width number
---@field height number
---@field anchorLeft boolean
---@field anchorRight boolean
---@field anchorTop boolean
---@field anchorBottom boolean
---@field moveWithMouse boolean
---@field resizable boolean
---@field drawFrame boolean
---@field javaObject unknown
---@field backgroundColor table
---@field borderColor table
---@field backgroundColorMouseOver table
---@field addChild fun(self: ISUIElement, child: ISUIElement)
---@field removeChild fun(self: ISUIElement, child: ISUIElement)
---@field setVisible fun(self: ISUIElement, visible: boolean)
---@field setAlwaysOnTop fun(self: ISUIElement, alwaysOnTop: boolean)
---@field isVisible fun(self: ISUIElement): boolean
---@field getX fun(self: ISUIElement): number
---@field getY fun(self: ISUIElement): number
---@field getWidth fun(self: ISUIElement): number
---@field getHeight fun(self: ISUIElement): number
---@field setX fun(self: ISUIElement, x: number)
---@field setY fun(self: ISUIElement, y: number)
---@field setWidth fun(self: ISUIElement, width: number)
---@field setHeight fun(self: ISUIElement, height: number)
---@field bringToTop fun(self: ISUIElement)
---@field initialise fun(self: ISUIElement)
---@field instantiate fun(self: ISUIElement)
---@field addToUIManager fun(self: ISUIElement)
---@field removeFromUIManager fun(self: ISUIElement)
---@field setWantKeyEvents fun(self: ISUIElement, want: boolean)
---@field close fun(self: ISUIElement)
---@field onResize fun(self: ISUIElement)
---@field update fun(self: ISUIElement)
---@field render fun(self: ISUIElement)
---@field prerender fun(self: ISUIElement)
---@field getScreenWidth fun(self: ISUIElement): integer
---@field getScreenHeight fun(self: ISUIElement): integer
---@field getAbsoluteX fun(self: ISUIElement): number
---@field getAbsoluteY fun(self: ISUIElement): number
---@field isMouseOver fun(self: ISUIElement): boolean
---@field drawRect fun(self: ISUIElement, x: number, y: number, w: number, h: number, a: number, r: number, g: number, b: number)
---@field drawRectBorder fun(self: ISUIElement, x: number, y: number, w: number, h: number, a: number, r: number, g: number, b: number)
---@field drawText fun(self: ISUIElement, text: string, x: number, y: number, r: number, g: number, b: number, a: number, font: UIFont)
---@field drawTextRight fun(self: ISUIElement, text: string, x: number, y: number, r: number, g: number, b: number, a: number, font: UIFont)
---@field drawTextCentre fun(self: ISUIElement, text: string, x: number, y: number, r: number, g: number, b: number, a: number, font: UIFont)
---@field drawTexture fun(self: ISUIElement, texture: Texture, x: number, y: number, a: number, r: number, g: number, b: number)
---@field drawTextureScaled fun(self: ISUIElement, texture: Texture, x: number, y: number, w: number, h: number, a: number, r: number, g: number, b: number)
---@field drawTextureScaledAspect fun(self: ISUIElement, texture: Texture, x: number, y: number, w: number, h: number, a: number, r: number, g: number, b: number)
ISUIElement = {}

---@param x number
---@param y number
---@param width number
---@param height number
---@return ISUIElement
function ISUIElement:new(x, y, width, height) end

---@param name string
---@return ISUIElement
function ISUIElement:derive(name) end

---@class ISPanel : ISUIElement
---@field [any] any Allow arbitrary fields for derived classes
ISPanel = {}

---@param x number
---@param y number
---@param width number
---@param height number
---@return ISPanel
function ISPanel:new(x, y, width, height) end

---@param name string
---@return table
function ISPanel:derive(name) end

---@class ISButton : ISUIElement
---@field title string
---@field internal string
---@field onclick function
---@field onClickTarget any
---@field enable boolean
---@field tooltip string
---@field [any] any Allow arbitrary fields
ISButton = {}

---@param x number
---@param y number
---@param width number
---@param height number
---@param title string
---@param target any
---@param onclick function
---@return ISButton
function ISButton:new(x, y, width, height, title, target, onclick) end

---@class ISScrollBar : ISUIElement
---@field [any] any
ISScrollBar = {}

---@param parent ISUIElement
---@param vertical boolean
---@return ISScrollBar
function ISScrollBar:new(parent, vertical) end

---@param name string
---@return table
function ISScrollBar:derive(name) end

---@class ISTextEntryBox : ISUIElement
---@field [any] any
ISTextEntryBox = {}

---@param title string
---@param x number
---@param y number
---@param width number
---@param height number
---@return ISTextEntryBox
function ISTextEntryBox:new(title, x, y, width, height) end

---@class UIElementInstance
---@field setHeight fun(self: UIElementInstance, height: number)
---@field setWidth fun(self: UIElementInstance, width: number)
---@field setAnchorLeft fun(self: UIElementInstance, value: boolean)
---@field setAnchorRight fun(self: UIElementInstance, value: boolean)
---@field setAnchorTop fun(self: UIElementInstance, value: boolean)
---@field setAnchorBottom fun(self: UIElementInstance, value: boolean)
---@field setScrollWithParent fun(self: UIElementInstance, value: boolean)

---@class UIElementStatic
---@field new fun(table: table): UIElementInstance
---@type UIElementStatic
UIElement = {}

---@class ISResizeWidget : ISUIElement
---@field resizeFunction function
---@field [any] any Allow arbitrary fields
ISResizeWidget = {}

---@param x number
---@param y number
---@param width number
---@param height number
---@param target any
---@param ... any
---@return ISResizeWidget
function ISResizeWidget:new(x, y, width, height, target, ...) end

-- Keyboard input
---@class Keyboard
---@field KEY_ESCAPE integer
---@field KEY_RETURN integer
---@field KEY_SPACE integer
---@field KEY_UP integer
---@field KEY_DOWN integer
---@field KEY_LEFT integer
---@field KEY_RIGHT integer
---@field KEY_TAB integer
---@field KEY_LSHIFT integer
---@field KEY_RSHIFT integer
---@field KEY_LCONTROL integer
---@field KEY_RCONTROL integer
Keyboard = {}
Keyboard.KEY_F9 = 0

---@param key integer
---@return boolean
function isKeyDown(key) end

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

---@param num number
---@param decimalPlaces? integer
---@return number
function round(num, decimalPlaces) end

---@generic K, V
---@param value table<K, V>
---@return fun(table<K, V>, K?): K?, V?, table<K, V>
---@return table<K, V>
---@return nil
function xpairs(value) end

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
---@field getID fun(self: IsoSprite): integer
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

---@param key string
---@param fallback string
---@return string
function getTextOrDefault(key, fallback) end

-- Logging
---@param ... any
function print(...) end

---Log message to specific debug channel (calls debugln internally)
---@param debugType DebugType Debug channel to log to
---@param message string Message to log
function log(debugType, message) end

---Write to a named log file in Lua cache directory
---@param loggerName string Name of the log file (e.g., "MySpatialRefuge")
---@param text string Text to write
function writeLog(loggerName, text) end

-- Debug Type enum (debug channels)
---@class DebugType
---@field Mod DebugType Mod logging channel
---@field General DebugType General logging channel
---@field Lua DebugType Lua logging channel
---@field Script DebugType Script logging channel
---@field Network DebugType Network logging channel
---@field Multiplayer DebugType Multiplayer logging channel
---@field Vehicle DebugType Vehicle logging channel
---@field Zombie DebugType Zombie logging channel
---@field Sound DebugType Sound logging channel
---@field Animation DebugType Animation logging channel
---@field Combat DebugType Combat logging channel
---@field Foraging DebugType Foraging logging channel
---@field Recipe DebugType Recipe logging channel
---@field Radio DebugType Radio logging channel
---@field MapLoading DebugType Map loading channel
---@field Objects DebugType Objects logging channel
---@field Clothing DebugType Clothing logging channel
---@field Fireplace DebugType Fireplace logging channel
---@field Input DebugType Input logging channel
---@field FileIO DebugType File I/O logging channel
---@field Death DebugType Death logging channel
---@field Damage DebugType Damage logging channel
---@field ActionSystem DebugType Action system logging channel
---@field IsoRegion DebugType IsoRegion logging channel
---@field Asset DebugType Asset logging channel
---@field Shader DebugType Shader logging channel
---@field Sprite DebugType Sprite logging channel
---@field Statistic DebugType Statistic logging channel
---@field Voice DebugType Voice logging channel
---@field Animal DebugType Animal logging channel
---@field Entity DebugType Entity logging channel
---@field Saving DebugType Saving logging channel
---@field Zone DebugType Zone logging channel
---@field WorldGen DebugType World generation channel
---@field Fluid DebugType Fluid logging channel
---@field Energy DebugType Energy logging channel
---@field Physics DebugType Physics logging channel
DebugType = {}

---@class IsoFlagType
---@field solid IsoFlagType
---@field solidtrans IsoFlagType
---@field solidfloor IsoFlagType
IsoFlagType = {}

-- Log Severity enum
---@class LogSeverity
---@field Trace LogSeverity Most verbose
---@field Noise LogSeverity Very verbose  
---@field Debug LogSeverity Debug info
---@field General LogSeverity Normal logging
---@field Warning LogSeverity Warnings
---@field Error LogSeverity Errors
---@field Off LogSeverity Disabled
LogSeverity = {}

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
function LuaEventManager.AddEvent(event) end

---Trigger a custom event registered with LuaEventManager.AddEvent
---@param event string Event name
---@param ... any Arguments to pass to listeners
function triggerEvent(event, ...) end

-- Timed Actions
---@class ISBaseTimedAction
---@field character IsoPlayer
---@field maxTime integer
---@field stopOnWalk boolean
---@field stopOnRun boolean
---@field stopOnAim boolean
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

---@class ISModalRichText : ISUIElement
---@field [any] any
ISModalRichText = {}

---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
---@param yesNo boolean
---@return ISModalRichText
function ISModalRichText:new(x, y, width, height, text, yesNo) end

---@class ISInventoryPage
---@field dirtyUI fun()
ISInventoryPage = {}

---@class ISVehicleMenu
---@field showRadialMenu fun(player: IsoPlayer, ...)
---@field getVehicleToInteractWith fun(player: IsoPlayer): BaseVehicle|nil
ISVehicleMenu = {}

---@class ISInventoryTransferUtil
---@field newInventoryTransferAction fun(player: IsoPlayer, item: InventoryItem, source: ItemContainer, destination: ItemContainer): ISBaseTimedAction
ISInventoryTransferUtil = {}

---@class HaloTextHelperStatic
---@field addText fun(player: IsoPlayer, text: string, separator?: string, color?: HaloTextHelper.ColorRGB)
---@field getColorGreen fun(): HaloTextHelper.ColorRGB
---@type HaloTextHelperStatic
HaloTextHelper = {}

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

---@class ISInventoryTransferAction : ISBaseTimedAction
---@field item InventoryItem
---@field perform fun(self: ISInventoryTransferAction)
ISInventoryTransferAction = {}

---@class ISGrabItemAction : ISBaseTimedAction
---@field item InventoryItem
---@field perform fun(self: ISGrabItemAction)
ISGrabItemAction = {}

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
---@field setSpriteFromName fun(self: IsoObject, spriteName: string)
---@field sendObjectChange fun(self: IsoObject, change: string)
---@field transmitModData fun(self: IsoObject)
IsoObject = {}

---@param cell IsoCell
---@param square IsoGridSquare
---@param spriteName string
---@return IsoObject
function IsoObject.new(cell, square, spriteName) end

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

---@class BaseVehicle
---@field getCurrentSpeedKmHour fun(self: BaseVehicle): number
---@field getCurrentSquare fun(self: BaseVehicle): IsoGridSquare|nil
---@field getId fun(self: BaseVehicle): integer
---@field getSeat fun(self: BaseVehicle, player: IsoPlayer): number
---@field getX fun(self: BaseVehicle): number
---@field getY fun(self: BaseVehicle): number
---@field getZ fun(self: BaseVehicle): number
---@field exit fun(self: BaseVehicle, player: IsoPlayer)
---@field enter fun(self: BaseVehicle, seat: number, player: IsoPlayer): boolean
---@field setCharacterPosition fun(self: BaseVehicle, player: IsoPlayer, seat: number, position: string)
---@field transmitCharacterPosition fun(self: BaseVehicle, seat: number, position: string)
---@field playPassengerAnim fun(self: BaseVehicle, seat: number, animation: string)
BaseVehicle = {}

---@class IsoZombie : IsoGameCharacter
---@field addItemToSpawnAtDeath fun(self: IsoZombie, item: InventoryItem)
IsoZombie = {}

---@class IsoDeadBody : IsoObject
IsoDeadBody = {}

---@class IsoGameCharacter : IsoObject
IsoGameCharacter = {}

---@class Perk
---@field getId fun(self: Perk): string
Perk = {}

---@class PerkFactory
---@field PerkList ArrayList
---@field getPerkFromName fun(name: string): Perk|nil
PerkFactory = {}

---@type table<string, Perk>
Perks = {}

---@param player IsoPlayer
---@param perk Perk
---@param amount number
function addXpNoMultiplier(player, perk, amount) end

---@class ScriptItem
---@field getDisplayName fun(self: ScriptItem): string
---@field getNormalTexture fun(self: ScriptItem): Texture|nil
ScriptItem = {}

---@class ScriptManager
---@field instance ScriptManager
---@field getItem fun(self: ScriptManager, fullType: string): ScriptItem|nil
ScriptManager = {}

---@class UIManager
---@field getMillisSinceLastRender fun(): number
UIManager = {}

---@class LuaUtils
---@field stringStarts fun(value: string, prefix: string): boolean
luautils = {}

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
