-- Living Front: fighting off-screen (roadmap phase 3).
--
-- Near you, men fight for real. Out of your range a fight is settled here, unit against unit,
-- once a simulated second (LF.simTime: game speed counts, a pause stops it):
--   * Two hostile units with no bodies within CFG.range tiles of each other are in contact: each
--     knows where the other's men are (so platoon and squad logic react as they would on-screen)
--     and a march halts.
--   * Each side puts out firepower: its fit men (a rifleman 1, a machine gunner 5, an officer's
--     pistol 0.3), less for distance, ammunition running low, being suppressed and low morale.
--   * What lands on the other side is cut down by its cover: inside the objective it holds 0.35,
--     dug in 0.6, halted in the open 0.85, caught on the march 1.2.
--   * Hits add up per unit; each whole one is a man hit - killed (40%) or wounded (60%) - named,
--     where he stands. Being under fire wears morale down; a death costs more (LF_Morale).
--   * A unit down to under 35% fit, or whose men's morale averages under 25, breaks: it falls
--     back 40 tiles away from the enemy and digs in (a platoon's main effort is left to its
--     lieutenant, who takes over or withdraws - LF_Platoon).
--   * An objective empties when its defenders fall or break; the attacker then walks in and it
--     changes hands (LF_Objective).
-- The handoff: if either side of a contact has men with bodies (near you), the fight is real -
-- the other side is given its bodies too where the ground is loaded (LF.Bodies.want). Only
-- fights with nobody near you are settled here.
-- Every hit and every break is written to the event log (LF.Clash.events) with who saw it - the
-- raw material for the reports and memories of roadmap phase 4.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Squad"
require "LivingFront/Units/LF_March"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Soldier/LF_Morale"
require "LivingFront/Soldier/LF_Service"

LF.Clash = LF.Clash or {}

local CFG = {
    updateTicks = 30,
    range = 45,             -- tiles: contact off-screen
    rate = 0.006,           -- hits per firepower point per simulated second at close range, in the open
    killShare = 0.4,
    breakFit = 0.35,        -- a unit breaks below this share of fit men ...
    breakMorale = 25,       -- ... or below this average morale
    fallBack = 40,          -- a broken unit falls back this far from the enemy
    ammoUse = 0.004,        -- share of a unit's ammunition used per second of firing
    ammoBack = 0.001,       -- ... and got back per quiet second (redistributed, scrounged)
    pinPerSecond = 0.25,    -- morale lost per second under heavy fire
    contactHold = 10,       -- a march stays halted this many seconds after the last contact
    eventsKept = 400,
}
LF.Clash.CFG = CFG

local COVER = { building = 0.35, dug = 0.6, open = 0.85, march = 1.2 }

local function bodyOf(id)
    local b = id and LF.Bodies.get(id)
    if b and not b:isDead() then return b end
    return nil
end

-- ---- the event log ----------------------------------------------------------------------------

local function events()
    local data = LF.Records.data()
    data.lfEvents = data.lfEvents or {}
    return data.lfEvents
end
LF.Clash.events = events

