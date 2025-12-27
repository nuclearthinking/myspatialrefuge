-- Spatial Refuge Server Module
-- Server-side validation and handlers for multiplayer

require "shared/SpatialRefugeConfig"

SpatialRefugeServer = SpatialRefugeServer or {}

-- Server-side initialization
local function OnServerStart()
    if getDebug() then
        print("[SpatialRefuge] Server initialized")
    end
end

-- Validate player refuge operations (for multiplayer security)
function SpatialRefugeServer.ValidateRefugeAccess(player, refugeId)
    if not player then return false end
    
    -- In multiplayer, ensure player can only access their own refuge
    local username = player:getUsername()
    local expectedRefugeId = "refuge_" .. username
    
    return refugeId == expectedRefugeId
end

-- Register events
Events.OnServerStarted.Add(OnServerStart)

if getDebug() then
    print("[SpatialRefuge] Server module loaded")
end

return SpatialRefugeServer

