-- Pure geometry for refuge slots and their effective, relic-anchored area.
-- This module deliberately performs no world or ModData mutation.

local Geometry = MSR.register("RefugeGeometry")
if not Geometry then return MSR.RefugeGeometry end

local Config = MSR.Config

local ANCHORS = {
    Center = { name = "Center", dx = 0, dy = 0 },
    Up = { name = "Up", dx = -1, dy = -1 },
    Right = { name = "Right", dx = 1, dy = -1 },
    Left = { name = "Left", dx = -1, dy = 1 },
    Down = { name = "Down", dx = 1, dy = 1 },
}

local function integerOrZero(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then return 0 end
    if number ~= math.floor(number) then return 0 end
    return number
end

local function copyRefugeData(refugeData)
    local result = {}
    for key, value in pairs(refugeData or {}) do
        result[key] = value
    end
    return result
end

function Geometry.GetAreaOffset(refugeData)
    if not refugeData then return 0, 0 end
    return integerOrZero(refugeData.areaOffsetX), integerOrZero(refugeData.areaOffsetY)
end

function Geometry.GetAreaCenter(refugeData)
    if not refugeData then return nil, nil end
    local offsetX, offsetY = Geometry.GetAreaOffset(refugeData)
    return refugeData.centerX + offsetX, refugeData.centerY + offsetY
end

function Geometry.GetTileBounds(refugeData)
    if not refugeData then return nil end
    local centerX, centerY = Geometry.GetAreaCenter(refugeData)
    local radius = tonumber(refugeData.radius) or 1
    return {
        minX = centerX - radius,
        maxX = centerX + radius,
        minY = centerY - radius,
        maxY = centerY + radius,
        centerX = centerX,
        centerY = centerY,
        radius = radius,
    }
end

function Geometry.GetWallBounds(refugeData)
    local tiles = Geometry.GetTileBounds(refugeData)
    if not tiles then return nil end
    return {
        minX = tiles.minX,
        maxX = tiles.maxX + 1,
        minY = tiles.minY,
        maxY = tiles.maxY + 1,
        centerX = tiles.centerX,
        centerY = tiles.centerY,
        radius = tiles.radius,
    }
end

function Geometry.ContainsTile(refugeData, x, y)
    local bounds = Geometry.GetTileBounds(refugeData)
    if not bounds or type(x) ~= "number" or type(y) ~= "number" then return false end
    local tileX = math.floor(x)
    local tileY = math.floor(y)
    return tileX >= bounds.minX and tileX <= bounds.maxX
        and tileY >= bounds.minY and tileY <= bounds.maxY
end

function Geometry.ValidateAnchor(dx, dy, name)
    if type(dx) ~= "number" or type(dy) ~= "number" then
        return false, nil, "Invalid anchor offsets"
    end
    if dx ~= dx or dy ~= dy or dx < -1 or dx > 1 or dy < -1 or dy > 1 then
        return false, nil, "Unsupported relic anchor"
    end
    if dx ~= math.floor(dx) or dy ~= math.floor(dy) then
        return false, nil, "Anchor offsets must be integers"
    end

    for anchorName, anchor in pairs(ANCHORS) do
        if anchor.dx == dx and anchor.dy == dy then
            if name ~= nil and name ~= anchorName then
                return false, nil, "Anchor name does not match offsets"
            end
            return true, { name = anchor.name, dx = anchor.dx, dy = anchor.dy }, nil
        end
    end
    return false, nil, "Unsupported relic anchor"
end

function Geometry.GetAnchor(name)
    local anchor = ANCHORS[name]
    if not anchor then return nil end
    return { name = anchor.name, dx = anchor.dx, dy = anchor.dy }
end

function Geometry.InferAnchor(refugeData, relicX, relicY)
    local bounds = Geometry.GetTileBounds(refugeData)
    if not bounds or relicX == nil or relicY == nil then return nil end

    for _, name in ipairs({ "Center", "Up", "Right", "Left", "Down" }) do
        local anchor = ANCHORS[name]
        local expectedX = bounds.centerX + anchor.dx * bounds.radius
        local expectedY = bounds.centerY + anchor.dy * bounds.radius
        if relicX == expectedX and relicY == expectedY then
            return { name = anchor.name, dx = anchor.dx, dy = anchor.dy }
        end
    end
    return nil
end

function Geometry.GetRelicTarget(refugeData, anchor)
    local bounds = Geometry.GetTileBounds(refugeData)
    if not bounds or not anchor then return nil, nil, nil end
    return bounds.centerX + anchor.dx * bounds.radius,
        bounds.centerY + anchor.dy * bounds.radius,
        refugeData.centerZ
end

function Geometry.PlanExpansion(refugeData, newRadius, anchor)
    if not refugeData or not anchor then return nil, "Missing expansion geometry" end
    newRadius = tonumber(newRadius)
    local oldRadius = tonumber(refugeData.radius) or 1
    if not newRadius or newRadius ~= newRadius or newRadius == math.huge or newRadius == -math.huge
        or newRadius <= oldRadius or newRadius ~= math.floor(newRadius)
    then
        return nil, "Invalid expansion radius"
    end

    local valid, canonical, anchorError = Geometry.ValidateAnchor(anchor.dx, anchor.dy, anchor.name)
    if not valid then return nil, anchorError end

    local oldOffsetX, oldOffsetY = Geometry.GetAreaOffset(refugeData)
    local delta = newRadius - oldRadius
    local candidate = copyRefugeData(refugeData)
    candidate.radius = newRadius
    candidate.areaOffsetX = oldOffsetX - canonical.dx * delta
    candidate.areaOffsetY = oldOffsetY - canonical.dy * delta

    return {
        candidate = candidate,
        anchor = canonical,
        oldBounds = Geometry.GetTileBounds(refugeData),
        newBounds = Geometry.GetTileBounds(candidate),
        oldRadius = oldRadius,
        newRadius = newRadius,
    }, nil
end

function Geometry.GetSlotKey(refugeData)
    if not refugeData or refugeData.centerX == nil or refugeData.centerY == nil then return nil end
    return tostring(refugeData.centerX) .. ":" .. tostring(refugeData.centerY)
end

function Geometry.GetMaximumDirectionalExtent()
    local minRadius, maxRadius = nil, nil
    for _, tier in pairs(Config.TIERS or {}) do
        local radius = tier and tonumber(tier.radius)
        if radius then
            if minRadius == nil or radius < minRadius then minRadius = radius end
            if maxRadius == nil or radius > maxRadius then maxRadius = radius end
        end
    end
    minRadius = minRadius or 1
    maxRadius = maxRadius or minRadius
    return maxRadius + (maxRadius - minRadius) + 1 -- include the positive-side wall line
end

local function assertInvariant(condition, message)
    if not condition then error("[MSR] Refuge geometry invariant failed: " .. message) end
end

function Geometry.ValidateConfiguration()
    local radii = {}
    for tier = 0, Config.MAX_TIER do
        local tierConfig = Config.TIERS[tier]
        if not tierConfig or not tierConfig.radius then
            error("[MSR] Refuge geometry invariant failed: missing tier " .. tostring(tier))
        end
        table.insert(radii, tierConfig.radius)
    end

    local centered = {
        centerX = 100,
        centerY = 100,
        centerZ = 0,
        radius = radii[1],
    }
    local centeredBounds = Geometry.GetTileBounds(centered)
    assertInvariant(centeredBounds.minX == 100 - radii[1], "legacy minX changed")
    assertInvariant(centeredBounds.maxX == 100 + radii[1], "legacy maxX changed")
    assertInvariant(centeredBounds.minY == 100 - radii[1], "legacy minY changed")
    assertInvariant(centeredBounds.maxY == 100 + radii[1], "legacy maxY changed")
    assertInvariant(
        Geometry.ContainsTile(centered, centeredBounds.maxX + 0.9, centeredBounds.maxY + 0.9),
        "fractional position on edge tile treated as outside"
    )
    assertInvariant(
        not Geometry.ContainsTile(centered, centeredBounds.maxX + 1, centeredBounds.maxY),
        "position beyond edge tile treated as inside"
    )

    for _, anchorName in ipairs({ "Center", "Up", "Right", "Left", "Down" }) do
        local current = copyRefugeData(centered)
        local anchor = Geometry.GetAnchor(anchorName)
        for index = 2, #radii do
            local relicX, relicY = Geometry.GetRelicTarget(current, anchor)
            local operation, expansionError = Geometry.PlanExpansion(current, radii[index], anchor)
            assertInvariant(operation ~= nil, expansionError or "expansion plan missing")
            current = operation.candidate
            local nextRelicX, nextRelicY = Geometry.GetRelicTarget(current, anchor)
            local bounds = Geometry.GetTileBounds(current)
            assertInvariant(relicX == nextRelicX and relicY == nextRelicY, anchorName .. " moved")
            assertInvariant(bounds.maxX - bounds.minX + 1 == radii[index] * 2 + 1, "width changed")
            assertInvariant(bounds.maxY - bounds.minY + 1 == radii[index] * 2 + 1, "height changed")
            assertInvariant(Geometry.IsInsideSlotEnvelope(current), anchorName .. " left its slot")
        end
    end

    local mixed = copyRefugeData(centered)
    local mixedAnchors = { "Up", "Right", "Center", "Left", "Down", "Up", "Right", "Left" }
    for index = 2, #radii do
        local operation = Geometry.PlanExpansion(mixed, radii[index], Geometry.GetAnchor(mixedAnchors[index - 1]))
        assertInvariant(operation ~= nil, "mixed expansion plan missing")
        mixed = operation.candidate
        local bounds = Geometry.GetTileBounds(mixed)
        assertInvariant(bounds.maxX - bounds.minX == bounds.maxY - bounds.minY, "mixed result is not square")
        assertInvariant(Geometry.IsInsideSlotEnvelope(mixed), "mixed result left its slot")
    end

    return true
end

function Geometry.IsInsideSlotEnvelope(refugeData)
    local bounds = Geometry.GetWallBounds(refugeData)
    if not bounds then return false end
    local halfSpacing = (tonumber(Config.REFUGE_SPACING) or 0) / 2
    return bounds.minX > refugeData.centerX - halfSpacing
        and bounds.maxX < refugeData.centerX + halfSpacing
        and bounds.minY > refugeData.centerY - halfSpacing
        and bounds.maxY < refugeData.centerY + halfSpacing
end

local maximumExtent = Geometry.GetMaximumDirectionalExtent()
if maximumExtent >= (Config.REFUGE_SPACING / 2) then
    error(string.format(
        "[MSR] Refuge tiers exceed slot spacing: extent=%s halfSpacing=%s",
        tostring(maximumExtent),
        tostring(Config.REFUGE_SPACING / 2)
    ))
end
Geometry.ValidateConfiguration()

return Geometry
