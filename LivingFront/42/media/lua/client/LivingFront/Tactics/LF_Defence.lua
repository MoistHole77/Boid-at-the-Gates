-- Living Front: tactics - defence. All-round defence in the open (each team a quarter, re-facing
-- an attack), and holding a building (a man at a window on every wall, doors, the back line,
-- reserves inside).

require "LivingFront/Tactics/LF_Tactics"
require "LivingFront/Tactics/LF_Manoeuvre"

local I = LF.Tactics.I
local digInRecords          -- (below)
local CFG, fit, setIntent, squads, teams = I.CFG, I.fit, I.setIntent, I.squads, I.teams

-- ---- defensive stance: all-round defence ---------------------------------------------------
--
-- The sergeant calls it where he stands: that spot is the centre of the perimeter and he stays
-- there. Each pair holds a quarter, ~7 tiles out: Alpha's front pair north, its back pair west,
-- Bravo's front pair south, its back pair (and the medic) east (a squad that has taken in more
-- teams: a team to a quarter; a lone fire team: one man per quarter, ~3 tiles out). Every man
-- takes cover facing out of his quarter and stays there.
-- Facing the threat: with no enemy known, the four quarters follow the compass. Once the
-- sergeant knows where the enemy is (when he calls it, or when the enemy first shows up), the
-- defence re-forms around him: the first quarter faces him, the second and fourth take the
-- front-left and front-right (55 degrees off), and the third is rear security, closer in. Every man's cover then
-- faces the enemy's fire, not just out of his quarter. If the attack later comes from a quite
-- different direction (70+ degrees off), it re-forms again - at most once per ~45 s.
-- A man fires at any enemy he can see, but he only covers (area fire) and watches his own
-- quarter, ~70 degrees either side. When a quarter has nobody fit left, the teams either side
-- widen their arcs to cover it, without moving.
-- No maneuver orders, no reposition by teams, no falling back: the unit fights to the death.

local SECTOR_ANGLE = { -math.pi / 2, math.pi, math.pi / 2, 0 }    -- north, west, south, east
local SECTOR_NAME = { "north", "west", "south", "east" }
local MAN_OFFSET = { -4.5, -1.5, 1.5, 4.5 }                      -- along the arc, by slot (a team per quarter)
local PAIR_OFFSET = { -1.5, 1.5, -1.5, 1.5, 0 }                  -- ... (a pair per quarter; the medic between)

