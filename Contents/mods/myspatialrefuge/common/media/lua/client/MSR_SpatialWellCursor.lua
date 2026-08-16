-- The vanilla building cursor lives under media/lua/server and is unavailable
-- during the early client-file loading pass. Build the derived class lazily,
-- after a world is loaded and the player actually starts placement.

require "MSR_SpatialWell"
require "MSR_PlayerMessage"

MSR_SpatialWellCursor = MSR_SpatialWellCursor or {}

local CursorClass = nil

local function getCursorClass()
    if CursorClass then return CursorClass end

    if not ISBuildingObject then
        require "BuildingObjects/ISBuildingObject"
    end
    if not ISBuildingObject then return nil end

    local SpatialWellPlacementCursor = ISBuildingObject:derive("MSR_SpatialWellPlacementCursor")

    function SpatialWellPlacementCursor:new(playerObj)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o:init()

        local spriteName = MSR.SpatialWell.ResolveSprite()
        o:setSprite(spriteName)
        o:setNorthSprite(spriteName)
        o:setEastSprite(spriteName)
        o:setSouthSprite(spriteName)
        o:setDragNilAfterPlace(true)
        o.player = playerObj:getPlayerNum()
        o.name = getText("UI_SpatialWell_Name")
        o.blockAllTheSquare = true
        o.isThumpable = false
        o.dismantable = false
        return o
    end

    function SpatialWellPlacementCursor:isValid(square)
        local playerObj = getSpecificPlayer(self.player)
        if not playerObj then return false end
        local valid = MSR.SpatialWell.CanPlaceAt(playerObj, square)
        return valid == true
    end

    function SpatialWellPlacementCursor:tryBuild(x, y, z)
        local playerObj = getSpecificPlayer(self.player)
        if not playerObj then return end

        local success, reason = MSR.SpatialWell.RequestPlacement(playerObj, x, y, z)
        if success then
            getCell():setDrag(nil --[[@as ISBuildingObject]], self.player)
        elseif reason then
            MSR.PlayerMessage.Say(playerObj, reason)
        end
    end

    function SpatialWellPlacementCursor:render(x, y, z, square)
        ISBuildingObject.render(self, x, y, z, square)
    end

    CursorClass = SpatialWellPlacementCursor
    return CursorClass
end

function MSR_SpatialWellCursor.Start(playerObj)
    if not playerObj or not MSR.SpatialWell.ResolveSprite() then return false end

    local cursorClass = getCursorClass()
    if not cursorClass then return false end

    local cursor = cursorClass:new(playerObj)
    getCell():setDrag(cursor, playerObj:getPlayerNum())
    return true
end

return MSR_SpatialWellCursor
