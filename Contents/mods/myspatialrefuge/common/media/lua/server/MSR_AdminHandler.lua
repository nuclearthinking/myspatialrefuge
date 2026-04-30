require "00_core/00_MSR"
require "MSR_AdminCommands"

local Handler = MSR.register("AdminHandler")
local LOG = L.logger("AdminHandler")
if not Handler then
    return MSR.AdminHandler
end

MSR.AdminHandler = Handler

local Config = MSR.Config

local function buildResponse(cmd, lines, success)
    return {
        cmd = cmd,
        lines = lines or {},
        success = success ~= false
    }
end

local function sendResponse(player, response)
    if not player or not response then
        return
    end

    sendServerCommand(player, Config.COMMAND_NAMESPACE, Config.COMMANDS.ADMIN_RESPONSE, response)
end

local function getCommandArg(args, index)
    if not args then
        return nil
    end

    return args[index]
end

local function isAdmin(player)
    if not player or not player.isAccessLevel then
        return false
    end

    return player:isAccessLevel("admin")
end

local function getHandlers()
    return MSR.Admin and MSR.Admin.Commands or {}
end

local function appendLines(target, source)
    if not source then
        return target
    end

    for _, line in ipairs(source) do
        table.insert(target, line)
    end

    return target
end

local function executeCommand(player, payload)
    local cmd = payload and payload.cmd or "help"
    cmd = string.lower(tostring(cmd or "help"))
    local args = payload and payload.args or {}
    local handlers = getHandlers()

    if not isAdmin(player) then
        return buildResponse(cmd, {
            "[MSR] Admin access required for /msr commands."
        }, false)
    end

    local dispatch = {
        help = function()
            return handlers.help and handlers.help() or { "[MSR] Help is unavailable." }
        end,
        stats = function()
            return handlers.stats and handlers.stats() or { "[MSR] Stats command is unavailable." }
        end,
        list = function()
            return handlers.list and handlers.list() or { "[MSR] List command is unavailable." }
        end,
        info = function()
            return handlers.info and handlers.info(getCommandArg(args, 1)) or { "[MSR] Info command is unavailable." }
        end,
        inactive = function()
            return handlers.inactive and handlers.inactive(getCommandArg(args, 1)) or { "[MSR] Inactive command is unavailable." }
        end,
        purge = function()
            local executeNow = nil
            if getCommandArg(args, 2) == "confirm" then
                executeNow = true
            else
                executeNow = getCommandArg(args, 2)
            end

            return handlers.purge and handlers.purge(getCommandArg(args, 1), executeNow) or { "[MSR] Purge command is unavailable." }
        end,
        delete = function()
            return handlers.delete and handlers.delete(getCommandArg(args, 1)) or { "[MSR] Delete command is unavailable." }
        end,
        goto = function()
            return handlers.goto and handlers.goto(getCommandArg(args, 1), player) or { "[MSR] Goto command is unavailable." }
        end,
        scan = function()
            return handlers.scan and handlers.scan(getCommandArg(args, 1), player) or { "[MSR] Scan command is unavailable." }
        end
    }

    local handler = dispatch[cmd]
    if not handler then
        local lines = {
            "[MSR] Unknown /msr command: " .. tostring(cmd),
            "[MSR] Try /msr help."
        }

        if handlers.help then
            appendLines(lines, handlers.help())
        end

        return buildResponse(cmd, lines, false)
    end

    local ok, lines = pcall(handler)
    if not ok then
        LOG.error("Failed to execute admin command %s: %s", tostring(cmd), tostring(lines))
        return buildResponse(cmd, {
            "[MSR] Command failed: " .. tostring(cmd)
        }, false)
    end

    return buildResponse(cmd, lines, true)
end

Handler.Execute = executeCommand

local function onClientCommand(module, command, player, args)
    if module ~= Config.COMMAND_NAMESPACE or command ~= Config.COMMANDS.ADMIN_COMMAND then
        return
    end

    local response = executeCommand(player, args or {})
    sendResponse(player, response)
end

if Events.OnClientCommand then
    Events.OnClientCommand.Add(onClientCommand)
end

return MSR.AdminHandler
