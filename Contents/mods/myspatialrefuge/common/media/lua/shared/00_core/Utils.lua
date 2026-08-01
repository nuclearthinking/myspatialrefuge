-- 01_Utils - Common utility functions for MSR
-- Provides: Player resolution, delayed execution, polling utilities
-- Depends on: MSR namespace (global)
-- Optional: K (safeCall), L (logging)

if not MSR then
    error("[MSR] 01_Utils requires MSR namespace to be defined first")
end

local Utils = {}
local LOG = L.logger("MSR")

-----------------------------------------------------------
-- Player Resolution Utilities
-----------------------------------------------------------

--- Resolve player reference to live IsoPlayer (handles index, object, or stale refs)
--- @param player number|IsoPlayer
--- @return IsoPlayer|nil
function Utils.resolvePlayer(player)
    if not player then return nil end
    
    if type(player) == "number" and getSpecificPlayer then
        return getSpecificPlayer(player)
    end
    
    -- Re-resolve to avoid stale references in MP
    if (type(player) == "userdata" or type(player) == "table") and player.getPlayerNum then
        local ok, num = pcall(function() return player:getPlayerNum() end)
        if ok and num ~= nil and getSpecificPlayer then
            local resolved = getSpecificPlayer(num)
            if resolved then return resolved end
        end
        return player
    end
    return nil
end

--- Safely call method on player (guards against disconnected/null refs)
--- @param player any
--- @param methodName string
--- @return any|nil
function Utils.safePlayerCall(player, methodName)
    local resolved = Utils.resolvePlayer(player)
    if not resolved then return nil end
    
    if K and K.safeCall then
        return K.safeCall(resolved, methodName)
    end
    
    local ok, method = pcall(function() return resolved[methodName] end)
    if not ok or not method then return nil end
    
    local callOk, result = pcall(function() return method(resolved) end)
    if not callOk then return nil end
    return result
end

--- Check if player reference is still valid (connected)
--- @param playerRef IsoPlayer
--- @return boolean
function Utils.isPlayerValid(playerRef)
    if not playerRef then return false end
    local ok, result = pcall(function() return playerRef:getUsername() end)
    return ok and result ~= nil
end

--- Check if player is inside refuge coordinates
--- @param player IsoPlayer|number
--- @return boolean
function Utils.isPlayerInRefuge(player)
    local resolved = Utils.resolvePlayer(player)
    if not resolved then return false end
    if MSR.Data and MSR.Data.IsPlayerInRefugeCoords then
        return MSR.Data.IsPlayerInRefugeCoords(resolved)
    end
    return false
end

--- Best-effort combat check (zombie pressure or recent damage)
--- @param player IsoPlayer|number
--- @return boolean
function Utils.isPlayerInCombat(player)
    local resolved = Utils.resolvePlayer(player)
    if not resolved then return false end

    local stats = Utils.safePlayerCall(resolved, "getStats")
    if stats then
        local ok, chasing = pcall(function() return stats:getNumChasingZombies() end)
        if ok and chasing and chasing > 0 then return true end
        local ok2, visible = pcall(function() return stats:getNumVisibleZombies() end)
        if ok2 and visible and visible > 0 then return true end
        local ok3, close = pcall(function() return stats:getNumVeryCloseZombies() end)
        if ok3 and close and close > 0 then return true end
    end

    if MSR.GetLastDamageTime and MSR.Config and MSR.Config.getCombatBlockTime then
        local lastDamage = MSR.GetLastDamageTime(resolved)
        if lastDamage and (K.time() - lastDamage) < MSR.Config.getCombatBlockTime() then
            return true
        end
    end

    return false
end

--- Scale positive value using difficulty (higher value = better)
--- @param baseValue number
--- @return number
function Utils.scalePositiveValue(baseValue)
    if type(baseValue) ~= "number" then return baseValue end
    if D and D.positiveValue then
        return D.positiveValue(baseValue)
    end
    return baseValue
end

-- Dynamic keyed scheduler
-----------------------------------------------------------

local Scheduler = {}
local scheduledByKey = {}
local scheduledTasks = {}
local dueTasks = {}
local freeTasks = {}
local freeTaskCount = 0
local scheduledTaskCount = 0
local activeTaskCount = 0
local schedulerActive = false
local getTimeMs = getTimestampMs

