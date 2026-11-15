-- Living Front: the district battle - its start state (0.88, strategic layer S1).
--
-- The first time a save runs on the Stalingrad map, Downtown North is set up as it stood on 18
-- November 1942, the eve of Operation Uranus, when the Germans held about 90% of the city. From
-- then on only gameplay moves the front: nothing historical is scripted.
--   * Who holds what (CFG.start): the Germans 9 of the district's 16 points; the Soviets a strip
--     along the Volga from the Mill to the Riverside Warehouses with Pavlov's House as its
--     outpost; 9 January Square no-man's land between them.
--   * Every building of the district (the sites file) starts with its sector's holder; in the
--     square, the buildings on Pavlov's side are Soviet, those on the Milk House side German. A few
--     buildings on the line (CFG.shared) start held by both sides, each holding the sections
--     nearer its own ground (LF_Control).
--   * Forces (CFG.sides): a Soviet battalion (13th Guards Rifle Division, 42nd Guards Rifle
--     Regiment) and a German one (71st Infantry Division), each a few companies badly under
--     strength (CFG.rifleSquads, CFG.mgSquads, CFG.squadMen: about half). Each company has its
--     sectors; in them it puts a garrison in every objective it holds (worth 2: two squads), a
--     squad in each building on the line (CFG.frontReach of the enemy, CFG.postSpacing apart,
--     nearest the enemy first; the Milk House and the shared buildings always), spare squads in
--     reserve in the rear, the platoon headquarters behind their squads and the company
--     headquarters in a rear building (CFG.hqBack from the enemy). Nobody is put within
--     CFG.playerClear of you.
--   * After weeks facing each other each side knows the other's front-line posts (sightings
--     filled in), not his reserves or headquarters.
--   * Captains hold (LF_Captain: posture "hold" - no assaults until battalion command, S2).
-- Seeded once per save after the district's objectives; a save version (CFG.version) is kept.
-- Every game hour a BATTLE line logs the budget: records, bodies, units, casualties, control.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Objective"
require "LivingFront/Tactics/LF_Company"
require "LivingFront/World/LF_District"
require "LivingFront/World/LF_Control"

LF.Battle = LF.Battle or {}

local CFG = {
    version = 1,
    district = "downtown_north",
    date = "18 November 1942",
    start = { raildepot = "GER", railwaymen = "GER", square = false, pavlov = "SOV", mill = "SOV", engworks = "GER",
              workshops = "GER", warehouses = "SOV", station = "GER", depot = "GER", nails = "GER", machworks = "GER" },
    noMans = { square = { GER = 290, SOV = 325 } },     -- no-man's land sectors: west of GER x German, east of SOV x Soviet
    milkHouse = { 268, 238 },                           -- the Germans' strongpoint across the square from Pavlov's House
    shared = { { 345, 244 }, { 572, 122 } },            -- buildings on the line held by both sides on day one
    sides = {
        SOV = { unit = "42nd Guards Rifle Regiment, 13th Guards Rifle Division", companies = {
            { name = "7th Company", sectors = { "pavlov", "square" } },
            { name = "8th Company", sectors = { "mill" } },
            { name = "9th Company", sectors = { "warehouses" } },
        } },
        GER = { unit = "71st Infantry Division", companies = {
            { name = "1st Company", sectors = { "raildepot", "railwaymen", "square" } },
            { name = "2nd Company", sectors = { "engworks", "workshops" } },
            { name = "3rd Company", sectors = { "station", "depot", "nails", "machworks" } },
        } },
    },
    rifleSquads = 3,        -- squads kept in each rifle platoon (of 4)
    mgSquads = 2,           -- ... and in the machine-gun platoon
    squadMen = 6,           -- men kept in each squad (of 10): the sergeant, corporals, gunners, medic first
    frontReach = 32,        -- tiles: a building this close to the enemy's is on the line
    postSpacing = 30,       -- tiles between front-line posts
    hqBack = 70,            -- tiles: a company headquarters at least this far from the enemy (if it can be)
    platoonBack = 30,       -- ... a platoon headquarters
    playerClear = 50,       -- tiles: nobody placed this close to you
    reportHours = 1,        -- game hours between BATTLE budget lines
}
LF.Battle.CFG = CFG

