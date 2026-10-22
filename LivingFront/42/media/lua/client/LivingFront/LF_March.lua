-- Living Front: troop movements - a squad marching along a road in a tactical column.
--
-- LF.March.order(squad, x, y, z) plans a route to (x, y): from the road nearest the squad, along
-- the road (asphalt street tiles and the map's "Nav" road zones), to the road nearest the
-- destination, then on to the destination itself. With no road to follow it goes straight.
--
-- The column: a staggered file on both sides of the road, ~2.5 tiles between men, in order
--   Alpha 1, Alpha 2, the sergeant (in the centre), Bravo 1, Bravo 2
-- (a lone team: its four men). The head of the column walks along the route; every man walks to
-- his own place behind it. The head waits for anyone who falls behind.
-- Contact: the column halts and the squad fights as usual (LF_Tactics). Once it has been quiet
-- for ~10 s with no orders, the sergeant forms the column up again and marches on.
-- At the destination: "Halt!" - the squad stands in its usual formation, facing on.
--
-- Bodies only exist near the player, so a column only moves while you are near it.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Units"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Combat"

LF.March = LF.March or {}

local CFG = {
    spacing = 2.5,          -- tiles between men along the column
    lateral = 1.5,          -- each man this far left or right of the road's line, alternately
    step = 0.6,             -- the head moves this far per tactics update (~1.2 tiles/s)
    waitBehind = 5,         -- the head waits while anyone is further than this from his place
    roadSearch = 20,        -- look this far for the nearest road square
    searchMargin = 40,      -- route search box: start/goal bounding box plus this
    maxNodes = 25000,       -- give up the road search after this many squares
    nodeEvery = 3,          -- keep every n-th square of the road route as a waypoint
    arrive = 2.0,           -- a man within this of his final place has arrived
    resumeQuiet = 600,      -- form up again after ~10 s with no contact and no orders
    lead = 3,               -- a marching man walks toward a point this far ahead of his place
}
LF.March.CFG = CFG

local marches = {}          -- squad id -> march (runtime)
Events.OnInitGlobalModData.Add(function() marches = {} end)
function LF.March.forgetAll() marches = {} end
function LF.March.get(squadId) return marches[squadId] end
function LF.March.cancel(squadId) marches[squadId] = nil end

-- ---- roads ----------------------------------------------------------------------------------

local function isRoad(sq)
    if not sq then return false end
    local f = sq:getFloor()
    local spr = f and f:getSprite()
    local name = spr and spr:getName()
    if name and (name:find("blends_street", 1, true) or name:find("street_", 1, true)) then return true end
    local zt = sq:getZoneType()
    return zt == "Nav"
end
LF.March.isRoad = isRoad

local function key(x, y) return x * 100000 + y end

-- The road square nearest (x, y) within CFG.roadSearch: x, y or nil.
local function nearestRoad(x, y, z)
    local cell = getCell()
    local bx, by = math.floor(x), math.floor(y)
    for r = 0, CFG.roadSearch do
        local best, bd = nil, math.huge
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local sq = cell:getGridSquare(bx + dx, by + dy, z)
                    if isRoad(sq) then
                        local d = dx * dx + dy * dy
                        if d < bd then best, bd = { bx + dx, by + dy }, d end
                    end
                end
            end
        end
        if best then return best[1], best[2] end
    end
    return nil
end

local N8 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

-- Breadth-first search over road squares from (sx, sy) to (gx, gy). Returns a list of squares
-- { x, y } from start to goal, or nil.
local function roadRoute(sx, sy, gx, gy, z)
    local cell = getCell()
    local minX, maxX = math.min(sx, gx) - CFG.searchMargin, math.max(sx, gx) + CFG.searchMargin
    local minY, maxY = math.min(sy, gy) - CFG.searchMargin, math.max(sy, gy) + CFG.searchMargin
    local prev = { [key(sx, sy)] = -1 }
    local qx, qy = { sx }, { sy }
    local head, n = 1, 0
    local goal = key(gx, gy)
    while head <= #qx do
        local x, y = qx[head], qy[head]
        head = head + 1
        n = n + 1
        if n > CFG.maxNodes then return nil end
        if key(x, y) == goal then
            local out = {}
            local k = goal
            while k and k ~= -1 do
                local px, py = math.floor(k / 100000), k % 100000
                table.insert(out, 1, { x = px, y = py })
                k = prev[k]
            end
            return out
        end
        for _, d in ipairs(N8) do
            local nx, ny = x + d[1], y + d[2]
            local k = key(nx, ny)
            if not prev[k] and nx >= minX and nx <= maxX and ny >= minY and ny <= maxY then
                if isRoad(cell:getGridSquare(nx, ny, z)) then
                    prev[k] = key(x, y)
                    qx[#qx + 1], qy[#qy + 1] = nx, ny
                end
            end
        end
    end
    return nil
end

-- ---- the route --------------------------------------------------------------------------------

-- Cumulative lengths of a polyline.
local function measure(pts)
    local s = { 0 }
    for i = 2, #pts do s[i] = s[i - 1] + LF.dist(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y) end
    return s
end

-- The point s tiles along the route and the direction of travel there: x, y, dx, dy.
local function pointAt(M, s)
    local pts, len = M.pts, M.len
    if s <= 0 then
        local dx, dy = pts[2].x - pts[1].x, pts[2].y - pts[1].y
        local l = math.max(0.01, math.sqrt(dx * dx + dy * dy))
        return pts[1].x, pts[1].y, dx / l, dy / l
    end
    for i = 2, #pts do
        if s <= len[i] or i == #pts then
            local seg = math.max(0.01, len[i] - len[i - 1])
            local t = math.min(1, (s - len[i - 1]) / seg)
            local dx, dy = pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y
            local l = math.max(0.01, math.sqrt(dx * dx + dy * dy))
            return pts[i - 1].x + dx * t, pts[i - 1].y + dy * t, dx / l, dy / l
        end
    end
end

-- The column, in order: Alpha 1, Alpha 2, the sergeant, Bravo 1, Bravo 2 (living men only).
local function columnOrder(squad)
    local order = {}
    local function addTeam(slot)
        for _, tid in ipairs(squad.teams) do
            local team = LF.Units.get(tid)
            if team and team.slot == slot then
                for _, rid in ipairs(team.members) do
                    local r = LF.Records.get(rid)
                    if r and r.alive and r.team == tid then order[#order + 1] = rid end
                end
            end
        end
    end
    addTeam(1); addTeam(2)
    if squad.leader then
        local r = LF.Records.get(squad.leader)
        if r and r.alive then order[#order + 1] = squad.leader end
    end
    addTeam(3); addTeam(4)
    return order
end

-- Order a squad to march to (x, y). Returns true if it could plan a route.
function LF.March.order(squad, x, y, z)
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    if not cmd then return false, "its commander isn't here" end
    z = math.floor(z or 0)
    local cx, cy = cmd:getX(), cmd:getY()
    local pts = { { x = cx, y = cy } }
    local how = "straight (no road)"
    local rsx, rsy = nearestRoad(cx, cy, z)
    local rgx, rgy = nearestRoad(x, y, z)
    if rsx and rgx then
        local route = roadRoute(rsx, rsy, rgx, rgy, z)
        if route then
            for i = 1, #route, CFG.nodeEvery do pts[#pts + 1] = { x = route[i].x + 0.5, y = route[i].y + 0.5 } end
            local last = route[#route]
            pts[#pts + 1] = { x = last.x + 0.5, y = last.y + 0.5 }
            how = "by road (" .. #route .. " squares)"
        end
    end
    pts[#pts + 1] = { x = x + 0.5, y = y + 0.5 }
    -- Drop points on top of each other.
    local clean = { pts[1] }
    for i = 2, #pts do
        if LF.dist(clean[#clean].x, clean[#clean].y, pts[i].x, pts[i].y) > 0.5 then clean[#clean + 1] = pts[i] end
    end
    if #clean < 2 then return false, "already there" end
    local M = { pts = clean, z = z, dest = { x = x + 0.5, y = y + 0.5 } }
    M.len = measure(clean)
    M.total = M.len[#clean]
    M.order = columnOrder(squad)
    M.head = (#M.order - 1) * CFG.spacing        -- the column unrolls from where the squad is
    M.started = LF.tick
    marches[squad.id] = M
    LF.log("MARCH " .. squad.name .. " to " .. math.floor(x) .. "," .. math.floor(y) .. ", "
        .. string.format("%.0f", M.total) .. " tiles " .. how .. ", " .. #M.order .. " men in column")
    if LF.Tactics and LF.Tactics.shout then LF.Tactics.shout(cid, "Column of route - on the road! Move out!") end
    return true
end

-- A man's place in the column: x, y, and the point he faces (ahead along the road). With lead,
-- the place a few tiles further on (so a walking man keeps walking instead of stopping and
-- starting as his place moves up the road).
local function placeOf(M, i, lead)
    local s = math.min(M.head, M.total) - (i - 1) * CFG.spacing
    if lead and M.head < M.total then s = math.min(s + lead, M.total - (i - 1) * CFG.spacing) end
    s = math.max(0, s)
    local x, y, dx, dy = pointAt(M, s)
    local side = (i % 2 == 1) and -1 or 1
    local lx, ly = -dy * side * CFG.lateral, dx * side * CFG.lateral
    return x + lx, y + ly, x + dx * 6, y + dy * 6
end

-- The brain asks where a marching man goes: "file", x, y, z, facePoint, "march" - or nil.
function LF.March.place(rec)
    local M = rec.squad and marches[rec.squad]
    if not M or M.halted then return nil end
    for i, rid in ipairs(M.order) do
        if rid == rec.id then
            local x, y, fx, fy = placeOf(M, i, CFG.lead)
            M.faces = M.faces or {}
            local f = M.faces[rid]
            if not f then f = LF.Tactics.point(fx, fy, M.z); M.faces[rid] = f end
            f.x, f.y = fx, fy
            return "file", x, y, M.z, f, "march"
        end
    end
    return nil
end

-- Each tactics update. Returns true while the column is marching (the squad's other orders wait).
function LF.March.update(squad, cid, cmd, contact, quietTicks)
    local M = marches[squad.id]
    if not M then return false end
    if contact then
        if not M.halted then
            M.halted = true
            LF.log("MARCH " .. squad.name .. ": contact - the column halts")
            LF.Tactics.shout(cid, "Contact! Off the road - take cover!")
        end
        return false
    end
    if M.halted then
        if (quietTicks or 0) < CFG.resumeQuiet then return false end
        M.halted = false
        M.order = columnOrder(squad)                -- the fallen are left out
        LF.log("MARCH " .. squad.name .. ": quiet again - forming up and marching on")
        LF.Tactics.shout(cid, "Form up on the road! Move out!")
    end
    -- Wait for anyone who has fallen behind; otherwise the head walks on.
    local behind, done = false, true
    for i, rid in ipairs(M.order) do
        local r = LF.Records.get(rid)
        local b = LF.Bodies.get(rid)
        if r and r.alive and b then
            local x, y = placeOf(M, i)
            local d = LF.dist(b:getX(), b:getY(), x, y)
            if d > CFG.waitBehind then behind = true end
            if d > CFG.arrive then done = false end
        end
    end
    if M.head < M.total then
        if not behind then M.head = math.min(M.total, M.head + CFG.step) end
        return true
    end
    if done then
        -- Arrived: halt, facing on along the last stretch.
        local _, _, dx, dy = pointAt(M, M.total)
        squad.facingX, squad.facingY = dx, dy
        marches[squad.id] = nil
        LF.log("MARCH " .. squad.name .. " arrived (" .. math.floor((LF.tick - M.started) / 60) .. " s)")
        LF.Tactics.shout(cid, "Halt! Take a breather - eyes open.")
        return false
    end
    return true
end
