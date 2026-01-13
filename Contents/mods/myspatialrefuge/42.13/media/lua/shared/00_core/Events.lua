-- MSR_Events - Smart event registration wrapper
-- Handles SP/Coop/Dedicated/Client differences automatically
--
-- LIFECYCLE EVENTS (fire once on startup):
--   MSR.Events.OnServerReady.Add(function() ... end)  -- Server authority only
--   MSR.Events.OnClientReady.Add(function() ... end)  -- Client only (not dedicated)
--   MSR.Events.OnAnyReady.Add(function() ... end)     -- All environments
--
-- CUSTOM EVENTS (local pub/sub):
--   MSR.Events.Custom.Fire("MyEvent", arg1, arg2)       -- Fire locally (all environments)
--   MSR.Events.Custom.FireServer("MyEvent", arg1, arg2) -- Fire only with server authority
--   MSR.Events.Custom.Add("MyEvent", function(arg1, arg2) ... end)
--
-- PRE-REGISTERED CUSTOM EVENTS:
--   MSR_PlayerDeath         - Any player death, args: { username, x, y, z, diedInRefuge, player }
--   MSR_PlayerDiedInRefuge  - Player died inside refuge, args: username
--   MSR_CorpseFound         - Corpse found after death, args: { username, corpse, x, y, z, diedInRefuge, earnedXp }
--   MSR_CorpseProtected     - Corpse marked protected (refuge death), args: { username, corpse }
--   MSR_EssenceCreated      - XP essence was created, args: { username, essence, location }
--
-- SERVER-AUTHORITATIVE PZ EVENTS (client→server bridge):
--   MSR.Events.Server.On("OnPlayerDeath")
--       :withArgs(function(player) return { username = player:getUsername() } end)
--       :onServer(function(player, args, reply) ... end)
--       :register()
--
-- SERVER-AUTHORITATIVE CUSTOM EVENTS:
--   MSR.Events.Server.Register("MyServerEvent", function(player, args, reply) ... end)
--   MSR.Events.Server.Fire("MyServerEvent", { data = 123 })  -- Routes to server
--
-- The wrapper ensures handlers run exactly ONCE in the appropriate environment.
-- Assumes: MSR, L, MSR.Env exist (loaded by 00_MSR.lua)

if MSR.Events and MSR.Events._loaded then
    return MSR.Events
end

MSR.Events = MSR.Events or {}
MSR.Events._loaded = true

local E = MSR.Events
local LOG = L.logger("Events")

local serverReadyHandlers = {}
local clientReadyHandlers = {}
local anyReadyHandlers = {}

local serverReadyFired = false
local clientReadyFired = false
local anyReadyFired = false

-----------------------------------------------------------
-- Lifecycle Events
-----------------------------------------------------------

E.OnServerReady = {} -- SP, Coop host, Dedicated

--- @param fn function
function E.OnServerReady.Add(fn)
    if type(fn) ~= "function" then
        LOG.error("OnServerReady.Add: expected function")
        return
    end
    
    -- Late registration: run immediately if already fired
    if serverReadyFired and MSR.Env.hasServerAuthority() then
        local ok, err = pcall(fn)
        if not ok then
            LOG.error("OnServerReady handler error: %s", tostring(err))
        end
        return
    end
    
    table.insert(serverReadyHandlers, fn)
end

--- @param fn function
function E.OnServerReady.Remove(fn)
    for i = #serverReadyHandlers, 1, -1 do
        if serverReadyHandlers[i] == fn then
            table.remove(serverReadyHandlers, i)
            return true
        end
    end
    return false
end

E.OnClientReady = {} -- SP, Coop host, MP client (NOT dedicated)

--- @param fn function
function E.OnClientReady.Add(fn)
    if type(fn) ~= "function" then
        LOG.error("OnClientReady.Add: expected function")
        return
    end
    
    if clientReadyFired and not MSR.Env.isDedicatedServer() then
        local ok, err = pcall(fn)
        if not ok then
            LOG.error("OnClientReady handler error: %s", tostring(err))
        end
        return
    end
    
    table.insert(clientReadyHandlers, fn)
end

--- @param fn function
function E.OnClientReady.Remove(fn)
    for i = #clientReadyHandlers, 1, -1 do
        if clientReadyHandlers[i] == fn then
            table.remove(clientReadyHandlers, i)
            return true
        end
    end
    return false
end

E.OnAnyReady = {} -- All environments

