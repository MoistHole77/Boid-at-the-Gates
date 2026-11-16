-- Living Front: the tactical position system (0.89, the soldier AI rewrite - docs/soldier-ai.md).
--
-- One place decides where a soldier stands, for every reason he has to stand somewhere: to fight
-- (a firing position), to shelter (out of the fire, no shot needed), to watch (facing where the
-- enemy was last seen) or to hide (wounded: out of every enemy's sight, toward his own men).
-- Up to 0.88 that was four finders that grew apart (LF.Cover.findFiringPosition, LF.SquadBrain's
-- placement, findHidingSpot, the Brain's "step to cover") with dozens of special cases on top -
-- and the squad's placement never looked inside a building, in a battle fought in buildings.
--
-- A query (Killzone's position evaluation, Crysis' tactical point system):
--   GENERATE  the squares within q.radius of his anchor (the place his orders put him) that a man
--             can stand on and nobody else has claimed - in the open, in rubble, inside buildings
--             (not inside a building the enemy holds, unless he is in it already) - and the square
--             he stands on, so that staying is always one of the answers.
--   SCORE     cheaply first (how far from his anchor, how far to walk, how close to his mates,
--             the right range from the enemy), then exactly for the best few: his protection
--             from each enemy he knows of (out of sight, or behind low cover he can fire over, or
--             a wall), the line of fire to his target, the walk there (fences to climb, open
--             ground in the enemy's view). Weights per kind of query (PROFILES).
--   COMMIT    (LF.TPS.better) a man keeps the position he has unless another is better by a clear
--             margin - he doesn't run between two spots of about the same worth.
-- Each query is bounded: CFG.maxCands squares scored cheaply, CFG.exact given the exact tests.

require "LivingFront/Core/LF_Core"
require "LivingFront/World/LF_Cover"
require "LivingFront/World/LF_Ground"
require "LivingFront/World/LF_Bodies"

LF.TPS = LF.TPS or {}

local CFG = {
    radius = 8,             -- tiles round the anchor searched (or his leash, if shorter)
    maxCands = 300,         -- squares scored cheaply at most
    exact = 10,             -- the best this many get the exact tests
    margin = 14,            -- a new position must beat the one he holds by this much
    minRange = 4,           -- no position closer than this to the enemy (unless he is already)
    logBest = false,        -- a TPS line for every answer (debug tools)
}
LF.TPS.CFG = CFG

-- The weights of each kind of query. All terms run 0..1.
--   prot     protection from his target (or the main threat): out of sight 1, low cover he can
--            fire over 1 (fight) / 0.75, a wall 0.6 (fight: a corner he leans out of) / 1, none 0
--   fire     a line of fire to his target from there
--   others   protection from the other enemies he knows of (on average)
--   range    the enemy at the range his weapon wants
--   near     how close to his anchor (1 on it, 0 at the edge of the search)
--   walk     how short the walk (1 standing on it)
--   space    clear of his mates (0 a tile from one, 0.5 two tiles off, 1 otherwise)
--   path     the walk there neither climbs nor crosses open ground in the enemy's view
--   hidden   out of every enemy's sight
--   rear     toward his own lines (the squad's rear)
--   stay     he is standing on it now
--   exposed  (taken off) in his target's sight with nothing between them
local PROFILES = {
    fight   = { prot = 40, fire = 34, others = 18, range = 8, near = 16, walk = 8, space = 14, path = 10, stay = 12, exposed = 26 },
    watch   = { prot = 34, fire = 26, others = 14, range = 4, near = 22, walk = 8, space = 14, path = 8, stay = 14, exposed = 20 },
    shelter = { prot = 44, others = 26, near = 16, walk = 14, space = 10, path = 12, hidden = 10, stay = 12 },
    hide    = { hidden = 50, prot = 16, rear = 20, near = 6, walk = 10, space = 8, path = 14, stay = 10 },
}
LF.TPS.PROFILES = PROFILES

local stats = { queries = 0, cands = 0, exact = 0, los = 0, kept = 0, moved = 0 }
LF.TPS.stats = stats

-- ---- the tests ---------------------------------------------------------------------------------------

local function sqAt(x, y, z) local c = getCell(); return c and c:getGridSquare(x, y, z) end

local function buildingId(sq)
    local b = sq and sq:getBuilding()
    return b and b:getID() or nil
end

-- Can someone standing at (tx, ty, tz) see square (x, y, z)? The exact line test.
local POINT = {}
POINT.__index = POINT
function POINT:getX() return self.x end
function POINT:getY() return self.y end
function POINT:getZ() return self.z end
local P = setmetatable({ x = 0, y = 0, z = 0 }, POINT)
local function sees(x, y, z, t)
    stats.los = stats.los + 1
    P.x, P.y, P.z = t.x, t.y, t.z or z
    return LF.Cover.canSeeFrom(x, y, z, P)
end

-- How well (x, y, z) protects a man from an enemy at t: 0..1, and whether t can see him there.
-- fight: he must see t, so being out of t's sight is no use to him - only what he can fire over.
local function protection(x, y, z, t, fight)
    local seen = sees(x, y, z, t)
    -- (Out of his sight: safe - but a man who has to fight him can't from there.)
    if not seen then return fight and 0.75 or 1, false end
    local q = LF.Cover.quality(x, y, z, t.x, t.y)
    if q == LF.Cover.LOW then return fight and 1 or 0.75, true end
    if q == LF.Cover.HIGH then return fight and 0.6 or 1, true end
    -- (Inside a building with the enemy outside: the walls round him still break the line.)
    local g = LF.Ground.peekCover(x, y, z, t.x, t.y)
    if g == LF.Ground.GARRISON then return 0.4, true end
    return 0, true
end
LF.TPS.protection = protection

-- ---- a query ---------------------------------------------------------------------------------------
--
-- q = {
--   id, body                  the soldier
--   want                      "fight" | "watch" | "shelter" | "hide"
--   target                    {x, y, z} his target (fight), the point he watches (watch), the main threat
--   threats                   { {x, y, z}, ... } the other enemies he knows of (at most 6 are used)
--   ax, ay, az                his anchor (default: where he stands)
--   radius                    search radius (default CFG.radius, never beyond his leash)
--   leash                     hard limit from the anchor (squares beyond it are not candidates)
--   range = {lo, hi}          the range his weapon wants (fight, watch)
--   rx, ry                    his own lines (hide)
--   mates                     { {x, y}, ... } his mates' spots, for spacing (default: the claims)
--   avoid                     { ["x,y"] = true } squares he couldn't get to
--   cur                       {x, y, z} the position he holds, scored with its "stay" bonus
--   indoorsOk                 false: open ground only (default true)
-- }
-- Returns best = { x, y, z, score, prot, fire, ... } or nil, and the score of q.cur (if given).

local cands = {}
local function byScore(a, b) return a.score > b.score end

local function key(x, y) return x .. "," .. y end

local function cheapPass(q, Wt)
    local body = q.body
    local bx, by, bz = math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ())
    local z = q.az and math.floor(q.az) or bz
    local ax, ay = q.ax or (bx + 0.5), q.ay or (by + 0.5)
    local r = q.radius or CFG.radius
    if q.leash and q.leash < r then r = q.leash end
    r = math.max(1, math.ceil(r))
    local leashSq = q.leash and (q.leash + 0.5) ^ 2 or nil
    local t = q.target
    local tb = nil
    if t then
        local tsq = sqAt(math.floor(t.x), math.floor(t.y), math.floor(t.z or z))
        tb = buildingId(tsq)
        if tb and tb == buildingId(sqAt(bx, by, bz)) then tb = nil end      -- (clearing it: he may)
    end
    local lo, hi = 0, math.huge
    if q.range then lo, hi = q.range[1] or 0, q.range[2] or math.huge end
    local myTd = t and LF.dist(bx + 0.5, by + 0.5, t.x, t.y) or nil
    local n = 0
    local function add(x, y, isCur)
        if n >= CFG.maxCands then return end
        if not isCur and leashSq and LF.distSq(x + 0.5, y + 0.5, ax, ay) > leashSq then return end
        if not isCur and q.avoid and q.avoid[key(x, y)] then return end
        local sq = sqAt(x, y, z)
        if not sq then return end
        if not isCur then
            if not sq:isFree(false) then return end
            if q.indoorsOk == false and sq:getBuilding() then return end
            if tb and buildingId(sq) == tb then return end
            if LF.Brain and LF.Brain.hardClaimed and LF.Brain.hardClaimed(x, y, z, q.id) then return end
            if LF.Cover.takenExactly(x, y, z, q.id) then return end
            -- (Somebody standing on it - not just passing: a body that isn't moving.)
            local movers = sq:getMovingObjects()
            for i = 0, movers:size() - 1 do
                local o = movers:get(i)
                if o ~= body and instanceof(o, "IsoGameCharacter") and not o:isDead() then return end
            end
        end
        local td = t and LF.dist(x + 0.5, y + 0.5, t.x, t.y) or nil
        if td and td < CFG.minRange and not isCur and td < (myTd or 0) then return end
        n = n + 1
        local c = cands[n]
        if not c then c = {}; cands[n] = c end
        for k in pairs(c) do c[k] = nil end
        c.x, c.y, c.z, c.cur = x, y, z, isCur
        local d = LF.dist(x + 0.5, y + 0.5, ax, ay)
        local s = 0
        c.near = math.max(0, 1 - d / (r + 1))
        local walk = LF.dist(bx, by, x, y)
        c.walk = math.max(0, 1 - walk / (r * 2 + 2))
        c.walkD = walk
        if td and q.range then
            if td < lo then c.range = math.max(0, 1 - (lo - td) / 8)
            elseif td > hi then c.range = math.max(0, 1 - (td - hi) / 8)
            else c.range = 1 end
        else c.range = 1 end
        -- Spacing: his mates' spots (or the claims).
        local sp = 1
        if q.mates then
            for _, mp in ipairs(q.mates) do
                local dd = math.max(math.abs(mp.x - x), math.abs(mp.y - y))
                if dd <= 1 then sp = 0; break elseif dd <= 2 then sp = math.min(sp, 0.5) end
            end
        elseif LF.Cover.taken(x, y, z, q.id) then sp = 0.3 end
        c.space = sp
        if Wt.rear and q.rx then
            local d0 = LF.dist(bx, by, q.rx, q.ry)
            c.rear = math.max(0, math.min(1, 0.5 + (d0 - LF.dist(x, y, q.rx, q.ry)) / 16))
        else c.rear = 0.5 end
        c.stay = isCur and 1 or 0
        s = (Wt.near or 0) * c.near + (Wt.walk or 0) * c.walk + (Wt.range or 0) * c.range
            + (Wt.space or 0) * c.space + (Wt.rear or 0) * c.rear + (Wt.stay or 0) * c.stay
        c.base = s
        -- An estimate of what the exact tests will find, to choose which squares get them: the
        -- square's own cover against his target (a few square reads, no line test) - low cover
        -- he can fire over, a wall, or (inside a building, or anywhere) the chance he is out of sight.
        local est = 0
        if t then
            local cq = LF.Cover.quality(x, y, z, t.x, t.y)
            local inside = sq:getBuilding() ~= nil
            local pe, fe
            if cq == LF.Cover.LOW then pe, fe = 1, 1
            elseif cq == LF.Cover.HIGH then pe, fe = (Wt.fire and 0.6 or 1), 0.3
            else pe, fe = (inside and 0.5 or 0.1), (inside and 0.5 or 1) end
            est = (Wt.prot or 0) * pe + (Wt.fire or 0) * fe + (Wt.hidden or 0) * ((cq == LF.Cover.HIGH or inside) and 0.6 or 0.1)
                + (Wt.others or 0) * (inside and 0.6 or 0.3) + (Wt.path or 0) * 0.8
        else
            est = (Wt.prot or 0) + (Wt.others or 0) * 0.5 + (Wt.path or 0)
        end
        c.score = s + est
    end
    -- The square he holds, and the one he stands on, always.
    if q.cur then add(math.floor(q.cur.x), math.floor(q.cur.y), true) end
    if not (q.cur and math.floor(q.cur.x) == bx and math.floor(q.cur.y) == by) then
        if not leashSq or LF.distSq(bx + 0.5, by + 0.5, ax, ay) <= leashSq then add(bx, by, false) end
    end
    local cx, cy = math.floor(ax), math.floor(ay)
    for d = 0, r do
        for dx = -d, d do
            for dy = -d, d do
                if math.max(math.abs(dx), math.abs(dy)) == d then
                    local x, y = cx + dx, cy + dy
                    if not (x == bx and y == by) and not (q.cur and x == math.floor(q.cur.x) and y == math.floor(q.cur.y)) then
                        add(x, y, false)
                    end
                end
            end
        end
    end
    for i = #cands, n + 1, -1 do cands[i] = nil end
    return n, bx, by, bz
end

local function exactPass(q, Wt, c, bx, by, bz)
    stats.exact = stats.exact + 1
    local t = q.target
    local fight = q.want == "fight" or q.want == "watch"
    local s = c.base
    -- His target / the main threat.
    local seenByT = false
    if t then
        local pr, seen = protection(c.x, c.y, c.z, t, fight and Wt.fire ~= nil)
        c.prot, seenByT = pr, seen
        c.fire = seen and 1 or 0
        s = s + (Wt.prot or 0) * pr + (Wt.fire or 0) * c.fire
        -- (In his sight with nothing between them: a shot, but a man standing in the open to take
        -- it. Better behind a wall waiting for one than that.)
        if seen and pr < 0.3 then s = s - (Wt.exposed or 0) end
    else
        c.prot, c.fire = 1, 0
        s = s + (Wt.prot or 0)
    end
    -- The others.
    local ot, on, hiddenAll = 0, 0, not seenByT
    if q.threats then
        for i = 1, math.min(#q.threats, 6) do
            local o = q.threats[i]
            if not (t and math.abs(o.x - t.x) < 3 and math.abs(o.y - t.y) < 3) then
                local pr, seen = protection(c.x, c.y, c.z, o, false)
                ot, on = ot + pr, on + 1
                if seen then hiddenAll = false end
            end
        end
    end
    c.others = on > 0 and ot / on or 1
    c.hidden = hiddenAll and 1 or 0
    s = s + (Wt.others or 0) * c.others + (Wt.hidden or 0) * c.hidden
    -- The walk there: fences and walls to climb, and the open ground half way, in the enemy's view.
    local path = 1
    if c.walkD > 1.5 then
        if LF.Cover.crossings(bx, by, c.x, c.y, bz, 1) > 0 then path = path - 0.5 end
        if t and c.walkD > 3 then
            local mx, my = math.floor((bx + c.x) / 2), math.floor((by + c.y) / 2)
            local pr = protection(mx, my, bz, t, false)
            if pr < 0.5 then path = path - 0.5 end
        end
    end
    c.path = math.max(0, path)
    s = s + (Wt.path or 0) * c.path
    c.score = s
    return s
end

function LF.TPS.query(q)
    local Wt = PROFILES[q.want] or PROFILES.fight
    stats.queries = stats.queries + 1
    local t0 = getTimestampMs()
    local n, bx, by, bz = cheapPass(q, Wt)
    stats.cands = stats.cands + n
    if n == 0 then return nil end
    table.sort(cands, byScore)
    -- The exact tests for the best by estimate (and always the position he holds).
    local best, curScore = nil, nil
    local done = 0
    for i = 1, n do
        local c = cands[i]
        if done < CFG.exact or c.cur then
            local s = exactPass(q, Wt, c, bx, by, bz)
            done = done + 1
            if c.cur then curScore = s end
            if not best or s > best.score then best = c end
        end
        if done >= CFG.exact and (curScore or not q.cur) then break end
    end
    -- (A copy: the candidate tables are reused.)
    local out = nil
    if best then
        out = { x = best.x, y = best.y, z = best.z, score = best.score, prot = best.prot, fire = best.fire,
                others = best.others, hidden = best.hidden, path = best.path, cur = best.cur, want = q.want }
    end
    if CFG.logBest and out then
        LF.log(string.format("TPS #%s %s -> %d,%d score %.0f (prot %.2f fire %d others %.2f hidden %d path %.1f)%s%s",
            tostring(q.id), q.want, out.x, out.y, out.score, out.prot or 0, out.fire or 0, out.others or 0, out.hidden or 0,
            out.path or 0, out.cur and " - he stays" or "", curScore and string.format(" [his own: %.0f]", curScore) or ""))
    end
    if LF.Perf then LF.Perf.stop("tps", t0) end
    return out, curScore
end

-- Should a man holding a position with score `cur` move to `best`? Only for a clear gain.
function LF.TPS.better(best, curScore, margin)
    if not best then return false end
    if best.cur then return false end
    if not curScore then return true end
    return best.score >= curScore + (margin or CFG.margin)
end

-- Score just one square (the one he holds) the way a query would: for "is my spot still good?".
function LF.TPS.score(q, x, y, z)
    q.cur = { x = x, y = y, z = z }
    local Wt = PROFILES[q.want] or PROFILES.fight
    local r = q.radius
    q.radius = 0
    local n, bx, by, bz = cheapPass(q, Wt)
    q.radius = r
    for i = 1, n do
        if cands[i].cur then return exactPass(q, Wt, cands[i], bx, by, bz), cands[i] end
    end
    return nil
end

-- ---- the old finders' questions, answered by a query -------------------------------------------------

local SQ = {}
local function contactsNear(id)
    local rec = LF.Records.get(id)
    if not (rec and rec.squad and LF.Squad and LF.Squad.contactPoints) then return nil end
    return LF.Squad.contactPoints(rec.squad, 1800, 8)
end

-- A firing position (want "fight"), or any cover ("shelter"), for a man against threat, within
-- leash of (ax, ay), the enemy no further than maxRange: x, y, z, cover quality (LF.Cover) or nil.
-- (LF.Cover.findFiringPosition and LF.SquadBrain.spotFor up to 0.88; the machine gun's crew.)
function LF.TPS.spot(id, body, threat, maxRange, ax, ay, leash, want)
    local q = SQ
    for k in pairs(q) do q[k] = nil end
    q.id, q.body, q.want = id, body, want or "fight"
    q.target = { x = threat:getX(), y = threat:getY(), z = threat:getZ() }
    q.threats = contactsNear(id)
    q.ax, q.ay, q.az = ax, ay, body:getZ()
    if ax and leash then q.leash, q.radius = leash, math.min(CFG.radius, leash) end
    q.range = { 6, maxRange or 20 }
    local best = LF.TPS.query(q)
    if not best then return nil end
    if want == "fight" and best.fire ~= 1 then return nil end      -- (no shot from anywhere near)
    if want == "shelter" and (best.prot or 0) < 0.5 then return nil end
    return best.x, best.y, best.z, LF.Cover.quality(best.x, best.y, best.z, q.target.x, q.target.y)
end

-- Somewhere out of every known enemy's sight (the wounded, the medic's patient): toward (rx, ry),
-- his own lines, if given. x, y, z or nil. (LF.Cover.findHidingSpot up to 0.88.)
function LF.TPS.hideSpot(id, body, threat, rx, ry, others)
    local q = SQ
    for k in pairs(q) do q[k] = nil end
    q.id, q.body, q.want = id, body, "hide"
    q.target = { x = threat:getX(), y = threat:getY(), z = threat:getZ() }
    local th = {}
    for _, o in ipairs(others or contactsNear(id) or {}) do
        th[#th + 1] = { x = o.getX and o:getX() or o.x, y = o.getY and o:getY() or o.y, z = o.getZ and o:getZ() or o.z }
    end
    q.threats = th
    q.ax, q.ay, q.az = body:getX(), body:getY(), body:getZ()
    q.radius = 12
    q.rx, q.ry = rx, ry
    local best = LF.TPS.query(q)
    if not best or best.cur then return nil end
    if (best.hidden or 0) < 1 and (best.prot or 0) < 0.75 then return nil end   -- (nowhere out of sight: he falls back instead)
    return best.x, best.y, best.z
end

function LF.TPS.report()
    LF.log(string.format("TPS %d queries, %d candidates, %d exact, %d sight lines; kept %d, moved %d",
        stats.queries, stats.cands, stats.exact, stats.los, stats.kept, stats.moved))
end
