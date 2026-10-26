-- Living Front: objectives on the map.
--
-- Every objective is drawn on the world map (M) and the minimap over its building's footprint -
-- its ground-floor rooms (LF_Objective) - tinted by who holds it:
--   Germans field grey-blue, Soviets red, contested amber (both sides inside), nobody yet pale yellow
-- with its name over it once you are zoomed in far enough to read it. Hovering over one on the
-- world map outlines it brightly and shows a label like the game's street names: its name and
-- what kind of building it is, who holds it, and which units are taking or holding it.
--
-- Right-click on the world map: on a building, make it an objective (or stop it being one) and
-- send any platoon or squad to take or hold it; anywhere, send them to patrol (or a platoon to
-- withdraw) there. Buildings anywhere on the map will do - far ones are found again properly as
-- the troops get near them.

require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"
require "LivingFront/Core/LF_Core"
require "LivingFront/Units/LF_Objective"
require "LivingFront/Tactics/LF_Platoon"
require "LivingFront/Units/LF_March"

LF.Map = LF.Map or {}

local CFG = {
    fill = 0.28,            -- alpha of the footprint
    hoverFill = 0.45,
    nameZoom = 14.5,        -- names show from this zoom in (the map's own zoom scale)
    nameZoomMini = 16,
    nameScale = 2,          -- names drawn at twice the small font
    trackers = true,        -- unit markers on the maps (for following off-screen fights)
    unitLabelZoom = 13.5,   -- unit names and status from this zoom in (world map)
}
LF.Map.CFG = CFG

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
    local fontB, font = UIFont.Large, UIFont.Medium
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

-- ---- unit trackers -----------------------------------------------------------------------------
-- Every squad and platoon headquarters, on- or off-screen: a marker where its men are (their
-- bodies, or their records off-screen), a thin line to where it is marching, and - zoomed in on
-- the world map - its name, fit men and what it is doing. Red outline: in a fight; amber: broken.

local function unitPos(u)
    local sx, sy, n, fit, total = 0, 0, 0, 0, 0
    for _, rid in ipairs(LF.Units.members(u.id)) do
        local r = LF.Records.get(rid)
        if r then
            total = total + 1
            if r.alive then
                local b = LF.Bodies.get(rid)
                local x, y = r.x, r.y
                if b and not b:isDead() then x, y = b:getX(), b:getY() end
                sx, sy, n = sx + x, sy + y, n + 1
                if not r.wounded then fit = fit + 1 end
            end
        end
    end
    if n == 0 then return nil end
    return sx / n, sy / n, fit, total, n
end

local function unitStatus(u)
    if u.offBroken and u.offBroken <= LF.simTime and LF.simTime - u.offBroken < 120 then return "broken", "broken" end
    if LF.Clash and LF.Clash.inContact(u) then return "fighting", "fighting" end
    local t = u.objTask
    if t and t.kind == "take" then return "taking (" .. tostring(t.phase) .. ")" end
    local M = LF.March.get(u.id)
    if M and not M.arrived then return M.halted and "halted on the march" or "moving" end
    if t and t.kind == "hold" then return "holding" end
    if u.platoonTask and u.platoonTask ~= "patrol" then return u.platoonTask end
    return u.stance or ""
end

local function shortName(u)
    local n = u.name or "?"
    n = n:gsub(" platoon (%d+) / ", " P%1/"):gsub(" platoon (%d+) HQ", " P%1 HQ"):gsub(" squad", "")
    return n
end

local function drawUnits(ui, api, mini)
    local zoom = api:getZoomF()
    local labels = not mini and zoom >= CFG.unitLabelZoom
    local font = UIFont.Small
    local tm = getTextManager()
    for _, u in pairs(LF.Units.all()) do
        if ((u.kind == "squad" and not u.joined) or u.kind == "hq") then
            local wx, wy, fit, total, alive = unitPos(u)
            if wx then
                local c = COLORS[u.faction] or COLORS.none
                local sx, sy = api:worldToUIX(wx, wy), api:worldToUIY(wx, wy)
                -- Where it is marching.
                local M = LF.March.get(u.id)
                if M and not M.arrived and M.x and not mini then
                    local dx, dy = api:worldToUIX(M.x, M.y), api:worldToUIY(M.x, M.y)
                    line(ui, sx, sy, dx, dy, 1, c[1], c[2], c[3], 0.55)
                end
                local word, flag = unitStatus(u)
                local h = u.kind == "hq" and 3 or 4
                ui:drawRect(sx - h, sy - h, h * 2, h * 2, 0.95, c[1], c[2], c[3])
                local br, bg, bb = 0, 0, 0
                if flag == "fighting" then br, bg, bb = 1, 0.15, 0.1 elseif flag == "broken" then br, bg, bb = 1, 0.7, 0.1 end
                ui:drawRectBorder(sx - h - 1, sy - h - 1, h * 2 + 2, h * 2 + 2, 1, br, bg, bb)
                if labels then
                    local text = shortName(u) .. "  " .. fit .. "/" .. total .. (word ~= "" and ("  " .. word) or "")
                    local fh = tm:getFontHeight(font)
                    ui:drawText(text, sx + h + 4, sy - fh / 2 + 1, 0, 0, 0, 0.8, font)
                    ui:drawText(text, sx + h + 3, sy - fh / 2, c[1], c[2], c[3], 1, font)
                end
            end
        end
    end
end

-- Draw every objective on a map UI (world map or minimap), and the unit trackers.
local function drawAll(ui, api, mini)
    if CFG.trackers then LF.guard("map units", drawUnits, ui, api, mini) end
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
                local font, k = UIFont.Small, CFG.nameScale
                local tx = sx - tm:MeasureStringX(font, obj.name) * k / 2
                local ty = sy - tm:getFontHeight(font) * k / 2
                ui:drawTextZoomed(obj.name, tx + 1, ty + 1, k, 0, 0, 0, 0.8, font)
                ui:drawTextZoomed(obj.name, tx, ty, k, c[1], c[2], c[3], 1, font)
            end
        end
    end
    if hovered then
        local sx, sy = centre(api, hovered)
        label(ui, detailLines(hovered), sx, sy, colorOf(hovered))
    end
    ui.lfHoveredObjective = hovered
end

-- ---- orders from the map ----------------------------------------------------------------------

local function sub(menu, label)
    local o = menu:addOption(label)
    local m = ISContextMenu:getNew(menu)
    menu:addSubMenu(o, m)
    return m
end

local function kindWord(obj, def)
    if obj then return obj.kind or "building" end
    return def and "building" or nil
end

-- Add the Living Front options for world point (wx, wy) to a context menu.
local function addMapOptions(ctx, wx, wy)
    local z = 0
    local x, y = math.floor(wx), math.floor(wy)
    local obj = LF.Objective.atPoint(x, y)
    local def = not obj and LF.Objective.metaDefAt(x, y)
    local isBuilding = obj ~= nil or def ~= nil
    -- The objective here, made if need be.
    local function objective()
        if obj then return obj end
        local o, why = LF.Objective.create(x, y, z)
        if not o then LF.say("Can't: " .. tostring(why)); return nil end
        obj = o
        return o
    end
    local head = obj and (obj.name .. " - " .. kindWord(obj) .. ", " .. holderWords(obj):lower())
        or (isBuilding and "Living Front: this building" or "Living Front: here")
    local lf = sub(ctx, head)
    if obj then
        local id = obj.id
        lf:addOption("Stop this being an objective", nil, function() LF.Objective.remove(id); LF.say("No longer an objective") end)
    elseif isBuilding then
        lf:addOption("Make this building an objective", nil, function()
            local o = objective()
            if o then LF.say(o.name .. " - " .. (o.kind or "building")) end
        end)
    end
    local O = LF.Debug and LF.Debug.orders
    if not O then return end
    local where = isBuilding and "this building" or "here"
    local plists = O.platoonList(x, y)
    for _, f in ipairs({ { "GER", "German platoons" }, { "SOV", "Soviet platoons" } }) do
        local list = plists[f[1]]
        if list and #list > 0 then
            local fm = sub(lf, f[2])
            for _, e in ipairs(list) do
                local plt = e.p
                local pm = sub(fm, LF.Platoon.describe(plt) .. string.format(" (%d tiles)", math.floor(e.d)))
                if isBuilding then
                    pm:addOption("Take " .. where, nil, function()
                        local o = objective()
                        if not o then return end
                        local ok, why = LF.Platoon.take(plt, o)
                        LF.say(ok and (plt.name .. " moves to take " .. o.name) or ("Can't: " .. tostring(why)))
                    end)
                    pm:addOption("Hold " .. where, nil, function()
                        local o = objective()
                        if not o then return end
                        local ok, why = LF.Platoon.hold(plt, o)
                        LF.say(ok and (plt.name .. " holds " .. o.name) or ("Can't: " .. tostring(why)))
                    end)
                end
                pm:addOption("Patrol " .. where, nil, function()
                    local ok, why = LF.Platoon.patrol(plt, x, y, z)
                    LF.say(ok and (plt.name .. " patrols there") or ("Can't: " .. tostring(why)))
                end)
                pm:addOption("Withdraw to " .. where, nil, function()
                    LF.Platoon.withdraw(plt, x, y, z, "ordered from the map")
                    LF.say(plt.name .. " withdraws")
                end)
            end
        end
    end
    local lists = O.unitList(x, y)
    for _, f in ipairs({ { "GER", "German squads" }, { "SOV", "Soviet squads" } }) do
        local list = lists[f[1]]
        if list and #list > 0 then
            local fm = sub(lf, f[2])
            for _, e in ipairs(list) do
                local u = e.u
                local um = sub(fm, string.format("%s (%d/%d, %d tiles)", u.name, e.n, e.total, math.floor(e.d)))
                if isBuilding then
                    um:addOption("Take " .. where, nil, function()
                        local o = objective()
                        if o then O.takeOf(u, x, y, z, o) end
                    end)
                    um:addOption("Hold " .. where, nil, function()
                        local o = objective()
                        if o then O.holdOf(u, x, y, z, o) end
                    end)
                end
                um:addOption("Patrol " .. where, nil, function() O.patrolOf(u, x, y, z, "auto") end)
            end
        end
    end
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

-- Right-click: the game's own menu (debug mode has one), with ours added to it.
local rightUp = ISWorldMap.onRightMouseUp
function ISWorldMap:onRightMouseUp(x, y)
    if self.symbolsUI and self.symbolsUI:onRightMouseUpMap(x, y) then return true end
    local handled = rightUp(self, x, y)
    if not getSpecificPlayer(0) then return handled end
    local wx, wy = self.mapAPI:uiToWorldX(x, y), self.mapAPI:uiToWorldY(x, y)
    local ctx = nil
    if handled and getPlayerContextMenu then
        local ok, c = pcall(getPlayerContextMenu, 0)
        if ok and c and c:isVisible() then ctx = c end
    end
    if not ctx then ctx = ISContextMenu.get(0, x + self:getAbsoluteX(), y + self:getAbsoluteY()) end
    LF.guard("map orders", addMapOptions, ctx, wx, wy)
    return true
end

if ISMiniMapInner then
    local miniPrerender = ISMiniMapInner.prerender
    function ISMiniMapInner:prerender()
        miniPrerender(self)
        if self.mapAPI then LF.guard("minimap objectives", drawAll, self, self.mapAPI, true) end
    end
end
