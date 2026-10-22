-- Pure room geometry. Coordinates, never engine room IDs, form the save format.
local Topology = {}

function Topology.key(x, y)
    return x .. "," .. y
end

-- Exact, non-overlapping coverage, including holes and concave outlines.
function Topology.rectangles(tiles)
    local ordered, used, rects = {}, {}, {}
    for _, tile in pairs(tiles) do ordered[#ordered + 1] = tile end
    table.sort(ordered, function(a, b)
        return a.y < b.y or (a.y == b.y and a.x < b.x)
    end)
    for _, tile in ipairs(ordered) do
        if not used[Topology.key(tile.x, tile.y)] then
            local w, h = 1, 1
            while tiles[Topology.key(tile.x + w, tile.y)] and not used[Topology.key(tile.x + w, tile.y)] do
                w = w + 1
            end
            while true do
                local complete = true
                for dx = 0, w - 1 do
                    local k = Topology.key(tile.x + dx, tile.y + h)
                    if not tiles[k] or used[k] then complete = false; break end
                end
                if not complete then break end
                h = h + 1
            end
            for dx = 0, w - 1 do
                for dy = 0, h - 1 do used[Topology.key(tile.x + dx, tile.y + dy)] = true end
            end
            rects[#rects + 1] = { x = tile.x, y = tile.y, w = w, h = h }
        end
    end
    return rects
end

-- tiles include the east/south boundary squares, where those walls live.
-- Ground rooms require a complete roof and enclosure; the basement envelope
-- supplies its own enclosure/ceiling, including its intentional stair opening.
function Topology.rooms(bounds, tiles, basement)
    local seen, rooms = {}, {}
    local function blocked(a, b, dx, dy)
        if dx == 1 then return b and b.west end
        if dx == -1 then return a.west end
        if dy == 1 then return b and b.north end
        return a.north
    end
    for y = bounds.minY, bounds.maxY do
        for x = bounds.minX, bounds.maxX do
            local start = tiles[Topology.key(x, y)]
            if start and start.floor and not seen[Topology.key(x, y)] then
                local members, queue, head = {}, { start }, 1
                local enclosed, roofed = true, true
                seen[Topology.key(x, y)] = true
                while head <= #queue do
                    local a = queue[head]
                    head = head + 1
                    members[Topology.key(a.x, a.y)] = a
                    roofed = roofed and a.roof
                    for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1} }) do
                        local nx, ny = a.x + d[1], a.y + d[2]
                        local k = Topology.key(nx, ny)
                        local b = tiles[k]
                        local inside = nx >= bounds.minX and nx <= bounds.maxX
                            and ny >= bounds.minY and ny <= bounds.maxY
                        if not blocked(a, b, d[1], d[2]) then
                            if not inside or not b or not b.floor then
                                enclosed = false
                            elseif not seen[k] then
                                seen[k] = true
                                queue[#queue + 1] = b
                            end
                        end
                    end
                end
                if basement or (enclosed and roofed) then
                    rooms[#rooms + 1] = { rects = Topology.rectangles(members) }
                end
            end
        end
    end
    return rooms
end

function Topology.signature(rooms)
    local parts = {}
    for _, room in ipairs(rooms) do
        local rects = {}
        for _, r in ipairs(room.rects) do
            rects[#rects + 1] = table.concat({r.x, r.y, r.w, r.h}, ",")
        end
        parts[#parts + 1] = table.concat(rects, ";")
    end
    return table.concat(parts, "|")
end

return Topology