local ENEMY = { GER = "SOV", SOV = "GER" }
local WORDS = { GER = "German", SOV = "Soviet" }

local function store()
    local d = LF.Records.data()
    d.battle = d.battle or {}
    return d.battle
end
LF.Battle.store = store

local function hours() local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end); return ok and h or 0 end

-- ---- geometry ------------------------------------------------------------------------------------

local function centre(b) return (b[1] + b[3]) / 2, (b[2] + b[4]) / 2 end
local function boxDist(a, b)
    local dx = math.max(0, a[1] - b[3], b[1] - a[3])
    local dy = math.max(0, a[2] - b[4], b[2] - a[4])
    return math.sqrt(dx * dx + dy * dy)
end
local function partBox(p) return { p[1], p[2], p[3], p[4] } end

-- ---- start owners ----------------------------------------------------------------------------------

local function siteSide(s)
    local h = CFG.start[s.sec]
    local split = CFG.noMans[s.sec]
    if split then
        local cx = centre(s.box)
        if cx < split.GER then return "GER" elseif cx > split.SOV then return "SOV" end
        return nil
    end
    return h or nil
end

local function sharedSites()
    local out = {}
    for _, pt in ipairs(CFG.shared) do
        local s = LF.Control.siteAt(pt[1], pt[2])
        if s and #s.parts >= 2 then out[s.id] = s
        else LF.log("BATTLE no building with two sections at " .. pt[1] .. "," .. pt[2] .. " to share") end
    end
    return out
end

