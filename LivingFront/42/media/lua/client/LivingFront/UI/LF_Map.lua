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
require "ISUI/ISButton"
require "LivingFront/Core/LF_Core"
require "LivingFront/Units/LF_Objective"
require "LivingFront/Tactics/LF_Platoon"
require "LivingFront/Units/LF_March"
require "LivingFront/World/LF_Front"

LF.Map = LF.Map or {}

local CFG = {
    fill = 0.28,            -- alpha of the footprint
    hoverFill = 0.45,
    nameZoom = 14.5,        -- names show from this zoom in (the map's own zoom scale)
    nameZoomMini = 16,
    nameScale = 2,          -- names drawn at twice the small font
    trackers = true,        -- unit markers on the maps (for following off-screen fights)
    unitLabelZoom = 13.5,   -- unit names and status from this zoom in (world map)
    platoonPicture = false, -- what each lieutenant believes of his squads, beside where they really are
    revealAll = false,      -- show the whole map, not just where you have been (debug tools)
    mapRuns = true,         -- the game keeps running while the world map is open (debug tools)
    warView = "truth",      -- the front on the map: "truth", "GER" / "SOV" (what that side believes), "off"
    sectorFill = 0.10,
    frontWidth = 3,
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

-- The side whose picture the map shows (nil: the truth).
local function viewSide()
    local v = CFG.warView
    return (v == "GER" or v == "SOV") and v or nil
end

-- An objective as the map shows it: the truth, or - in a side's view - what that side believes
-- (who holds it, its name), with only that side's units listed.
local function asViewed(obj)
    local side = viewSide()
    if not side or not LF.Front then return obj end
    local b = LF.Front.objectiveBelief(side, obj.id)
    local v = setmetatable({}, { __index = obj })
    v.lfReal = obj
    -- (false, not nil: a nil would fall through to the real objective and show the truth.)
    v.holder = b and b.holder or false
    v.contested = b and b.contested or false
    v.name = b and b.name or obj.name
    return v
end

local function detailLines(obj)
    local lines = { obj.name .. (obj.kind and (" - " .. obj.kind) or ""), holderWords(obj) }
    local side = viewSide()
    for _, t in ipairs(LF.Objective.tasked(obj.lfReal or obj)) do
        if not side or t.unit.faction == side then
            lines[#lines + 1] = t.unit.name .. ": " .. t.words
        end
    end
    if side then
        local b = LF.Front and LF.Front.objectiveBelief(side, (obj.lfReal or obj).id)
        local mins = b and math.floor((LF.simTime - b.at) / 60) or nil
        if mins and mins >= 1 then lines[#lines + 1] = "(as last seen " .. mins .. " min ago)" end
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
    local side = viewSide()
    for _, u in pairs(LF.Units.all()) do
        -- (In a side's view only its own units: the enemy is where its sightings say.)
        if ((u.kind == "squad" and not u.joined) or u.kind == "hq") and (not side or u.faction == side) then
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

-- ---- the front ---------------------------------------------------------------------------------------
-- Sectors tinted by who holds them (or, in a side's view, who that side believes holds them), the
-- front line between the two, and - in a side's view - its sightings of the enemy, faded by age.

local VIEW_WORDS = { truth = "The front as it really is", GER = "What the Germans believe", SOV = "What the Soviets believe" }
LF.Map.VIEW_WORDS = VIEW_WORDS

local function drawFront(ui, api, mini)
    local view = CFG.warView
    if view == "off" or not LF.Front then return end
    local side = (view == "GER" or view == "SOV") and view or nil
    -- Sectors: the ground round each objective, tinted by who holds it (in this view).
    local own = LF.Front.owners(side or "truth")
    local runs, edges = LF.Front.shapes()
    for _, r in ipairs(runs) do
        local o = own[r.key]
        local c = o and (COLORS[o] or (o == "contested" and COLORS.contested)) or nil
        if c then
            local x1, y1, x2, y2, x3, y3, x4, y4 = corners(api, r.x1, r.y1, r.x2, r.y2)
            local a = o == "contested" and CFG.sectorFill * 1.6 or CFG.sectorFill
            ui:drawPolygon(nil, x1, y1, x2, y2, x3, y3, x4, y4, c[1], c[2], c[3], a)
        end
    end
    -- Borders between sectors, faint (the front line is drawn over them).
    if not mini then
        for _, e in ipairs(edges) do
            local ax, ay = api:worldToUIX(e.x1, e.y1), api:worldToUIY(e.x1, e.y1)
            local bx, by = api:worldToUIX(e.x2, e.y2), api:worldToUIY(e.x2, e.y2)
            line(ui, ax, ay, bx, by, 1, 1, 1, 1, 0.25)
        end
    end
    -- The front line.
    local w = mini and 2 or CFG.frontWidth
    for _, e in ipairs(LF.Front.line(side or "truth")) do
        local ax, ay = api:worldToUIX(e[1], e[2]), api:worldToUIY(e[1], e[2])
        local bx, by = api:worldToUIX(e[3], e[4]), api:worldToUIY(e[3], e[4])
        line(ui, ax, ay, bx, by, w + 2, 0, 0, 0, 0.7)
        line(ui, ax, ay, bx, by, w, 1, 0.95, 0.85, 0.95)
    end
    if mini then return end
    -- A side's sightings of the enemy: hollow markers, fading as the news gets old.
    if side then
        local enemy = LF.Front.ENEMY[side]
        local c = COLORS[enemy]
        local labels = api:getZoomF() >= CFG.unitLabelZoom
        local tm = getTextManager()
        local fh = tm:getFontHeight(UIFont.Small)
        for _, sgt in pairs(LF.Front.sightings(side)) do
            local age = LF.simTime - sgt.at
            local a = math.max(0.25, 1 - age / LF.Front.CFG.forget)
            local sx, sy = api:worldToUIX(sgt.x, sgt.y), api:worldToUIY(sgt.x, sgt.y)
            line(ui, sx, sy - 6, sx + 6, sy, 2, c[1], c[2], c[3], a)
            line(ui, sx + 6, sy, sx, sy + 6, 2, c[1], c[2], c[3], a)
            line(ui, sx, sy + 6, sx - 6, sy, 2, c[1], c[2], c[3], a)
            line(ui, sx - 6, sy, sx, sy - 6, 2, c[1], c[2], c[3], a)
            if labels then
                local mins = math.floor(age / 60)
                local text = "~" .. sgt.men .. "  " .. (mins < 1 and "now" or (mins .. " min ago"))
                ui:drawText(text, sx + 10, sy - fh / 2 + 1, 0, 0, 0, 0.8 * a, UIFont.Small)
                ui:drawText(text, sx + 9, sy - fh / 2, c[1], c[2], c[3], a, UIFont.Small)
            end
        end
    end
    -- Which view this is.
    local title = VIEW_WORDS[view] or ""
    ui:drawText(title, 21, 61, 0, 0, 0, 0.8, UIFont.Medium)
    ui:drawText(title, 20, 60, 1, 1, 1, 1, UIFont.Medium)
end

-- What each lieutenant believes of his squads: a hollow square where he thinks each is, with how
-- old his news is, and a thin line to where the squad really is.
local function drawPictures(ui, api)
    local labels = api:getZoomF() >= CFG.unitLabelZoom
    local tm = getTextManager()
    local fh = tm:getFontHeight(UIFont.Small)
    local side = viewSide()
    for _, p in pairs(LF.Units.all()) do
        if p.kind == "platoon" and p.known and (not side or p.faction == side) then
            local c = COLORS[p.faction] or COLORS.none
            for sid, k in pairs(p.known) do
                local sq = LF.Units.get(sid)
                if sq and k.x then
                    local sx, sy = api:worldToUIX(k.x, k.y), api:worldToUIY(k.x, k.y)
                    local tx, ty = unitPos(sq)
                    if tx then
                        line(ui, sx, sy, api:worldToUIX(tx, ty), api:worldToUIY(tx, ty), 1, 1, 1, 1, 0.35)
                    end
                    ui:drawRectBorder(sx - 6, sy - 6, 12, 12, 1, c[1], c[2], c[3])
                    ui:drawRectBorder(sx - 5, sy - 5, 10, 10, 1, 1, 1, 1)
                    if labels then
                        local age = math.floor(LF.simTime - (k.at or LF.simTime))
                        local what = k.broken and "broken" or (k.contact and "in contact") or (k.holding and "holding")
                            or (k.arrived == false and "on the move") or (k.task or "")
                        local text = shortName(sq) .. "  " .. tostring(k.fit or "?") .. "/" .. tostring(k.total or "?")
                            .. "  " .. what .. "  (" .. (age < 2 and "seen now" or (age .. " s old")) .. ")"
                        ui:drawText(text, sx + 10, sy + 4, 0, 0, 0, 0.8, UIFont.Small)
                        ui:drawText(text, sx + 9, sy + 3, 1, 1, 1, 0.9, UIFont.Small)
                    end
                end
            end
        end
    end
end

-- Draw every objective on a map UI (world map or minimap), and the unit trackers.
local function drawAll(ui, api, mini)
    LF.guard("map front", drawFront, ui, api, mini)
    if CFG.trackers then LF.guard("map units", drawUnits, ui, api, mini) end
    if CFG.platoonPicture and not mini then LF.guard("map pictures", drawPictures, ui, api) end
    local list = {}
    local any = false
    for id, obj in pairs(LF.Objective.all()) do list[id] = asViewed(obj); any = true end
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
    ui.lfHoveredObjective = hovered and (hovered.lfReal or hovered) or nil
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

-- ---- the map as a commander's map: the whole of it, the game running, time at your command ----------

local SPEEDS = { { 0, "Pause" }, { 1, "1x" }, { 2, "5x" }, { 3, "20x" }, { 4, "40x" } }

local function setSpeed(n)
    pcall(function() setGameSpeed(n) end)
    pcall(function() UIManager.getSpeedControls():SetCurrentGameSpeed(n) end)
end

local function applyReveal(map)
    if map and map.setHideUnvisitedAreas then pcall(function() map:setHideUnvisitedAreas(not CFG.revealAll) end) end
end
function LF.Map.setRevealAll(on)
    CFG.revealAll = on
    if ISWorldMap_instance then applyReveal(ISWorldMap_instance) end
end

-- (The game pauses while the map is open only if this says so.)
local shouldPause = ISWorldMap.shouldPause
function ISWorldMap.shouldPause()
    if CFG.mapRuns then return false end
    return shouldPause()
end

local showMap = ISWorldMap.ShowWorldMap
function ISWorldMap.ShowWorldMap(...)
    showMap(...)
    if CFG.revealAll then applyReveal(ISWorldMap_instance) end
end

-- Speed buttons along the top of the world map.
local function speedButtons(map)
    if map.lfSpeedButtons then return map.lfSpeedButtons end
    local list = {}
    local x = 20
    for _, s in ipairs(SPEEDS) do
        local n = s[1]
        local b = ISButton:new(x, 92, 54, 22, s[2], map, function() setSpeed(n) end)
        b:initialise()
        b:instantiate()
        b.lfSpeed = n
        map:addChild(b)
        list[#list + 1] = b
        x = x + 58
    end
    map.lfSpeedButtons = list
    return list
end

local function updateSpeedButtons(map)
    local cur = getGameSpeed()
    for _, b in ipairs(speedButtons(map)) do
        local on = b.lfSpeed == cur
        b.backgroundColor = on and { r = 0.25, g = 0.45, b = 0.25, a = 0.9 } or { r = 0, g = 0, b = 0, a = 0.6 }
        b:bringToTop()
    end
end

-- ---- hooks -------------------------------------------------------------------------------------

local worldPrerender = ISWorldMap.prerender
function ISWorldMap:prerender()
    worldPrerender(self)
    LF.guard("map objectives", drawAll, self, self.mapAPI, false)
    LF.guard("map speed", updateSpeedButtons, self)
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
        if CFG.revealAll and self.mapAPI and not self.lfRevealed then
            self.lfRevealed = true
            pcall(function() self.mapAPI:setBoolean("HideUnvisited", false) end)
        elseif not CFG.revealAll and self.lfRevealed then
            self.lfRevealed = nil
            pcall(function() self.mapAPI:setBoolean("HideUnvisited", true) end)
        end
        if self.mapAPI then LF.guard("minimap objectives", drawAll, self, self.mapAPI, true) end
    end
end
