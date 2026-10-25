-- Living Front: objectives on the map.
--
-- Every objective is drawn on the world map (M) and the minimap over its building's footprint -
-- its ground-floor rooms (LF_Objective) - tinted by who holds it:
--   Germans field grey-blue, Soviets red, contested amber (both sides inside), nobody yet pale yellow
-- with its name over it once you are zoomed in far enough to read it. Hovering over one on the
-- world map outlines it brightly and shows a label like the game's street names: its name and
-- what kind of building it is, who holds it, and which units are taking or holding it.

require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"
require "LivingFront/Core/LF_Core"
require "LivingFront/Units/LF_Objective"

LF.Map = LF.Map or {}

local CFG = {
    fill = 0.28,            -- alpha of the footprint
    hoverFill = 0.45,
    nameZoom = 14.5,        -- names show from this zoom in (the map's own zoom scale)
    nameZoomMini = 16,
}

local COLORS = {
    GER = { 0.55, 0.65, 0.82 },
    SOV = { 0.85, 0.25, 0.22 },
    contested = { 0.95, 0.62, 0.15 },
    none = { 0.95, 0.90, 0.45 },
}

local function colorOf(obj)
    if obj.contested then return COLORS.contested end
    return COLORS[obj.holder or ""] or COLORS.none
end

local function holderWords(obj)
    if obj.contested then return "Contested" end
    local F = LF.Objective.FACTION or {}
    if obj.holder then return "Held by the " .. (F[obj.holder] or obj.holder) end
    return "Not held by anyone"
end

-- The four screen corners of a map rectangle (the map can be drawn isometric, so not a box).
local function corners(api, x1, y1, x2, y2)
    return api:worldToUIX(x1, y1), api:worldToUIY(x1, y1), api:worldToUIX(x2, y1), api:worldToUIY(x2, y1),
        api:worldToUIX(x2, y2), api:worldToUIY(x2, y2), api:worldToUIX(x1, y2), api:worldToUIY(x1, y2)
end

local function line(ui, ax, ay, bx, by, w, r, g, b, a)
    ui.javaObject:DrawLine(nil, ax, ay, bx, by, w, r, g, b, a)
end

-- Is the point (px, py) inside the quad?
local function inQuad(px, py, q)
    local inside = false
    local j = 4
    for i = 1, 4 do
        local xi, yi, xj, yj = q[i * 2 - 1], q[i * 2], q[j * 2 - 1], q[j * 2]
        if (yi > py) ~= (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi then inside = not inside end
        j = i
    end
    return inside
end

-- Draw one objective; returns true if the mouse (mx, my) is over it.
local function drawObjective(ui, api, obj, mx, my, hovered)
    local c = colorOf(obj)
    local over = false
    local fill = hovered and CFG.hoverFill or CFG.fill
    local rects = obj.rects
    if not rects then
        -- (An objective from before 0.52, or one whose building was never loaded: a box round it.)
        rects = { { math.floor(obj.x) - 4, math.floor(obj.y) - 4, 8, 8 } }
    end
    for _, r in ipairs(rects) do
        local x1, y1, x2, y2, x3, y3, x4, y4 = corners(api, r[1], r[2], r[1] + r[3], r[2] + r[4])
        ui:drawPolygon(nil, x1, y1, x2, y2, x3, y3, x4, y4, c[1], c[2], c[3], fill)
        if mx and inQuad(mx, my, { x1, y1, x2, y2, x3, y3, x4, y4 }) then over = true end
    end
    -- Its outline: the bounds (bright white when hovered).
    local b = obj.bounds or { rects[1][1], rects[1][2], rects[1][1] + rects[1][3], rects[1][2] + rects[1][4] }
    local x1, y1, x2, y2, x3, y3, x4, y4 = corners(api, b[1], b[2], b[3], b[4])
    local w = hovered and 2 or 1
    local lr, lg, lb, la = c[1], c[2], c[3], 0.9
    if hovered then lr, lg, lb, la = 1, 1, 1, 1 end
    line(ui, x1, y1, x2, y2, w, lr, lg, lb, la)
    line(ui, x2, y2, x3, y3, w, lr, lg, lb, la)
    line(ui, x3, y3, x4, y4, w, lr, lg, lb, la)
    line(ui, x4, y4, x1, y1, w, lr, lg, lb, la)
    return over
end

local function centre(api, obj)
    local cx, cy = obj.x, obj.y
    if obj.bounds then cx, cy = (obj.bounds[1] + obj.bounds[3]) / 2, (obj.bounds[2] + obj.bounds[4]) / 2 end
    return api:worldToUIX(cx, cy), api:worldToUIY(cx, cy), cx, cy
end

-- The hover label: a box with the game's street-name look (a tab at each end).
local function label(ui, lines, sx, sy, c)
    local tm = getTextManager()
    local fontB, font = UIFont.Medium, UIFont.Small
    local hB, h = tm:getFontHeight(fontB), tm:getFontHeight(font)
    local wid = 0
    for i, t in ipairs(lines) do wid = math.max(wid, tm:MeasureStringX(i == 1 and fontB or font, t)) end
    local rh = hB + (#lines - 1) * h + 8
    local rw = wid + 16
    local rx, ry = math.floor(sx - rw / 2), math.floor(sy - rh - 14)
    local r, g, b = c[1] * 0.45, c[2] * 0.45, c[3] * 0.45
    ui:drawRect(rx, ry, rw, rh, 0.92, r, g, b)
    ui:drawPolygon(nil, rx, ry, rx, ry + rh, rx - rh / 4, ry + rh * 2 / 3, rx - rh / 4, ry + rh / 3, r, g, b, 0.92)
    ui:drawPolygon(nil, rx + rw, ry, rx + rw, ry + rh, rx + rw + rh / 4, ry + rh * 2 / 3, rx + rw + rh / 4, ry + rh / 3, r, g, b, 0.92)
    local y = ry + 4
    for i, t in ipairs(lines) do
        ui:drawTextCentre(t, sx, y, 1, 1, 1, i == 1 and 1 or 0.85, i == 1 and fontB or font)
        y = y + (i == 1 and hB or h)
    end
end

local function detailLines(obj)
    local lines = { obj.name .. (obj.kind and (" - " .. obj.kind) or ""), holderWords(obj) }
    for _, t in ipairs(LF.Objective.tasked(obj)) do
        lines[#lines + 1] = t.unit.name .. ": " .. t.words
    end
    return lines
end

-- Draw every objective on a map UI (world map or minimap).
local function drawAll(ui, api, mini)
    local list = LF.Objective.all()
    local any = false
    for _ in pairs(list) do any = true; break end
    if not any then return end
    local mx, my = nil, nil
    if not mini and ui:isMouseOver() and not ui:isMouseOverChild() then mx, my = ui:getMouseX(), ui:getMouseY() end
    local zoom = api:getZoomF()
    -- Footprints first, finding the one under the mouse; then that one again, highlighted.
    local hovered = nil
    for _, obj in pairs(list) do
        if drawObjective(ui, api, obj, mx, my, false) then hovered = obj end
    end
    if hovered then drawObjective(ui, api, hovered, nil, nil, true) end
    -- Names, zoomed in far enough.
    local tm = getTextManager()
    if zoom >= (mini and CFG.nameZoomMini or CFG.nameZoom) then
        for _, obj in pairs(list) do
            if obj ~= hovered then
                local sx, sy = centre(api, obj)
                local c = colorOf(obj)
                local font = UIFont.Small
                ui:drawTextCentre(obj.name, sx + 1, sy - tm:getFontHeight(font) / 2 + 1, 0, 0, 0, 0.8, font)
                ui:drawTextCentre(obj.name, sx, sy - tm:getFontHeight(font) / 2, c[1], c[2], c[3], 1, font)
            end
        end
    end
    if hovered then
        local sx, sy = centre(api, hovered)
        label(ui, detailLines(hovered), sx, sy, colorOf(hovered))
    end
    ui.lfHoveredObjective = hovered
end

-- ---- hooks -------------------------------------------------------------------------------------

local worldPrerender = ISWorldMap.prerender
function ISWorldMap:prerender()
    worldPrerender(self)
    LF.guard("map objectives", drawAll, self, self.mapAPI, false)
end

-- (A hovered objective takes the place of the street name under the mouse.)
local pickStreet = ISWorldMap.pickMouseOverStreet
function ISWorldMap:pickMouseOverStreet()
    pickStreet(self)
    if self.lfHoveredObjective then
        pcall(function() self.mapAPI:getStreetsAPI():setMouseOverStreet(nil, 0.0, 0.0) end)
    end
end

if ISMiniMapInner then
    local miniPrerender = ISMiniMapInner.prerender
    function ISMiniMapInner:prerender()
        miniPrerender(self)
        if self.mapAPI then LF.guard("minimap objectives", drawAll, self, self.mapAPI, true) end
    end
end