--- @param fn function
function E.OnAnyReady.Add(fn)
    if type(fn) ~= "function" then
        LOG.error("OnAnyReady.Add: expected function")
        return
    end
    
    if anyReadyFired then
        local ok, err = pcall(fn)
        if not ok then
            LOG.error("OnAnyReady handler error: %s", tostring(err))
        end
        return
    end
    
    table.insert(anyReadyHandlers, fn)
end

--- @param fn function
function E.OnAnyReady.Remove(fn)
    for i = #anyReadyHandlers, 1, -1 do
        if anyReadyHandlers[i] == fn then
            table.remove(anyReadyHandlers, i)
            return true
        end
    end
    return false
end

local function runHandlers(handlers, name)
    for i, fn in ipairs(handlers) do
        local ok, err = pcall(fn)
        if not ok then
            LOG.error("%s handler #%d error: %s", name, i, tostring(err))
        end
    end
end

local function runAnyReadyOnce(source)
    if anyReadyFired then return end
    anyReadyFired = true
    LOG.debug("OnAnyReady firing (%s)", source)
    runHandlers(anyReadyHandlers, "OnAnyReady")
end

-- OnGameStart: SP, MP Client, Coop Host
local function onGameStart()
    -- SP only (Coop gets server authority from OnServerStarted)
    if MSR.Env.isSingleplayer() and not serverReadyFired then
        serverReadyFired = true
        LOG.debug("OnServerReady firing (Singleplayer)")
        runHandlers(serverReadyHandlers, "OnServerReady")
    end
    
    if not MSR.Env.isDedicatedServer() and not clientReadyFired then
        clientReadyFired = true
        LOG.debug("OnClientReady firing")
        runHandlers(clientReadyHandlers, "OnClientReady")
    end
    
    -- Coop waits for OnServerStarted before firing OnAnyReady
    if MSR.Env.isSingleplayer() or not MSR.Env.hasServerAuthority() then
        runAnyReadyOnce(MSR.Env.isSingleplayer() and "Singleplayer" or "MP Client")
    end
end

-- OnServerStarted: Dedicated, Coop Host
local function onServerStarted()
    if not serverReadyFired then
        serverReadyFired = true
        LOG.debug("OnServerReady firing (Server/Coop)")
        runHandlers(serverReadyHandlers, "OnServerReady")
    end
    
    runAnyReadyOnce(MSR.Env.isDedicatedServer() and "Dedicated" or "Coop Host")
end

if Events.OnGameStart then
    Events.OnGameStart.Add(onGameStart)
end

if Events.OnServerStarted then
    Events.OnServerStarted.Add(onServerStarted)
end

-----------------------------------------------------------
-- Custom Events (local pub/sub)
-----------------------------------------------------------
--
-- Pre-registered death-related events:
--   MSR_PlayerDeath         - Any player death (server authority)
--                             Args: { username, x, y, z, diedInRefuge, player }
--   MSR_PlayerDiedInRefuge  - Player died inside refuge area
--                             Args: username
--   MSR_CorpseFound         - Corpse found after any death (for XP essence, etc.)
--   MSR_CorpseProtected     - Corpse was marked as protected (refuge death only)
--                             Args: { username, corpse }
--   MSR_EssenceCreated      - Experience essence was created
--                             Args: { username, essence, location }
-----------------------------------------------------------

E.Custom = {}
local customEventHandlers = {}

--- @param eventName string
function E.Custom.Register(eventName)
    customEventHandlers[eventName] = customEventHandlers[eventName] or {}
    LOG.debug("Registered custom event: %s", eventName)
end

--- @param eventName string
--- @param fn function
function E.Custom.Add(eventName, fn)
    if type(fn) ~= "function" then
        LOG.error("Custom.Add: expected function for %s", tostring(eventName))
        return
    end
    customEventHandlers[eventName] = customEventHandlers[eventName] or {}
    table.insert(customEventHandlers[eventName], fn)
end

--- @param eventName string
--- @param fn function
--- @return boolean
function E.Custom.Remove(eventName, fn)
    local handlers = customEventHandlers[eventName]
    if not handlers then return false end
    for i = #handlers, 1, -1 do
        if handlers[i] == fn then
            table.remove(handlers, i)
            return true
        end
    end
    return false
end

--- Fire custom event locally
--- @param eventName string
--- @param ... any
function E.Custom.Fire(eventName, ...)
    local handlers = customEventHandlers[eventName]
    if not handlers then return end
    LOG.debug("Firing custom event: %s", eventName)
    for i, fn in ipairs(handlers) do
        local ok, err = pcall(fn, ...)
        if not ok then
            LOG.error("%s handler #%d error: %s", eventName, i, tostring(err))
        end
    end
