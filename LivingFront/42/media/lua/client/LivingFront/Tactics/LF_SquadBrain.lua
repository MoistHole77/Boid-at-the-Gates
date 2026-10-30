-- Living Front: the squad brain (combat overhaul, 0.74).
--
-- The squad, not each man, looks for the enemy and decides where its men stand. Two jobs that every
-- soldier's brain (LF_Brain) used to do for himself, three times a second:
--
--   sight     Twice a second the squad looks for the enemy as a whole: the hostile men within sight
--             range of its middle, nearest first, each checked from the two of its own men nearest
--             him (at most 16 line-of-sight checks a look, for the squad - where every man used to
--             make up to 14 of his own, three times a second). What the squad has seen is what its
--             men can shoot at: a man only checks his own line to the few the squad has seen (at
--             most 2 new checks a think, each kept a second), so nobody fires through a wall.
--
--   placement Where a man takes cover is one query for the squad (Killzone's scoring, CoH's squad
--             cover): on a trigger - a new threat direction (swung more than 45 degrees), the squad
--             moved, or 10 s gone in a fight - the squares round the squad are scored once from the
--             cover map (LF_Ground): cover from the threat 40, the line of fire on it 30, spacing
--             from his mates' spots 20, distance from his place 10. Each man then takes the best
--             square within his leash that is free, with an exact check (the cover against the
--             threat's actual line, the line of fire) only on the few best. The machine gun's crew
--             and men holding a building keep their own posts (LF_MG, LF_Defence). With no square
--             inside his leash, a man may go up to 10 tiles for cover rather than stay in the open.
--
-- The rest of a soldier's brain - moving, firing, his wounds, the jobs he's been given - is
-- unchanged until the squad plans (0.75) take over his remaining decisions.
-- Runtime only (nothing saved): after a load the squads simply look again.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Core/LF_Perf"
require "LivingFront/World/LF_Bodies"
require "LivingFront/World/LF_Sense"
require "LivingFront/World/LF_Cover"
require "LivingFront/World/LF_Ground"
require "LivingFront/Units/LF_Units"

LF.SquadBrain = LF.SquadBrain or {}
LF.SquadBrain.enabled = true

local CFG = {
    lookTicks = 30,         -- the squad looks twice a second
    flankRange = 30,        -- (0.85) a man's spot is checked against the nearest enemy the squad sees this close to him
    flankTicks = 120,       -- ... at most this often a man
    sightRange = 30,
    maxEnemies = 8,         -- enemies the squad finds per look
    maxChecks = 16,         -- line-of-sight checks per look, for the whole squad
    observers = 2,          -- each enemy is checked from this many of its men nearest him
    manChecks = 2,          -- new checks a man makes of his own per think
    pairTicks = 60,         -- a man's line to an enemy is known this long
    maxSeen = 5,            -- enemies a man is given per think (nearest first)
    spotChance = 25,        -- (0.78) percent a look to recognise a sergeant or corporal the squad sees
    -- (0.82: held positions - the squad places on a new order or stance (LF.SquadBrain.replace),
    -- when the enemy comes round 60 degrees, when it moves on; 0.74-0.81 also every 10 s, at 45
    -- degrees and 4 tiles, and each placement could move every man.)
    placeEvery = 3600,      -- placement is redone at least this often while in use
    placeTurn = 0.5,        -- ... or when the threat swings more than 60 degrees (cos)
    placeMove = 6,          -- ... or the squad's middle has moved this far
    placeRadius = 9,        -- squares this far round the squad's men are candidates
    farLeash = 10,          -- no cover on his leash: this far for shelter
    exactChecks = 6,        -- candidates given the exact cover and sight checks per man, at most
    W_COVER = 40, W_FIRE = 30, W_SPACE = 20, W_DIST = 10,
}
LF.SquadBrain.CFG = CFG

local S = {}                -- squad id -> state
local stats = { los = 0, looks = 0, places = 0, spots = 0, at = 0 }
-- (0.80) Why candidates were turned down in spot searches, for the test: no candidate on his
-- leash at all, its cover wrong against his own threat, claimed, blocked, inside a building, no view.
local function noWhy() return { empty = 0, quality = 0, claimed = 0, blocked = 0, building = 0, noView = 0 } end
stats.why = noWhy()
function LF.SquadBrain.resetStats()
    stats.why, stats.nearFound, stats.testSpots, stats.testNone = noWhy(), 0, 0, 0
    stats.kept, stats.tableQ, stats.liveQ, stats.tableV, stats.liveV, stats.testPlaces = 0, 0, 0, 0, 0, 0
    stats.held, stats.flanked = 0, 0
end
LF.SquadBrain.stats = stats

local shareTargets           -- (below)
local function stateOf(sid)
    local s = S[sid]
    if not s then
        s = { sid = sid, seen = {}, seenAt = -100000, pairs = {}, cands = nil, spots = {} }
        S[sid] = s
    end
    return s
end

local function fitBody(rid)
    local r = LF.Records.get(rid)
    if not (r and r.alive) or r.aid or r.captured then return nil end
    local b = LF.Bodies.get(rid)
    if not b or b:isDead() then return nil end
    return b, r
end

-- The squad's men with bodies: list of { id, body, rec }, and their middle.
local menList = {}
local function menOf(sid)
    local n, cx, cy, cz = 0, 0, 0, 0
    for _, rid in ipairs(LF.Units.members(sid)) do
        local b, r = fitBody(rid)
        if b then
            n = n + 1
            local e = menList[n]
            if not e then e = {}; menList[n] = e end
            e.id, e.body, e.rec = rid, b, r
            cx, cy, cz = cx + b:getX(), cy + b:getY(), cz + b:getZ()
        end
    end
    for i = #menList, n + 1, -1 do menList[i] = nil end
    if n == 0 then return menList, 0 end
    return menList, n, cx / n, cy / n, math.floor(cz / n + 0.5)
end

-- ---- sight ---------------------------------------------------------------------------------------

local cands, nCands = {}, 0
local lookCtx = {}
local function collect(e, dsq, ctx)
    if not LF.isHostile(ctx.faction, e.rec.faction) or e.body:isDead() then return end
    if LF.Medic and LF.Medic.isCritical(e.id) then return end
    nCands = nCands + 1
    local c = cands[nCands]
    if not c then c = {}; cands[nCands] = c end
    c.e, c.dsq = e, dsq
end
local function byDsq(a, b) return a.dsq < b.dsq end

local function setPair(s, manId, enemyId, ok)
    local p = s.pairs[manId]
    if not p then p = {}; s.pairs[manId] = p end
    p[enemyId] = ok and LF.tick or -LF.tick
end

-- The squad looks: who of the enemy can it see?
local function squadLook(sid, s)
    s.seenAt = LF.tick
    local men, n, cx, cy = menOf(sid)
    local seen = s.seen
    for i = #seen, 1, -1 do seen[i] = nil end
    if n == 0 then return end
    local squad = LF.Units.get(sid)
    s.mx, s.my, s.mn, s.faction = cx, cy, n, squad.faction
    local spread = 0
    for i = 1, n do spread = math.max(spread, LF.dist(cx, cy, men[i].body:getX(), men[i].body:getY())) end
    nCands = 0
    lookCtx.faction = squad.faction
    LF.Sense.near(cx, cy, CFG.sightRange + math.min(15, spread), collect, lookCtx)
    for i = #cands, nCands + 1, -1 do cands[i] = nil end
    if nCands > 1 then table.sort(cands, byDsq) end
    stats.looks = stats.looks + 1
    local checks = 0
    local rangeSq = CFG.sightRange * CFG.sightRange
    for i = 1, nCands do
        if #seen >= CFG.maxEnemies or checks >= CFG.maxChecks then break end
        local e = cands[i].e
        local ex, ey = e.body:getX(), e.body:getY()
        -- His nearest observers (two passes: nearest, then next nearest).
        local o1, d1, o2, d2 = nil, math.huge, nil, math.huge
        for j = 1, n do
            local m = men[j]
            local d = LF.distSq(m.body:getX(), m.body:getY(), ex, ey)
            if d < d1 then o2, d2, o1, d1 = o1, d1, m, d elseif d < d2 then o2, d2 = m, d end
        end
        local found = false
        for k = 1, CFG.observers do
            local o, od = o1, d1
            if k == 2 then o, od = o2, d2 end
            if o and od <= rangeSq and checks < CFG.maxChecks then
                local p = s.pairs[o.id]
                local known = p and p[e.id]
                local ok
                if known and LF.tick - math.abs(known) <= CFG.pairTicks then
                    ok = known > 0
                else
                    checks = checks + 1
                    stats.los = stats.los + 1
                    ok = LF.Sense.canSee(o.body, e.body)
                    setPair(s, o.id, e.id, ok)
                end
                if ok then found = true; break end
            end
        end
        if found then
            local v = {}
            v.body, v.id, v.rec = e.body, e.id, e.rec
            seen[#seen + 1] = v
        end
    end
    -- (0.78) What it saw goes into the squad's picture once a look (not once per man a think), a
    -- sergeant or corporal among them perhaps recognised; and the sergeant shares out the targets.
    if #seen > 0 then
        if not s.contactSince or LF.tick - (s.lastSeen or -100000) > 600 then s.contactSince = LF.tick end
        s.lastSeen = LF.tick
    end
    -- (0.79) An enemy the squad hadn't seen at its last look: every man re-decides.
    s.prevSeen = s.prevSeen or {}
    local fresh = false
    for i = 1, #seen do if not s.prevSeen[seen[i].id] then fresh = true end end
    for k in pairs(s.prevSeen) do s.prevSeen[k] = nil end
    for i = 1, #seen do s.prevSeen[seen[i].id] = true end
    if fresh and LF.Brain and LF.Brain.wakeSquad then LF.Brain.wakeSquad(sid, "new enemy") end
    for i = 1, #seen do
        local v = seen[i]
        LF.Squad.report(sid, v.id, v.body)
        local rank = v.rec.rank
        if (rank == "SGT" or rank == "CPL") and not LF.Squad.knowsLeader(sid, v.id) and ZombRand(100) < CFG.spotChance then
            LF.Squad.markLeader(sid, v.id)
            LF.log("SPOTTED " .. squad.name .. " recognised enemy leader #" .. v.id .. " " .. LF.Units.title(v.rec))
        end
    end
    shareTargets(s, men, n, cx, cy)
    -- (0.78.1, the reaction test) Since when each man has had an enemy his squad sees within his own
    -- range (a rifle's 20 tiles, a gun's 30): his reaction is timed from then, not from the squad's
    -- first sighting at 30 tiles and more.
    s.eng = s.eng or {}
    s.flankAt, s.flanked = s.flankAt or {}, s.flanked or {}
    local rifle = (LF.Brain and LF.Brain.CFG and LF.Brain.CFG.fireRange) or 20
    local gun = (LF.MG and LF.MG.CFG and LF.MG.CFG.range) or 30
    for i = 1, n do
        local man = men[i]
        local r = man.rec.mgRole == "gunner" and gun or rifle
        local rsq, any = r * r, false
        local bx, by = man.body:getX(), man.body:getY()
        local near, nearD = nil, CFG.flankRange * CFG.flankRange
        for j = 1, #seen do
            local v = seen[j]
            local d2 = LF.distSq(bx, by, v.body:getX(), v.body:getY())
            if d2 <= rsq then any = true end
            if d2 < nearD then near, nearD = v.body, d2 end
        end
        -- (0.85) A spot flanked: the nearest enemy the squad sees within 30 tiles of him has no cover
        -- against him from the spot the man holds - the sergeant moves him (LF_Brain asks again
        -- against that enemy). Checked at most every 2 s a man; one cover-map read. (0.84: men held
        -- shelter a tile from cover that faced the enemy nearest them - 11 left in the open.)
        -- (0.85.2) Against the nearest enemy the squad knows of (seen in the last 10 s, within 45
        -- tiles) when it sees none near him now - the enemy his cover is judged against in the test.
        if LF.tick - (s.flankAt[man.id] or -100000) >= CFG.flankTicks then
        -- (0.85.3) His own target if he has one, else the nearest enemy the squad knows of; the exact
        -- edge test, not the 8-direction map (they disagree at an angle).
        local c = LF.Brain and LF.Brain.coverOf and LF.Brain.coverOf(man.id)
        local ref = nil
        if c then
            local tid = LF.Brain.targetOf and LF.Brain.targetOf(man.id)
            local tb = tid and LF.Bodies.get(tid)
            if tb and not tb:isDead() then ref = tb
            else
                local k = LF.Squad.bestContact(sid, bx, by, 600, 45)
                if k then ref = LF.Tactics.point(k.x, k.y, c.z) end
            end
        end
        s.flankAt[man.id] = LF.tick
        if c and ref and LF.Cover.quality(c.x, c.y, c.z, ref:getX(), ref:getY()) == LF.Cover.NONE then
            s.flanked[man.id] = ref
            stats.flanked = (stats.flanked or 0) + 1
            if LF.Brain.wake then LF.Brain.wake(man.id, "flanked") end
        end
        end
        if any then
            -- (0.79.1) An enemy has just come within his range: he re-decides at once (0.79 waited
            -- for his heartbeat - the first shot slowed from 2.6 s to 3.3 s).
            if not s.eng[man.id] and LF.Brain and LF.Brain.wake then LF.Brain.wake(man.id, "in range") end
            s.eng[man.id] = s.eng[man.id] or LF.tick
        else s.eng[man.id] = nil end
    end
    -- Forget lines to men no longer about (kept small).
    s.looks = (s.looks or 0) + 1
    if s.looks % 40 == 0 then
        for mid, p in pairs(s.pairs) do
            for eid, t in pairs(p) do
                if LF.tick - math.abs(t) > CFG.pairTicks * 4 then p[eid] = nil end
            end
        end
    end
end

-- ---- the sergeant shares out the targets (0.78) -----------------------------------------------------
-- Each look, every fit man is given one of the enemies the squad sees: the men from left to right
-- along the squad's front take the enemies from left to right, so the fire spreads along the enemy
-- line rather than everyone shooting the nearest man. A machine gun firing on them counts double
-- (twice the men on it), a recognised leader half again. A man who can't see his own target keeps
-- choosing for himself (LF_Brain).
local slots, order = {}, {}
local function byLat(a, b) return a.lat < b.lat end
shareTargets = function(s, men, n, cx, cy)
    s.assign = s.assign or {}
    for k in pairs(s.assign) do s.assign[k] = nil end
    local seen = s.seen
    if #seen == 0 or n == 0 then return end
    local ex, ey = 0, 0
    for i = 1, #seen do ex, ey = ex + seen[i].body:getX(), ey + seen[i].body:getY() end
    ex, ey = ex / #seen - cx, ey / #seen - cy
    local l = math.sqrt(ex * ex + ey * ey)
    if l < 0.1 then ex, ey, l = 1, 0, 1 end
    local rx, ry = -ey / l, ex / l              -- (the squad's right, facing the enemy)
    local k = 0
    for i = 1, #seen do
        local v = seen[i]
        local w = 2
        if LF.MG and LF.MG.isFiring(v.id) then w = 4 elseif LF.Squad.knowsLeader(s.sid or 0, v.id) then w = 3 end
        local lat = (v.body:getX() - cx) * rx + (v.body:getY() - cy) * ry
        for _ = 1, w do
            k = k + 1
            local e = slots[k]
            if not e then e = {}; slots[k] = e end
            e.id, e.lat = v.id, lat
        end
    end
    for i = #slots, k + 1, -1 do slots[i] = nil end
    table.sort(slots, byLat)
    local m = 0
    for i = 1, n do
        local man = men[i]
        local r = man.rec
        if not r.wounded then
            m = m + 1
            local e = order[m]
            if not e then e = {}; order[m] = e end
            e.id, e.lat = man.id, (man.body:getX() - cx) * rx + (man.body:getY() - cy) * ry
        end
    end
    for i = #order, m + 1, -1 do order[i] = nil end
    table.sort(order, byLat)
    for i = 1, m do
        local j = math.min(k, math.floor((i - 0.5) * k / m) + 1)
        s.assign[order[i].id] = slots[j].id
    end
end

-- The target his sergeant gave a man (an enemy record id), or nil.
function LF.SquadBrain.targetOf(sid, id)
    local s = S[sid]
    if not s or not s.assign or LF.tick - (s.seenAt or -100000) > CFG.lookTicks * 3 then return nil end
    return s.assign[id]
end

-- Since when this man has had an enemy his squad sees within his range (the reaction test), or nil.
function LF.SquadBrain.engageableSince(sid, id)
    local s = S[sid]
    return s and s.eng and s.eng[id]
end

-- When the squad's present contact began (the first look that saw an enemy after 10 s of none), or nil.
function LF.SquadBrain.contactSince(sid)
    local s = S[sid]
    return s and s.contactSince
end

local out, res = {}, {}
local function byDist(a, b) return a.dist < b.dist end

-- A squad soldier's look (in place of LF.Sense.look): the enemies his squad has seen that he can
-- see himself, nearest first, as { body, id, rec, dist }. The returned array is reused.
function LF.SquadBrain.look(id, body, rec, range)
    local s = stateOf(rec.squad)
    if LF.tick - s.seenAt > CFG.lookTicks * 2 or s.seenAt > LF.tick then squadLook(rec.squad, s) end
    local n = 0
    local bx, by = body:getX(), body:getY()
    local rangeSq = range * range
    for i = 1, #s.seen do
        local v = s.seen[i]
        if not v.body:isDead() then
            local dsq = LF.distSq(bx, by, v.body:getX(), v.body:getY())
            if dsq <= rangeSq then
                n = n + 1
                local o = out[n]
                if not o then o = {}; out[n] = o end
                o.body, o.id, o.rec, o.dist = v.body, v.id, v.rec, math.sqrt(dsq)
            end
        end
    end
    for i = #out, n + 1, -1 do out[i] = nil end
    if n > 1 then table.sort(out, byDist) end
    -- Only those he can see himself: known lines, and at most manChecks new ones.
    local p = s.pairs[id]
    local checks, k = 0, 0
    for i = 1, n do
        local o = out[i]
        local known = p and p[o.id]
        local ok = nil
        if known and LF.tick - math.abs(known) <= CFG.pairTicks then
            ok = known > 0
        elseif checks < CFG.manChecks then
            checks = checks + 1
            stats.los = stats.los + 1
            ok = LF.Sense.canSee(body, o.body)
            setPair(s, id, o.id, ok)
            p = s.pairs[id]
        end
        if ok and k < CFG.maxSeen then
            k = k + 1
            local r = res[k]
            if not r then r = {}; res[k] = r end
            r.body, r.id, r.rec, r.dist = o.body, o.id, o.rec, o.dist
        end
    end
    for i = #res, k + 1, -1 do res[i] = nil end
    return res
end

-- Has the squad seen any enemy at its last look (or was its last look long ago - then assume so)?
function LF.SquadBrain.seesAny(sid)
    local s = S[sid]
    if not s or LF.tick - s.seenAt > CFG.lookTicks * 4 or s.seenAt > LF.tick then return true end
    return #s.seen > 0
end

local coverQ      -- (below)

-- ---- placement -----------------------------------------------------------------------------------

-- The candidate squares round the squad against a threat point: every square round its men with
-- cover against the threat (one edge check each - LF_Cover - once per trigger, not per man).
local function buildCands(sid, s, men, n, cx, cy, cz, tx, ty)
    local list = s.cands or {}
    for i = #list, 1, -1 do list[i] = nil end
    s.cands = list
    s.tx, s.ty, s.cx, s.cy, s.placedAt = tx, ty, cx, cy, LF.tick
    for k in pairs(s.spots) do s.spots[k] = nil end
    stats.places = stats.places + 1
    stats.testPlaces = (stats.testPlaces or 0) + 1
    local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, n do
        local b = men[i].body
        x0, x1 = math.min(x0, b:getX()), math.max(x1, b:getX())
        y0, y1 = math.min(y0, b:getY()), math.max(y1, b:getY())
    end
    local r = CFG.placeRadius
    x0, x1 = math.floor(x0 - r), math.floor(x1 + r)
    y0, y1 = math.floor(y0 - r), math.floor(y1 + r)
    -- (At most 33 x 33 squares round its middle.)
    x0, x1 = math.max(x0, math.floor(cx - 16)), math.min(x1, math.floor(cx + 16))
    y0, y1 = math.max(y0, math.floor(cy - 16)), math.min(y1, math.floor(cy + 16))
    -- (0.80.1) Only squares a man can stand on, outside buildings: 0.80's spot searches turned
    -- down 2811 blocked candidates and 1773 inside buildings, for every man, every search.
    local cell = getCell()
    for x = x0, x1 do
        for y = y0, y1 do
            local tdsq = LF.distSq(x + 0.5, y + 0.5, tx, ty)
            local sq = tdsq > 16 and cell:getGridSquare(x, y, cz)
            if sq and sq:isFree(false) and not sq:getBuilding() then
                -- (0.82.1) Any square with cover against fire from any side - each man is given the
                -- one covered against his own enemy; 0.82 listed only those covered against the
                -- squad's, and dug-in men sat in the open a tile from cover facing their own man.
                local light, heavy = LF.Ground.peekAny(x, y, cz)
                if light == nil then
                    stats.liveQ = (stats.liveQ or 0) + 1
                    local q = LF.Cover.quality(x, y, cz, tx, ty)
                    light, heavy = q == LF.Cover.LOW, q == LF.Cover.HIGH
                else
                    stats.tableQ = (stats.tableQ or 0) + 1
                end
                if light or heavy then
                    list[#list + 1] = { x = x, y = y, cls = light and LF.Ground.LIGHT or LF.Ground.HEAVY, td = math.sqrt(tdsq) }
                end
            end
        end
    end
end

-- Is (x, y) within 2 tiles of a spot another man of the squad has taken?
local function spacing(s, id, x, y)
    for mid, sp in pairs(s.spots) do
        if mid ~= id and math.abs(sp.x - x) <= 1 and math.abs(sp.y - y) <= 1 then return 0 end
    end
    for mid, sp in pairs(s.spots) do
        if mid ~= id and math.abs(sp.x - x) <= 2 and math.abs(sp.y - y) <= 2 then return 0.5 end
    end
    return 1
end

-- (0.74.1) Is (x, y) nearer another squad of the same side's middle than its own (by 3 tiles)?
-- Squads keep to their own ground: men don't take cover in among another squad's.
local function amongOthers(sid, faction, x, y)
    local own = S[sid]
    if not (own and own.mx) then return false end
    local d0 = LF.dist(x, y, own.mx, own.my)
    if d0 < 5 then return false end
    for osid, o in pairs(S) do
        if osid ~= sid and o.mx and o.faction == faction and o.mn and o.mn >= 3
            and LF.tick - (o.seenAt or -100000) < 300 and LF.dist(x, y, o.mx, o.my) <= d0 - 3 then
            return true
        end
    end
    return false
end

local scored = {}
local function byScore(a, b) return a.score > b.score end

-- (0.81) Cover and view of a square, from the cover overlay (LF_Ground) where it is filled - a
-- table read - else the live edge test / line test. 0.74-0.80 always ran the live tests: about
-- 1,100 edge tests a placement and a line test per candidate per man.
coverQ = function(x, y, z, tx, ty)
    local g = LF.Ground.peekCover(x, y, z, tx, ty)
    if g then
        stats.tableQ = (stats.tableQ or 0) + 1
        if g == LF.Ground.LIGHT then return LF.Cover.LOW end
        if g == LF.Ground.NONE then return LF.Cover.NONE end
        return LF.Cover.HIGH
    end
    stats.liveQ = (stats.liveQ or 0) + 1
    return LF.Cover.quality(x, y, z, tx, ty)
end
local function viewOf(x, y, z, threat)
    local v = LF.Ground.peekSeen(x, y, z, threat:getX(), threat:getY())
    if v ~= nil then stats.tableV = (stats.tableV or 0) + 1; return v end
    stats.liveV = (stats.liveV or 0) + 1
    return LF.Cover.canSeeFrom(x, y, z, threat)
end
LF.SquadBrain.coverQ = coverQ

-- A squad soldier's cover (in place of LF.Cover.findFiringPosition): x, y, z, quality or nil.
-- The arguments are findFiringPosition's (threat, maxRange, anchor, leash, loose); gun: a gun's
-- spot (it must see the enemy from there; any cover).
-- (0.81) The squad answers each man once a placement: the answer (a spot, or none) is kept until
-- the squad places again (the threat swings, the squad moves, 10 s) or he is sent elsewhere - up
-- to 0.80 he asked again every 2 s, and 9 times in 10 got nothing.
-- Three looks, best first: a firing position round where he was sent; (shelter) any cover round
-- where he is; then the nearest covered square to where he was sent within 14 tiles - so a man
-- sent to open ground goes to the cover nearest it instead of standing there (0.80: the most
-- common miss, nothing covered on his leash).
local function spotOf(id, body, rec, threat, maxRange, ax, ay, leash, loose, gun)
    local sid = rec.squad
    local s = stateOf(sid)
    local tx, ty = threat:getX(), threat:getY()
    local men, n, cx, cy, cz = menOf(sid)
    if n == 0 then return nil end
    local bz = math.floor(body:getZ())
    -- (0.81) The squad places against the enemy it sees as a whole (the middle of its last look),
    -- not each man's own target: men firing at enemies 45 degrees apart re-placed the squad by turns.
    local stx, sty = tx, ty
    local seen = s.seen
    if seen and #seen > 0 and LF.tick - s.seenAt < CFG.lookTicks * 4 then
        local sx, sy, k = 0, 0, 0
        for i = 1, #seen do
            local vb = seen[i].body
            if vb then sx, sy, k = sx + vb:getX(), sy + vb:getY(), k + 1 end
        end
        if k > 0 then stx, sty = sx / k, sy / k end
    elseif s.tx then
        -- (0.82.1) Seeing nobody: the enemy stays where the squad last placed against - 0.82 took
        -- each asking man's own quarter, and a dug-in squad placed again for every man in turn (442
        -- placements in 2 minutes).
        stx, sty = s.tx, s.ty
    end
    -- Trigger: the threat has swung, the squad has moved, or it's been a while.
    local stale = not s.cands or LF.tick - s.placedAt > CFG.placeEvery or s.placedAt > LF.tick
        or LF.dist(cx, cy, s.cx, s.cy) > CFG.placeMove
    if not stale then
        local ax0, ay0 = s.tx - s.cx, s.ty - s.cy
        local ax1, ay1 = stx - cx, sty - cy
        local l0, l1 = math.sqrt(ax0 * ax0 + ay0 * ay0), math.sqrt(ax1 * ax1 + ay1 * ay1)
        if l0 > 0.1 and l1 > 0.1 and (ax0 * ax1 + ay0 * ay1) / (l0 * l1) < CFG.placeTurn then stale = true end
    end
    if stale then buildCands(sid, s, men, n, cx, cy, cz, stx, sty) end
    -- (0.82.1) A man is given a spot covered against his own enemy - he then holds it (LF_Brain);
    -- what he is given is kept through a placement if it still faces his enemy or the squad's.
    local qx, qy = s.tx or tx, s.ty or ty
    -- His answer this placement, if he has one for the same ask.
    local bx, by = body:getX(), body:getY()
    local ox, oy = ax or bx, ay or by
    s.answers = s.answers or {}
    local kind = gun and "gun" or (loose and "shelter" or "fire")
    -- (0.81.1: one answer per kind - a man asks for a firing position and then for shelter in the
    -- same think, and 0.81 kept only the last, so 72 of 2,343 asks were answered from it.)
    local AM = s.answers[id]
    if not AM then AM = {}; s.answers[id] = AM end
    local A = AM[kind]
    if A and A.placedAt == s.placedAt and A.kind == kind and LF.distSq(A.ox, A.oy, ox, oy) <= 4 then
        -- (0.81.4: a kept spot is checked against the enemy he asks about now - one map read; the
        -- squad placed against its enemy as a whole, his own may stand elsewhere.)
        local good = not A.x
        if A.x then
            local q = coverQ(A.x, A.y, A.z, tx, ty)
            good = q == LF.Cover.LOW or ((loose or gun) and q ~= LF.Cover.NONE)
        end
        if good then
            stats.kept = (stats.kept or 0) + 1
            if A.x then return A.x, A.y, A.z, A.q end
            return nil
        end
    end
    -- (0.81.2) A new placement, but the spot he was given last time still does: same place asked
    -- about, still on his leash, still covered against his enemy, free, and (a firing position or a
    -- gun) still with a view - he keeps it. 0.81.1 handed out fresh spots at every placement (117 in
    -- 2 minutes) and men ran from one to the next.
    if A and A.x and A.kind == kind and LF.distSq(A.ox, A.oy, ox, oy) <= 4 then
        local q = coverQ(A.x, A.y, A.z, tx, ty)
        local okQ = q == LF.Cover.LOW or ((loose or gun) and q ~= LF.Cover.NONE)
        if not okQ then
            local q2 = coverQ(A.x, A.y, A.z, qx, qy)
            okQ = q2 == LF.Cover.LOW or ((loose or gun) and q2 ~= LF.Cover.NONE)
        end
        if okQ and not LF.Brain.hardClaimed(A.x, A.y, A.z, id) and not LF.Cover.takenExactly(A.x, A.y, A.z, id)
            and (loose or viewOf(A.x, A.y, A.z, threat)) then
            A.placedAt = s.placedAt
            local sp = s.spots[id] or {}
            sp.x, sp.y = A.x, A.y
            s.spots[id] = sp
            stats.held = (stats.held or 0) + 1
            return A.x, A.y, A.z, A.q
        end
    end
    stats.spots = stats.spots + 1
    stats.testSpots = (stats.testSpots or 0) + 1
    local cell = getCell()
    local W = stats.why
    local function answer(x, y, z, q)
        A = A or {}
        A.placedAt, A.kind, A.ox, A.oy, A.x, A.y, A.z, A.q = s.placedAt, kind, ox, oy, x, y, z, q
        AM[kind] = A
        if x then
            local sp = s.spots[id] or {}
            sp.x, sp.y = x, y
            s.spots[id] = sp
        else
            s.spots[id] = nil
            stats.none = (stats.none or 0) + 1
            stats.testNone = (stats.testNone or 0) + 1
            if #s.cands == 0 then stats.noCands = (stats.noCands or 0) + 1 end
        end
        return x, y, z, q
    end
    for pass = 1, 2 do
        if pass == 2 and not loose then break end   -- (a firing position stays on the leash; shelter may go further)
        local lim = pass == 1 and (leash or 7) or CFG.farLeash
        local limSq = lim * lim
        -- (The second look, for shelter: round where he is, not where he was sent - 0.74.2.)
        local px, py = ox, oy
        if pass == 2 then px, py = bx, by end
        local m = 0
        for i = 1, #s.cands do
            local c = s.cands[i]
            local dsq = LF.distSq(c.x + 0.5, c.y + 0.5, px, py)
            if dsq <= limSq and c.td <= maxRange then
                m = m + 1
                local e = scored[m]
                if not e then e = {}; scored[m] = e end
                e.c = c
                -- (A firing position is low cover - over it he can shoot; a wall is shelter only.)
                e.score = CFG.W_COVER * ((c.cls == LF.Ground.LIGHT or loose or gun) and 1 or 0)
                    + CFG.W_SPACE * spacing(s, id, c.x, c.y)
                    + CFG.W_DIST * (1 - math.sqrt(dsq) / lim)
                    - math.max(0, LF.dist(bx, by, tx, ty) - c.td) * 0.5       -- (not walking at the enemy)
                    - (LF.Cover.taken(c.x, c.y, bz, id) and 15 or 0)          -- (right beside another man's spot)
                    - (amongOthers(sid, rec.faction, c.x, c.y) and CFG.W_SPACE * 1.5 or 0)   -- (in among another squad, 0.74.1)
            end
        end
        for i = #scored, m + 1, -1 do scored[i] = nil end
        if m > 1 then table.sort(scored, byScore) end
        if m == 0 then W.empty = W.empty + 1 end
        -- The exact checks, best first: cover against his actual line, free, line of fire.
        local checks = 0
        local best, bestScore, bestQ = nil, nil, nil
        for i = 1, m do
            if checks >= CFG.exactChecks then break end
            local e = scored[i]
            if best and e.score + CFG.W_FIRE <= bestScore then break end    -- (can't beat it)
            local c = e.c
            local q = coverQ(c.x, c.y, bz, tx, ty)
            if not (q == LF.Cover.LOW or ((loose or gun) and q == LF.Cover.HIGH)) then W.quality = W.quality + 1
            elseif LF.Brain.hardClaimed(c.x, c.y, bz, id) or LF.Cover.takenExactly(c.x, c.y, bz, id) then W.claimed = W.claimed + 1
            else
                checks = checks + 1
                local fire = loose or viewOf(c.x, c.y, bz, threat)
                if fire then
                    local sc = e.score + (fire and CFG.W_FIRE or 0)
                    if not best or sc > bestScore then best, bestScore, bestQ = c, sc, q end
                else W.noView = W.noView + 1 end
            end
        end
        if best then return answer(best.x, best.y, bz, bestQ) end
    end
    -- (Shelter or a gun) the nearest covered square to where he was sent, within 14 tiles - past
    -- his leash if that's where the cover is. (0.81.3: he keeps it until his squad moves on - LF_Brain;
    -- 0.81.2 cut this to 5 past his leash instead, and men were left in the open.)
    if loose or gun then
        local lim = CFG.farLeash + 4
        local bestD, best, bestQ = lim * lim, nil, nil
        for i = 1, #s.cands do
            local c = s.cands[i]
            local dsq = LF.distSq(c.x + 0.5, c.y + 0.5, ox, oy)
            if dsq < bestD and c.td <= maxRange + 10 then
                local q = coverQ(c.x, c.y, bz, tx, ty)
                if q ~= LF.Cover.NONE and not LF.Brain.hardClaimed(c.x, c.y, bz, id)
                    and not LF.Cover.takenExactly(c.x, c.y, bz, id) and (not gun or viewOf(c.x, c.y, bz, threat)) then
                    bestD, best, bestQ = dsq, c, q
                end
            end
        end
        if best then
            stats.nearFound = (stats.nearFound or 0) + 1
            return answer(best.x, best.y, bz, bestQ)
        end
    end
    return answer(nil)
end
function LF.SquadBrain.spotFor(id, body, rec, threat, maxRange, ax, ay, leash, loose, gun)
    local t0 = getTimestampMs()
    local x, y, z, q = spotOf(id, body, rec, threat, maxRange, ax, ay, leash, loose, gun)
    LF.Perf.stop("squad spot", t0)
    return x, y, z, q
end

-- (0.82) The sergeant places again (a new order or stance): every man is given his spot afresh -
-- the one he has, if it still does.
function LF.SquadBrain.replace(sid)
    local s = S[sid]
    if s then s.cands = nil end
end
-- (0.85) The enemy a man's spot was found flanked by (and forget it), or nil.
function LF.SquadBrain.takeFlanked(sid, id)
    local s = S[sid]
    local e = s and s.flanked and s.flanked[id]
    if e then s.flanked[id] = nil end
    if e and e.isDead and e:isDead() then return nil end
    return e
end

-- (0.85.1) A man just moved for a flank: no flank check on him for 10 s (no bouncing between two enemies).
function LF.SquadBrain.settled(sid, id)
    local s = S[sid]
    if s and s.flankAt then s.flankAt[id] = LF.tick + 480 end
end

-- (0.82) A man can't get to the spot he was given: the squad works his out again.
function LF.SquadBrain.forgetAnswer(sid, id)
    local s = S[sid]
    if s and s.answers then s.answers[id] = nil end
end

-- (0.81.4) The point the squad last placed against (the middle of the enemy it sees), or nil.
function LF.SquadBrain.threatOf(sid)
    local s = S[sid]
    if s and s.cands and s.tx then return s.tx, s.ty end
    return nil
end

-- (0.80) When the squad last placed (rebuilt its candidates): a man whose search found nothing
-- looks again at once after a new placement.
function LF.SquadBrain.placedAt(sid)
    local s = S[sid]
    return s and s.placedAt
end

-- ---- upkeep --------------------------------------------------------------------------------------

LF.onTick("SquadBrain", function()
    if not LF.SquadBrain.enabled then return end
    -- Each squad in a fight looks on its own beat (staggered by its id).
    for sid, s in pairs(S) do
        local u = LF.Units.get(sid)
        if not u then
            S[sid] = nil
        elseif LF.due(CFG.lookTicks, sid % CFG.lookTicks) and LF.tick - s.seenAt >= CFG.lookTicks then
            LF.guard("squad look", squadLook, sid, s)
        end
    end
    -- A line a minute in the log: how much looking it took.
    if LF.due(3600, 7) and stats.looks > 0 then
        LF.log(string.format("SQUADBRAIN last minute: %d squad looks, %d sight checks, %d placements, %d spots asked for, %d found nothing (%d with no covered square round the squad at all)",
            stats.looks, stats.los, stats.places, stats.spots, stats.none or 0, stats.noCands or 0))
        stats.looks, stats.los, stats.places, stats.spots, stats.none, stats.noCands = 0, 0, 0, 0, 0, 0
    end
end)

-- A squad soldier's mind is in the squad: forget it with him.
function LF.SquadBrain.forget(sid) S[sid] = nil end
function LF.SquadBrain.forgetAll() for k in pairs(S) do S[k] = nil end end
Events.OnInitGlobalModData.Add(function() LF.SquadBrain.forgetAll() end)
