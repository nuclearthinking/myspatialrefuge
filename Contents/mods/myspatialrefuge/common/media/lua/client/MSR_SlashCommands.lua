require "00_core/00_MSR"
require "00_core/Events"

local Slash = MSR.register("SlashCommands")
local LOG = L.logger("SlashCommands")
if not Slash then
    return MSR.SlashCommands
end

MSR.SlashCommands = Slash

local Config = MSR.Config
local EventsBus = MSR.Events

local OUTPUT_COLOR = "<RGB:0.45,0.75,0.95>"

local function getChatClass()
    ---@diagnostic disable-next-line: undefined-field
    return _G.ISChat
end

local function trim(text)
    return (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
end

local function startsWith(text, prefix)
    if not text or not prefix then
        return false
    end

    return string.sub(text, 1, string.len(prefix)) == prefix
end

local function hasLocalAdminAccess()
    if getDebug and getDebug() then
        return true
    end

    if MSR.Env and MSR.Env.hasServerAuthority and MSR.Env.hasServerAuthority() then
        return true
    end

    ---@diagnostic disable-next-line: undefined-field
    if isClient and isClient() and _G.getAccessLevel then
        ---@diagnostic disable-next-line: undefined-field
        return _G.getAccessLevel() == "admin"
    end

    return false
end

local function appendChatLine(chatText, line)
    local chatClass = getChatClass()
    chatText.chatTextLines = chatText.chatTextLines or {}

    if #chatText.chatTextLines > chatClass.maxLine then
        local newLines = {}
        for i, existingLine in ipairs(chatText.chatTextLines) do
            if i ~= 1 then
                table.insert(newLines, existingLine)
            end
        end
        table.insert(newLines, line .. " <LINE> ")
        chatText.chatTextLines = newLines
    else
        table.insert(chatText.chatTextLines, line .. " <LINE> ")
    end
end

local function rebuildChatText(chatText)
    chatText.text = ""

    local newText = ""
    for i, line in ipairs(chatText.chatTextLines or {}) do
        local textLine = line
        if i == #(chatText.chatTextLines or {}) then
            textLine = string.gsub(textLine, " <LINE> $", "")
        end
        newText = newText .. textLine
    end

    chatText.text = newText
    chatText:paginate()
end

local function showLinesInChat(lines)
    if not lines or #lines == 0 then
        return
    end

    local chatClass = getChatClass()
    if not chatClass or not chatClass.instance then
        for _, line in ipairs(lines) do
            print(line)
        end
        return
    end

    local chat = chatClass.instance
    if not chat.chatText then
        chat.chatText = chat.defaultTab
        chat:onActivateView()
    end

    local chatText = chat.chatText or chat.defaultTab
    if not chatText then
        for _, line in ipairs(lines) do
            print(line)
        end
        return
    end

    local vscroll = chatText.vscroll
    local scrolledToBottom = (chatText:getScrollHeight() <= chatText:getHeight()) or (vscroll and vscroll.pos == 1)

    for _, line in ipairs(lines) do
        appendChatLine(chatText, OUTPUT_COLOR .. " " .. tostring(line))
    end

    rebuildChatText(chatText)

    if scrolledToBottom then
        chatText:setYScroll(-10000)
    end
end

local function tokenize(text)
    local tokens = {}
    local current = ""
    local quote = nil
    local escapeNext = false

    for i = 1, string.len(text) do
        local ch = string.sub(text, i, i)

        if escapeNext then
            current = current .. ch
            escapeNext = false
        elseif quote then
            if ch == "\\" then
                escapeNext = true
            elseif ch == quote then
                quote = nil
            else
                current = current .. ch
            end
        elseif ch == "\"" or ch == "'" then
            quote = ch
        elseif ch == " " or ch == "\t" then
            if current ~= "" then
                table.insert(tokens, current)
                current = ""
            end
        else
            current = current .. ch
        end
    end

    if current ~= "" then
        table.insert(tokens, current)
    end

    return tokens
end

local function parseCommand(text)
    local commandText = text or ""
    local trimmed = trim(commandText)
    local rest = ""

    if string.len(trimmed) > 4 then
        rest = trim(string.sub(trimmed, 5))
    end

    if rest == "" then
        return {
            cmd = "help",
            args = {}
        }
    end

    local tokens = tokenize(rest)
    local cmd = string.lower(tokens[1] or "help")
    table.remove(tokens, 1)

    return {
        cmd = cmd,
        args = tokens
    }
end

local function isSlashCommand(text)
    if not text then
        return false
    end

    local lowered = string.lower(trim(text))
    return lowered == "/msr" or startsWith(lowered, "/msr ")
end

local function executeLocally(payload)
    if not MSR.AdminHandler or not MSR.AdminHandler.Execute then
        return false
    end

    local player = getPlayer and getPlayer() or nil
    local ok, response = pcall(MSR.AdminHandler.Execute, player, payload)
    if not ok then
        LOG.error("Local /msr execution failed: %s", tostring(response))
        showLinesInChat({
            "[MSR] Command failed locally."
        })
        return true
    end

    if response and response.lines then
        showLinesInChat(response.lines)
    end

    return true
end

local function dispatchSlashCommand(text)
    local payload = parseCommand(text)

    if not hasLocalAdminAccess() then
        showLinesInChat({
            "[MSR] Admin access required for /msr commands."
        })
        return true
    end

    if MSR.Env and MSR.Env.hasServerAuthority and MSR.Env.hasServerAuthority() then
        if executeLocally(payload) then
            return true
        end
    end

    sendClientCommand(Config.COMMAND_NAMESPACE, Config.COMMANDS.ADMIN_COMMAND, payload)
    return true
end

local function onServerCommand(module, command, args)
    if module ~= Config.COMMAND_NAMESPACE or command ~= Config.COMMANDS.ADMIN_RESPONSE then
        return
    end

    showLinesInChat(args and args.lines or {
        "[MSR] No response received."
    })
end

local function installHook()
    if Slash._hookInstalled then
        return true
    end

    local chatClass = getChatClass()
    if not chatClass or not chatClass.instance or not chatClass.onCommandEntered or not chatClass.instance.textEntry then
        return false
    end

    Slash._originalOnCommandEntered = chatClass.onCommandEntered

    function chatClass:onCommandEntered()
        local activeChatClass = getChatClass()
        local chat = activeChatClass and activeChatClass.instance or nil
        if not chat or not chat.textEntry then
            return Slash._originalOnCommandEntered(self)
        end

        local commandText = chat.textEntry:getText()
        if not isSlashCommand(commandText) then
            return Slash._originalOnCommandEntered(self)
        end

        chat:unfocus()
        chat:logChatCommand(commandText)
        dispatchSlashCommand(commandText)
    end

    chatClass.instance.textEntry.onCommandEntered = chatClass.onCommandEntered
    Slash._hookInstalled = true
    LOG.debug("Installed /msr chat hook")
    return true
end

local function ensureHookInstalled()
    if installHook() then
        if Slash._pendingInstallTick then
            Events.OnTick.Remove(Slash._pendingInstallTick)
            Slash._pendingInstallTick = nil
        end
        return
    end

    if Slash._pendingInstallTick then
        return
    end

    Slash._pendingInstallTick = function()
        if installHook() then
            Events.OnTick.Remove(Slash._pendingInstallTick)
            Slash._pendingInstallTick = nil
        end
    end

    Events.OnTick.Add(Slash._pendingInstallTick)
end

if Events.OnServerCommand then
    Events.OnServerCommand.Add(onServerCommand)
end

EventsBus.OnClientReady.Add(ensureHookInstalled)

return MSR.SlashCommands