-- Record an event: kind, the man (or unit) it happened to, where, and who saw it.
local function note(kind, fields)
    local ev = events()
    fields.kind = kind
    fields.sim = math.floor(LF.simTime)
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    if ok then fields.hours = h end
    ev[#ev + 1] = fields
    while #ev > CFG.eventsKept do table.remove(ev, 1) end
end
LF.Clash.note = note

-- ---- units ------------------------------------------------------------------------------------

-- The units that fight: squads (not ones away with another unit) and platoon headquarters,
-- German or Soviet, with someone alive. For each: its men, where it is, whether any has a body.
local function survey()
    local out = {}
    for _, u in pairs(LF.Units.all()) do
        if (u.kind == "squad" and not u.joined) or u.kind == "hq" then
            if u.faction == "GER" or u.faction == "SOV" then
                local men, sx, sy, sz, bodies = {}, 0, 0, 0, 0
                for _, rid in ipairs(LF.Units.members(u.id)) do
                    local r = LF.Records.get(rid)
                    if r and r.alive then
                        men[#men + 1] = r
                        local b = bodyOf(rid)
                        if b then bodies = bodies + 1; sx, sy, sz = sx + b:getX(), sy + b:getY(), sz + b:getZ()
                        else sx, sy, sz = sx + r.x, sy + r.y, sz + (r.z or 0) end
                    end
                end
                if #men > 0 then
                    out[#out + 1] = { u = u, men = men, x = sx / #men, y = sy / #men, z = math.floor(sz / #men),
                                      bodies = bodies }
                end
            end
        end
    end
    return out
end

local function fitOf(r) return LF.Tactics and LF.Tactics.I and LF.Tactics.I.fit(r) or (r.alive and not r.wounded) end

-- Firepower of a unit's fit men (before distance and the rest).
local function firepower(e)
    local f, n = 0, 0
    for _, r in ipairs(e.men) do
        if fitOf(r) then
            n = n + 1
            if r.mgRole == "gunner" then f = f + 5
            elseif r.rank == "LT" then f = f + 0.3
            else f = f + 1 end
        end
    end
    e.fit = n
    return f
end

-- How much cover a unit is in: building / dug / open / march.
local function coverOf(e)
    local u = e.u
    local M = LF.March.get(u.id)
    if M and not M.arrived and not M.halted then return "march" end
    local t = u.objTask
    local obj = t and t.kind == "hold" and LF.Objective and LF.Objective.get(t.obj)
    if obj and LF.Objective.at(obj, e.x, e.y, e.z) then return "building" end
    if u.stance == "defensive" or u.platoonTask == "dig" or u.platoonTask == "reserve" then return "dug" end
    return "open"
end

-- Cover against a particular enemy: defenders being stormed (the enemy inside with them) have
-- only the close-quarters cover of rooms and doorways.
local function coverAgainst(t, e)
    local c = coverOf(t)
    local et = e.u.objTask
    if c == "building" and et and et.storm then return "dug" end
    return c
end

local function fleeing(u) return u.offBroken ~= nil and u.offBroken <= LF.simTime and LF.simTime - u.offBroken < 120 end

local function rangeMul(d) return math.max(0.15, math.min(1, 1.25 - d / 40)) end

local function moraleMul(e)
    local m = LF.Morale.average(e.u.id)
    return math.max(0.4, math.min(1.1, 0.4 + m / 100))
end

-- ---- hits -------------------------------------------------------------------------------------

local HIT_PARTS = { "Torso_Upper", "Torso_Lower", "UpperArm_L", "UpperArm_R", "UpperLeg_L", "UpperLeg_R", "Head" }

local function witnesses(a, b)
    local ids = {}
    for _, r in ipairs(a.men) do if r.alive then ids[#ids + 1] = r.id end end
    for _, r in ipairs(b.men) do if r.alive then ids[#ids + 1] = r.id end end
    return ids
end

-- One man of target unit e is hit by unit by.
local function hit(e, by)
    local cands = {}
    for _, r in ipairs(e.men) do if r.alive and fitOf(r) then cands[#cands + 1] = r end end
    if #cands == 0 then for _, r in ipairs(e.men) do if r.alive then cands[#cands + 1] = r end end end
    if #cands == 0 then return end
    local r = cands[ZombRand(#cands) + 1]
    local title = LF.Units.title(r)
    -- (A man already wounded who is hit again is far more likely to die: 0.56 wounded one man
    -- three times over and he lived.)
    local kill = (r.wounded or r.offWound) and 70 or CFG.killShare * 100
    if ZombRand(100) < kill then
        r.alive = false
        r.diedOffscreen = { x = r.x, y = r.y, z = r.z or 0, by = by.u.id }
        LF.log("CLASH " .. title .. " #" .. r.id .. " of " .. e.u.name .. " KILLED off-screen by " .. by.u.name
            .. " at " .. math.floor(r.x) .. "," .. math.floor(r.y))
        if LF.Service then LF.guard("service record", LF.Service.died, r) end
        LF.guard("succession", LF.Units.onDeath, r)
        note("killed", { who = r.id, unit = e.u.id, by = by.u.id, x = math.floor(r.x), y = math.floor(r.y), seen = witnesses(e, by) })
    else
        local part = HIT_PARTS[ZombRand(#HIT_PARTS) + 1]
        r.offWound = { part = part, severity = 40 + ZombRand(40), impact = 20 + ZombRand(25) }
        if not (LF.Units.leads(r) and LF.Units.relieve(r)) then r.wounded = true end
        LF.Morale.unitEvent(e.u.id, -3, title .. " wounded (off-screen)")
        LF.log("CLASH " .. title .. " #" .. r.id .. " of " .. e.u.name .. " wounded off-screen (" .. part .. ") by " .. by.u.name)
        note("wounded", { who = r.id, unit = e.u.id, by = by.u.id, part = part, x = math.floor(r.x), y = math.floor(r.y), seen = witnesses(e, by) })
    end
end

-- ---- breaking --------------------------------------------------------------------------------

local function breakUnit(e, enemy)
    local u = e.u
    u.offBroken = LF.simTime
    LF.Morale.broke(u)
    LF.log("CLASH " .. u.name .. " breaks off-screen (" .. e.fit .. " of " .. #e.men .. " fit, morale "
        .. math.floor(LF.Morale.average(u.id)) .. ")")
    note("broke", { unit = u.id, by = enemy.u.id, x = math.floor(e.x), y = math.floor(e.y), seen = witnesses(e, enemy) })
    -- A platoon's main effort on a mission is its lieutenant's to deal with (LF_Platoon).
    local p = u.platoon and LF.Units.get(u.platoon)
    if p and p.mission and p.mainEffort == u.id and LF.Platoon and LF.Platoon.commander(p) then return end
    if u.kind ~= "squad" then return end
    local dx, dy = e.x - enemy.x, e.y - enemy.y
    local d = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    local tx, ty = math.floor(e.x + dx / d * CFG.fallBack), math.floor(e.y + dy / d * CFG.fallBack)
    u.objTask, u.pendingHold = nil, nil
    u.platoonTask = "withdraw"
    u.withdrawTo = { x = tx, y = ty, z = e.z }
    LF.March.cancel(u.id)
    local ok = LF.March.order(u, tx, ty, e.z, "auto", { noGather = true })
    if not ok and LF.Tactics then LF.Tactics.setStance(u, "defensive") end
end

-- ---- each simulated second -------------------------------------------------------------------

local lastSim = nil
local function update()
    local now = LF.simTime
    local dt = lastSim and (now - lastSim) or 0
    lastSim = now
    if dt <= 0 then return end
    dt = math.min(dt, 5)
    local units = survey()
    -- Contacts: every hostile pair in range.
    local pairs_ = {}
    for i = 1, #units do
        local a = units[i]
        for j = i + 1, #units do
            local b = units[j]
            if LF.isHostile(a.u.faction, b.u.faction) then
                local d = LF.dist(a.x, a.y, b.x, b.y)
                if d <= CFG.range then pairs_[#pairs_ + 1] = { a = a, b = b, d = d } end
            end
        end
    end
    local incoming = {}             -- unit -> firepower landing on it (for suppression)
    local fights = {}
    for _, pr in ipairs(pairs_) do
        local a, b = pr.a, pr.b
        if a.bodies > 0 or b.bodies > 0 then
            -- Near you: fought for real. Give the side with no bodies its bodies where it can.
            if a.bodies == 0 and LF.Bodies.want then LF.Bodies.want(a.u.id) end
            if b.bodies == 0 and LF.Bodies.want then LF.Bodies.want(b.u.id) end
        else
            fights[#fights + 1] = pr
        end
    end
    if #fights == 0 then
        -- Quiet units get some ammunition back.
        for _, e in ipairs(units) do
            local u = e.u
            if u.offAmmo and u.offAmmo < 1 then u.offAmmo = math.min(1, u.offAmmo + CFG.ammoBack * dt) end
        end
        return
    end
    local engaged = {}
    -- Firepower out, by unit and target.
    for _, pr in ipairs(fights) do
        for _, side in ipairs({ { pr.a, pr.b }, { pr.b, pr.a } }) do
            local e, t = side[1], side[2]
            e.fp = e.fp or firepower(e)
            local ammo = e.u.offAmmo or 1
            local f = e.fp * rangeMul(pr.d) * moraleMul(e) * (ammo < 0.25 and ammo * 4 or 1)
            if coverOf(e) == "march" then f = f * 0.5 end
            if fleeing(e.u) then f = f * 0.3 end            -- (running, not fighting)
            t.inFire = (t.inFire or 0) + f
            e.targets = e.targets or {}
            e.targets[#e.targets + 1] = { t = t, f = f }
            engaged[e] = true
        end
    end
    -- Suppression cuts what each unit puts out; then the hits land.
    for e in pairs(engaged) do
        local s = (e.inFire or 0) / math.max(1, e.fit or 1)
        e.supp = math.min(0.5, 0.5 * s / 3)
    end
    for e in pairs(engaged) do
        local u = e.u
        u.offAmmo = math.max(0, (u.offAmmo or 1) - CFG.ammoUse * dt)
        u.offContactAt = LF.simTime
        -- (A squad marching in a platoon's file: its whole file halts.)
        local M = LF.March.get(u.id)
        if M and not M.arrived and not fleeing(u) then
            if not M.halted then
                M.halted = true
                LF.log("PATROL " .. u.name .. ": contact off-screen - halt and fight")
            end
            if M.lead and M.lead ~= u.id then
                local lead = LF.Units.get(M.lead)
                if lead then lead.offContactAt = LF.simTime end
            end
        end
        for _, tg in ipairs(e.targets) do
            local t = tg.t
            -- What he knows: where the enemy's men are (for his platoon's and sergeant's logic).
            local n = 0
            for _, r in ipairs(t.men) do
                if r.alive and n < 6 and LF.Tactics and LF.Tactics.point then
                    n = n + 1
                    LF.Squad.report(u.id, r.id, LF.Tactics.point(r.x, r.y, r.z or 0))
                end
            end
            local landed = tg.f * (1 - (e.supp or 0)) * CFG.rate * COVER[coverAgainst(t, e)] * dt
            t.u.offHits = (t.u.offHits or 0) + landed
            -- Pinned: morale wears down under heavy fire.
            local heavy = (t.inFire or 0) / math.max(1, t.fit or 1)
            if heavy > 1 then
                for _, r in ipairs(t.men) do LF.Morale.add(r, -CFG.pinPerSecond * dt * math.min(2, heavy / 2)) end
            end
        end
    end
    for e in pairs(engaged) do
        local u = e.u
        if not u.offFightLogged or LF.simTime - u.offFightLogged > 30 then
            u.offFightLogged = LF.simTime
            local foes = {}
            for _, tg in ipairs(e.targets) do foes[#foes + 1] = tg.t.u.name end
            LF.log(string.format("CLASH %s fights %s off-screen: %d of %d fit, cover %s, ammo %.0f%%, morale %.0f",
                u.name, table.concat(foes, ", "), e.fit or 0, #e.men, coverOf(e), (u.offAmmo or 1) * 100, LF.Morale.average(u.id)))
        end
        while (u.offHits or 0) >= 1 do
            u.offHits = u.offHits - 1
            hit(e, e.targets[1].t)
        end
    end
    -- Breaking.
    for e in pairs(engaged) do
        local u = e.u
        local fitN = 0
        for _, r in ipairs(e.men) do if r.alive and fitOf(r) then fitN = fitN + 1 end end
        e.fit = fitN
        local share = fitN / math.max(1, #e.men)
        local broken = u.offBroken and u.offBroken <= LF.simTime and LF.simTime - u.offBroken < 120
        if not broken and (share < CFG.breakFit or LF.Morale.average(u.id) < CFG.breakMorale) then
            breakUnit(e, e.targets[1].t)
        end
    end
end

Events.OnTick.Add(function()
    if LF.tick % CFG.updateTicks ~= 17 then return end
    LF.guard("clash", update)
end)
Events.OnInitGlobalModData.Add(function() lastSim = nil end)

-- Is this unit still in an off-screen fight (a march stays halted)?
function LF.Clash.inContact(u)
    if u ~= nil and fleeing(u) then return false end       -- (a broken unit runs, it doesn't stop to fight)
    return u ~= nil and u.offContactAt ~= nil and LF.simTime - u.offContactAt < CFG.contactHold
        and u.offContactAt <= LF.simTime
end
