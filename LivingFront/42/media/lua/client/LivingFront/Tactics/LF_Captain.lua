-- Living Front: the company commander (roadmap phase 5, step C2).
--
-- Every few simulated seconds each captain looks at his picture and puts his FREE squads to work.
-- He never re-tasks a squad that is busy - an assault under way, a withdrawal, a probe out, a
-- garrison - so deciding often costs nothing and never thrashes.
--
-- His picture: his own platoons as their lieutenants know them (by radio - instant); the enemy as
-- his side's reported sightings show it (each reached a headquarters after a runner's run -
-- LF_Front); objectives as his side last saw them; what his probes have found.
--
-- He works with squads, not whole platoons - there is no reserve: every free squad is his to use.
--   1. A finished job frees its men: an objective taken leaves ONE squad holding it (a garrison,
--      answering to him) and the rest are free again; squads lent to the assault go back to their
--      own platoons. A withdrawal that has rallied frees everyone.
--   2. Defence first: each objective his side holds on the front line gets a garrison squad (two if
--      the enemy is reported close in strength). A garrison of an objective no longer on the front
--      is let go after a while.
--   3. Probes: a worthwhile objective he knows nothing (recent) about gets one squad sent to look
--      from CFG.probeStand tiles short of it, for CFG.probeWatch seconds; it pulls back at the first
--      contact. What it saw reaches him when its runner reaches the lieutenant.
--   4. Assaults, best objective first (worth / distance): a lieutenant with his free squads leads,
--      and squads from other platoons are lent to him until the group has CFG.odds times the
--      enemy he expects there (a machine-gun squad goes along as support when there is one free).
--      As many at once as he has lieutenants free and squads to fill them.
-- (Before all of these: squads that need to go back to the company headquarters go - LF_XO.)
-- Orders go to the lieutenants by radio (instant) and from them to the squads by voice or runner;
-- they are heard on the radio net. Every decision is logged with its reasons ("CAPTAIN ...").

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Objective"
require "LivingFront/Tactics/LF_Platoon"
require "LivingFront/Tactics/LF_Company"
require "LivingFront/World/LF_Front"

LF.Captain = LF.Captain or {}

local CFG = {
    on = true,              -- captains command their companies (debug tools can turn it off)
    every = 10,             -- simulated seconds between looks
    stale = 1800,           -- simulated seconds: news older than this counts as no news
    near = 50,              -- tiles: enemy this close to an objective counts as there
    threat = 70,            -- tiles: enemy this close to one of his objectives threatens it
    frontReach = 90,        -- tiles: enemy (reported) this close makes an objective front line
    odds = 1.3,             -- attackers wanted per enemy expected
    minAttack = 6,          -- fit men in an assault at the least
    probeStand = 35,        -- tiles short of the objective the probe looks from
    probeWatch = 180,       -- simulated seconds it watches
    probeOut = 900,         -- ... gives up getting there after this
    probes = 2,             -- probes out at once, at most
    maxRange = 700,         -- tiles: objectives further than this from his squads are out of his reach
    releaseAfter = 300,     -- simulated seconds an objective must be off the front before its garrison goes
}
LF.Captain.CFG = CFG

local ENEMY = { GER = "SOV", SOV = "GER" }

local function title(rec) return rec and LF.Units.title(rec) or "?" end
local function short(u) return u and (u.name:gsub("^.* / ", "")) or "?" end

local function captainOf(c)
    local hq = LF.Company.hq(c)
    local r = hq and hq.leader and LF.Records.get(hq.leader)
    if r and r.alive and r.rank == "CPT" then return r end
    return nil
end

local function recPos(id)
    local b = LF.Bodies and LF.Bodies.get(id)
    if b and not b:isDead() then return b:getX(), b:getY(), math.floor(b:getZ()) end
    local r = LF.Records.get(id)
    if r and r.alive then return r.x, r.y, r.z or 0 end
    return nil
end

local function squadPos(sq)
    local x, y, z = LF.Platoon.posOf(sq)
    return x, y, z
end

