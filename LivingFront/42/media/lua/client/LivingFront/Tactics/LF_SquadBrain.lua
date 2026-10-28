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
require "LivingFront/World/LF_Bodies"
require "LivingFront/World/LF_Sense"
require "LivingFront/World/LF_Cover"
require "LivingFront/World/LF_Ground"
require "LivingFront/Units/LF_Units"

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
    placeEvery = 600,       -- placement is redone at least this often while in use
    placeTurn = 0.7,        -- ... or when the threat swings more than ~45 degrees (cos)
    placeMove = 4,          -- ... or the squad's middle has moved this far
    placeRadius = 9,        -- squares this far round the squad's men are candidates
    farLeash = 10,          -- no cover on his leash: this far for shelter
    exactChecks = 6,        -- candidates given the exact cover and sight checks per man, at most
    W_COVER = 40, W_FIRE = 30, W_SPACE = 20, W_DIST = 10,
}
LF.SquadBrain.CFG = CFG

local S = {}                -- squad id -> state
local stats = { los = 0, looks = 0, places = 0, spots = 0, at = 0 }
LF.SquadBrain.stats = stats

local function stateOf(sid)
    local s = S[sid]
    if not s then
        s = { seen = {}, seenAt = -100000, pairs = {}, cands = nil, spots = {} }
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
    local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, n do
        local b = men[i].body
        x0, x1 = math.min(x0, b:getX()), math.max(x1, b:getX())
        y0, y1 = math.min(y0, b:getY()), math.max(y1, b:getY())
    end
    local r = CFG.placeRadius
    x0, x1 = math.floor(x0 - r), math.floor(x1 + r)
    y0, y1 = math.floor(y0 - r), math.floor(y1 + r)
    -- (At most 25 x 25 squares round its middle.)
    x0, x1 = math.max(x0, math.floor(cx - 12)), math.min(x1, math.floor(cx + 12))
    y0, y1 = math.max(y0, math.floor(cy - 12)), math.min(y1, math.floor(cy + 12))
    for x = x0, x1 do
        for y = y0, y1 do
            local tdsq = LF.distSq(x + 0.5, y + 0.5, tx, ty)
            if tdsq > 16 then
                local q = LF.Cover.quality(x, y, cz, tx, ty)
                if q ~= LF.Cover.NONE then
                    list[#list + 1] = { x = x, y = y, cls = q == LF.Cover.HIGH and LF.Ground.HEAVY or LF.Ground.LIGHT, td = math.sqrt(tdsq) }
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

local scored = {}
local function byScore(a, b) return a.score > b.score end

-- A squad soldier's cover (in place of LF.Cover.findFiringPosition): x, y, z, quality or nil.
-- The arguments are findFiringPosition's (threat, maxRange, anchor, leash, loose).
function LF.SquadBrain.spotFor(id, body, rec, threat, maxRange, ax, ay, leash, loose)
    local sid = rec.squad
    local s = stateOf(sid)
    local tx, ty = threat:getX(), threat:getY()
    local men, n, cx, cy, cz = menOf(sid)
    if n == 0 then return nil end
    local bz = math.floor(body:getZ())
    -- Trigger: the threat has swung, the squad has moved, or it's been a while.
    local stale = not s.cands or LF.tick - s.placedAt > CFG.placeEvery or s.placedAt > LF.tick
        or LF.dist(cx, cy, s.cx, s.cy) > CFG.placeMove
    if not stale then
        local ax0, ay0 = s.tx - s.cx, s.ty - s.cy
        local ax1, ay1 = tx - cx, ty - cy
        local l0, l1 = math.sqrt(ax0 * ax0 + ay0 * ay0), math.sqrt(ax1 * ax1 + ay1 * ay1)
        if l0 > 0.1 and l1 > 0.1 and (ax0 * ax1 + ay0 * ay1) / (l0 * l1) < CFG.placeTurn then stale = true end
    end
    if stale then buildCands(sid, s, men, n, cx, cy, cz, tx, ty) end
    stats.spots = stats.spots + 1
    local bx, by = body:getX(), body:getY()
    local ox, oy = ax or bx, ay or by
    local cell = getCell()
    for pass = 1, 2 do
        local lim = pass == 1 and (leash or 7) or CFG.farLeash
        local limSq = lim * lim
        local m = 0
        for i = 1, #s.cands do
            local c = s.cands[i]
            local dsq = LF.distSq(c.x + 0.5, c.y + 0.5, ox, oy)
            if dsq <= limSq and c.td <= maxRange then
                m = m + 1
                local e = scored[m]
                if not e then e = {}; scored[m] = e end
                e.c = c
                -- (A firing position is low cover - over it he can shoot; a wall is shelter only.)
                e.score = CFG.W_COVER * ((c.cls == LF.Ground.LIGHT or loose) and 1 or 0)
                    + CFG.W_SPACE * spacing(s, id, c.x, c.y)
                    + CFG.W_DIST * (1 - math.sqrt(dsq) / lim)
                    - math.max(0, LF.dist(bx, by, tx, ty) - c.td) * 0.5       -- (not walking at the enemy)
            end
        end
        for i = #scored, m + 1, -1 do scored[i] = nil end
        if m > 1 then table.sort(scored, byScore) end
        -- The exact checks, best first: cover against his actual line, free, line of fire.
        local checks = 0
        local best, bestScore, bestQ = nil, nil, nil
        for i = 1, m do
            if checks >= CFG.exactChecks then break end
            local e = scored[i]
            if best and e.score + CFG.W_FIRE <= bestScore then break end    -- (can't beat it)
            local c = e.c
            local q = LF.Cover.quality(c.x, c.y, bz, tx, ty)
            if (q == LF.Cover.LOW or (loose and q == LF.Cover.HIGH)) and not LF.Brain.hardClaimed(c.x, c.y, bz, id)
                and not LF.Cover.taken(c.x, c.y, bz, id) then
                local sq = cell:getGridSquare(c.x, c.y, bz)
                if sq and sq:isFree(false) and not sq:getBuilding() then
                    checks = checks + 1
                    local fire = loose or LF.Cover.canSeeFrom(c.x, c.y, bz, threat)
                    if loose or fire then
                        local sc = e.score + (fire and CFG.W_FIRE or 0)
                        if not best or sc > bestScore then best, bestScore, bestQ = c, sc, q end
                    end
                end
            end
        end
        if best then
            local sp = s.spots[id] or {}
            sp.x, sp.y = best.x, best.y
            s.spots[id] = sp
            return best.x, best.y, bz, bestQ
        end
        if not loose then break end          -- (a firing position stays on the leash; shelter may go further)
    end
    s.spots[id] = nil
    return nil
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
        LF.log(string.format("SQUADBRAIN last minute: %d squad looks, %d sight checks, %d placements, %d spots handed out",
            stats.looks, stats.los, stats.places, stats.spots))
        stats.looks, stats.los, stats.places, stats.spots = 0, 0, 0, 0
    end
end)

-- A squad soldier's mind is in the squad: forget it with him.
function LF.SquadBrain.forget(sid) S[sid] = nil end
function LF.SquadBrain.forgetAll() for k in pairs(S) do S[k] = nil end end
Events.OnInitGlobalModData.Add(function() LF.SquadBrain.forgetAll() end)
