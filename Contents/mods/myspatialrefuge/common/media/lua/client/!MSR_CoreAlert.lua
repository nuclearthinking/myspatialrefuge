-- MSR_CoreAlert - Standalone alert for core module failures
-- This file intentionally has NO dependencies on MSR core modules
-- It only checks if MSR._coreValid is set and shows an alert if validation failed

local alertShown = false

local function showCoreFailureAlert()
    if alertShown then return end
    alertShown = true
    
    local message = " <CENTRE> <SIZE:large> <RGB:1,0.3,0.3> WARNING <LINE> <LINE> " ..
        "<SIZE:medium> <RGB:1,1,1> My Spatial Refuge did not load properly! <LINE> <LINE> " ..
        "<SIZE:small> <LEFT> Some core modules failed to initialize. <LINE> " ..
        "<RGB:1,0.6,0.6> This may cause mod functions to not work and could corrupt your refuge data! <LINE> <LINE> " ..
        "<SIZE:medium> <RGB:0.7,1,0.7> How to fix: <LINE> " ..
        "<SIZE:small> <RGB:1,1,1> 1. Open Mods menu and check load order <LINE> " ..
        "2. Move <RGB:1,1,0> My Spatial Refuge <RGB:1,1,1> higher (closer to top) <LINE> " ..
        "3. Disable other mods to check for conflicts <LINE> " ..
        "4. Restart the game after changes <LINE> <LINE> " ..
        "<SIZE:medium> <RGB:0.7,0.7,1> If problem persists: <LINE> " ..
        "<SIZE:small> <RGB:1,1,1> Check logs for details: <LINE> " ..
        "<RGB:0.8,0.8,0.8> - SP: Zomboid/console.txt <LINE> " ..
        "- Coop: Zomboid/coop-console.txt <LINE> " ..
        "- Server: Zomboid/server-console.txt <LINE> <LINE> " ..
        "<RGB:1,1,0> Report bugs at: <LINE> " ..
        "<RGB:0.6,0.8,1> Steam Workshop > My Spatial Refuge > Discussions > Bug reports <LINE> "
    
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local width, height = 500, 350
    
    local modal = ISModalRichText:new((screenW - width) / 2, (screenH - height) / 2, width, height, message, false)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    
    print("[MSR] ================================================")
    print("[MSR] CRITICAL: Core modules failed to load!")
    print("[MSR] Check mod conflicts and load order, then restart.")
    print("[MSR] Report: Steam Workshop > My Spatial Refuge > Discussions")
    print("[MSR] ================================================")
end

local function shouldShowAlert()
    if not MSR then return true end  -- namespace missing = critical
    if MSR._coreValidated and not MSR._coreValid then return true end
    return false
end

local function delayedCheck(ticks, callback)
    local count = 0
    local checkFunc
    checkFunc = function()
        count = count + 1
        if count > ticks then
            Events.OnTick.Remove(checkFunc)
            callback()
        end
    end
    Events.OnTick.Add(checkFunc)
end

-- Delay ensures UI system is ready
Events.OnGameStart.Add(function()
    delayedCheck(60, function()
        if shouldShowAlert() then
            showCoreFailureAlert()
        end
    end)
end)

-- Show early if issue detected before game start
Events.OnMainMenuEnter.Add(function()
    if shouldShowAlert() then
        delayedCheck(30, showCoreFailureAlert)
    end
end)