local function stopSchedulerIfIdle()
    if activeTaskCount == 0 and schedulerActive then
        schedulerActive = false
        Events.OnTick.Remove(Scheduler._process)
        for index = 1, scheduledTaskCount do
            scheduledTasks[index] = nil
        end
        scheduledTaskCount = 0
    end
end

function Scheduler._process()
    local nowMs = nil
    local dueTaskCount = 0
    local writeIndex = 1

    for readIndex = 1, scheduledTaskCount do
        local task = scheduledTasks[readIndex]
        if task and task.key and scheduledByKey[task.key] == task then
            if task.ticksRemaining then
                task.ticksRemaining = task.ticksRemaining - 1
            end

            local ticksReady = not task.ticksRemaining or task.ticksRemaining <= 0
            local timeReady = true
            if task.dueAtMs then
                nowMs = nowMs or getTimeMs()
                timeReady = nowMs >= task.dueAtMs
            end
            if ticksReady and timeReady then
                scheduledByKey[task.key] = nil
                activeTaskCount = activeTaskCount - 1
                dueTaskCount = dueTaskCount + 1
                dueTasks[dueTaskCount] = task
            else
                scheduledTasks[writeIndex] = task
                writeIndex = writeIndex + 1
            end
        end
    end

    for index = writeIndex, scheduledTaskCount do
        scheduledTasks[index] = nil
    end
    scheduledTaskCount = writeIndex - 1
    stopSchedulerIfIdle()

    -- Run callbacks after compacting the queue. A callback can safely schedule
    -- the same key again without mutating the queue currently being traversed.
    for index = 1, dueTaskCount do
        local task = dueTasks[index]
        dueTasks[index] = nil
        local callback = task.callback
        local callbackArg = task.callbackArg
        task.key = nil
        task.callback = nil
        task.callbackArg = nil
        local ok, err
        if callbackArg == nil then
            ok, err = pcall(callback)
        else
            ok, err = pcall(callback, callbackArg)
        end
        if not ok and L then
            LOG.error("Scheduler callback error: " .. tostring(err))
        end

        freeTaskCount = freeTaskCount + 1
        freeTasks[freeTaskCount] = task
    end
end

local function scheduleTask(key, delayTicks, delayMs, callback, callbackArg)
    local existingTask = scheduledByKey[key]
    if existingTask then
        existingTask.callback = callback
        existingTask.callbackArg = callbackArg
        existingTask.ticksRemaining = delayTicks
        existingTask.dueAtMs = delayMs and (getTimeMs() + delayMs) or nil
        return false
    end

    local task = {}
    if freeTaskCount > 0 then
        local pooledTask = freeTasks[freeTaskCount]
        freeTasks[freeTaskCount] = nil
        freeTaskCount = freeTaskCount - 1
        if pooledTask then task = pooledTask end
    end
    task.key = key
    task.callback = callback
    task.callbackArg = callbackArg
    task.ticksRemaining = delayTicks
    task.dueAtMs = delayMs and (getTimeMs() + delayMs) or nil
    scheduledByKey[key] = task
    scheduledTaskCount = scheduledTaskCount + 1
    scheduledTasks[scheduledTaskCount] = task
    activeTaskCount = activeTaskCount + 1

    if not schedulerActive then
        schedulerActive = true
        Events.OnTick.Add(Scheduler._process)
    end
    return true
end

--- Schedule or replace one keyed task. Only one shared OnTick dispatcher is
--- active regardless of the number of callers.
--- @param key any Stable key used for coalescing
--- @param opts table? Supports delayTicks and delayMs
--- @param callback function
--- @param callbackArg any?
--- @return boolean
function Scheduler.schedule(key, opts, callback, callbackArg)
    if key == nil or type(callback) ~= "function" then return false end
    opts = opts or {}

    local delayTicks = tonumber(opts.delayTicks)
    if delayTicks ~= nil and delayTicks < 1 then delayTicks = 1 end
    local delayMs = tonumber(opts.delayMs)
    if delayMs ~= nil and delayMs < 0 then delayMs = 0 end

    return scheduleTask(key, delayTicks, delayMs, callback, callbackArg)
end