local function fitOf(sq)
    local n = 0
    for _, rid in ipairs(LF.Units.members(sq.id)) do
        local r = LF.Records.get(rid)
        if r and r.alive and not r.wounded and not r.captured and not r.aid then n = n + 1 end
    end
    return n
end

local function isMG(sq) return sq.mg or (sq.name and sq.name:find("MG squad", 1, true) ~= nil) end

local function radio(c, cap, text)
    if LF.Radio and LF.Radio.broadcast then LF.Radio.broadcast(c.faction, title(cap), c.name, text) end
end

local function intelOf(c) c.intel = c.intel or {}; return c.intel end

-- ---- his picture ---------------------------------------------------------------------------------

-- The enemy he expects at objective obj: fit men, and how old the news is (nil, nil: no news).
local function expectedAt(c, obj)
    local side = c.faction
    local men, age = 0, nil
    local nearSq = CFG.near * CFG.near
    for _, s in pairs(LF.Front.sightings(side)) do
        local a = LF.simTime - s.at
        if a <= CFG.stale and LF.distSq(s.x, s.y, obj.x, obj.y) <= nearSq then
            men = men + (s.men or 0)
            if not age or a < age then age = a end
        end
    end
    local i = intelOf(c)[obj.id]
    if i and i.reportAt <= LF.simTime and LF.simTime - i.at <= CFG.stale then
        local a = LF.simTime - i.at
        if not age or a < age then men, age = math.max(men, i.men), a end
    end
    return age and men or nil, age
end

-- Is the enemy (as reported) within r tiles of (x, y)? Fit men.
local function enemyNear(c, x, y, r)
    local men = 0
    local rsq = r * r
    for _, s in pairs(LF.Front.sightings(c.faction)) do
        if LF.simTime - s.at <= CFG.stale and LF.distSq(s.x, s.y, x, y) <= rsq then men = men + (s.men or 0) end
    end
    return men
end

-- Neighbouring sectors (from the borders between them).
local function neighbours()
    local adj = {}
    local _, edges = LF.Front.shapes()
    for _, e in ipairs(edges) do
        adj[e.a] = adj[e.a] or {}; adj[e.a][e.b] = true
        adj[e.b] = adj[e.b] or {}; adj[e.b][e.a] = true
    end
    return adj
end

-- What his side believes of an objective: holder ("GER" / "SOV" / nil) and contested.
local function believed(c, obj)
    local b = LF.Front.objectiveBelief(c.faction, obj.id)
    if not b then return obj.holder, obj.contested end
    return b.holder, b.contested
end

-- Is an objective on the front line, to him? (Its sector borders one he believes the enemy's, or
-- the enemy has been reported close to it.)
local function frontLine(c, obj, owners, adj)
    local key = tostring(obj.id)
    for k in pairs(adj[key] or {}) do
        local o = owners[k]
        if o == ENEMY[c.faction] or o == "contested" then return true end
    end
    return enemyNear(c, obj.x, obj.y, CFG.frontReach) > 0
end

-- ---- his squads ----------------------------------------------------------------------------------

local BUSY = { take = true, withdraw = true, hold = true, patrol = true }

