-- 01_Utils - Common utility functions for MSR
-- Provides: Player resolution, delayed execution, polling utilities
-- Depends on: MSR namespace (global)
-- Optional: K (safeCall), L (logging)

if not MSR then
    error("[MSR] 01_Utils requires MSR namespace to be defined first")
end

local Utils = {}

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
    
    local tickCount = 0
    local cancelled = false
    
    local function onTick()
        if cancelled then
            Events.OnTick.Remove(onTick)
            return
        end
        
        tickCount = tickCount + 1
        if tickCount < ticks then return end
        
        Events.OnTick.Remove(onTick)
        local ok, err = pcall(callback)
        if not ok and L then
            L.error("MSR", "delay callback error: " .. tostring(err))
        end
    end
    
    Events.OnTick.Add(onTick)
    
    return function()
        cancelled = true
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
    local cancelled = false
    local completed = false
    local minTicks = tonumber(opts.minTicks) or 0
    if minTicks < 0 then minTicks = 0 end
    local maxTicks = opts.maxTicks
    local tag = opts.tag
    
    local function onTick()
        if cancelled or completed then
            Events.OnTick.Remove(onTick)
            return
        end
        
        tickCount = tickCount + 1
        
        -- Check timeout first
        if tickCount >= maxTicks then
            completed = true
            Events.OnTick.Remove(onTick)
            if tag and L then
                L.debug("MSR", "poll timeout: " .. tag .. " after " .. tickCount .. " ticks")
            end
            if opts.onTimeout then
                local ok, err = pcall(opts.onTimeout)
                if not ok and L then
                    L.error("MSR", "poll onTimeout error: " .. tostring(err))
                end
            end
            return
        end
        
        -- Skip condition check if below minTicks
        if tickCount < minTicks then return end
        
        -- Check condition
        local ok, success, result = pcall(opts.condition)
        if not ok then
            if L then L.error("MSR", "poll condition error: " .. tostring(success)) end
            return
        end
        
        if success then
            completed = true
            Events.OnTick.Remove(onTick)
            if tag and L then
                L.debug("MSR", "poll success: " .. tag .. " after " .. tickCount .. " ticks")
            end
            local callOk, err = pcall(opts.onSuccess, result)
            if not callOk and L then
                L.error("MSR", "poll onSuccess error: " .. tostring(err))
            end
        end
    end
    
    Events.OnTick.Add(onTick)
    
    return function()
        cancelled = true
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
                L.debug("MSR", "poll cancelled - player disconnected: " .. tag)
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
MSR.delay            = Utils.delay
MSR.delayWithPlayer  = Utils.delayWithPlayer
MSR.poll             = Utils.poll
MSR.pollWithPlayer   = Utils.pollWithPlayer
MSR.waitFor          = Utils.waitFor

-- Also expose the Utils table for direct access if needed
MSR.Utils = Utils

return Utils