--- Schedule a keyed callback after a number of ticks without allocating an
--- options table in recurring callers such as poll.
--- @param key any
--- @param delayTicks number
--- @param callback function
--- @param callbackArg any?
--- @return boolean
function Scheduler.afterTicks(key, delayTicks, callback, callbackArg)
    if key == nil or type(callback) ~= "function" then return false end
    delayTicks = tonumber(delayTicks) or 1
    if delayTicks < 1 then delayTicks = 1 end
    return scheduleTask(key, delayTicks, nil, callback, callbackArg)
end

--- Coalesce repeated work by key and run it no earlier than the next tick.
--- @param key any
--- @param delayMs number
--- @param callback function
--- @param callbackArg any?
--- @return boolean
function Scheduler.coalesce(key, delayMs, callback, callbackArg)
    if key == nil or type(callback) ~= "function" then return false end
    delayMs = tonumber(delayMs) or 0
    if delayMs < 0 then delayMs = 0 end
    return scheduleTask(key, 1, delayMs, callback, callbackArg)
end

--- @param key any
--- @return boolean
function Scheduler.isScheduled(key)
    return key ~= nil and scheduledByKey[key] ~= nil
end

--- @param key any
--- @return boolean
function Scheduler.cancel(key)
    local task = key ~= nil and scheduledByKey[key] or nil
    if not task then return false end

    scheduledByKey[key] = nil
    activeTaskCount = activeTaskCount - 1
    task.key = nil
    task.callback = nil
    task.callbackArg = nil
    stopSchedulerIfIdle()
    return true
end

Utils.Scheduler = Scheduler
MSR.Scheduler = Scheduler

-----------------------------------------------------------
-- Delayed Execution Utilities
-----------------------------------------------------------

--- Run a callback after a specified number of ticks
--- @param ticks number Number of ticks to wait (1 tick ≈ 16ms at 60fps)
--- @param callback function Function to call after delay
--- @return function cancel Function to cancel the delayed execution
function Utils.delay(ticks, callback)
    if type(callback) ~= "function" then return function() end end
    ticks = tonumber(ticks) or 1
    if ticks < 1 then ticks = 1 end

    local key = {}
    Scheduler.afterTicks(key, ticks, callback)

    return function()
        Scheduler.cancel(key)
    end
end

--- Run a callback after delay, resolving player reference before calling
--- Useful for player-specific operations where the reference might become stale
--- @param ticks number Number of ticks to wait
--- @param player IsoPlayer|number Player reference to resolve
--- @param callback function(player) Function to call with resolved player
--- @return function cancel Function to cancel the delayed execution
function Utils.delayWithPlayer(ticks, player, callback)
    if type(callback) ~= "function" then return function() end end
    
    local playerRef = player
    
    return Utils.delay(ticks, function()
        local resolved = Utils.resolvePlayer(playerRef)
        if resolved then
            callback(resolved)
        end
    end)
end

-----------------------------------------------------------
-- Poll Until Condition Utilities
-----------------------------------------------------------

--- Poll until condition is met or timeout reached
--- Replaces common pattern of waiting for chunks/objects/state with timeout
--- @param opts table Options table
---   - condition: function() -> bool, any? -- Required. Return true (and optional result) when done
---   - onSuccess: function(result?) -- Required. Called when condition returns true
---   - onTimeout: function()? -- Optional. Called when maxTicks exceeded
---   - minTicks: number? -- Optional. Skip condition checks until this many ticks (default: 0)
---   - maxTicks: number -- Required. Maximum ticks before timeout
---   - tag: string? -- Optional. Tag for debug logging
--- @return function cancel Function to cancel the polling
function Utils.poll(opts)
    if type(opts) ~= "table" then return function() end end
    if type(opts.condition) ~= "function" then return function() end end
    if type(opts.onSuccess) ~= "function" then return function() end end
    if not opts.maxTicks or opts.maxTicks <= 0 then return function() end end
    
    local tickCount = 0
    local completed = false
    local minTicks = tonumber(opts.minTicks) or 0
    if minTicks < 0 then minTicks = 0 end
    local maxTicks = opts.maxTicks
    local tag = opts.tag
    
    local key = {}
    local function pollOnce()
        if completed then return end

        tickCount = tickCount + 1

        -- Check timeout first
        if tickCount >= maxTicks then
            completed = true
            if tag and L then
                LOG.debug( "poll timeout: " .. tag .. " after " .. tickCount .. " ticks")
            end
            if opts.onTimeout then
                local ok, err = pcall(opts.onTimeout)
                if not ok and L then
                    LOG.error( "poll onTimeout error: " .. tostring(err))
                end
            end
            return
        end

        -- Skip condition check if below minTicks
        if tickCount < minTicks then
            Scheduler.afterTicks(key, 1, pollOnce)
            return
        end

        -- Check condition
        local ok, success, result = pcall(opts.condition)
        if not ok then
            if L then LOG.error( "poll condition error: " .. tostring(success)) end
            Scheduler.afterTicks(key, 1, pollOnce)
            return
        end

        if success then
            completed = true
            if tag and L then
                LOG.debug( "poll success: " .. tag .. " after " .. tickCount .. " ticks")
            end
            local callOk, err = pcall(opts.onSuccess, result)
            if not callOk and L then
                LOG.error( "poll onSuccess error: " .. tostring(err))
            end
            return
        end

        Scheduler.afterTicks(key, 1, pollOnce)
    end

    Scheduler.afterTicks(key, 1, pollOnce)

    return function()
        completed = true
        Scheduler.cancel(key)
    end
