-- The vanilla building cursor lives under media/lua/server and is unavailable
-- during the early client-file loading pass. Build the derived class lazily,
-- after a world is loaded and the player actually starts placement.

require "MSR_SpatialWell"
require "MSR_PlayerMessage"

MSR_SpatialWellCursor = MSR_SpatialWellCursor or {}

---@class MSR_SpatialWellPlacementCursor : ISBuildingObject
---@field player integer
---@field moveExisting boolean
---@field sourceWell IsoObject?
---@type MSR_SpatialWellPlacementCursor?
local CursorClass = nil

local function getCursorClass()
    if CursorClass then return CursorClass end

    if not ISBuildingObject then
        require "BuildingObjects/ISBuildingObject"
    end
    if not ISBuildingObject then return nil end

    ---@type MSR_SpatialWellPlacementCursor
    local SpatialWellPlacementCursor = ISBuildingObject:derive("MSR_SpatialWellPlacementCursor")

    ---@param playerObj IsoPlayer
    ---@param moveExisting boolean
    ---@param sourceWell IsoObject?
    ---@return MSR_SpatialWellPlacementCursor
    function SpatialWellPlacementCursor:new(playerObj, moveExisting, sourceWell)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        ---@cast o MSR_SpatialWellPlacementCursor
        o:init()

        local spriteName = MSR.SpatialWell.ResolveSprite()
        o:setSprite(spriteName)
        o:setNorthSprite(spriteName)
        o:setEastSprite(spriteName)
        o:setSouthSprite(spriteName)
        o:setDragNilAfterPlace(true)
        o.player = playerObj:getPlayerNum()
        o.moveExisting = moveExisting == true
        o.sourceWell = sourceWell
        o.name = o.moveExisting and getText("IGUI_MoveSpatialWell") or getText("UI_SpatialWell_Name")
        o.blockAllTheSquare = true
        o.isThumpable = false
        o.dismantable = false
        return o
    end

    ---@param square IsoGridSquare
    ---@return boolean
    function SpatialWellPlacementCursor:isValid(square)
        local playerObj = getSpecificPlayer(self.player)
        if not playerObj then return false end
        local valid
        if self.moveExisting then
            valid = MSR.SpatialWell.CanMoveTo(playerObj, square, nil, self.sourceWell)
        else
            valid = MSR.SpatialWell.CanPlaceAt(playerObj, square)
        end
        return valid == true
    end

    ---@param x number
    ---@param y number
    ---@param z number
    function SpatialWellPlacementCursor:tryBuild(x, y, z)
        local playerObj = getSpecificPlayer(self.player)
        if not playerObj then return end

        local success, reason, reasonArgs
        if self.moveExisting then
            success, reason, reasonArgs = MSR.SpatialWell.RequestMove(playerObj, self.sourceWell, x, y, z)
        else
            success, reason = MSR.SpatialWell.RequestPlacement(playerObj, x, y, z)
        end
        if success then
            getCell():setDrag(nil --[[@as ISBuildingObject]], self.player)
        elseif reason then
            if reasonArgs and #reasonArgs > 0 then
                MSR.PlayerMessage.Say(playerObj, reason, unpack(reasonArgs))
            else
                MSR.PlayerMessage.Say(playerObj, reason)
            end
        end
    end

    ---@param x number
    ---@param y number
    ---@param z number
    ---@param square IsoGridSquare
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

    ---@diagnostic disable-next-line: redundant-parameter
    local cursor = cursorClass:new(playerObj, false, nil)
    getCell():setDrag(cursor, playerObj:getPlayerNum())
    return true
end

function MSR_SpatialWellCursor.StartMove(playerObj, well)
    if not playerObj or not well or not MSR.SpatialWell.ResolveSprite() then return false end

    local remaining = MSR.SpatialWell.GetMoveCooldownRemaining(playerObj)
    if remaining > 0 then
        return false, MSR.PlayerMessage.CANNOT_MOVE_SPATIAL_WELL_YET, { math.ceil(remaining) }
    end

    local canMove = MSR.SpatialWell.CanMoveObject(playerObj, well)
    if not canMove then return false end

    local cursorClass = getCursorClass()
    if not cursorClass then return false end

    ---@diagnostic disable-next-line: redundant-parameter
    local cursor = cursorClass:new(playerObj, true, well)
    getCell():setDrag(cursor, playerObj:getPlayerNum())
    return true
end

return MSR_SpatialWellCursor