end

--- Fire custom event only if we have server authority (SP/Coop host/Dedicated)
--- Use this to prevent duplicate event firing in MP environments
--- @param eventName string
--- @param ... any
function E.Custom.FireServer(eventName, ...)
    if not MSR.Env.hasServerAuthority() then
        LOG.debug("Skipping %s (no server authority)", eventName)
        return
    end
    E.Custom.Fire(eventName, ...)
end

--- @param eventName string
--- @return number
function E.Custom.GetHandlerCount(eventName)
    local handlers = customEventHandlers[eventName]
    return handlers and #handlers or 0
end

-- Pre-register death events for documentation and initialization
E.Custom.Register("MSR_PlayerDeath")
E.Custom.Register("MSR_PlayerDiedInRefuge")
E.Custom.Register("MSR_CorpseFound")
E.Custom.Register("MSR_CorpseProtected")
E.Custom.Register("MSR_EssenceCreated")

-----------------------------------------------------------
-- Server-Authoritative Events (auto client→server forwarding)
-----------------------------------------------------------

E.Server = {}
local serverEventHandlers = {}   -- eventName -> config
local pendingServerCallbacks = {} -- transactionId -> callback

local SERVER_EVENT_CMD = "MSR_ServerEvent"
local SERVER_EVENT_REPLY_CMD = "MSR_ServerEventReply"

local ServerEventBuilder = {}
ServerEventBuilder.__index = ServerEventBuilder

function ServerEventBuilder:new(eventName)
    local builder = setmetatable({}, ServerEventBuilder)
    builder.eventName = eventName
    builder._argBuilder = nil
    builder._serverHandler = nil
    builder._clientCallback = nil
    builder._filter = nil
    return builder
end

--- @param fn function(player, ...) -> table
function ServerEventBuilder:withArgs(fn)
    self._argBuilder = fn
    return self
end

--- @param fn function(player, args, reply)
function ServerEventBuilder:onServer(fn)
    self._serverHandler = fn
    return self
end

--- Optional: client callback after server handles (MP only)
--- @param fn function(player, response)
function ServerEventBuilder:onClientReply(fn)
    self._clientCallback = fn
    return self
end

--- @param fn function(player, ...) -> boolean
function ServerEventBuilder:filter(fn)
    self._filter = fn
    return self
end

function ServerEventBuilder:register()
    if not self.eventName then
        LOG.error("Server.On: no event name")
        return
    end
    if not self._serverHandler then
        LOG.error("Server.On(%s): no server handler", self.eventName)
        return
    end
    
    serverEventHandlers[self.eventName] = {
        argBuilder = self._argBuilder or function() return {} end,
        serverHandler = self._serverHandler,
        clientCallback = self._clientCallback,
        filter = self._filter
    }
    
    local pzEvent = Events[self.eventName]
    if not pzEvent then
        LOG.warning("Server.On: PZ event not found: %s", self.eventName)
        return
    end
    
    pzEvent.Add(function(...)
        E.Server._handleGameEvent(self.eventName, ...)
    end)
    
    LOG.debug("Registered server-authoritative handler for %s", self.eventName)
    return self
end

--- @param eventName string PZ event name
--- @return ServerEventBuilder
function E.Server.On(eventName)
    return ServerEventBuilder:new(eventName)
end

--- @param eventName string
--- @param handler function(player, args, reply)
function E.Server.Register(eventName, handler)
    serverEventHandlers[eventName] = {
        argBuilder = function(args) return args end,
        serverHandler = handler,
        clientCallback = nil,
        filter = nil
    }
    LOG.debug("Registered custom server event: %s", eventName)
end

--- @param eventName string
--- @param args table
--- @param player IsoPlayer|nil
function E.Server.Fire(eventName, args, player)
    player = player or getPlayer()
    local config = serverEventHandlers[eventName]
    
    if not config or not config.serverHandler then
        LOG.warning("Server.Fire: no handler for %s", tostring(eventName))
        return
    end
    
    E.Server._dispatchToServer(eventName, player, args or {}, config)
end

function E.Server._handleGameEvent(eventName, ...)
    local config = serverEventHandlers[eventName]
    if not config then return end
    
    local args = {...}
    local player = args[1]
    
    if config.filter and not config.filter(unpack(args)) then
        return
    end
    
    local eventArgs = config.argBuilder(unpack(args))
    E.Server._dispatchToServer(eventName, player, eventArgs, config)
end

