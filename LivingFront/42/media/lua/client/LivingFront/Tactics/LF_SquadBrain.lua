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
require "LivingFront/World/LF_TPS"

LF.SquadBrain = LF.SquadBrain or {}
LF.SquadBrain.enabled = true

local CFG = {
    lookTicks = 30,         -- the squad looks twice a second
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
    local rifle = (LF.Brain and LF.Brain.CFG and LF.Brain.CFG.fireRange) or 20
    local gun = (LF.MG and LF.MG.CFG and LF.MG.CFG.range) or 30
    for i = 1, n do
        local man = men[i]
        local r = man.rec.mgRole == "gunner" and gun or rifle
        local rsq, any = r * r, false
        local bx, by = man.body:getX(), man.body:getY()
        for j = 1, #seen do
            local v = seen[j]
            if LF.distSq(bx, by, v.body:getX(), v.body:getY()) <= rsq then any = true; break end
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
LF.SquadBrain.coverQ = coverQ

function LF.SquadBrain.spotFor(id, body, rec, threat, maxRange, ax, ay, leash, loose, gun)
    local t0 = getTimestampMs()
    -- (0.89: the tactical position system - LF_TPS; a gun's spot must see the enemy, any cover.)
    local x, y, z, q = LF.TPS.spot(id, body, threat, maxRange, ax, ay, leash, (loose and not gun) and "shelter" or "fight")
    LF.Perf.stop("squad spot", t0)
    return x, y, z, q
end

-- (0.82) The sergeant places again (a new order or stance): every man is given his spot afresh -
-- the one he has, if it still does.
-- (0.89) Its men look at their positions again at once (LF_Brain: the "placement" is now just this
-- moment - each man's own query, LF_TPS).
function LF.SquadBrain.replace(sid)
    local s = stateOf(sid)
    s.placedAt = LF.tick
end



-- (0.81.4) The point the squad last placed against (the middle of the enemy it sees), or nil.
function LF.SquadBrain.threatOf(sid)
    local s = S[sid]
    local seen = s and s.seen
    if not (seen and #seen > 0) then return nil end
    local sx, sy, k = 0, 0, 0
    for i = 1, #seen do
        local vb = seen[i].body
        if vb then sx, sy, k = sx + vb:getX(), sy + vb:getY(), k + 1 end
    end
    if k == 0 then return nil end
    return sx / k, sy / k
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