end

--- Poll with automatic player validity tracking
--- Automatically cancels if player disconnects during polling
--- @param player IsoPlayer|number Player to track
--- @param opts table Same options as Utils.poll, plus:
---   - onDisconnect: function()? -- Optional. Called if player disconnects
--- @return function cancel Function to cancel the polling
function Utils.pollWithPlayer(player, opts)
    if type(opts) ~= "table" then return function() end end
    if not player then return function() end end
    
    local playerRef = Utils.resolvePlayer(player)
    if not playerRef then return function() end end
    
    local originalCondition = opts.condition
    local originalOnSuccess = opts.onSuccess
    local onDisconnect = opts.onDisconnect
    local tag = opts.tag
    
    -- Create new opts table to avoid mutating caller's table
    local wrappedOpts = {
        minTicks = opts.minTicks,
        maxTicks = opts.maxTicks,
        tag = tag,
        onTimeout = opts.onTimeout,
    }
    
    -- Wrap condition to check player validity first
    wrappedOpts.condition = function()
        if not Utils.isPlayerValid(playerRef) then
            -- Signal disconnect via special return
            return true, { _disconnected = true }
        end
        -- Re-resolve player in case reference became stale
        playerRef = Utils.resolvePlayer(playerRef)
        if originalCondition then
            return originalCondition(playerRef)
        end
        return true, playerRef
    end
    
    -- Wrap onSuccess to handle disconnect case
    wrappedOpts.onSuccess = function(result)
        if result and result._disconnected then
            if tag and L then
                LOG.debug( "poll cancelled - player disconnected: " .. tag)
            end
            if onDisconnect then
                onDisconnect()
            end
            return
        end
        if originalOnSuccess then
            -- Pass resolved player as first arg if original condition didn't return a result
            local arg = result
            if arg == nil then
                arg = playerRef
            end
            originalOnSuccess(arg)
        end
    end
    
    return Utils.poll(wrappedOpts)
end

--- Convenience: Simple wait-for-condition with just condition function and callbacks
--- @param condition function() -> bool Check function, return true when ready
--- @param onReady function() Called when condition is true
--- @param maxTicks number Timeout in ticks
--- @param onTimeout function()? Optional timeout callback
--- @return function cancel
function Utils.waitFor(condition, onReady, maxTicks, onTimeout)
    return Utils.poll({
        condition = condition,
        onSuccess = onReady,
        onTimeout = onTimeout,
        maxTicks = maxTicks
    })
end

-----------------------------------------------------------
-- Attach to MSR namespace
-----------------------------------------------------------

MSR.resolvePlayer    = Utils.resolvePlayer
MSR.safePlayerCall   = Utils.safePlayerCall
MSR.isPlayerValid    = Utils.isPlayerValid
MSR.isPlayerInRefuge = Utils.isPlayerInRefuge
MSR.isPlayerInCombat = Utils.isPlayerInCombat
MSR.delay            = Utils.delay
MSR.delayWithPlayer  = Utils.delayWithPlayer
MSR.poll             = Utils.poll
MSR.pollWithPlayer   = Utils.pollWithPlayer
MSR.waitFor          = Utils.waitFor

-- Also expose the Utils table for direct access if needed
MSR.Utils = Utils

return Utils