function E.Server._dispatchToServer(eventName, player, eventArgs, config)
    -- Has server authority: run directly
    if MSR.Env.hasServerAuthority() then
        LOG.debug("Server.%s - running locally", eventName)
        
        local reply = function(response)
            if config.clientCallback and player then
                config.clientCallback(player, response)
            end
        end
        
        local ok, err = pcall(config.serverHandler, player, eventArgs, reply)
        if not ok then
            LOG.error("Server.%s handler error: %s", eventName, tostring(err))
        end
        return
    end
    
    -- MP Client: forward to server
    if MSR.Env.isMultiplayerClient() then
        LOG.debug("Server.%s - forwarding to server", eventName)
        
        local transactionId = nil
        if config.clientCallback then
            transactionId = tostring(K.timeMs()) .. "_" .. eventName
            pendingServerCallbacks[transactionId] = config.clientCallback
        end
        
        -- Debug: log what we're sending
        if eventArgs.earnedXp then
            local count = 0
            for _ in pairs(eventArgs.earnedXp) do count = count + 1 end
            LOG.debug("Sending earnedXp with %d perks", count)
        end
        
        sendClientCommand(MSR.Config.COMMAND_NAMESPACE, SERVER_EVENT_CMD, {
            eventName = eventName,
            args = eventArgs,
            transactionId = transactionId
        })
    end
end

local function onServerEventCommand(module, command, player, cmdArgs)
    if module ~= MSR.Config.COMMAND_NAMESPACE then return end
    
    if command == SERVER_EVENT_CMD then
        local eventName = cmdArgs.eventName
        local args = cmdArgs.args or {}
        local transactionId = cmdArgs.transactionId
        
        -- Debug: check if args came through
        local argsCount = 0
        for k in pairs(args) do argsCount = argsCount + 1 end
        LOG.debug("cmdArgs.args has %d keys", argsCount)
        
        local config = serverEventHandlers[eventName]
        if not config or not config.serverHandler then
            LOG.warning("Server: no handler for %s", tostring(eventName))
            return
        end
        
        LOG.debug("Server handling: %s from %s", eventName, tostring(player:getUsername()))
        
        -- Debug: log what we received
        if args.earnedXp then
            local count = 0
            for _ in pairs(args.earnedXp) do count = count + 1 end
            LOG.debug("Received earnedXp with %d perks", count)
        else
            LOG.debug("Received args, no earnedXp field")
        end
        
        local reply = function(response)
            if transactionId then
                sendServerCommand(player, MSR.Config.COMMAND_NAMESPACE, SERVER_EVENT_REPLY_CMD, {
                    transactionId = transactionId,
                    response = response
                })
            end
        end
        
        local ok, err = pcall(config.serverHandler, player, args, reply)
        if not ok then
            LOG.error("Server.%s handler error: %s", eventName, tostring(err))
        end
    end
end

local function onServerEventReply(module, command, args)
    if module ~= MSR.Config.COMMAND_NAMESPACE then return end
    
    if command == SERVER_EVENT_REPLY_CMD then
        local transactionId = args.transactionId
        local response = args.response
        
        local callback = pendingServerCallbacks[transactionId]
        if callback then
            pendingServerCallbacks[transactionId] = nil
            local player = getPlayer()
            local ok, err = pcall(callback, player, response)
            if not ok then
                LOG.error("Server reply callback error: %s", tostring(err))
            end
        end
    end
end

if Events.OnClientCommand then
    Events.OnClientCommand.Add(onServerEventCommand)
end
if Events.OnServerCommand then
    Events.OnServerCommand.Add(onServerEventReply)
end

-----------------------------------------------------------
-- Debug
-----------------------------------------------------------

function E.GetStatus()
    local serverEventCount = 0
    for _ in pairs(serverEventHandlers) do serverEventCount = serverEventCount + 1 end
    
    return {
        serverReadyFired = serverReadyFired,
        clientReadyFired = clientReadyFired,
        anyReadyFired = anyReadyFired,
        serverHandlerCount = #serverReadyHandlers,
        clientHandlerCount = #clientReadyHandlers,
        anyHandlerCount = #anyReadyHandlers,
        serverEventCount = serverEventCount,
        environment = {
            isSingleplayer = MSR.Env.isSingleplayer(),
            isServer = MSR.Env.isServer(),
            isClient = MSR.Env.isClient(),
            isDedicatedServer = MSR.Env.isDedicatedServer(),
            hasServerAuthority = MSR.Env.hasServerAuthority()
        }
    }
end

LOG.debug("Event wrapper system loaded")

return MSR.Events