local function wrapAngle(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a < -math.pi do a = a + 2 * math.pi end
    return a
end

-- Threat-weighted layout: degrees off the enemy's bearing and radius scale, by quarter.
local WEIGHTED_DEG = { 0, -55, 180, 55 }       -- quarters: front, left, rear, right
local WEIGHTED_SCALE = { 1, 1, 0.6, 1 }
-- A machine-gun squad: each gun (its team's front pair) front-left and front-right, its two
-- riflemen out on that flank.
local MG_WEIGHTED_DEG = { -25, -110, 25, 110 }
local MG_WEIGHTED_SCALE = { 1, 0.8, 1, 0.8 }

local function sectorDir(sq, i)
    local a = sq.perim.ang and sq.perim.ang[i] or SECTOR_ANGLE[i]
    return math.cos(a), math.sin(a)
end

local function sectorScale(sq, i)
    return sq.perim.scale and sq.perim.scale[i] or 1
end

-- Re-form the perimeter around an enemy at (tx, ty).
local function faceThreat(sq, tx, ty)
    local P = sq.perim
    local theta = math.atan2(ty - P.y, tx - P.x)
    P.theta, P.formedAt = theta, LF.tick
    P.ang, P.scale = {}, P.mg and MG_WEIGHTED_SCALE or WEIGHTED_SCALE
    local deg = P.mg and MG_WEIGHTED_DEG or WEIGHTED_DEG
    for i = 1, 4 do P.ang[i] = theta + math.rad(deg[i]) end
end

-- Does each pair hold a quarter (a squad of two teams), or each team (one that has taken in more)?
local function byPairs(squad) return not squad.teamOnly and #squad.teams <= 2 end
I.byPairs = byPairs

-- Which quarter (1-4) a soldier holds; nil for the sergeant.
local function sectorOf(squad, rec)
    if squad.teamOnly then return rec.slot end
    if rec.id == squad.leader then return nil end
    local team = rec.team and LF.Units.get(rec.team)
    if not team then return nil end
    if byPairs(squad) then
        return math.min(4, (team.slot - 1) * 2 + (rec.element == "B" and 2 or 1))
    end
    return team.slot
end

local function sectorHasFit(squad, i)
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r and sectorOf(squad, r) == i and fit(r) then return true end
    end
    return false
end

local function compassOf(dx, dy)
    local names = { "east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east" }
    local a = math.atan2(dy, dx)
    local k = math.floor((a / (2 * math.pi)) * 8 + 0.5)
    k = ((k % 8) + 8) % 8        -- (Kahlua's % can return a negative remainder)
    return names[k + 1] or "front"
end

local function reusePoint(cache, id)
    local p = cache[id]
    if not p then p = LF.Tactics.point(0, 0, 0); cache[id] = p end
    return p
end

-- (0.74.3) How far out this squad's perimeter goes (share of the stance's radius): drawn in when
-- another defending squad of its side has its perimeter close by, so the two don't overlap and
-- their men mix (0.74 gate: a platoon's squads dug in 10 tiles apart, each 7 tiles round).
local function perimScale(squad, sq)
    local P = sq.perim
    if sq.perimKAt and sq.perimKAt <= LF.tick and LF.tick - sq.perimKAt < 300 and sq.perimKFor == P then return sq.perimK end
    local st = LF.Stance.get(squad)
    local k, near, nd = 1, nil, nil
    for _, u in pairs(LF.Units.all()) do
        if u ~= squad and (u.kind == "squad" or u.kind == "hq") and u.faction == squad.faction and LF.Stance.get(u).name == "defensive" then
            local o = LF.Tactics.state(u)
            local Q = o and o.perim
            if Q and Q.x then
                local d = LF.dist(P.x, P.y, Q.x, Q.y)
                local want = (d / 2 - 1) / (st.radius or 7)
                if want < k then k, near, nd = want, u, d end
            end
        end
    end
    k = math.max(0.45, k)
    if k < 1 and (sq.perimK or 1) >= 1 then
        LF.log(string.format("PERIMETER %s draws in to %.0f tiles - %s's perimeter is %.0f tiles away", squad.name,
            (st.radius or 7) * k, near and near.name or "?", nd or 0))
    end
    sq.perimK, sq.perimKAt, sq.perimKFor = k, LF.tick, P
    return k
end

-- Where a soldier stands in the perimeter and what he faces:
-- "sector", x, y, z, point (the enemy he covers, or where he watches), watching (no enemy in his
-- arc), coverPoint (what his cover must face: out of his quarter).
function LF.Tactics.perimeterPlace(squad, sq, rec)
    local P = sq.perim
    local st = LF.Stance.get(squad)
    sq.watchPts = sq.watchPts or {}
    sq.coverPts = sq.coverPts or {}
    local i = sectorOf(squad, rec)
    local sx, sy, dx, dy
    if not i then
        -- The sergeant, in the middle, faces the enemy (or the first quarter's way).
        sx, sy = P.x, P.y
        if sq.contact then
            dx, dy = sq.contact.x - sx, sq.contact.y - sy
            local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
            dx, dy = dx / len, dy / len
        else
            dx, dy = sectorDir(sq, 1)
        end
    else
        dx, dy = sectorDir(sq, i)
        local r = sectorScale(sq, i) * perimScale(squad, sq)
        if squad.teamOnly then
            sx, sy = P.x + dx * st.loneRadius * r, P.y + dy * st.loneRadius * r
        else
            local off = ((byPairs(squad) and PAIR_OFFSET or MAN_OFFSET)[rec.slot] or 0) * (r < 1 and 0.7 or 1)
            sx, sy = P.x + dx * st.radius * r - dy * off, P.y + dy * st.radius * r + dx * off
        end
    end
    -- His cover faces the enemy's fire when the enemy is known, else out of his quarter.
    local cp = sq.contact
    if not cp then
        cp = reusePoint(sq.coverPts, rec.id)
        cp.x, cp.y, cp.z = sx + dx * 15, sy + dy * 15, P.z
    end

    -- His arc: his own quarter, plus a neighbouring quarter that has nobody left.
    local l1, l2 = nil, nil
    if i then
        local a, b = (i + 2) % 4 + 1, i % 4 + 1     -- the quarters either side
        if sq.lost[a] then l1 = a end
        if sq.lost[b] then l2 = b end
    end
    local best, bestD = nil, math.huge
    for _, c in ipairs(sq.contacts or {}) do
        local vx, vy = c.x - sx, c.y - sy
        local d = math.sqrt(vx * vx + vy * vy)
        if d > 0.5 and d < bestD then
            local ok = not i or (vx * dx + vy * dy) / d >= st.arcCos
            if not ok and l1 then local ex, ey = sectorDir(sq, l1); ok = (vx * ex + vy * ey) / d >= st.arcCos end
            if not ok and l2 then local ex, ey = sectorDir(sq, l2); ok = (vx * ex + vy * ey) / d >= st.arcCos end
            if ok then best, bestD = c, d end
        end
    end
    if best then return "sector", sx, sy, P.z, best, false, cp end
    -- Nothing in his arc: watch it (leaning toward a lost neighbouring quarter).
    local wx, wy = dx, dy
    if l1 then local ex, ey = sectorDir(sq, l1); wx, wy = wx + ex, wy + ey end
    if l2 then local ex, ey = sectorDir(sq, l2); wx, wy = wx + ex, wy + ey end
    local wl = math.max(0.1, math.sqrt(wx * wx + wy * wy))
    local wp = reusePoint(sq.watchPts, rec.id)
    wp.x, wp.y, wp.z = sx + wx / wl * 15, sy + wy / wl * 15, P.z
    return "sector", sx, sy, P.z, wp, true, cp
end

-- ---- defensive stance inside a building ------------------------------------------------------
--
-- When the sergeant calls the defence standing in a building, the teams take its walls instead
-- of quarters in the open, a pair (or a team, in a squad that has taken in more) to a wall: by the
-- compass (Alpha's front pair north, its back pair west, Bravo's south and east) until the enemy is
-- known, then the first on the wall facing him, the second and fourth on the walls either side,
-- the third on the back wall.
-- A team's posts on its wall, in order: covering each door from 2 tiles inside, then each window
-- (he stands in it to fire, ducking only under fire), then a back line 2 tiles in from the wall.
-- A wall with no windows or doors gets one man watching it from inside; the rest of that team
-- reinforce the wall with the most openings. The sergeant takes the middle.
-- Posts are dealt once. Nobody changes walls afterwards: when the enemy shows up at a different
-- wall, or a man at a window falls, the spares on the back line go to the free windows facing
-- him. A man at a window keeps it - only death (or, later, a withdrawal) takes him from it. A
-- man's post is his cover: he doesn't go looking for anything better.

local WALL_DIR = LF.Building.WALL_DIR
local WALL_NAME = LF.Building.WALL_NAME

-- The wall each team slot holds when the enemy is at wall `front` (1 = compass order).
local function wallsFor(front)
    local f = front or 1
    return { f, f % 4 + 1, (f + 1) % 4 + 1, (f + 2) % 4 + 1 }
end

-- The wall that faces a point.
local function threatWall(L, tx, ty)
    local dx, dy = tx - L.cx, ty - L.cy
    local best, bd = 1, -math.huge
    for w, d in ipairs(WALL_DIR) do
        local v = d[1] * dx + d[2] * dy
        if v > bd then best, bd = w, v end
    end
    return best
end

-- The post for a window: in it, or - with furniture in it - on the square behind (a narrower
-- view), shoving the furniture aside first if it can be shoved. nil if neither is possible.
local function windowPost(L, o)
    if not o.blocked then
        return { x = o.x, y = o.y, wall = o.wall, stand = true, kind = "window", win = o, depth = 0 }
    end
    local bx, by = o.x - o.dx, o.y - o.dy
    if LF.Building.isInside(L, bx, by) then
        return { x = bx, y = by, wall = o.wall, stand = true, kind = "window", win = o, depth = 1, shove = o.movable or nil }
    end
    return nil
end

-- Posts on one wall, best first: windows, doors (covered from inside), then the back line.
-- (Windows first: every wall that has one gets a man at it before anyone covers a door.)
local function wallPosts(L, w)
    local list = {}
    local d = WALL_DIR[w]
    for _, o in ipairs(L.openings) do
        if o.wall == w and o.kind == "window" then
            local p = windowPost(L, o)
            if p then list[#list + 1] = p end
        end
    end
    for _, o in ipairs(L.openings) do
        if o.wall == w and o.kind == "door" then
            local x, y = LF.Building.inward(L, o.x, o.y, o.dx, o.dy, 2)
            list[#list + 1] = { x = x or o.x, y = y or o.y, wall = w, stand = false, kind = "door" }
        end
    end
    -- Back line: 2 tiles in from the wall, spread out from its middle.
    local edges = {}
    for _, e in ipairs(L.edges[w]) do edges[#edges + 1] = e end
    table.sort(edges, function(a, b)
        if d[1] ~= 0 then return a.y < b.y end
        return a.x < b.x
    end)
    local n = #edges
    local mid = math.floor((n + 1) / 2)
    local seen = {}
    for k = 0, n do
        for _, idx in ipairs({ mid + k * 3, mid - k * 3 }) do
            local e = edges[idx]
            if e then
                local x, y = LF.Building.inward(L, e.x, e.y, d[1], d[2], 2)
                if x and not seen[x .. "," .. y] then
                    seen[x .. "," .. y] = true
                    list[#list + 1] = { x = x, y = y, wall = w, stand = false, kind = "back" }
                end
            end
        end
    end
    return list
end

local function dealBuilding(squad, sq, front)
    local P = sq.perim
    local L = P.layout
    local walls = wallsFor(front)
    P.walls, P.front, P.formedAt = walls, front, LF.tick
    local old = sq.posts or {}
    local posts, taken, spares = {}, {}, {}
    local function take(rid, p) posts[rid] = p; taken[p.x .. "," .. p.y] = true end
    local function free(list)
        for _, p in ipairs(list) do if not taken[p.x .. "," .. p.y] then return p end end
        return nil
    end
    local function able(rid)
        local r = LF.Records.get(rid)
        return r and r.alive and not r.wounded
    end
    -- Groups that each hold a wall: the teams (a lone team: each man).
    local groups = {}
    for _, tid in ipairs(squad.teams) do
        local team = LF.Units.get(tid)
        if team then
            if squad.teamOnly then
                for _, rid in ipairs(team.members) do
                    local r = LF.Records.get(rid)
                    if able(rid) then groups[#groups + 1] = { slot = r.slot, men = { rid } } end
                end
            elseif byPairs(squad) then
                -- (Two teams: a pair to a wall, so all four walls are held.)
                local a, b = {}, {}
                for _, rid in ipairs(team.members) do
                    local r = LF.Records.get(rid)
                    if able(rid) then table.insert(r.element == "B" and b or a, rid) end
                end
                groups[#groups + 1] = { slot = (team.slot - 1) * 2 + 1, men = a }
                groups[#groups + 1] = { slot = (team.slot - 1) * 2 + 2, men = b }
            else
                local men = {}
                for _, rid in ipairs(team.members) do if able(rid) then men[#men + 1] = rid end end
                groups[#groups + 1] = { slot = team.slot, men = men }
            end
        end
    end
    -- The men, by the wall their group holds.
    local byWall = {}
    for _, g in ipairs(groups) do
        local w = walls[g.slot] or walls[1]
        byWall[w] = byWall[w] or {}
        for _, rid in ipairs(g.men) do table.insert(byWall[w], rid) end
    end
    local function donor()          -- the wall with the most men still without a post
        local bw, bn = nil, 0
        for w, men in pairs(byWall) do if #men > bn then bw, bn = w, #men end end
        return bw
    end
    -- First, a man at a window on every wall that has one (the front first): from that wall's own
    -- group, or else from the group with the most men left - two teams still cover four walls.
    for _, w in ipairs(walls) do
        local win = nil
        for _, p in ipairs(wallPosts(L, w)) do
            if p.kind == "window" and not taken[p.x .. "," .. p.y] then win = p; break end
        end
        if win then
            local src = (byWall[w] and #byWall[w] > 0) and w or donor()
            if src then take(table.remove(byWall[src], 1), win) end
        end
    end
    -- Then the rest of each group on its own wall: windows, doors, the back line. (A blank wall:
    -- one man watches it.)
    for _, w in ipairs(walls) do
        local list = wallPosts(L, w)
        local blank = L.wallOpenings[w] == 0
        for k, rid in ipairs(byWall[w] or {}) do
            local p = (not blank or k == 1) and free(list) or nil
            if p and blank then p.kind = "watch" end
            if p then take(rid, p) else spares[#spares + 1] = rid end
        end
    end
    -- Every wall with a window has a man at one: a wall whose group is short (dead, wounded, a
    -- small team) gets a spare first.
    for _, w in ipairs(walls) do
        if #spares == 0 then break end
        local covered = false
        for _, p in pairs(posts) do if p.wall == w and p.kind == "window" then covered = true; break end end
        if not covered then
            for _, p in ipairs(wallPosts(L, w)) do
                if p.kind == "window" and not taken[p.x .. "," .. p.y] then
                    take(table.remove(spares, 1), p)
                    break
                end
            end
        end
    end
    -- Spares reinforce the wall with the most openings (the front wall on a tie), then any wall.
    local busy = walls[1]
    for w = 1, 4 do if L.wallOpenings[w] > L.wallOpenings[busy] then busy = w end end
    local lists = { wallPosts(L, busy) }
    for _, w in ipairs(walls) do if w ~= busy then lists[#lists + 1] = wallPosts(L, w) end end
    for _, rid in ipairs(spares) do
        for _, list in ipairs(lists) do
            local p = free(list)
            if p then take(rid, p); break end
        end
    end
    -- Anyone still without a post: a square of his own inside (nearest the middle first, each man
    -- a different one) - not all on the middle square, crowding each other out of the building.
    local inner = {}
    for _, q in ipairs(L.inside) do inner[#inner + 1] = q end
    table.sort(inner, function(a, b) return LF.dist(a.x, a.y, L.cx, L.cy) < LF.dist(b.x, b.y, L.cx, L.cy) end)
    local k = 1
    for _, rid in ipairs(spares) do
        if not posts[rid] then
            while inner[k] and taken[inner[k].x .. "," .. inner[k].y] do k = k + 1 end
            local q = inner[k]
            if q then take(rid, { x = q.x, y = q.y, wall = walls[1], stand = false, kind = "reserve", any = true }) end
        end
    end
    -- The sergeant: the middle.
    if squad.leader and able(squad.leader) then
        local best, bd = nil, math.huge
        for _, q in ipairs(L.inside) do
            local d = LF.dist(q.x + 0.5, q.y + 0.5, L.cx, L.cy)
            if d < bd and not taken[q.x .. "," .. q.y] then best, bd = q, d end
        end
        if best then posts[squad.leader] = { x = best.x, y = best.y, wall = walls[1], stand = false, kind = "centre", any = true } end
    end
    if LF.MG then LF.guard("mg posts", LF.MG.dealPosts, squad, sq, L, walls, posts, wallPosts) end
    sq.posts = posts
    local moved, wins = 0, 0
    for rid, p in pairs(posts) do
        local o = old[rid]
        if not (o and o.x == p.x and o.y == p.y) then moved = moved + 1 end
        if p.kind == "window" then wins = wins + 1 end
    end
    LF.log("BUILDING " .. squad.name .. " holds the building: walls in order " .. WALL_NAME[walls[1]] .. ", "
        .. WALL_NAME[walls[2]] .. ", " .. WALL_NAME[walls[3]] .. ", " .. WALL_NAME[walls[4]]
        .. "; " .. wins .. " men at windows, " .. #spares .. " spare(s) to the " .. WALL_NAME[busy]
        .. " wall; " .. moved .. " man/men to (new) posts")
end

-- A man can't get to his window post (a path blocked by furniture): he fires out of the window
-- from a square further back instead (up to 2 tiles in). Returns true if he has a new post.
function LF.Tactics.postUnreachable(rec)
    local sq = rec.squad and squads[rec.squad]
    local P = sq and sq.perim
    local p = P and P.layout and sq.posts and sq.posts[rec.id]
    if not (p and p.win) or (p.depth or 0) >= 2 then return false end
    local o = p.win
    local d = (p.depth or 0) + 1
    local nx, ny = o.x - o.dx * d, o.y - o.dy * d
    if not LF.Building.isInside(P.layout, nx, ny) then return false end
    p.x, p.y, p.depth, p.shove = nx, ny, d, nil
    LF.log("BUILDING #" .. rec.id .. " " .. LF.Units.title(rec) .. " can't get to his window; firing out of it from "
        .. d .. " tile(s) back")
    return true
end

-- A man posted behind a window with furniture in it shoves the furniture aside (to a free
-- square that isn't anyone's post) and takes the window. Returns true if he did.
function LF.Tactics.shoveWindow(rec)
    local sq = rec.squad and squads[rec.squad]
    local P = sq and sq.perim
    local p = P and P.layout and sq.posts and sq.posts[rec.id]
    if not (p and p.shove and p.win) then return false end
    p.shove = nil
    local avoid = {}
    for _, q in pairs(sq.posts) do avoid[q.x .. "," .. q.y] = true end
    local o = p.win
    if LF.Building.shove(P.layout, o.x, o.y, o.dx, o.dy, avoid) then
        p.x, p.y, p.depth = o.x, o.y, 0
        LF.log("BUILDING #" .. rec.id .. " " .. LF.Units.title(rec) .. " shoves the furniture out of the window at "
            .. o.x .. "," .. o.y .. " and takes it")
        return true
    end
    LF.log("BUILDING #" .. rec.id .. " " .. LF.Units.title(rec) .. " can't shift the furniture in his window; firing from behind it")
    return false
end

-- The enemy is at a different wall, or a man at a window has fallen: the men on the back line
-- (the spares) go to the free windows facing the enemy, nearest spare first. Nobody already at a
-- window, covering a door or watching a blank wall moves: once a man has a window he keeps it.
-- Returns how many men moved.
local function reinforceWindows(squad, sq, tx, ty)
    local P = sq.perim
    local L = P.layout
    local posts = sq.posts or {}
    local held, taken, spares = {}, {}, {}
    for rid, p in pairs(posts) do
        local r = LF.Records.get(rid)
        local able = r and r.alive and fit(r)
        if able then taken[p.x .. "," .. p.y] = true end
        if p.kind == "window" and able then
            held[p.win.x .. "," .. p.win.y] = true
        elseif p.kind == "back" and able and rid ~= squad.leader then
            spares[#spares + 1] = rid
        end
    end
    if #spares == 0 then return 0 end
    local dx, dy = tx - L.cx, ty - L.cy
    local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    dx, dy = dx / len, dy / len
    local cands = {}
    for _, o in ipairs(L.openings) do
        if o.kind == "window" and not held[o.x .. "," .. o.y] then
            local score = o.dx * dx + o.dy * dy
            if score > -0.3 then cands[#cands + 1] = { o = o, score = score } end
        end
    end
    table.sort(cands, function(a, b) return a.score > b.score end)
    local moved = 0
    for _, c in ipairs(cands) do
        if #spares == 0 then break end
        local p = windowPost(L, c.o)
        if p and not taken[p.x .. "," .. p.y] then
            local bi, bd = nil, math.huge
            for i, rid in ipairs(spares) do
                local b = LF.Bodies.get(rid)
                local r = LF.Records.get(rid)
                local x, y = b and b:getX() or r.x, b and b:getY() or r.y
                local d = LF.dist(x, y, p.x + 0.5, p.y + 0.5)
                if d < bd then bi, bd = i, d end
            end
            local rid = table.remove(spares, bi)
            local old = posts[rid]
            if old then taken[old.x .. "," .. old.y] = nil end
            posts[rid] = p
            taken[p.x .. "," .. p.y] = true
            moved = moved + 1
        end
    end
    return moved
end

-- Where a soldier stands in the building's defence: "post", x, y, z, point, watching,
-- coverPoint, stand (at a window: stand to fire), win (his window's opening, or nil), shove
-- (furniture in it to shove aside first).
function LF.Tactics.buildingPlace(squad, sq, rec)
    local P = sq.perim
    local L = P.layout
    local st = LF.Stance.get(squad)
    local p = sq.posts and sq.posts[rec.id]
    if not p then
        p = { x = math.floor(L.cx), y = math.floor(L.cy), wall = P.walls[1], stand = false, kind = "centre", any = true }
    end
    local sx, sy = p.x + 0.5, p.y + 0.5
    local d = WALL_DIR[p.wall]
    local dx, dy = d[1], d[2]
    -- His arc: out of his wall, plus a neighbouring wall whose team is gone.
    local lostW = {}
    for slot = 1, 4 do if sq.lost[slot] then lostW[P.walls[slot]] = true end end
    local n1, n2 = (p.wall + 2) % 4 + 1, p.wall % 4 + 1
    local e1 = lostW[n1] and WALL_DIR[n1] or nil
    local e2 = lostW[n2] and WALL_DIR[n2] or nil
    local best, bestD = nil, math.huge
    for _, c in ipairs(sq.contacts or {}) do
        local vx, vy = c.x - sx, c.y - sy
        local dd = math.sqrt(vx * vx + vy * vy)
        if dd > 0.5 and dd < bestD then
            local ok = p.any or (vx * dx + vy * dy) / dd >= st.arcCos
            if not ok and e1 then ok = (vx * e1[1] + vy * e1[2]) / dd >= st.arcCos end
            if not ok and e2 then ok = (vx * e2[1] + vy * e2[2]) / dd >= st.arcCos end
            if ok then best, bestD = c, dd end
        end
    end
    sq.watchPts = sq.watchPts or {}
    local cp = sq.contact
    if not cp then
        sq.coverPts = sq.coverPts or {}
        cp = reusePoint(sq.coverPts, rec.id)
        cp.x, cp.y, cp.z = sx + dx * 15, sy + dy * 15, P.z
    end
    local win = (p.depth or 0) <= 1 and p.win or nil      -- close enough to reach the glass
    if best then return "post", sx, sy, P.z, best, false, cp, p.stand, win, p.shove end
    local wx, wy = dx, dy
    if e1 then wx, wy = wx + e1[1], wy + e1[2] end
    if e2 then wx, wy = wx + e2[1], wy + e2[2] end
    local wl = math.max(0.1, math.sqrt(wx * wx + wy * wy))
    local wp = reusePoint(sq.watchPts, rec.id)
    wp.x, wp.y, wp.z = sx + wx / wl * 15, sy + wy / wl * 15, P.z
    return "post", sx, sy, P.z, wp, true, cp, p.stand, win, p.shove
end

-- ---- the doors -------------------------------------------------------------------------------------
-- While the windows are got ready, the men without a window (the back line, the reserves, the
-- men covering the doors) go round the building's outside doors and shut every one that's open,
-- one man to a door.
local DOOR_DUTY = { back = true, reserve = true, door = true, watch = true }

function LF.Tactics.doorDuty(rec, body)
    local sq = rec.squad and squads[rec.squad]
    local P = sq and sq.perim
    local L = P and P.layout
    local p = L and sq.posts and sq.posts[rec.id]
    if not (p and DOOR_DUTY[p.kind]) then return nil end
    -- Only while the enemy isn't at the building: once he's coming in, the doors are his business
    -- and the men fight (up to 0.46 a man kept going to shut the door the enemy was coming through).
    for _, c in ipairs(sq.contacts or {}) do
        if LF.dist(c.x, c.y, body:getX(), body:getY()) <= 30 then return nil end
    end
    -- And only once the whole unit is in: nobody shuts the door on his own men still coming in.
    -- (A man down outside - waiting for the medic, or being dragged - isn't waited for.)
    for _, rid in ipairs(LF.Units.members(rec.squad)) do
        local r = LF.Records.get(rid)
        local b = r and r.alive and LF.Bodies.get(rid)
        if b and not b:isDead() and not (LF.Medic and LF.Medic.busy(rid))
            and LF.Building.idAt(b:getX(), b:getY(), b:getZ()) ~= L.id then
            return nil
        end
    end
    sq.doorClaims = sq.doorClaims or {}
    local best, bd, bdoor = nil, math.huge, nil
    for _, o in ipairs(L.openings) do
        if o.kind == "door" then
            local d = LF.Building.doorOf(L, o)
            local k = o.x .. "," .. o.y
            local cl = sq.doorClaims[k]
            local claimed = cl and cl.by ~= rec.id and LF.tick - cl.at < 900
            if d and not claimed and LF.Building.isOpen(d) then
                local dist = LF.dist(body:getX(), body:getY(), o.x + 0.5, o.y + 0.5)
                if dist < bd then best, bd, bdoor = o, dist, d end
            end
        end
    end
    if best then sq.doorClaims[best.x .. "," .. best.y] = { by = rec.id, at = LF.tick } end
    return best, bdoor, L.z
end

function LF.Tactics.doorDone(rec, o)
    local sq = rec.squad and squads[rec.squad]
    if sq and sq.doorClaims and o then sq.doorClaims[o.x .. "," .. o.y] = nil end
end

-- He can't get to his post in the building: his post becomes the square he's on, if that's
-- inside, or the free inside square nearest his post (never somewhere outside - up to 0.45 he
-- went out of the door to "the nearest cover"). Returns true if he has one.
function LF.Tactics.repostInside(rec, body)
    local sq = rec.squad and squads[rec.squad]
    local P = sq and sq.perim
    local L = P and P.layout
    local p = L and sq.posts and sq.posts[rec.id]
    if not p then return false end
    local bx, by = math.floor(body:getX()), math.floor(body:getY())
    local nx, ny = nil, nil
    if LF.Building.isInside(L, bx, by) then
        nx, ny = bx, by
    else
        local taken = {}
        for _, q in pairs(sq.posts) do taken[q.x .. "," .. q.y] = true end
        local bd = math.huge
        for _, q in ipairs(L.inside) do
            local d = LF.dist(q.x, q.y, p.x, p.y)
            if d < bd and not taken[q.x .. "," .. q.y] then nx, ny, bd = q.x, q.y, d end
        end
    end
    if not nx then return false end
    sq.posts[rec.id] = { x = nx, y = ny, wall = p.wall, stand = false, kind = "reserve", any = true }
    LF.log("BUILDING #" .. rec.id .. " " .. LF.Units.title(rec) .. " can't get to his post - takes " .. nx .. "," .. ny .. " inside instead")
    return true
end

-- His unit holds a building, he has a post in it, and he's outside the building: the post (x, y, z)
-- to get back to. nil otherwise.
function LF.Tactics.insidePost(rec, body)
    local sq = rec.squad and squads[rec.squad]
    local P = sq and sq.perim
    local L = P and P.layout
    local p = L and sq.posts and sq.posts[rec.id]
    if not p or LF.Building.isInside(L, body:getX(), body:getY()) then return nil end
    return p.x, p.y, L.z
end

-- May a man posted in a building shoot at (x, y)? Out of his own wall (and a neighbouring wall
-- left unmanned), anyone inside the building, or anyone within 4 tiles - not across the building
-- out of somebody else's window.
function LF.Tactics.postCovers(rec, x, y)
    local sq = rec.squad and squads[rec.squad]
    local P = sq and sq.perim
    local L = P and P.layout
    local p = sq and sq.posts and sq.posts[rec.id]
    if not (L and p) or p.any then return true end
    local sx, sy = p.x + 0.5, p.y + 0.5
    local vx, vy = x - sx, y - sy
    local dd = math.sqrt(vx * vx + vy * vy)
    if dd <= 4 or LF.Building.isInside(L, x, y) then return true end
    local squad = LF.Units.get(rec.squad)
    local arc = squad and LF.Stance.get(squad).arcCos or 0.34
    local function within(w) local d = WALL_DIR[w]; return (vx * d[1] + vy * d[2]) / dd >= arc end
    if within(p.wall) then return true end
    for slot = 1, 4 do
        if sq.lost[slot] then
            local w = P.walls[slot]
            if (w == (p.wall + 2) % 4 + 1 or w == p.wall % 4 + 1) and within(w) then return true end
        end
    end
    return false
end

local updateDefensiveInner
local function updateDefensive(squad, sq, cid, cmd)
    local r = updateDefensiveInner(squad, sq, cid, cmd)
    -- A defence throws only when it's losing (LF_Grenade decides).
    if LF.Grenade then LF.guard("grenade", LF.Grenade.consider, squad, sq) end
    return r
end
updateDefensiveInner = function(squad, sq, cid, cmd)
    local c = LF.Squad.bestContact(squad.id, cmd:getX(), cmd:getY(), CFG.contactMemory, CFG.contactRange)
    if c then
        if not sq.contact then sq.contact = LF.Tactics.point(c.x, c.y, c.z)
        else sq.contact.x, sq.contact.y, sq.contact.z = c.x, c.y, c.z end
    else
        sq.contact = nil
    end
    sq.contacts = LF.Squad.contactPoints(squad.id, CFG.contactMemory, 24)
    sq.lost = sq.lost or {}
    if not sq.perim then
        sq.perim = { x = cmd:getX(), y = cmd:getY(), z = math.floor(cmd:getZ()), mg = squad.mg }
        -- In a building? The spot the unit was told to hold, else where its commander stands
        -- (or right next to it: a doorstep).
        local L = nil
        local h = squad.holdAt
        if h then L = LF.Building.at(h.x, h.y, h.z) end
        if not L then
            local bx, by, bz = math.floor(cmd:getX()), math.floor(cmd:getY()), math.floor(cmd:getZ())
            L = LF.Building.at(bx, by, bz)
            for dx = -1, 1 do
                for dy = -1, 1 do
                    if not L then L = LF.Building.at(bx + dx, by + dy, bz) end
                end
            end
        end
        if L then
            sq.perim.layout = L
            LF.guard("unlock inner doors", LF.Building.unlockInside, L)
            local front = c and threatWall(L, c.x, c.y) or 1
            sq.perim.faced = c ~= nil
            dealBuilding(squad, sq, front)
            sq.intent = nil
            setIntent(squad, sq, cid, "DEFEND", "holding the building at " .. math.floor(L.cx) .. "," .. math.floor(L.cy)
                .. (c and (", enemy to the " .. WALL_NAME[front]) or ", walls by the compass"))
            return
        end
        local how = "by the compass (no enemy known)"
        if c then
            faceThreat(sq, c.x, c.y)
            how = "facing the enemy to the " .. compassOf(c.x - sq.perim.x, c.y - sq.perim.y)
        end
        sq.intent = nil
        setIntent(squad, sq, cid, "DEFEND", "all-round defence at " .. math.floor(sq.perim.x) .. ","
            .. math.floor(sq.perim.y) .. ", " .. how)
        return
    end
    if sq.perim.layout then
        -- In a building: nobody changes walls. When the enemy shows up at a different wall, or a
        -- man at a window falls, the spare men on the back line go to the free windows facing him.
        local P = sq.perim
        local held = 0
        for rid, p in pairs(sq.posts or {}) do
            local r = LF.Records.get(rid)
            if p.kind == "window" and r and r.alive and fit(r) then held = held + 1 end
        end
        local fell = P.held and held < P.held
        if c then P.tx, P.ty = c.x, c.y end
        local tw = c and threatWall(P.layout, c.x, c.y)
        local turned = tw and (tw ~= P.front or not P.faced)     -- (first sight of him counts too)
        if (turned or fell) and P.tx then
            if turned then P.front = tw end
            local moved = reinforceWindows(squad, sq, P.tx, P.ty)
            if moved > 0 then
                local where = WALL_NAME[threatWall(P.layout, P.tx, P.ty)]
                LF.log("BUILDING " .. squad.name .. ": " .. moved .. " spare man/men to the windows toward the "
                    .. where .. (fell and " (a man at a window is down)" or " (enemy at the " .. where .. " wall)"))
                LF.Tactics.shout(cid, fell and "Man down at the window - fill it!" or ("Enemy " .. where .. "! Spare men to the windows!"))
                held = held + moved
            end
        end
        P.held = held
        P.faced = P.faced or c ~= nil
    elseif c then
        local P = sq.perim
        local bearing = math.atan2(c.y - P.y, c.x - P.x)
        local off = P.theta and math.abs(wrapAngle(bearing - P.theta)) or math.pi
        if not P.theta or (off > math.rad(70) and LF.tick - P.formedAt >= CFG.reformTicks) then
            faceThreat(sq, c.x, c.y)
            local where = compassOf(c.x - P.x, c.y - P.y)
            LF.log("PERIMETER " .. squad.name .. " re-forms to face the enemy to the " .. where)
            LF.Tactics.shout(cid, squad.teamOnly and ("Enemy " .. where .. "! Face them - one man watch the rear!")
                or ("Enemy " .. where .. "! Alpha front, Bravo watch the flanks and rear!"))
        end
    end
    -- Quarters with nobody fit left: the teams either side widen their arcs. In a building, a
    -- wall counts by the men actually posted on it (or it has no window or door to watch) - not
    -- by the team named for it: two teams hold all four walls between them, and up to 0.37 the
    -- walls of the two teams that didn't exist were "down" from the start, so every man aimed
    -- through the building at them.
    for i = 1, 4 do
        local alive
        if sq.perim.layout then
            local w = sq.perim.walls[i]
            alive = (sq.perim.layout.wallOpenings[w] or 0) == 0
            for rid, p in pairs(sq.posts or {}) do
                if not alive and p.wall == w and p.kind ~= "reserve" and p.kind ~= "centre" then
                    alive = fit(LF.Records.get(rid))
                end
            end
        else
            alive = sectorHasFit(squad, i)
        end
        if not alive and not sq.lost[i] then
            sq.lost[i] = true
            local d = SECTOR_NAME[i]
            if sq.perim.layout then
                d = WALL_NAME[sq.perim.walls[i]] .. " wall"
            elseif sq.perim.ang then
                local x, y = sectorDir(sq, i)
                d = compassOf(x, y)
            end
            LF.log("PERIMETER " .. squad.name .. ": the " .. d .. " quarter is down; the teams either side cover it")
            LF.Tactics.shout(cid, "We've lost the " .. d .. " side - cover it!")
        elseif alive then
            sq.lost[i] = nil
        end
    end
end

-- Change a unit's stance (offensive / defensive). The unit starts afresh: a defensive unit forms
-- its perimeter where its commander stands.
-- Forget a unit's runtime tactics (its teams changed: one joined or left).
function LF.Tactics.forgetUnit(squad)
    squads[squad.id] = nil
    for _, tid in ipairs(squad.teams) do teams[tid] = nil end
end

digInRecords = function(squad)
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        if LF.Bodies.get(rid) then return end            -- (someone has a body: the perimeter forms on screen)
    end
    local ax, ay, az = LF.Squad.anchor(squad.id)
    if not ax then return end
    local tx, ty = ax + (squad.facingX or 1) * 15, ay + (squad.facingY or 0) * 15
    local c = LF.Squad.bestContact(squad.id, ax, ay, 3600, 60)
    if c then tx, ty = c.x, c.y end
    local spots = LF.Tactics.perimeterSpots(squad, ax, ay, math.floor(az or 0), tx, ty)
    local n = 0
    for rid, sp in pairs(spots) do
        local r = LF.Records.get(rid)
        if r and r.alive and not r.aid then r.x, r.y, n = sp.x, sp.y, n + 1 end
    end
    if n > 0 then LF.log("STANCE " .. squad.name .. " digs in off screen: " .. n .. " men to their places in the all-round defence") end
end

function LF.Tactics.setStance(squad, stance, holdAt)
    -- Holding a building: standing-by fire teams nearby come and help hold it.
    if stance == "defensive" and holdAt and LF.Join then LF.guard("join", LF.Join.gather, squad, "defend") end
    if stance ~= "patrolling" then LF.March.cancel(squad.id) end
    squad.stance = stance
    squad.holdAt = holdAt
    squads[squad.id] = nil
    for _, tid in ipairs(squad.teams) do teams[tid] = nil end
    LF.log("STANCE " .. squad.name .. " -> " .. stance)
    if LF.Brain and LF.Brain.wakeSquad then LF.Brain.wakeSquad(squad.id, "stance") end     -- (0.79)
    -- (0.76.1) Digging in in the open with nobody of it in sight of you (a reserve arriving, a unit
    -- at its rally point): its men go straight to their places in the all-round defence, facing the
    -- enemy it knows of (else its front) - so when their bodies appear they are already there.
    if stance == "defensive" and not holdAt and squad.kind == "squad" then LF.guard("dig in off screen", digInRecords, squad) end
    -- (A defensive unit's commander calls it when the perimeter goes up.)
    local cid = LF.Units.commander(squad)
    if stance ~= "defensive" and stance ~= "standby" and cid and LF.Bodies.get(cid) then LF.Tactics.shout(cid, "On me!") end
end

-- ---- shared with the other tactics files ----------------------------------------------------
I.updateDefensive = updateDefensive

-- (0.76) Where each man of a squad would stand in an all-round defence centred on (x, y), facing
-- an enemy at (tx, ty) - the same quarters LF.Tactics.perimeterPlace gives on screen. For a dug-in
-- squad deploying off screen (LF_Clash): when its bodies appear, the perimeter its sergeant forms
-- round himself puts them where they already are (0.76 walk-in: men walked ~10 tiles from a line
-- into their ring). Returns record id -> { x, y }.
function LF.Tactics.perimeterSpots(squad, x, y, z, tx, ty)
    local tmp = { perim = { x = x, y = y, z = z, mg = squad.mg }, lost = {}, contacts = {} }
    faceThreat(tmp, tx, ty)
    tmp.contact = LF.Tactics.point(tx, ty, z)
    local out = {}
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r then
            local _, sx, sy = LF.Tactics.perimeterPlace(squad, tmp, r)
            if sx then out[rid] = { x = sx, y = sy } end
        end
    end
    return out
end
