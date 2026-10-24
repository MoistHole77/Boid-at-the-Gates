-- Living Front: troop movements - patrolling in a tactical formation.
--
-- LF.March.order(squad, x, y, z, form) puts the unit in the patrolling stance and moves it to
-- (x, y) in a formation: ranger file or tactical column (by road where there is one: asphalt
-- street tiles and the map's "Nav" road zones, then on to the spot) or wedge (straight across
-- country). The point man sets off; every other man waits where he is and falls into his place
-- as it comes up to him. The point man is the base: the formation moves at his pace and doesn't
-- wait for anyone; a man who has dropped behind walks at the normal pace until he is back in his
-- place. A tactical column walks one file along each edge of the road (each man 0-0.5 tiles in).
-- Patrol pace is the aimed (ADS) walk at its own speed (LF.Move.PATROL_PACE), always, and now and then a man
-- brings his rifle up and scans his outboard side without stopping.
-- Contact: the patrol halts and the unit fights as usual (LF_Tactics, offensive rules). Once it
-- has been quiet for ~10 s it sets off again on the point man.
-- At the destination it halts: every man crouches and aims outboard (see the formations below).
--
-- Bodies only exist near the player, so a patrol only moves while you are near it.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Soldier/LF_Combat"

LF.March = LF.March or {}

