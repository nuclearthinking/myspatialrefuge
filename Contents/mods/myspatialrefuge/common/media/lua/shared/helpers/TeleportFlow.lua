-- MSR_TeleportFlow - Shared tick-based helpers for teleport sequences

require "00_core/00_MSR"
require "helpers/World"

if MSR.TeleportFlow and MSR.TeleportFlow._loaded then
    return MSR.TeleportFlow
end

MSR.TeleportFlow = MSR.TeleportFlow or {}
MSR.TeleportFlow._loaded = true

local Flow = MSR.TeleportFlow

---@class TeleportWaitOptions
---@field player IsoPlayer|nil
---@field centerX number
---@field centerY number
---@field centerZ number
---@field minTicks number|nil
---@field maxTicks number
---@field rotateTicks number|nil
---@field onReady function
---@field onTimeout function|nil

---Wait for the center square chunk to load with optional rotation and timeout
---@param opts TeleportWaitOptions
---@return function cancel
function Flow.waitForCenterChunk(opts)
    if type(opts) ~= "table" then return function() end end
    if not opts.centerX or not opts.centerY or opts.centerZ == nil then return function() end end
    if type(opts.onReady) ~= "function" then return function() end end
    if not opts.maxTicks or opts.maxTicks <= 0 then return function() end end

    local tickCount = 0
    local cancelled = false
    local minTicks = tonumber(opts.minTicks) or 0
    if minTicks < 0 then minTicks = 0 end
    local rotateTicks = tonumber(opts.rotateTicks) or 0
    local player = opts.player

    local function onTick()
        if cancelled then
            Events.OnTick.Remove(onTick)
            return
        end

        tickCount = tickCount + 1

        if player and rotateTicks > 0 and tickCount <= rotateTicks then
            player:setDir(tickCount % 4)
            return
        end

        if tickCount < minTicks then return end

        if tickCount >= opts.maxTicks then
            Events.OnTick.Remove(onTick)
            if opts.onTimeout then
                opts.onTimeout()
            end
            return
        end

        if MSR.World.isChunkLoaded(opts.centerX, opts.centerY, opts.centerZ) then
            Events.OnTick.Remove(onTick)
            opts.onReady()
        end
    end

    Events.OnTick.Add(onTick)

    return function()
        cancelled = true
    end
end

return MSR.TeleportFlow