-- Every squad of the company: { sq, p (its platoon now, or nil), state = free/busy/probe/garrison }
local function squadsOf(c)
    local out = {}
    local mine = {}
    for _, p in ipairs(LF.Company.platoons(c)) do mine[p.id] = p end
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "squad" and not u.companyHQ then
            local p = u.platoon and mine[u.platoon]
            local g = u.garrison and u.garrison.company == c.id
            local pr = u.probe and u.probe.company == c.id
            local rf = u.refit and u.refit.company == c.id
            if p or g or pr or rf then
                local state = "free"
                if pr then state = "probe"
                elseif g then state = "garrison"
                elseif rf then state = "refit"
                elseif p.mission and BUSY[p.mission.kind] and not (p.mission.kind == "take" and p.mission.phase == "taken") then state = "busy"
                elseif p.move then state = "busy" end
                out[#out + 1] = { sq = u, p = p, state = state, fit = fitOf(u), mg = isMG(u) }
            end
        end
    end
    return out
end

-- ---- 1. finished jobs ----------------------------------------------------------------------------

local function endJobs(c, cap)
    for _, p in ipairs(LF.Company.platoons(c)) do
        local m = p.mission
        if m and m.kind == "take" and m.phase == "taken" then
            local obj = LF.Objective.get(m.obj)
            local main = m.main and LF.Units.get(m.main)
            local others = {}
            for _, sid in ipairs(p.squads or {}) do
                local s = LF.Units.get(sid)
                if s and s ~= main then others[#others + 1] = s end
            end
            if main and obj then LF.Platoon.garrison(main, c, obj) end
            local back = 0
            for _, s in ipairs(others) do
                if s.homePlatoon then LF.Platoon.goHome(s); back = back + 1 end
            end
            p.mission = nil
            LF.log(string.format("CAPTAIN %s: %s taken - %s holds it, %d squad(s) free again%s", c.name,
                obj and obj.name or "?", main and short(main) or "nobody", #others, back > 0 and (", " .. back .. " back to their own platoons") or ""))
            if obj then radio(c, cap, short(p) .. ", well done on " .. obj.name .. ". Leave " .. (main and short(main) or "a squad") .. " to hold it. Over.") end
        elseif m and m.kind == "rally" then
            for _, sid in ipairs(p.squads or {}) do
                local s = LF.Units.get(sid)
                if s and s.homePlatoon then LF.Platoon.goHome(s) end
            end
            p.mission = nil
            LF.log("CAPTAIN " .. c.name .. ": " .. p.name .. " has pulled back and rallied - free again")
        end
    end
end

-- ---- 3. probes ----------------------------------------------------------------------------------

local function sendProbe(c, cap, e, obj)
    local sq, p = e.sq, e.p
    local sx, sy, sz = squadPos(sq)
    if not sx then return false end
    local dx, dy = sx - obj.x, sy - obj.y
    local d = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    local stand = math.min(CFG.probeStand, d)
    local ox, oy = math.floor(obj.x + dx / d * stand), math.floor(obj.y + dy / d * stand)
    LF.Platoon.issue(p, { squad = sq.id, kind = "probe", x = ox, y = oy, z = obj.z or 0,
        words = short(sq) .. ", go and have a look at " .. obj.name .. " - don't get drawn in!" })
    sq.homePlatoon = sq.homePlatoon or p.id
    for i = #(p.squads or {}), 1, -1 do if p.squads[i] == sq.id then table.remove(p.squads, i) end end
    sq.platoon = nil
    -- (Time to get there: the walk at the patrol pace and then some, plus the order's run.)
    local pace = (LF.Move and LF.Move.PATROL_PACE) or 0.75
    sq.probe = { company = c.id, obj = obj.id, x = ox, y = oy, z = obj.z or 0, phase = "out", since = LF.simTime,
                 deadline = LF.simTime + (LF.dist(sx, sy, ox, oy) / pace) * 1.5 + 300 }
    LF.log(string.format("CAPTAIN %s: probe - %s goes to look at %s from %d,%d (no news of it)", c.name, sq.name, obj.name, ox, oy))
    radio(c, cap, short(p) .. ", send a squad to look at " .. obj.name .. ". Report what you see. Over.")
    return true
end

-- What a probe can see from where it is: enemy fit men within sight.
local function enemyInSight(faction, x, y)
    local men = 0
    local r = (LF.Front.CFG.sight or 40)
    local rsq = r * r
    for _, u in pairs(LF.Units.all()) do
        if (u.kind == "squad" or u.kind == "hq") and u.faction == ENEMY[faction] then
            local ux, uy = LF.Platoon.posOf(u)
            if ux and LF.distSq(ux, uy, x, y) <= rsq then men = men + fitOf(u) end
        end
    end
    return men
end

local function updateProbes(c)
    for _, u in pairs(LF.Units.all()) do
        local pr = u.kind == "squad" and u.probe
        if pr and pr.company == c.id then
            local obj = LF.Objective.get(pr.obj)
            local x, y = squadPos(u)
            local home = u.homePlatoon and LF.Units.get(u.homePlatoon)
            local function intel(men, how)
                local delay = LF.Front.reportDelay and LF.Front.reportDelay({ u = u, x = x or pr.x, y = y or pr.y }) or 0
                intelOf(c)[pr.obj] = { men = men, at = LF.simTime, reportAt = LF.simTime + delay, how = how }
                LF.log(string.format("CAPTAIN %s: probe at %s - %s (%d enemy); word reaches the lieutenant in %.0f s",
                    c.name, obj and obj.name or "?", how, men, delay))
            end
            local function comeBack()
                pr.phase = "back"
                local hx, hy, hz = nil, nil, 0
                local cmd = home and LF.Platoon.commander(home)
                if cmd then hx, hy, hz = recPos(cmd.id) end
                if hx then LF.March.order(u, math.floor(hx), math.floor(hy), hz or 0, "auto", { noGather = true }) end
            end
            local fit = fitOf(u)
            if fit == 0 or not obj then
                if obj then intelOf(c)[pr.obj] = { men = 40, at = LF.simTime, reportAt = LF.simTime + 300, how = "the probe never came back" } end
                u.probe, u.platoonTask = nil, nil
                LF.Platoon.goHome(u)
                LF.log("CAPTAIN " .. c.name .. ": the probe " .. u.name .. (obj and (" is lost (no fit man left of " .. #LF.Units.members(u.id) .. ")") or " is called off (the objective is gone)"))
            elseif pr.phase == "out" or pr.phase == "watch" then
                local contact = (LF.Clash and LF.Clash.inContact(u)) or (x and LF.Squad.bestContact(u.id, x, y, 600, 40) ~= nil)
                if contact then
                    intel(math.max(1, x and enemyInSight(u.faction, x, y) or 1), "contact - pulling back")
                    comeBack()
                elseif pr.phase == "out" then
                    -- There: close to the spot, or its march (once it has its orders) is over.
                    local M = LF.March.get(u.id)
                    local marched = u.platoonTask == "probe" and (M == nil or M.arrived == true)
                    if (x and LF.dist(x, y, pr.x, pr.y) <= 12) or marched then
                        pr.phase, pr.watchUntil = "watch", LF.simTime + CFG.probeWatch
                    elseif LF.simTime > (pr.deadline or (pr.since + CFG.probeOut)) then
                        LF.log("CAPTAIN " .. c.name .. ": the probe " .. u.name .. " never got there - called back")
                        comeBack()
                    end
                elseif LF.simTime >= (pr.watchUntil or 0) then
                    local men = x and enemyInSight(u.faction, x, y) or 0
                    intel(men, men > 0 and "enemy seen" or "nobody there")
                    comeBack()
                end
            elseif pr.phase == "back" then
                local cmd = home and LF.Platoon.commander(home)
                local hx, hy = nil, nil
                if cmd then hx, hy = recPos(cmd.id) end
                local M = LF.March.get(u.id)
                if not home or not hx or (x and LF.dist(x, y, hx, hy) <= 20) or (M == nil and LF.simTime - pr.since > 60) then
                    u.probe, u.platoonTask = nil, nil
                    LF.Platoon.goHome(u)
                    LF.log("CAPTAIN " .. c.name .. ": the probe " .. u.name .. " is back")
                end
            end
        end
    end
end

-- ---- deciding --------------------------------------------------------------------------------------

local function takeFrom(list, pick)
    for i, e in ipairs(list) do if e == pick then table.remove(list, i); return end end
end

local function nearestOf(list, x, y, test)
    local best, bd = nil, math.huge
    for _, e in ipairs(list) do
        if not test or test(e) then
            local sx, sy = squadPos(e.sq)
            local d = sx and LF.dist(sx, sy, x, y) or math.huge
            if d < bd then best, bd = e, d end
        end
    end
    return best, bd
end

local canLead, ownFree            -- (set inside decide: they see its lists)

local function decide(c, cap)
    endJobs(c, cap)
    updateProbes(c)
    if LF.XO then LF.XO.updateRefits(c, cap) end
    local side = c.faction
    local all = squadsOf(c)
    local owners = LF.Front.owners(side)
    local adj = neighbours()
    local objs = {}
    for _, obj in pairs(LF.Objective.all()) do objs[#objs + 1] = obj end
    -- Garrisons he has, by objective; free squads.
    local held, free = {}, {}
    local probing = {}
    local nProbes = 0
    for _, e in ipairs(all) do
        if e.state == "garrison" then
            local g = e.sq.garrison
            held[g.obj] = held[g.obj] or {}
            held[g.obj][#held[g.obj] + 1] = e
        elseif e.state == "probe" then
            probing[e.sq.probe.obj] = true
            nProbes = nProbes + 1
        elseif e.state == "free" and e.fit > 0 and e.p then
            free[#free + 1] = e
        end
    end
    -- 0. Back to headquarters, squads that need to (wounded for the surgeon, men waiting for them
    -- there - LF_XO).
    if LF.XO then
        LF.XO.refits(c, cap, all, function(e) takeFrom(free, e) end, function(obj)
            local _, contested = believed(c, obj)
            return not contested and enemyNear(c, obj.x, obj.y, CFG.threat) == 0
        end)
    end
    -- (A probe's report still on its way: wait for it rather than send another.)
    for oid, i in pairs(intelOf(c)) do
        if i.reportAt > LF.simTime then probing[oid] = true end
    end
    local attacking = {}
    for _, p in ipairs(LF.Company.platoons(c)) do
        local m = p.mission
        if m and m.kind == "take" and m.phase ~= "taken" then attacking[m.obj] = true end
    end
    -- Can this lieutenant lead an assault now? (Alive, his platoon not on a job or a move.)
    function canLead(p)
        if not p or p.mission or p.move or not LF.Platoon.commander(p) then return false end
        for _, e in ipairs(all) do if e.p == p and e.state == "busy" then return false end end
        return true
    end
    -- His own squads still free (not lent ones; not counting those already in group g).
    function ownFree(p, g)
        local n = 0
        for _, e in ipairs(free) do
            if e.p == p and not e.sq.homePlatoon then
                local taken = false
                for _, x in ipairs(g or {}) do if x == e then taken = true end end
                if not taken then n = n + 1 end
            end
        end
        return n
    end

    -- 2. Defence: a garrison on every objective of ours on the front line; two if threatened. A
    -- garrison of one no longer on the front is let go (after a while).
    for _, obj in ipairs(objs) do
        local holder = believed(c, obj)
        local gs = held[obj.id] or {}
        if holder == side then
            local front = frontLine(c, obj, owners, adj)
            if front then
                obj.lfOffFront = obj.lfOffFront or {}
                obj.lfOffFront[side] = nil
                local want = 1
                local threat = enemyNear(c, obj.x, obj.y, CFG.threat)
                local have = 0
                for _, g in ipairs(gs) do have = have + g.fit end
                local _, contested = believed(c, obj)
                if (threat > have or contested) and #gs >= 1 then want = 2 end
                while #gs < want do
                    local e = nearestOf(free, obj.x, obj.y)
                    if not e then break end
                    takeFrom(free, e)
                    if #gs == 0 then
                        LF.Platoon.issue(e.p, { squad = e.sq.id, kind = "hold", obj = obj.id,
                            words = short(e.sq) .. ", go and hold " .. obj.name .. "!" })
                        LF.Platoon.garrison(e.sq, c, obj)
                        LF.log(string.format("CAPTAIN %s: garrison - %s to hold %s (front line%s)", c.name, e.sq.name, obj.name,
                            threat > 0 and (", ~" .. threat .. " enemy reported near") or ""))
                        radio(c, cap, short(e.p) .. ", put a squad in " .. obj.name .. " and hold it. Over.")
                    else
                        -- A second squad doesn't crowd into the building (a house has windows for
                        -- one squad): it waits close by, out of the enemy's sight, ready to help.
                        local ex, ey = obj.x - (c.facingX or 1) * 20, obj.y - (c.facingY or 0) * 20
                        local best, bd = nil, math.huge
                        for _, sg in pairs(LF.Front.sightings(side)) do
                            local d = LF.dist(sg.x, sg.y, obj.x, obj.y)
                            if LF.simTime - sg.at <= CFG.stale and d < bd then best, bd = sg, d end
                        end
                        if best and bd > 1 then
                            ex = obj.x - (best.x - obj.x) / bd * 20
                            ey = obj.y - (best.y - obj.y) / bd * 20
                        end
                        local x, y = math.floor(ex), math.floor(ey)
                        local hx, hy = LF.Cover.hiddenNear(x, y, obj.z or 0, obj.x, obj.y, 12)
                        if hx then x, y = hx, hy end
                        LF.Platoon.issue(e.p, { squad = e.sq.id, kind = "reserve", x = x, y = y, z = obj.z or 0,
                            words = short(e.sq) .. ", get behind " .. obj.name .. " and be ready to help hold it!" })
                        LF.Platoon.garrison(e.sq, c, obj)
                        e.sq.garrison.support = true
                        LF.log(string.format("CAPTAIN %s: %s waits behind %s at %d,%d to help hold it (%s)", c.name, e.sq.name,
                            obj.name, x, y, contested and "contested" or ("~" .. threat .. " enemy reported near")))
                        radio(c, cap, short(e.p) .. ", send a squad up behind " .. obj.name .. ". Over.")
                    end
                    gs[#gs + 1] = e
                end
            elseif #gs > 0 then
                obj.lfOffFront = obj.lfOffFront or {}
                obj.lfOffFront[side] = obj.lfOffFront[side] or LF.simTime
                if LF.simTime - obj.lfOffFront[side] >= CFG.releaseAfter then
                    for _, g in ipairs(gs) do
                        g.sq.garrison = nil
                        LF.Platoon.goHome(g.sq)
                        LF.log("CAPTAIN " .. c.name .. ": " .. obj.name .. " is behind the front now - " .. g.sq.name .. " is free")
                    end
                    obj.lfOffFront[side] = nil
                end
            end
        end
    end

    -- Targets: what isn't his side's, best first (worth over distance from his free squads).
    local cx, cy, n = 0, 0, 0
    for _, e in ipairs(free) do
        local x, y = squadPos(e.sq)
        if x then cx, cy, n = cx + x, cy + y, n + 1 end
    end
    if n == 0 then return end
    cx, cy = cx / n, cy / n
    local targets = {}
    for _, obj in ipairs(objs) do
        local holder = believed(c, obj)
        -- (His own, even contested, is defended - not "attacked": 0.68 re-took its own objectives
        -- over and over, leaving another squad in each every time.)
        if holder ~= side then
            local d = LF.dist(cx, cy, obj.x, obj.y)
            if d <= CFG.maxRange and not attacking[obj.id] then
                local worth = 1
                local key = tostring(obj.id)
                for k in pairs(adj[key] or {}) do if owners[k] == side then worth = worth + 1.5; break end end
                if holder == ENEMY[side] then worth = worth + 0.5 end
                targets[#targets + 1] = { obj = obj, score = worth / (1 + d / 100), d = d, holder = holder }
            end
        end
    end
    table.sort(targets, function(a, b) return a.score > b.score end)

    -- 3 and 4: probes for what he knows nothing of; assaults on what he does.
    for _, t in ipairs(targets) do
        if #free == 0 then break end
        local obj = t.obj
        local E, age = expectedAt(c, obj)
        if E == nil then
            if not probing[obj.id] and nProbes < CFG.probes then
                local e = nearestOf(free, obj.x, obj.y, function(x) return not x.mg end)
                if e and sendProbe(c, cap, e, obj) then
                    takeFrom(free, e)
                    probing[obj.id] = true
                    nProbes = nProbes + 1
                end
            end
        else
            -- A lieutenant to lead: a free platoon (its commander alive) with at least one of its
            -- own squads free - a lieutenant never leads an assault with none of his own men -
            -- rifle platoons first, nearest the objective. (So there are as many assaults at once
            -- as there are lieutenants free to lead them.)
            local leads = {}
            for _, p in ipairs(LF.Company.platoons(c)) do
                if canLead(p) and ownFree(p) > 0 then
                    local px, py = LF.Platoon.posOf(LF.Units.get(p.hq))
                    leads[#leads + 1] = { p = p, d = px and LF.dist(px, py, obj.x, obj.y) or math.huge }
                end
            end
            table.sort(leads, function(a, b)
                if (a.p.mgPlatoon or false) ~= (b.p.mgPlatoon or false) then return not a.p.mgPlatoon end
                return a.d < b.d
            end)
            local lead = leads[1] and leads[1].p
            if lead then
                local need = math.max(CFG.minAttack, math.ceil(CFG.odds * E))
                -- The lead's own free squads go; then the nearest other free rifle squads are lent
                -- until the group is strong enough; a machine-gun squad as support.
                local group, fit, rifles, mgs = {}, 0, 0, 0
                for _, e in ipairs(free) do
                    if e.p == lead and not e.sq.homePlatoon then
                        group[#group + 1] = e
                        fit = fit + e.fit
                        if e.mg then mgs = mgs + 1 else rifles = rifles + 1 end
                    end
                end
                local pool = {}
                for _, e in ipairs(free) do if e.p ~= lead then pool[#pool + 1] = e end end
                -- (A squad can be lent unless it is the last free squad of a lieutenant who could
                -- still lead an assault of his own.)
                local function lendable(x)
                    return not (canLead(x.p) and x.p ~= lead and ownFree(x.p, group) <= 1)
                end
                while fit < need or rifles == 0 do
                    local e = nearestOf(pool, obj.x, obj.y, function(x) return not x.mg and lendable(x) end)
                    if not e then break end
                    takeFrom(pool, e)
                    group[#group + 1] = e
                    fit, rifles = fit + e.fit, rifles + 1
                end
                if mgs == 0 and E > 0 then
                    local m = nearestOf(pool, obj.x, obj.y, function(x) return x.mg and lendable(x) end)
                    if m then takeFrom(pool, m); group[#group + 1] = m; fit, mgs = fit + m.fit, 1 end
                end
                if rifles > 0 and (fit >= need or E == 0) then
                    local lent = {}
                    for _, e in ipairs(group) do
                        takeFrom(free, e)
                        if e.p ~= lead then
                            lent[#lent + 1] = short(e.sq) .. " from " .. short(e.p)
                            LF.Platoon.attach(e.sq, lead)
                        end
                    end
                    local ok, why = LF.Platoon.take(lead, obj)
                    local news = age and string.format("~%d enemy, news %d min old", E, math.floor(age / 60)) or "no enemy seen"
                    if ok then
                        attacking[obj.id] = true
                        LF.log(string.format("CAPTAIN %s: attack %s with %s - %d squad(s), %d fit men (%s; wanted %d)%s",
                            c.name, obj.name, lead.name, #group, fit, news, need,
                            #lent > 0 and ("; lent: " .. table.concat(lent, ", ")) or ""))
                        radio(c, cap, short(lead) .. ", take " .. obj.name .. "." .. (#lent > 0 and (" You have " .. table.concat(lent, ", ") .. ".") or "") .. " Over.")
                    else
                        LF.log("CAPTAIN " .. c.name .. ": " .. lead.name .. " can't take " .. obj.name .. " (" .. tostring(why) .. ")")
                        for _, e in ipairs(group) do if e.p ~= lead then LF.Platoon.goHome(e.sq) end end
                    end
                end
            end
        end
    end
end

-- ---- running ----------------------------------------------------------------------------------------

local lastLook = {}
Events.OnInitGlobalModData.Add(function() lastLook = {} end)

Events.OnTick.Add(function()
    if not CFG.on or LF.tick % 60 ~= 29 then return end
    for _, c in pairs(LF.Units.all()) do
        if c.kind == "company" then
            local cap = captainOf(c)
            local last = lastLook[c.id]
            if cap and (not last or LF.simTime - last >= CFG.every or last > LF.simTime) then
                lastLook[c.id] = LF.simTime
                LF.guard("captain", decide, c, cap)
            end
        end
    end
end)

function LF.Captain.toggle()
    CFG.on = not CFG.on
    LF.log("CAPTAIN captains command their companies: " .. tostring(CFG.on))
    return CFG.on
end