local CFG = {
    spacing = 2.5,          -- tiles between men along the column (stretched to disperse, below)
    disperse = 5,           -- no two men nearer than this on patrol: one grenade (wounding out to
                            -- 3.5 tiles, killing out to 1.5) can't take out two
    lateral = 1.5,          -- each man this far left or right of the road's line, alternately
    step = 0.45,            -- the head moves this far per tactics update - set from the aiming pace
    waitBehind = 5,         -- the head waits while anyone is further than this from his place
    roadSearch = 20,        -- look this far for the nearest road square
    searchMargin = 40,      -- route search box: start/goal bounding box plus this
    maxNodes = 25000,       -- give up the road search after this many squares
    nodeEvery = 3,          -- keep every n-th square of the road route as a waypoint
    arrive = 2.0,           -- a man within this of his final place has arrived
    resumeQuiet = 600,      -- form up again after ~10 s with no contact and no orders
    clockSlack = 3,         -- the pace clock stays within this of the point man
    paceGain = 0.3,         -- per tile off his mark, a marching man walks this much faster / slower
    lead = 5,               -- a marching man walks toward a point this far ahead of his place
                            -- (far enough that he never quite gets there and stops)
    baseSlack = 3,          -- the head moves on only while the point man is this close to his place
    caughtUp = 2.0,         -- a man who fell behind walks at the normal pace until this close again
    edgeScan = 8,           -- look this far either side for the edges of the road
    edgeMargin = 0.5,       -- tactical column: each man up to this far in from his edge of the road
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

-- ---- the route ------------------------------------------------------------------------------

-- Cumulative lengths of a polyline.
local function measure(pts)
    local s = { 0 }
    for i = 2, #pts do s[i] = s[i - 1] + LF.dist(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y) end
    return s
end

local function segDir(pts, i)
    local dx, dy = pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y
    local l = math.max(0.01, math.sqrt(dx * dx + dy * dy))
    return dx / l, dy / l
end

-- The point s tiles along the route and the direction of travel there: x, y, dx, dy. Before
-- the start the route runs on straight back the way it came (so men behind the point man have
-- places too); past the end it stops at the end.
local function pointAt(M, s)
    local pts, len = M.pts, M.len
    if s <= 0 then
        local dx, dy = segDir(pts, 2)
        return pts[1].x + dx * s, pts[1].y + dy * s, dx, dy, 2, 0
    end
    -- Binary search for the segment (routes can be long; this runs for every man every think).
    local lo, hi = 2, #pts
    if s >= len[hi] then lo = hi end
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if len[mid] < s then lo = mid + 1 else hi = mid end
    end
    local i = lo
    local seg = math.max(0.01, len[i] - len[i - 1])
    local t = math.min(1, (s - len[i - 1]) / seg)
    local dx, dy = segDir(pts, i)
    return pts[i - 1].x + (pts[i].x - pts[i - 1].x) * t, pts[i - 1].y + (pts[i].y - pts[i - 1].y) * t, dx, dy, i, t
end

-- The road's edges either side of each route point: how far the road goes to the left and to
-- the right of the line (0 off the road), measured across the direction of travel.
local function roadEdges(M)
    local cell = getCell()
    M.edges = {}
    for i, p in ipairs(M.pts) do
        local dx, dy = segDir(M.pts, math.max(2, i))
        local rx, ry = -dy, dx
        local function reach(sign)
            local last = nil
            for k = 0, CFG.edgeScan do
                local q = cell:getGridSquare(math.floor(p.x + rx * sign * k), math.floor(p.y + ry * sign * k), M.z)
                if isRoad(q) then last = k elseif last or k > 2 then break end
            end
            return last
        end
        local r, l = reach(1), reach(-1)
        M.edges[i] = (r or l) and { l = l or 0, r = r or 0 } or nil
    end
end

-- Where the two files of a tactical column walk at a point: lateral offsets of the left and
-- right file (one along each edge of the road), or nil off the road.
local function filesAt(M, i, t, margin)
    local a, b = M.edges[i - 1], M.edges[i]
    if not (a and b) then a = a or b; b = a end
    if not a then return nil end
    local l = a.l + (b.l - a.l) * t
    local r = a.r + (b.r - a.r) * t
    local width = l + r
    if width < 2 then return nil end
    return -l + margin, r - margin
end

-- How far along the route the point nearest (x, y) is (negative: behind the start).
local function project(M, x, y)
    local pts, len = M.pts, M.len
    local bestS, bestD = 0, math.huge
    for i = 2, #pts do
        local ax, ay = pts[i - 1].x, pts[i - 1].y
        local dx, dy = pts[i].x - ax, pts[i].y - ay
        local L2 = math.max(0.0001, dx * dx + dy * dy)
        local t = ((x - ax) * dx + (y - ay) * dy) / L2
        if i == 2 and t < 0 then
            -- behind the start: keep the (negative) distance
        elseif t < 0 then t = 0 end
        if t > 1 then t = 1 end
        local px, py = ax + dx * t, ay + dy * t
        local d = LF.dist(x, y, px, py)
        if d < bestD then bestD, bestS = d, len[i - 1] + t * math.sqrt(L2) end
    end
    return bestS
end

-- ---- formations -----------------------------------------------------------------------------
--
--   file   - ranger file: single file on the line of the route, ~2.5 tiles apart
--   column - tactical column: a staggered file, men alternately ~1.5 tiles either side
--   wedge  - each team a wedge (point man, two men back-left and back-right, one behind); the
--            squad's teams echeloned - Alpha ahead and left, Bravo behind and right (teams that
--            joined: Charlie back-left, Delta at the rear), the sergeant in the middle
-- Order of march: Alpha leads; the point man is its first man. (A machine-gun squad: Gun 1, then
-- Gun 2.) The medic walks at the back of Bravo.
--   ranger file   - Alpha, then the sergeant, then the other teams
--   tactical column - the teams down both sides of the road; the sergeant walks in the middle of
--                   the road, level with the point man
--   wedge         - the sergeant in the middle of the formation
-- Halted (stopped while patrolling): every man crouches and aims outboard - in a file or column
-- the point man to the front, the rear man to the back, the rest alternately left and right; in
-- a wedge each man out from the middle of the formation (an all-round defence).

LF.March.FORMATIONS = { file = "ranger file", column = "tactical column", wedge = "wedge" }

local TEAM_WEDGE = { { 0, -3 }, { -8, 5 }, { -8, -9 }, { -15, 0 } }   -- by team slot: forward, lateral
local MAN_WEDGE = { { 0, 0 }, { -2, -2 }, { -2, 2 }, { -4, 0 }, { -5.5, 0 } }   -- by place in the team (5th: the medic)