-- Every section's owner on day one.
local function setOwners(sites)
    LF.Control.clear()
    local shared = sharedSites()
    for _, s in ipairs(sites) do
        local side = siteSide(s)
        if side and not shared[s.id] then
            for k in ipairs(s.parts) do LF.Control.set(s.id, k, side) end
        end
    end
    -- A shared building: each section to the side whose ground is nearer it; one at least each.
    for _, s in pairs(shared) do
        local near = {}
        for k, p in ipairs(s.parts) do
            local d = { GER = math.huge, SOV = math.huge }
            for _, o in ipairs(sites) do
                local side = o.id ~= s.id and siteSide(o)
                if side and not shared[o.id] then d[side] = math.min(d[side], boxDist(partBox(p), o.box)) end
            end
            near[k] = d
        end
        local own, n = {}, { GER = 0, SOV = 0 }
        for k in ipairs(s.parts) do
            own[k] = near[k].GER <= near[k].SOV and "GER" or "SOV"
            n[own[k]] = n[own[k]] + 1
        end
        for side, cnt in pairs(n) do
            if cnt == 0 then
                local best, bv = nil, math.huge
                for k in ipairs(s.parts) do
                    local v = near[k][side] - near[k][ENEMY[side]]
                    if v < bv then best, bv = k, v end
                end
                own[best] = side
            end
        end
        local words = {}
        for k in ipairs(s.parts) do
            LF.Control.set(s.id, k, own[k])
            words[#words + 1] = k .. " " .. own[k]
        end
        LF.log("BATTLE shared building " .. LF.Control.siteName(s) .. ": sections " .. table.concat(words, ", "))
    end
    return shared
end

-- ---- the forces --------------------------------------------------------------------------------------

local function dropUnit(u)
    if not u then return end
    for _, tid in ipairs(u.teams or {}) do
        local t = LF.Units.get(tid)
        for _, rid in ipairs(t and t.members or {}) do LF.Records.remove(rid) end
        LF.Units.all()[tid] = nil
    end
    if u.leader then LF.Records.remove(u.leader) end
    LF.Units.dirty(u.id)
    LF.Units.all()[u.id] = nil
end

-- Keep the squad's n most needed men (sergeant, corporals, gunners, then the medic).
local function thinSquad(sq, n)
    local list = {}
    for _, rid in ipairs(LF.Units.members(sq.id)) do
        local r = LF.Records.get(rid)
        if r then
            local pr = 4
            if rid == sq.leader then pr = 0
            elseif r.mgRole == "gunner" or r.rank == "CPL" then pr = 1
            elseif r.medic then pr = 2
            elseif r.mgRole == "assistant" then pr = 3 end
            list[#list + 1] = { r = r, pr = pr + ZombRandFloat(0, 0.5) }
        end
    end
    table.sort(list, function(a, b) return a.pr < b.pr end)
    local cut = {}
    for i = n + 1, #list do cut[list[i].r.id] = true end
    for _, tid in ipairs(sq.teams) do
        local t = LF.Units.get(tid)
        if t then
            local keep = {}
            for _, rid in ipairs(t.members) do
                if cut[rid] then LF.Records.remove(rid) else keep[#keep + 1] = rid end
            end
            t.members = keep
            if t.leader and cut[t.leader] then t.leader = keep[1] end
        end
    end
    LF.Units.dirty(sq.id)
end

-- A company badly under strength: its headquarters and four platoons, the platoons cut down.
local function raise(side, def, x, y, fx, fy)
    local c = LF.Company.create(side, x, y, 0, fx, fy)
    c.name = (side == "GER" and "German " or "Soviet ") .. def.name
    local hq = LF.Company.hq(c)
    if hq then hq.name = c.name .. " HQ" end
    for _ = 1, LF.Company.CFG.platoons do
        local p = LF.Company.addPlatoon(c)
        if not p then break end
        local keepN = p.mgPlatoon and CFG.mgSquads or CFG.rifleSquads
        local keep = {}
        for i, sid in ipairs(p.squads) do
            local sq = LF.Units.get(sid)
            if i <= keepN then keep[#keep + 1] = sid; thinSquad(sq, CFG.squadMen)
            else dropUnit(sq) end
        end
        p.squads = keep
    end
    c.posture = "hold"
    return c
end

local function companySquads(c)
    local out = {}
    for _, p in ipairs(LF.Company.platoons(c)) do
        for _, sid in ipairs(p.squads or {}) do
            local sq = LF.Units.get(sid)
            if sq then out[#out + 1] = { sq = sq, p = p, men = #LF.Units.members(sq.id) } end
        end
    end
    return out
end

-- The men of a unit off-screen onto squares of a box (2 apart), the commander on the anchor.
local function settle(u, p, z)
    local spots = {}
    local step = ((p[3] - p[1]) * (p[4] - p[2]) > 60) and 2 or 1
    for x = p[1] + 1, p[3] - 1, step do
        for y = p[2] + 1, p[4] - 1, step do spots[#spots + 1] = { x + 0.5, y + 0.5 } end
    end
    if #spots == 0 then spots[1] = { p[5] + 0.5, p[6] + 0.5 } end
    -- (Shuffled, so a squad isn't a block in one corner of a long section.)
    for i = #spots, 2, -1 do local j = ZombRand(i) + 1; spots[i], spots[j] = spots[j], spots[i] end
    local i = 0
    local cmd = LF.Units.commander(u)
    for _, rid in ipairs(LF.Units.members(u.id)) do
        local r = LF.Records.get(rid)
        if r and r.alive then
            if rid == cmd then r.x, r.y = p[5] + 0.5, p[6] + 0.5
            else i = i + 1; local sp = spots[(i - 1) % #spots + 1]; r.x, r.y = sp[1], sp[2] end
            r.z, r.homeX, r.homeY, r.homeZ = z or 0, r.x, r.y, z or 0
        end
    end
end

-- A unit takes up its post in one section of a building.
local function post(u, c, s, k, kind)
    local p = s.parts[k]
    u.post = { company = c.id, site = s.id, part = k, kind = kind, since = LF.simTime }
    settle(u, p, 0)
    LF.Tactics.setStance(u, "defensive", { x = p[5], y = p[6], z = 0, part = partBox(p) })
end

-- ---- seeding ---------------------------------------------------------------------------------------

local function objectiveFor(d, key)
    for _, e in ipairs(d.objectives) do
        if e.key == key then return LF.District.objectiveOf(d, e), e end
    end
    return nil
end

function LF.Battle.seed()
    local d = LF.District.get(CFG.district)
    if not d then return false, "no district " .. CFG.district .. " on this map" end
    local t0 = getTimestampMs()
    local sites = LF.Control.sites()
    -- 1. Who holds what: the objectives, then every building's sections.
    for key, h in pairs(CFG.start) do
        local o = objectiveFor(d, key)
        if o then
            o.holder, o.contested = h or nil, nil
            o.noMans = (h == false) or nil
            LF.Objective.rename(o)
        end
    end
    local shared = setOwners(sites)
    -- Distances: each building from the enemy's nearest (a shared building counts for both sides).
    local P = getPlayer()
    local px, py = P and P:getX() or -9999, P and P:getY() or -9999
    local info = {}
    for _, s in ipairs(sites) do
        local own = LF.Control.siteOwner(s)
        info[s.id] = { s = s, own = own, dE = { GER = math.huge, SOV = math.huge } }
    end
    local held = { GER = {}, SOV = {} }
    for _, s in ipairs(sites) do
        local o = info[s.id].own
        if o == "GER" or o == "split" then held.GER[#held.GER + 1] = s end
        if o == "SOV" or o == "split" then held.SOV[#held.SOV + 1] = s end
    end
    for _, s in ipairs(sites) do
        local I = info[s.id]
        for side in pairs(WORDS) do
            if I.own == side or I.own == "split" then
                local best = math.huge
                for _, o in ipairs(held[ENEMY[side]]) do
                    if o.id ~= s.id then best = math.min(best, boxDist(s.box, o.box)) end
                end
                I.dE[side] = I.own == "split" and 0 or best
            end
        end
    end
    local function nearPlayer(s) local cx, cy = centre(s.box); return LF.dist(cx, cy, px, py) < CFG.playerClear end
    local used = {}
    -- The section of a building a side's squad takes: its own, nearest the enemy.
    local function bestPart(s, side)
        local best, bd = nil, math.huge
        for k, p in ipairs(s.parts) do
            if LF.Control.owner(s.id, k) == side then
                local dd = math.huge
                for _, o in ipairs(held[ENEMY[side]]) do
                    if o.id ~= s.id then dd = math.min(dd, boxDist(partBox(p), o.box)) end
                end
                if shared[s.id] then
                    for k2, p2 in ipairs(s.parts) do
                        if LF.Control.owner(s.id, k2) == ENEMY[side] then dd = math.min(dd, boxDist(partBox(p), partBox(p2))) end
                    end
                end
                if dd < bd and not used[s.id .. ":" .. k] then best, bd = k, dd end
            end
        end
        return best
    end
    local milk = LF.Control.siteAt(CFG.milkHouse[1], CFG.milkHouse[2])
    local made = { companies = {}, men = { GER = 0, SOV = 0 }, posts = 0, short = 0 }
    for side, sd in pairs(CFG.sides) do
        for ci, def in ipairs(sd.companies) do
            local inSec = {}
            for _, k in ipairs(def.sectors) do inSec[k] = true end
            local area = {}
            for _, s in ipairs(sites) do
                local o = info[s.id].own
                if inSec[s.sec] and (o == side or o == "split") then area[#area + 1] = s end
            end
            if #area == 0 then
                LF.log("BATTLE " .. WORDS[side] .. " " .. def.name .. ": no buildings of its side in " .. table.concat(def.sectors, ", "))
            else
                -- The jobs, in order: garrisons, forced posts, the line nearest the enemy first.
                local jobs = {}
                local taken = {}
                for _, key in ipairs(def.sectors) do
                    local o, e = objectiveFor(d, key)
                    if o and o.holder == side then
                        local os = LF.Control.siteAt(o.anchor and o.anchor[1] or o.x, o.anchor and o.anchor[2] or o.y)
                        if os then
                            for n = 1, (e.weight or 1) do jobs[#jobs + 1] = { s = os, obj = n == 1 and o or nil, kind = "objective" } end
                            taken[os.id] = true
                        else
                            jobs[#jobs + 1] = { obj = o, kind = "objective" }
                        end
                    end
                end
                local forced = {}
                if milk and info[milk.id].own == side and inSec[milk.sec] then forced[#forced + 1] = milk end
                for _, s in pairs(shared) do if inSec[s.sec] then forced[#forced + 1] = s end end
                for _, s in ipairs(forced) do
                    if not taken[s.id] then jobs[#jobs + 1] = { s = s, kind = "front" }; taken[s.id] = not shared[s.id] or nil end
                end
                local front = {}
                for _, s in ipairs(area) do
                    if not taken[s.id] and info[s.id].dE[side] <= CFG.frontReach and not nearPlayer(s) then front[#front + 1] = s end
                end
                table.sort(front, function(a, b) return info[a.id].dE[side] < info[b.id].dE[side] end)
                local spots = {}
                for _, j in ipairs(jobs) do if j.s then local x, y = centre(j.s.box); spots[#spots + 1] = { x, y } end end
                for _, s in ipairs(front) do
                    local x, y = centre(s.box)
                    local ok = true
                    for _, q in ipairs(spots) do if LF.dist(x, y, q[1], q[2]) < CFG.postSpacing then ok = false; break end end
                    if ok then jobs[#jobs + 1] = { s = s, kind = "front" }; spots[#spots + 1] = { x, y }; taken[s.id] = true end
                end
                -- The company headquarters: a rear building, far enough from the enemy.
                local jx, jy, jn = 0, 0, 0
                for _, j in ipairs(jobs) do
                    local x, y
                    if j.s then x, y = centre(j.s.box) else x, y = j.obj.x, j.obj.y end
                    jx, jy, jn = jx + x, jy + y, jn + 1
                end
                if jn == 0 then local x, y = centre(area[1].box); jx, jy, jn = x, y, 1 end
                jx, jy = jx / jn, jy / jn
                local hqSite, hqScore = nil, math.huge
                for _, s in ipairs(area) do
                    if not taken[s.id] and info[s.id].own == side and not nearPlayer(s) then
                        local x, y = centre(s.box)
                        local dE = info[s.id].dE[side]
                        local score = LF.dist(x, y, jx, jy) + (dE < CFG.hqBack and (CFG.hqBack - dE) * 6 or 0)
                        if score < hqScore then hqSite, hqScore = s, score end
                    end
                end
                hqSite = hqSite or area[1]
                taken[hqSite.id] = true
                local hx, hy = hqSite.parts[1][5], hqSite.parts[1][6]
                -- Facing the enemy's nearest building.
                local ex, ey, ed = nil, nil, math.huge
                for _, o in ipairs(held[ENEMY[side]]) do
                    local x, y = centre(o.box)
                    local dd = LF.dist(x, y, hx, hy)
                    if dd < ed then ex, ey, ed = x, y, dd end
                end
                local fx, fy = 1, 0
                if ex and ed > 1 then fx, fy = (ex - hx) / ed, (ey - hy) / ed end
                local c = raise(side, def, hx + 0.5, hy + 0.5, fx, fy)
                c.battle = { sectors = def.sectors, index = ci }
                made.companies[#made.companies + 1] = c.id
                local chq = LF.Company.hq(c)
                if chq then
                    chq.post = { company = c.id, site = hqSite.id, part = 1, kind = "hq", since = LF.simTime }
                    settle(chq, hqSite.parts[1], 0)
                    LF.Tactics.setStance(chq, "defensive", { x = hx, y = hy, z = 0, part = partBox(hqSite.parts[1]) })
                end
                -- The squads to their jobs: the strongest to the objectives.
                local squads = companySquads(c)
                table.sort(squads, function(a, b)
                    if (a.sq.mg or false) ~= (b.sq.mg or false) then return not a.sq.mg end
                    return a.men > b.men
                end)
                local si, filled, words = 1, 0, {}
                for _, j in ipairs(jobs) do
                    local e = squads[si]
                    if not e then made.short = made.short + 1
                    else
                        si = si + 1
                        filled = filled + 1
                        local sq = e.sq
                        if j.obj and j.s then
                            LF.Platoon.garrison(sq, c, j.obj)
                            sq.garrison.fixed = true
                            LF.Objective.hold(sq, j.obj)
                            local k = bestPart(j.s, side) or 1
                            used[j.s.id .. ":" .. k] = true
                            settle(sq, j.s.parts[k], 0)
                            words[#words + 1] = j.obj.name
                        elseif j.obj then
                            LF.Platoon.garrison(sq, c, j.obj)
                            sq.garrison.fixed = true
                            LF.Objective.hold(sq, j.obj)
                            words[#words + 1] = j.obj.name
                        else
                            local k = bestPart(j.s, side)
                            if k then
                                used[j.s.id .. ":" .. k] = true
                                post(sq, c, j.s, k, j.kind)
                                words[#words + 1] = LF.Control.siteName(j.s) .. "/" .. k
                            else
                                si, filled = si - 1, filled - 1
                            end
                        end
                    end
                end
                -- Spare squads: in reserve, in the rear buildings nearest the headquarters.
                local rear = {}
                for _, s in ipairs(area) do
                    if not taken[s.id] and info[s.id].own == side and info[s.id].dE[side] > CFG.frontReach and not nearPlayer(s) then
                        rear[#rear + 1] = s
                    end
                end
                table.sort(rear, function(a, b)
                    local ax, ay = centre(a.box); local bx, by = centre(b.box)
                    return LF.dist(ax, ay, hx, hy) < LF.dist(bx, by, hx, hy)
                end)
                local ri, reserves = 1, 0
                while squads[si] and rear[ri] do
                    post(squads[si].sq, c, rear[ri], 1, "reserve")
                    taken[rear[ri].id] = true
                    si, ri, reserves = si + 1, ri + 1, reserves + 1
                end
                -- Platoon headquarters: behind their squads, a building of their own.
                for _, p in ipairs(LF.Company.platoons(c)) do
                    local hq = LF.Units.get(p.hq)
                    local sx, sy, n = 0, 0, 0
                    for _, sid in ipairs(p.squads or {}) do
                        local ax, ay = LF.Squad.anchor(sid)
                        if ax then sx, sy, n = sx + ax, sy + ay, n + 1 end
                    end
                    local best, bs = nil, math.huge
                    if n > 0 then
                        sx, sy = sx / n, sy / n
                        for _, s in ipairs(area) do
                            if not taken[s.id] and info[s.id].own == side and not nearPlayer(s) then
                                local x, y = centre(s.box)
                                local dE = info[s.id].dE[side]
                                local score = LF.dist(x, y, sx, sy) + (dE < CFG.platoonBack and (CFG.platoonBack - dE) * 6 or 0)
                                if score < bs then best, bs = s, score end
                            end
                        end
                    end
                    best = best or hqSite
                    taken[best.id] = true
                    if hq then
                        hq.post = { company = c.id, site = best.id, part = 1, kind = "hq", since = LF.simTime }
                        settle(hq, best.parts[1], 0)
                        LF.Tactics.setStance(hq, "defensive", { x = best.parts[1][5], y = best.parts[1][6], z = 0, part = partBox(best.parts[1]) })
                    end
                end
                local men = 0
                for _, rid in ipairs(LF.Units.members(chq and chq.id or -1)) do men = men + 1 end
                for _, e in ipairs(companySquads(c)) do men = men + e.men end
                for _, e in ipairs(squads) do if not e.sq.platoon then men = men + e.men end end      -- (garrisons left their platoons)
                for _, p in ipairs(LF.Company.platoons(c)) do men = men + #LF.Units.members(p.hq) end
                made.men[side] = made.men[side] + men
                made.posts = made.posts + filled
                LF.log(string.format("BATTLE %s: HQ in %s; %d men; %d job(s) of %d filled%s; %d squad(s) in reserve; posts: %s",
                    c.name, LF.Control.siteName(hqSite), men, filled, #jobs, filled < #jobs and (" - " .. (#jobs - filled) .. " left empty") or "",
                    reserves, table.concat(words, "; ")))
            end
        end
    end
    -- 3. Each side knows the other's front-line posts.
    local known = { GER = 0, SOV = 0 }
    if LF.Front and LF.Front.know then
        local postsOf = { GER = {}, SOV = {} }
        for _, u in pairs(LF.Units.all()) do
            local kind = u.post and u.post.kind or (u.garrison and u.garrison.fixed and "objective")
            if (kind == "front" or kind == "objective") and postsOf[u.faction] then
                local x, y = LF.Squad.anchor(u.id)
                if x then postsOf[u.faction][#postsOf[u.faction] + 1] = { u = u, x = x, y = y } end
            end
        end
        for side in pairs(WORDS) do
            for _, e in ipairs(postsOf[ENEMY[side]]) do
                local seen = false
                for _, m in ipairs(postsOf[side]) do
                    if LF.dist(m.x, m.y, e.x, e.y) <= CFG.frontReach * 1.6 then seen = true; break end
                end
                if seen then LF.Front.know(side, e.u, e.x, e.y); known[side] = known[side] + 1 end
            end
        end
    end
    local st = store()
    st.version, st.date, st.seededAt, st.seededHours = CFG.version, CFG.date, LF.simTime, hours()
    st.companies, st.lastReport = made.companies, hours()
    st.startMen = { GER = made.men.GER, SOV = made.men.SOV }
    local sum = LF.Control.summary()
    local tally = LF.District.tally(d)
    LF.log(string.format("BATTLE seeded %s - %s: %d companies, %d German and %d Soviet men, %d posts filled (%d short); "
        .. "district German %d, Soviet %d, no-man's land %d of %d; sections German %d, Soviet %d, %d building(s) shared; "
        .. "known posts: Germans know %d, Soviets %d; %d ms",
        d.name, CFG.date, #made.companies, made.men.GER, made.men.SOV, made.posts, made.short,
        tally.GER, tally.SOV, tally.none, tally.total, sum.GER, sum.SOV, sum.split, known.GER, known.SOV, getTimestampMs() - t0))
    return true
end

-- Debug tools: the battle's units taken away (every unit of its companies, and their men).
function LF.Battle.clear()
    local st = store()
    local n = 0
    local mine = {}
    for _, cid in ipairs(st.companies or {}) do mine[cid] = true end
    for id, u in pairs(LF.Units.all()) do
        local c = LF.Company and LF.Company.of(u)
        local cid = (u.kind == "company" and u.id) or (c and c.id) or (u.garrison and u.garrison.company) or (u.post and u.post.company)
        if cid and mine[cid] and (u.kind == "squad" or u.kind == "hq") then
            for _, rid in ipairs(LF.Units.members(id)) do
                if LF.Bodies.get(rid) then LF.Bodies.despawn(rid) end
                LF.Records.remove(rid); n = n + 1
            end
        end
    end
    for id, u in pairs(LF.Units.all()) do
        local c = LF.Company and LF.Company.of(u)
        local cid = (u.kind == "company" and u.id) or (c and c.id) or (u.garrison and u.garrison.company) or (u.post and u.post.company)
        if cid and mine[cid] then LF.Units.all()[id] = nil end
    end
    for _, u in pairs(LF.Units.all()) do if u.kind == "team" and u.squad and not LF.Units.get(u.squad) then LF.Units.all()[u.id] = nil end end
    for k in pairs(st) do st[k] = nil end
    LF.Control.clear()
    LF.log("BATTLE cleared: " .. n .. " men taken away")
    return n
end

-- ---- the budget: a BATTLE line every game hour -----------------------------------------------------

function LF.Battle.report()
    local st = store()
    local men = { GER = 0, SOV = 0 }
    local dead = { GER = 0, SOV = 0 }
    local hurt = { GER = 0, SOV = 0 }
    local recs = 0
    for _, r in pairs(LF.Records.all()) do
        recs = recs + 1
        if men[r.faction] then
            if r.alive then men[r.faction] = men[r.faction] + 1; if r.wounded then hurt[r.faction] = hurt[r.faction] + 1 end
            else dead[r.faction] = dead[r.faction] + 1 end
        end
    end
    local bodies = 0
    for _, b in pairs(LF.Bodies.all()) do if not b:isDead() then bodies = bodies + 1 end end
    local units = 0
    for _ in pairs(LF.Units.all()) do units = units + 1 end
    local d = LF.District.get(CFG.district)
    local t = d and LF.District.tally(d) or { GER = 0, SOV = 0, none = 0, total = 0, contested = 0 }
    local sum = LF.Control.summary()
    local moved = 0
    for _, u in pairs(LF.Units.all()) do
        if u.post and u.kind == "squad" then
            local s = LF.Control.site(u.post.site)
            local x, y = LF.Squad.anchor(u.id)
            if s and x and LF.dist(x, y, centre(s.box)) > 40 then moved = moved + 1 end
        end
    end
    local pf = LF.Perf and LF.Perf.last and LF.Perf.last()
    local hrs = hours() - (st.seededHours or hours())
    LF.log(string.format("BATTLE day %d %02d:00 (%.1f game h in): men German %d (%d wounded, %d dead), Soviet %d (%d wounded, %d dead); "
        .. "records %d, bodies %d, units %d; district German %d, Soviet %d, contested %d, nobody %d of %d; sections German %d, Soviet %d, "
        .. "contested %d, %d split; posts away from their building %d; %s",
        math.floor(hrs / 24) + 1, math.floor(hours() % 24), hrs, men.GER, hurt.GER, dead.GER, men.SOV, hurt.SOV, dead.SOV,
        recs, bodies, units, t.GER, t.SOV, t.contested, t.none, t.total, sum.GER, sum.SOV, sum.contested, sum.split, moved,
        pf and string.format("perf: %.1f fps, mod %.2f ms a frame (%s)", pf.fps, pf.mod, table.concat(pf.top or {}, " ")) or "perf log off"))
end

-- ---- each update ------------------------------------------------------------------------------------

LF.on("OnTick", "Battle", function()
    if not LF.due(300, 23) then return end
    local d = LF.District.get(CFG.district)
    if not d then return end
    local st = store()
    if not st.version then
        if st.skipped then return end
        if not getPlayer() then return end
        for _, e in ipairs(d.objectives) do if not LF.District.objectiveOf(d, e) then return end end   -- (the district first)
        LF.guard("battle seed", LF.Battle.seed)
        if not st.version then st.skipped = true end
        return
    end
    if st.version < CFG.version and not st.warned then
        st.warned = true
        LF.log("BATTLE this save's battle was set up by an older version (" .. st.version .. ", now " .. CFG.version
            .. ") - kept; debug tools can set it up again")
    end
    if hours() - (st.lastReport or 0) >= CFG.reportHours then
        st.lastReport = hours()
        LF.guard("battle report", LF.Battle.report)
    end
end)