-- The order of march (living men only). In a tactical column the sergeant is last in the list but
-- not in the file (he walks level with the point man, in the middle of the road - layOut).
local function columnOrder(squad, form)
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
    local slots = { 1, 2, 3, 4 }
    local sgt = nil
    if squad.leader then
        local r = LF.Records.get(squad.leader)
        if r and r.alive then sgt = squad.leader end
    end
    for i, slot in ipairs(slots) do
        addTeam(slot)
        if i == 1 and sgt and form == "file" then order[#order + 1] = sgt; sgt = nil end   -- behind the first team
        if i == 2 and sgt and form ~= "column" then order[#order + 1] = sgt; sgt = nil end -- (wedge: the centre)
    end
    if sgt then order[#order + 1] = sgt end
    return order
end

-- Each man's place relative to the point man (forward, lateral) and the way he faces at a halt
-- (forward, lateral unit vector).
local function layOut(squad, M)
    local n = #M.order
    M.off = {}
    local function finish(o)
        -- His own distance in from the road's edge (column), and the side he scans (his halt
        -- facing snapped to front / left / right / back).
        o.margin = ZombRand(0, 51) / 100 * CFG.edgeMargin / 0.5
        -- (The rear man scans out to a side, not backward: the aimed walk backward is slower than
        -- the patrol pace, so he fell behind and had to walk to catch up every time.)
        if math.abs(o.hf) >= math.abs(o.hl) and o.hf > 0 then o.scan = "fwd"
        else o.scan = (o.hl < 0 or (o.hl == 0 and (o.l or 0) < 0)) and "left" or "right" end
    end
    if M.form == "wedge" then
        local k = {}
        local cf, cl = 0, 0
        for _, rid in ipairs(M.order) do
            local r = LF.Records.get(rid)
            local f, l
            if rid == squad.leader then
                f, l = -7, 0
            else
                local team = LF.Units.get(r.team)
                local slot = squad.teamOnly and 1 or (team and team.slot or 1)
                k[slot] = (k[slot] or 0) + 1
                local t, mo = TEAM_WEDGE[slot] or TEAM_WEDGE[1], MAN_WEDGE[math.min(k[slot], 5)]
                f, l = t[1] + mo[1], t[2] + mo[2]
            end
            M.off[rid] = { f = f, l = l }
            cf, cl = cf + f, cl + l
        end
        cf, cl = cf / math.max(1, n), cl / math.max(1, n)
        for i, rid in ipairs(M.order) do
            local o = M.off[rid]
            local ff, ll = o.f - cf, o.l - cl
            if i == 1 then ff, ll = 1, 0 end
            local len = math.max(0.01, math.sqrt(ff * ff + ll * ll))
            o.hf, o.hl = ff / len, ll / len
            finish(o)
        end
    else
        local column = M.form == "column"
        local inFile = n - ((column and squad.leader and M.order[n] == squad.leader) and 1 or 0)
        local k = 0
        for _, rid in ipairs(M.order) do
            local o
            if column and rid == squad.leader then
                -- The sergeant: the middle of the road, level with the point man.
                o = { f = 0, l = 0, centre = true, hf = 1, hl = 0 }
            else
                k = k + 1
                local side = (k % 2 == 1) and -1 or 1
                o = { f = -(k - 1) * CFG.spacing, l = column and side * CFG.lateral or 0 }
                if k == 1 then o.hf, o.hl = 1, 0
                elseif k == inFile then o.hf, o.hl = -1, 0
                else o.hf, o.hl = 0, side end
            end
            finish(o)
            M.off[rid] = o
        end
    end
    -- Grenade dispersion: no two men close enough together for one grenade to hit them both.
    -- The formation is stretched until every pair is at least CFG.disperse apart (a column along
    -- its length only - its width is the road's).
    local D = CFG.disperse
    local ids = {}
    for rid, o in pairs(M.off) do
        if not o.centre then ids[#ids + 1] = rid end    -- (the sergeant in the road's middle is across it from the file)
    end
    local function minPair(kf, kl)
        local m = math.huge
        for i = 1, #ids do
            local a = M.off[ids[i]]
            for j = i + 1, #ids do
                local b = M.off[ids[j]]
                local df, dl = (a.f - b.f) * kf, (a.l - b.l) * kl
                m = math.min(m, math.sqrt(df * df + dl * dl))
            end
        end
        return m
    end
    if #ids >= 2 then
        local wedge = M.form == "wedge"
        local k = 1
        while k < 4 and minPair(k, wedge and k or 1) < D do k = k + 0.1 end
        if k > 1 then
            for _, rid in ipairs(ids) do
                local o = M.off[rid]
                o.f = o.f * k
                if wedge then o.l = o.l * k end
            end
        end
        M.spread = k
    end
end

-- Where a man's place is (x, y) and, for a halt, the point he aims at.
local function placeOf(M, rid, lead)
    local o = M.off[rid]
    local s = math.min(M.head, M.total) + o.f
    if lead and not M.arrived then s = math.min(s + lead, M.total + o.f) end
    local x, y, dx, dy, si, st = pointAt(M, s)
    local rx, ry = -dy, dx
    local lat = o.l
    if M.form == "column" and M.edges then
        local left, right = filesAt(M, si, st, o.margin or 0.25)
        if left then
            if o.centre then lat = (left + right) / 2 else lat = o.l < 0 and left or right end
        end
    end
    local px, py = x + rx * lat, y + ry * lat
    local hx, hy = dx * o.hf + rx * o.hl, dy * o.hf + ry * o.hl
    return px, py, px + hx * 8, py + hy * 8
end

-- Plan the route (road for a file or column, straight for a wedge) from (sx, sy) to (x, y).
-- ---- routes in legs ---------------------------------------------------------------------------

local LEG = 50            -- a route is planned at most this far ahead (the world is only loaded near you)

local function loaded(x, y, z) return getCell():getGridSquare(math.floor(x), math.floor(y), z) ~= nil end

-- One leg of a route from (sx, sy) to (x, y): along the road if a road route exists that isn't
-- much longer than going straight, otherwise straight across country. Returns the points, how,
-- and whether it is by road.
local function planRoute(sx, sy, x, y, z)
    local pts = { { x = sx, y = sy } }
    local how, onRoad = "cross-country", false
    local straight = LF.dist(sx, sy, x, y)
    local rsx, rsy = nearestRoad(sx, sy, z)
    local rgx, rgy = nearestRoad(x, y, z)
    if rsx and rgx then
        local route = roadRoute(rsx, rsy, rgx, rgy, z)
        if route and #route <= straight * 1.6 + 20 then
            for i = 1, #route, CFG.nodeEvery do pts[#pts + 1] = { x = route[i].x + 0.5, y = route[i].y + 0.5 } end
            local last = route[#route]
            pts[#pts + 1] = { x = last.x + 0.5, y = last.y + 0.5 }
            how, onRoad = "by road (" .. #route .. " squares)", true
        end
    end
    pts[#pts + 1] = { x = x + 0.5, y = y + 0.5 }
    local clean = { pts[1] }
    for i = 2, #pts do
        if LF.dist(clean[#clean].x, clean[#clean].y, pts[i].x, pts[i].y) > 0.5 then clean[#clean + 1] = pts[i] end
    end
    return clean, how, onRoad
end

-- Where this leg ends on the way from (sx, sy) to the final destination (fx, fy): the destination
-- itself if it is close and loaded, otherwise a loaded point up to LEG tiles toward it (a road
-- square near there if there is one). Returns x, y, final.
local function legTarget(sx, sy, fx, fy, z)
    local d = LF.dist(sx, sy, fx, fy)
    if d <= LEG and loaded(fx, fy, z) then return fx, fy, true end
    for k = math.min(LEG, d - 5), 10, -5 do
        local lx, ly = sx + (fx - sx) / d * k, sy + (fy - sy) / d * k
        if loaded(lx, ly, z) then
            local rx, ry = nearestRoad(lx, ly, z)
            if rx and LF.dist(rx, ry, lx, ly) < 12 and LF.dist(rx, ry, fx, fy) < d - 5 then return rx, ry, false end
            return math.floor(lx), math.floor(ly), false
        end
    end
    return math.floor(sx + (fx - sx) / d * 10), math.floor(sy + (fy - sy) / d * 10), false
end

-- ---- the sergeant's choice of formation -------------------------------------------------------
--
-- He goes by where most of his men are and what lies ahead on the route:
--   most men (half or more) in woods, tall bushes or a narrow gap  -> ranger file
--   on or along a road                                              -> tactical column
--   the squad off the road with no road ahead                       -> wedge
-- One man pushing through a hedge, or stepping off the road, doesn't change anything (he just
-- catches up). A change has to hold ~3 s, and comes at most every ~10 s.

local function isThick(sq)
    if not sq then return false end
    if sq:HasTree() then return true end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local spr = objs:get(i):getSprite()
        local n = spr and spr:getName()
        if n and (n:find("vegetation_foliage", 1, true) or n:find("f_bushes", 1, true)) then return true end
    end
    return false
end

local function blocked(x, y, z)
    local q = getCell():getGridSquare(x, y, z)
    return not q or not q:isFree(false)
end

-- "road", "thick" (trees, bushes, a narrow passage) or "open".
local function terrainAt(x, y, z)
    local bx, by = math.floor(x), math.floor(y)
    local sq = getCell():getGridSquare(bx, by, z)
    if isRoad(sq) then return "road" end
    if isThick(sq) then return "thick" end
    if (blocked(bx - 1, by, z) and blocked(bx + 1, by, z)) or (blocked(bx, by - 1, z) and blocked(bx, by + 1, z)) then
        return "thick"
    end
    return "open"
end
LF.March.terrainAt = terrainAt

local WORDS = { file = "Ranger file", column = "Tactical column", wedge = "Wedge" }
local SWITCH_WORDS = { file = "Ranger file - single file through here!", column = "Tactical column - on the road!",
                       wedge = "Wedge - spread out!" }

-- Order a unit to patrol to (x, y). form: "file", "column" or "wedge" to hold one formation, or
-- nil / "auto" for the sergeant to choose as the ground changes. It goes into the patrolling
-- stance. The point man sets off; the others fall in as their places reach them. A destination
-- beyond the loaded world is reached in legs (each re-planned from where the point man is).
-- opts.continuing: the next leg of a patrol already under way. Returns true, or false and why.
function LF.March.order(squad, x, y, z, form, opts)
    -- A new task (not the next leg, a resumption, or a team walking home): standing-by fire
    -- teams nearby join the unit first (LF_Join).
    if LF.Join and not (opts and (opts.continuing or opts.noGather)) then LF.guard("join", LF.Join.gather, squad, "patrol") end
    if not (opts and opts.continuing) then squad.pendingHold = nil end    -- a new order replaces a pending one
    local auto = not LF.March.FORMATIONS[form]
    local cid = LF.Units.commander(squad)
    if not (cid and LF.Bodies.get(cid)) then return false, "its commander isn't here" end
    local order = columnOrder(squad, LF.March.FORMATIONS[form] and form or "column")
    local point = nil
    for _, rid in ipairs(order) do
        local b = LF.Bodies.get(rid)
        if b and not b:isDead() then point = b; break end
    end
    if not point then return false, "nobody here to lead" end
    z = math.floor(z or 0)
    local lx, ly, final = legTarget(point:getX(), point:getY(), x, y, z)
    local pts, how, onRoad = planRoute(point:getX(), point:getY(), lx, ly, z)
    if #pts < 2 then return false, "already there" end
    if not (opts and opts.continuing) and LF.Tactics and LF.Tactics.setStance then LF.Tactics.setStance(squad, "patrolling") end
    if auto then
        form = (opts and opts.form) or (onRoad and "column" or "wedge")
    end
    order = columnOrder(squad, form)
    local M = { pts = pts, z = z, form = form, auto = auto, x = x, y = y, final = final,
                dest = { x = lx + 0.5, y = ly + 0.5 } }
    M.len = measure(pts)
    M.total = M.len[#pts]
    M.order = order
    layOut(squad, M)
    if form == "column" then roadEdges(M) end
    -- Everyone starts where he stands; he joins when his place in the formation reaches him.
    M.proj, M.joined, M.wait = {}, {}, {}
    for _, rid in ipairs(order) do
        local b = LF.Bodies.get(rid)
        local r = LF.Records.get(rid)
        local bx, by = b and b:getX() or r.x, b and b:getY() or r.y
        M.proj[rid] = project(M, bx, by) - M.off[rid].f
        M.wait[rid] = { x = bx, y = by }
    end
    M.head = 0
    M.joined[order[1]] = true
    M.started = (opts and opts.started) or LF.tick
    M.formAt = LF.tick
    marches[squad.id] = M
    LF.log("PATROL " .. squad.name .. (opts and opts.continuing and " next leg" or "") .. " to "
        .. math.floor(x) .. "," .. math.floor(y) .. (final and "" or (" (leg to " .. lx .. "," .. ly .. ")"))
        .. " in " .. LF.March.FORMATIONS[form] .. (auto and " (sergeant's choice)" or "") .. ", "
        .. string.format("%.0f", M.total) .. " tiles " .. how .. ", " .. #order .. " men")
    if LF.Tactics and LF.Tactics.shout and not (opts and opts.continuing) then
        LF.Tactics.shout(cid, WORDS[form] .. " - on the point man! Move out!")
    end
    return true
end

-- The sergeant looks at the ground (every ~1 s) and changes formation if most of his men need it.
local function chooseFormation(squad, cid, M)
    if not M.auto or LF.tick - (M.formCheck or 0) < 60 then return end
    M.formCheck = LF.tick
    local n, road, thick = 0, 0, 0
    for _, rid in ipairs(M.order) do
        local b = LF.Bodies.get(rid)
        local r = LF.Records.get(rid)
        if b and r and r.alive then
            n = n + 1
            local t = terrainAt(b:getX(), b:getY(), M.z)
            if t == "road" then road = road + 1 elseif t == "thick" then thick = thick + 1 end
        end
    end
    if n == 0 then return end
    -- The route ahead of the point man.
    local ra, rn = 0, 0
    for k = 0, 20, 4 do
        local x, y = pointAt(M, math.min(M.total, M.head + k))
        rn = rn + 1
        if terrainAt(x, y, M.z) == "road" then ra = ra + 1 end
    end
    local roadAhead = ra / rn
    local want = M.form
    if thick / n >= 0.5 then
        want = "file"
    elseif roadAhead >= 0.4 and (road / n >= 0.5 or roadAhead >= 0.6) then
        want = "column"
    elseif road / n < 0.3 and roadAhead < 0.3 then
        want = "wedge"
    end
    if want ~= M.wantForm then M.wantForm, M.wantSince = want, LF.tick end
    if want == M.form or LF.tick - M.wantSince < 180 or LF.tick - (M.formAt or 0) < 600 then return end
    M.form, M.formAt = want, LF.tick
    -- (The sergeant's place in the order changes with the formation.)
    local old = {}
    for _, rid in ipairs(M.order) do old[rid] = true end
    M.order = columnOrder(squad, want)
    for i = #M.order, 1, -1 do if not old[M.order[i]] then table.remove(M.order, i) end end
    layOut(squad, M)
    if want == "column" and not M.edges then roadEdges(M) end
    LF.log("PATROL " .. squad.name .. " changes to " .. LF.March.FORMATIONS[want] .. " (" .. thick .. "/" .. n
        .. " men in woods or close country, " .. road .. "/" .. n .. " on the road, "
        .. math.floor(roadAhead * 100) .. "% of the way ahead is road)")
    LF.Tactics.shout(cid, SWITCH_WORDS[want])
end

-- The brain asks where a patrolling man goes: "file", x, y, z, facePoint, gait - or nil.
--   gait "march" (walking in formation), "wait" (where he stands until his place reaches him),
--   "halt" (stopped: crouch and aim outboard)
function LF.March.place(rec)
    local M = rec.squad and marches[rec.squad]
    if not M or M.halted or not M.off[rec.id] then return nil end
    M.faces = M.faces or {}
    local f = M.faces[rec.id]
    if not f then f = LF.Tactics.point(0, 0, M.z); M.faces[rec.id] = f end
    if not M.joined[rec.id] then
        local w = M.wait[rec.id]
        local x, y = placeOf(M, rec.id)
        f.x, f.y = x, y                              -- watching his place come up the route
        return "file", w.x, w.y, M.z, f, "wait"
    end
    local stopped = M.arrived
    local x, y, hx, hy = placeOf(M, rec.id, not stopped and CFG.lead or nil)
    if stopped then
        f.x, f.y = hx, hy
        return "file", x, y, M.z, f, "halt"
    end
    local _, _, dx, dy = pointAt(M, math.min(M.head, M.total) + M.off[rec.id].f)
    f.x, f.y = x + dx * 6, y + dy * 6
    local gait = rec.id == M.order[1] and "point" or "march"
    if M.lag and M.lag[rec.id] then gait = "catchup" end
    return "file", x, y, M.z, f, gait, M.off[rec.id].scan
end

-- How much faster or slower than usual a marching man should step to hold the patrol pace:
-- the point man keeps with the pace clock, everyone else with his place in the formation (which
-- moves with the point man). Steered by where he is, not by how fast he seems to be going, so the
-- patrol averages exactly the patrol pace. A man who has fallen well behind is walking normally
-- to catch up (gait "catchup") and isn't steered.
function LF.March.paceMul(rec, body)
    -- Patrol pace is one speed: every man walks at it (the point man never faster), and a man who
    -- has dropped behind walks normally until he's back in place (gait "catchup"). No speeding up
    -- or slowing down in between. (Kept as a function so it can be switched back on.)
    if not LF.March.steerPace then return 1 end
    local M = rec.squad and marches[rec.squad]
    if not M or M.halted or M.arrived or not M.off[rec.id] or not M.joined[rec.id] then return 1 end
    local s = project(M, body:getX(), body:getY())
    local want
    if rec.id == M.order[1] then want = M.clock or s
    else want = math.min(M.head, M.total) + M.off[rec.id].f end
    return math.max(0.5, math.min(1.6, 1 + CFG.paceGain * (want - s)))
end

-- Each tactics update. Returns true while the patrol is under way (the squad's other orders wait).
function LF.March.update(squad, cid, cmd, contact, quietTicks)
    local M = marches[squad.id]
    if not M then return false end
    if contact then
        if not M.halted then
            M.halted = true
            LF.log("PATROL " .. squad.name .. ": contact - halt and fight")
            LF.Tactics.shout(cid, "Contact! Take cover!")
        end
        return false
    end
    if M.halted then
        if (quietTicks or 0) < CFG.resumeQuiet then return false end
        if M.arrived then
            M.halted = false
            LF.log("PATROL " .. squad.name .. ": quiet again - back into the halt")
            LF.Tactics.shout(cid, "All quiet - back in position, eyes out!")
            return true
        end
        -- Quiet again: set off again from where the men are, on the point man.
        LF.log("PATROL " .. squad.name .. ": quiet again - moving on")
        local ok = LF.March.order(squad, M.x, M.y, M.z, M.auto and "auto" or M.form,
            { continuing = true, form = M.form, started = M.started })
        if not ok then marches[squad.id] = nil end
        return ok
    end
    if M.arrived then return true end
    chooseFormation(squad, cid, M)
    -- Men fall in as their places reach them. The point man is the base: the head moves on while
    -- he keeps up with it. Anyone who has dropped well behind his place walks at the normal pace
    -- (not the patrol pace) until he is back in it; nobody waits for him.
    M.lag = M.lag or {}
    for _, rid in ipairs(M.order) do
        local r = LF.Records.get(rid)
        local b = LF.Bodies.get(rid)
        if r and r.alive and b then
            if not M.joined[rid] and math.min(M.head, M.total) >= M.proj[rid] - 1 then
                M.joined[rid] = true
            end
            if M.joined[rid] and rid ~= M.order[1] then
                -- Only a man BEHIND his place catches up (measured along the route). A man ahead
                -- of it - or off to the side of it - walks at the patrol pace and lets it come
                -- to him. (0.30 measured straight-line distance, so a man a few tiles ahead was
                -- "lagging" and walked at the full walk, further ahead, for good.)
                local want = math.min(M.head, M.total) + M.off[rid].f
                local d = want - project(M, b:getX(), b:getY())
                if d > CFG.waitBehind then
                    if not M.lag[rid] then M.lag[rid] = true end
                elseif d <= CFG.caughtUp then
                    M.lag[rid] = nil
                end
            end
        end
    end
    if M.head < M.total then
        -- The pace clock: a point on the route moving on at exactly the patrol pace, which the
        -- point man walks to keep up with (LF.March.paceMul). It never runs more than a few tiles
        -- ahead of him or falls behind him, so a hold-up doesn't turn into a sprint afterward.
        do
            local pbc = LF.Bodies.get(M.order[1])
            if pbc then
                local ps = project(M, pbc:getX(), pbc:getY())
                local nowMs = getTimestampMs and getTimestampMs() or 0
                local dt = M.clockMs and (nowMs - M.clockMs) / 1000 or 0
                M.clockMs = nowMs
                dt = math.max(0, math.min(1, dt))
                if (getGameSpeed and getGameSpeed() ~= 1) or not M.clock then
                    M.clock = ps
                else
                    local pace = LF.Move and LF.Move.PATROL_PACE or 0.5
                    M.clock = math.max(ps - CFG.clockSlack, math.min(ps + CFG.clockSlack, M.clock + pace * dt))
                end
            end
        end
        -- The point man is the base: the formation is wherever he has got to along the route
        -- (he walks toward a point just ahead of his place, so he keeps drawing it on). If he is
        -- held up for ~5 s, the head edges on by itself so the patrol can't freeze on him.
        local base = M.order[1]
        local pb = LF.Bodies.get(base)
        local rb = LF.Records.get(base)
        local before = M.head
        if pb and rb and rb.alive and not pb:isDead() then
            local ps = project(M, pb:getX(), pb:getY())
            if ps > M.head then M.head = math.min(M.total, ps) end
        else
            M.head = math.min(M.total, M.head + (LF.Move and LF.Move.PATROL_PACE or 0.5) * 0.5)
        end
        if M.head > before + 0.05 then
            M.headMovedAt = LF.tick
        elseif LF.tick - (M.headMovedAt or LF.tick) > 300 then
            M.head = math.min(M.total, M.head + 1)
            M.headMovedAt = LF.tick
        end
        M.headMovedAt = M.headMovedAt or LF.tick
        return true
    end
    if not M.final then
        -- End of a leg: on to the next, from where the point man is.
        local ok = LF.March.order(squad, M.x, M.y, M.z, M.auto and "auto" or M.form,
            { continuing = true, form = M.form, started = M.started })
        if not ok then marches[squad.id] = nil end
        return ok
    end
    -- The point man is at the destination: the patrol has arrived, now - nobody waits for the
    -- rear to close up (stragglers go straight to their halt places).
    M.arrived = true
    for _, rid in ipairs(M.order) do M.joined[rid] = true end
    local _, _, dx, dy = pointAt(M, M.total)
    squad.facingX, squad.facingY = dx, dy
    LF.log("PATROL " .. squad.name .. " arrives (" .. math.floor((LF.tick - M.started) / 60) .. " s)")
    -- A task waiting on the arrival (an objective's assault) takes over at once.
    if LF.Objective and LF.Objective.onArrived and LF.Objective.onArrived(squad) then return true end
    LF.log("PATROL " .. squad.name .. " halts at its destination - down and eyes outboard")
    LF.Tactics.shout(cid, "Halt! Get down - eyes out!")
    return true
end
