-- Living Front: the squad medic.
--
-- Who: in every full squad, the medic - Bravo's fifth man, behind it - is a private. He carries a
-- leather satchel of dressings (Bag_Satchel_Leather) and a sub-machine gun instead of a rifle
-- (MP40 / PPSh). His kit holds CFG2.kit dressings; it doesn't refill in a fight - only when his
-- squad comes back to the company headquarters (LF_AidPost, from the XO's medical supplies).
--
-- Critical, not dead: when a man of a squad whose medic is alive and has dressings left is brought
-- to death's door (health 10 or less, by a hit or by bleeding) - not by a head shot or the middle
-- of a grenade blast - there's a chance (the medic's: green 50%, veteran 75%, shaken 40%) that
-- he goes down critical instead. He lies on his back calling for the medic, and nothing can kill
-- him until his clock runs out - 60-90 s, 30% longer with a veteran medic (the game's god mode
-- holds him; the enemy stops shooting at him). Reached in time, he's stabilised: he gets up,
-- limps to cover and tends his wounds there - critically wounded (LF_Wounds): his squad leader
-- sends him back to the surgeon with a buddy as soon as he can spare one. Nobody comes: he dies
-- when the clock runs out. (The medic patches up; only the surgeon heals serious and critical men.)
--
-- The medic: every half second he looks for the worst case in his squad within 30 tiles - the
-- critical first (soonest to die), then badly hurt men still bleeding - and goes to him at a run
-- (the sergeant calls "Cover the medic!" when the enemy is near the man). Next to him he crouches,
-- slings his SMG and works (the game's low-reach clip): stabilising a critical man takes ~6 s and
-- 2 dressings, bandaging a bleeder ~2.5 s and 1. An enemy in sight within 6 tiles of him (3 while
-- saving a critical man), being pinned down on the way, or being knocked off his feet breaks it
-- off - he fights first, then goes back. A bleeder who goes critical under his hands he goes
-- straight on to saving. A shaken medic hesitates 4 s before going out; a veteran one (5 men
-- saved) works 30% faster.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Units/LF_Units"
require "LivingFront/Soldier/LF_Aid"
require "LivingFront/Specialists/LF_Downed"

local walk, moving = LF.Medic.walk, LF.Medic.moving
local setBusy, busyAs = LF.Medic.setBusy, LF.Medic.busyAs

local CFG2 = {
    kit = 8, stabiliseCost = 2, bandageCost = 1,
    chance = { green = 50, veteran = 75, shaken = 40 },
    bleedOut = { 3600, 1800 },  -- 60 s + up to 30 s
    vetWindow = 1.3,
    vetSaves = 5,               -- saves for a medic to count as a veteran at it
    floor = 3,                  -- a critical man's health is held at this (the clock kills him)
    dyingAt = 10,               -- a man this low (from a hit, or bleeding) is dying: he may go critical
    stableFloor = 15,           -- a stabilised man's health never drops below this
    stabiliseTicks = 360, bandageTicks = 150, vetSpeed = 0.7,
    range = 30,                 -- he goes to men this close
    severeHealth = 45,          -- "badly hurt" (and bleeding): worth his dressings
    threatRange = 6,            -- an enemy in sight this close: he fights first
    threatRangeSaving = 3,      -- ... saving a critical man, only this close
    shakenDelay = 240,
    quietRelease = 3600,        -- stabilised men get up after ~60 s with no enemy known
}
LF.Medic.CFG2 = CFG2

local crit = {}             -- id -> { squad, untilTick, since }
local stable = {}           -- id -> { squad, quietSince }
local jobs2 = {}            -- medic id -> { pid, kind, phase, at, nextPath }
local cooldown = {}         -- medic id -> tick he may take a new job
Events.OnInitGlobalModData.Add(function() crit, stable, jobs2, cooldown = {}, {}, {}, {} end)

function LF.Medic.isCritical(id) return crit[id] ~= nil end
function LF.Medic.isStable(id) return stable[id] ~= nil end
function LF.Medic.critLeft(id) local c = crit[id]; return c and math.max(0, c.untilTick - LF.tick) or nil end
function LF.Medic.job(id) return jobs2[id] end
-- Where a man the medic saved is: nil (not one), "rising", "limp" or "rest" (LF_Wounds waits for
-- him to be on his feet before he is sent back).
function LF.Medic.stablePhase(id) local s = stable[id]; return s and (s.phase or "down") or nil end
-- He's going back to the aid post (LF_AidPost): the medic's care of him ends here.
function LF.Medic.release(id)
    if not stable[id] then return end
    stable[id] = nil
    setBusy(id, nil)
end

local SMG = { GER = "MP40", SOV = "PPSh" }

-- His level at it: "veteran" (enough men saved, or a veteran soldier), "shaken", or "green".
local function levelOf(rec)
    local s = rec.svc
    if s and s.shaken then return "shaken" end
    if (rec.medicSaves or 0) >= CFG2.vetSaves or (s and s.veteran) then return "veteran" end
    return "green"
end
LF.Medic.levelOf = levelOf

-- Put the satchel on him and the SMG in his hands (at spawn, or when he's made the medic).
function LF.Medic.equip(body, rec)
    if not rec.medic then return end
    local inv = body:getInventory()
    local have = false
    pcall(function()
        local worn = body:getWornItems()
        for i = 0, worn:size() - 1 do
            local it = worn:getItemByIndex(i)
            if it and it:getFullType() == "Base.Bag_Satchel_Leather" then have = true end
        end
    end)
    if not have then
        local bag = inv:AddItem("Base.Bag_Satchel_Leather")
        local worn = false
        if bag then
            for _, loc in ipairs({ function() return bag:canBeEquipped() end, function() return "base:satchel" end,
                                   function() return "Satchel" end }) do
                local ok = pcall(function()
                    local l = loc()
                    if not l or l == "" then error("no location") end
                    body:setWornItem(l, bag)
                end)
                if ok then worn = true; break end
            end
        end
        pcall(function() body:onWornItemsChanged(); body:resetModelNextFrame() end)
        if not worn then LF.log("MEDIC #" .. rec.id .. " couldn't put the satchel on") end
    end
    if LF.Combat then LF.guard("medic arm", LF.Combat.arm, body) end
end

-- Make one private of the squad's rearmost team its medic.
function LF.Medic.pick(squad)
    if not squad or squad.kind ~= "squad" or squad.teamOnly then return nil end
    squad.medicSet = true
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r and r.medic and r.alive then return r end
    end
    local team = LF.Units.get(squad.teams[2]) or LF.Units.get(squad.teams[#squad.teams])
    if not team then return nil end
    local pick = nil
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.alive and r.rank == "PVT" then pick = r end
    end
    if not pick then return nil end
    pick.medic, pick.kit, pick.medicSaves = true, CFG2.kit, pick.medicSaves or 0
    pick.weapon = SMG[pick.faction] or pick.weapon
    local b = LF.Bodies.get(pick.id)
    if b then LF.guard("medic equip", LF.Medic.equip, b, pick) end
    LF.log("MEDIC " .. LF.Units.title(pick) .. " (#" .. pick.id .. ") of " .. team.name .. " is " .. squad.name .. "'s medic")
    return pick
end

-- The squad's medic, if he's alive, on his feet and has dressings.
local function medicOf(squadId)
    for _, rid in ipairs(LF.Units.members(squadId)) do
        local r = LF.Records.get(rid)
        if r and r.medic then
            -- (Not a medic himself out of the fight, or away at the aid post.)
            if r.alive and not crit[rid] and not stable[rid] and not r.wounded and not r.aid and (r.kit or 0) > 0 then return r end
            return nil
        end
    end
    return nil
end
LF.Medic.medicOf = medicOf

local function kill(body)
    pcall(function() body:setHealth(0) end)
    pcall(function() body:Kill(nil) end)
end

-- His health now. (The game only re-tallies a man's overall health from his body parts in its
-- own update, so straight after a hit the number is stale - 0.39 checked that and never saw a
-- killing blow. Re-tally first.)
local function hp(body)
    pcall(function() body:getBodyDamage():calculateOverallHealth() end)
    return LF.Combat.health(body)
end
LF.Medic.hp = hp

-- Bring his health up to at least `to` (healing his body parts, the way the game does).
local function healTo(body, to)
    for _ = 1, 12 do
        if hp(body) >= to then return end
        pcall(function() body:getBodyDamage():AddGeneralHealth(10) end)
    end
end
local function addHealth(body, n) healTo(body, hp(body) + n) end

-- ---- going critical -----------------------------------------------------------------------------

-- After any wound (LF_Combat, LF_Grenade): a killing blow may leave him critical instead.
-- cause: "shot" (part = where), "blast", "blastLethal", "melee".
function LF.Medic.onHit(body, cause, part, force)
    if body:isDead() then return end
    local id = body:getModData().LF_id
    local rec = id and LF.Records.get(id)
    if not (rec and rec.alive and rec.squad and rec.faction ~= "CIV") then return end
    if rec.aid then return end      -- (on his way to, or at, the aid post: the surgeon's, not the medic's)
    if hp(body) > CFG2.dyingAt then return end
    if crit[id] then return end
    if stable[id] or rec.critOnce then return end
    if cause == "blastLethal" or (cause == "shot" and part == "Head") then return end
    local medic = medicOf(rec.squad)
    if not medic or medic.id == id or (medic.kit or 0) < CFG2.stabiliseCost then return end
    local lvl = levelOf(medic)
    if not force and ZombRand(100) >= CFG2.chance[lvl] then return end
    rec.critOnce = true
    healTo(body, CFG2.floor + 5)
    -- Nothing kills him before his clock runs out - not more hits, not the bleeding: the game's
    -- own god mode holds him (it restores his health every update) until the medic has him or
    -- the clock kills him.
    -- (Forced: plain setGodMod(true) needs a capability NPCs don't have and quietly turns it off
    -- instead - up to 0.43 critical men could still be killed.)
    pcall(function() body:setGodMod(true, true) end)
    if LF.Tactics and LF.Tactics.dropCasualty then LF.Tactics.dropCasualty(id) end
    LF.Medic.holdDown(id, body)
    local secs = CFG2.bleedOut[1] + ZombRand(CFG2.bleedOut[2])
    if lvl == "veteran" then secs = math.floor(secs * CFG2.vetWindow) end
    crit[id] = { squad = rec.squad, untilTick = LF.tick + secs, since = LF.tick }
    if LF.Units.relieve then LF.Units.relieve(rec) end
    if LF.Tactics then LF.Tactics.shout(id, "Medic! MEDIC!") end
    LF.log(string.format("CRITICAL #%d %s is down, bleeding out in %d s (medic %s, %s)", id, LF.Units.title(rec),
        math.floor(secs / 60), LF.Units.title(medic), lvl))
end

-- ---- treating -----------------------------------------------------------------------------------

LF_TreatAction = ISBaseTimedAction:derive("LF_TreatAction")
function LF_TreatAction:isValid() return not self.character:isDead() and not self.patient:isDead() end
function LF_TreatAction:waitToStart() return false end
function LF_TreatAction:start()
    self.character:faceThisObject(self.patient)
    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "Low")
end
function LF_TreatAction:update()
    self.character:faceThisObject(self.patient)
end
function LF_TreatAction:stop()
    if self.onStop then LF.guard("treat stopped", self.onStop) end
    ISBaseTimedAction.stop(self)
end
function LF_TreatAction:perform()
    if self.onDone then LF.guard("treat done", self.onDone) end
    ISBaseTimedAction.perform(self)
end
function LF_TreatAction:new(medic, patient, ticks, onDone, onStop)
    local o = ISBaseTimedAction.new(self, medic)
    o.patient, o.onDone, o.onStop = patient, onDone, onStop
    o.maxTime = ticks
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

local function dressAll(body)
    local parts = body:getBodyDamage():getBodyParts()
    local n = 0
    for i = 0, parts:size() - 1 do
        local p = parts:get(i)
        if p:bleeding() or p:haveBullet() then
            pcall(function() p:setBleeding(false); p:setBleedingTime(0) end)
            pcall(function() p:setHaveBullet(false, 0) end)
            pcall(function() p:setBandaged(true, 10) end)
            n = n + 1
        end
    end
    return n
end

local function endJob(mid, why)
    local J = jobs2[mid]
    jobs2[mid] = nil
    if LF.Suppress then LF.Suppress.setMoving(mid, false) end
    setBusy(mid, nil)
    cooldown[mid] = LF.tick + (why and 180 or 60)
    local mb = LF.Bodies.get(mid)
    if mb and not mb:isDead() then
        if LF.Posture and LF.Posture.crouched(mb) then LF.Posture.set(mb, false) end
        if J and J.slung and LF.Combat then LF.Combat.unsling(mb) end
    end
    if why then LF.log("MEDIC #" .. mid .. " breaks off (" .. why .. ")") end
end

local function finishTreat(mid, J)
    local mrec, prec = LF.Records.get(mid), LF.Records.get(J.pid)
    local pb = LF.Bodies.get(J.pid)
    if not (mrec and prec and pb) or pb:isDead() then endJob(mid, "the man died"); return end
    if J.kind ~= "stabilise" and crit[J.pid] then
        -- He went critical while being dressed: straight on to saving him, no getting up.
        J.kind = "stabilise"
        local ticks = CFG2.stabiliseTicks * (levelOf(mrec) == "veteran" and CFG2.vetSpeed or 1)
        ISTimedActionQueue.add(LF_TreatAction:new(LF.Bodies.get(mid), pb, math.floor(ticks),
            function() finishTreat(mid, J) end,
            function() if jobs2[mid] == J and J.phase == "treat" then endJob(mid, "interrupted") end end))
        return
    end
    local n = dressAll(pb)
    if J.kind == "stabilise" then
        mrec.kit = math.max(0, (mrec.kit or 0) - CFG2.stabiliseCost)
        crit[J.pid] = nil
        -- Out of god mode, and badly hurt: a dressed wound, low health - brought to a set level, not
        -- knocked down by a fixed amount (up to 0.46 a man the god mode hadn't healed lost 55 more
        -- and died the moment he was saved).
        pcall(function() pb:setGodMod(false, true) end)
        local now = hp(pb)
        if now > CFG2.stableFloor + 10 then
            pcall(function() pb:getBodyDamage():ReduceGeneralHealth(now - (CFG2.stableFloor + 10)) end)
        end
        pcall(function() pb:getBodyDamage():getBodyPart(BodyPartType.Torso_Upper):setBandaged(true, 10) end)
        stable[J.pid] = { squad = prec.squad, quietSince = nil }      -- (stepStable: up, limp to cover)
        setBusy(J.pid, "lying")
        healTo(pb, CFG2.stableFloor + 5)
        mrec.medicSaves = (mrec.medicSaves or 0) + 1
        -- Saved, but critical: he must get back to the surgeon (LF_Wounds, LF_AidPost).
        if LF.Wounds then
            pb:getModData().LF_woundShown = "critical"
            LF.Wounds.grade(prec, "critical", "saved by " .. LF.Units.title(mrec))
        end
        LF.log(string.format("MEDIC #%d %s stabilises #%d %s (%d wounds dressed; %d saved; kit %d)", mid,
            LF.Units.title(mrec), J.pid, LF.Units.title(prec), n, mrec.medicSaves, mrec.kit))
        if LF.Tactics then LF.Tactics.shout(mid, "He'll live - keep your head down!") end
    else
        mrec.kit = math.max(0, (mrec.kit or 0) - CFG2.bandageCost)
        LF.log(string.format("MEDIC #%d %s dresses #%d %s's wounds (%d; kit %d)", mid, LF.Units.title(mrec), J.pid,
            LF.Units.title(prec), n, mrec.kit))
    end
    if (mrec.kit or 0) <= 0 and LF.Tactics then LF.Tactics.shout(mid, "I'm out of dressings!") end
    endJob(mid)
end

-- The worst case in his squad he can go to: (patient id, body, kind) or nil.
local function worstCase(mrec, mb)
    local best, bestScore, bestKind = nil, math.huge, nil
    for _, rid in ipairs(LF.Units.members(mrec.squad)) do
        local r, b = LF.Records.get(rid), LF.Bodies.get(rid)
        if rid ~= mrec.id and r and r.alive and b and not b:isDead() and math.abs(b:getZ() - mb:getZ()) < 0.5 then
            local d = LF.dist(mb:getX(), mb:getY(), b:getX(), b:getY())
            local taken = false
            for oid, oj in pairs(jobs2) do if oid ~= mrec.id and oj.pid == rid then taken = true end end
            if d <= CFG2.range and not taken then
                if crit[rid] then
                    local score = crit[rid].untilTick - LF.tick + d * 30
                    if score < bestScore then best, bestScore, bestKind = rid, score, "stabilise" end
                -- (A man already saved once has had his help: no going back to him.)
                elseif not stable[rid] and not r.critOnce and (mrec.kit or 0) >= CFG2.bandageCost and LF.Combat.health(b) < CFG2.severeHealth
                    and LF.Aid.bleedingPart(b) and not busyAs(rid) then
                    local score = 100000 + LF.Combat.health(b) * 100 + d * 30
                    if score < bestScore then best, bestScore, bestKind = rid, score, "bandage" end
                end
            end
        end
    end
    return best, best and LF.Bodies.get(best), bestKind
end

local function enemyClose(mid, mb, mrec, range)
    local seen = LF.Sense.look(mid, mb, mrec, range or CFG2.threatRange)
    return #seen > 0
end

local function startJob(mid, mb, mrec, pid, pb, kind)
    local lvl = levelOf(mrec)
    local J = { pid = pid, kind = kind, phase = "go", at = LF.tick, nextPath = 0,
                waitUntil = lvl == "shaken" and LF.tick + CFG2.shakenDelay or nil }
    jobs2[mid] = J
    setBusy(mid, "treating")
    ISTimedActionQueue.clear(mb)
    if LF.Idle then LF.Idle.stop(mb) end
    local prec = LF.Records.get(pid)
    LF.log(string.format("MEDIC #%d %s goes to %s #%d %s, %d tiles", mid, LF.Units.title(mrec),
        kind == "stabilise" and "save" or "dress", pid, prec and LF.Units.title(prec) or "?",
        math.floor(LF.dist(mb:getX(), mb:getY(), pb:getX(), pb:getY()))))
    -- The enemy near the man: the squad gives him cover.
    local near = false
    for _, c in ipairs(LF.Squad.contactPoints(mrec.squad, 600, 24)) do
        if LF.dist(c.x, c.y, pb:getX(), pb:getY()) <= 25 then near = true; break end
    end
    if near and LF.Tactics then
        local squad = LF.Units.get(mrec.squad)
        local caller = squad and LF.Units.commander(squad)
        if caller and caller ~= mid and caller ~= pid and LF.Bodies.get(caller) then LF.Tactics.shout(caller, "Cover the medic!") end
    end
    J.callOut = kind == "stabilise" and mrec.lastCalled ~= pid
    mrec.lastCalled = pid
    -- Off at once (not on the next half-second check).
    LF.guard("medic job", LF.Medic.stepJob, mid, J)
end

local stepJob
function LF.Medic.stepJob(mid, J) return stepJob(mid, J) end
stepJob = function(mid, J)
    local mb, pb = LF.Bodies.get(mid), LF.Bodies.get(J.pid)
    local mrec = LF.Records.get(mid)
    if not (mb and mrec and mrec.alive) or mb:isDead() then jobs2[mid] = nil; setBusy(mid, nil); return end
    if not pb or pb:isDead() then endJob(mid, "the man is dead"); return end
    if J.kind == "stabilise" and not crit[J.pid] then endJob(mid); return end
    if J.kind ~= "stabilise" and crit[J.pid] and J.phase == "go" then J.kind = "stabilise" end
    -- (Only really down: a bump running past his own men isn't - 0.40 broke off for those,
    -- walked back to his place and came out again.)
    local down = false
    pcall(function() down = mb:isOnFloor() or mb:isKnockedDown() end)
    if down then endJob(mid, "knocked down"); return end
    if enemyClose(mid, mb, mrec, J.kind == "stabilise" and CFG2.threatRangeSaving or CFG2.threatRange) then
        local q = ISTimedActionQueue.getTimedActionQueue(mb)
        local a = q and q.queue and q.queue[1]
        if a and a.Type == "LF_TreatAction" then ISTimedActionQueue.clear(mb) end
        endJob(mid, "enemy in sight close by")
        return
    end
    if J.waitUntil and LF.tick < J.waitUntil then return end
    if J.callOut then
        J.callOut = nil
        if LF.Tactics then LF.Tactics.shout(mid, "I'm coming - hold on!") end
    end
    -- Running to a man he isn't pinned on the way (like a man moving under orders).
    if LF.Suppress then LF.Suppress.setMoving(mid, J.phase == "go") end
    if J.phase == "go" then
        local d = LF.dist(mb:getX(), mb:getY(), pb:getX(), pb:getY())
        if d <= 1.4 then
            ISTimedActionQueue.clear(mb)
            if LF.Posture then LF.Posture.set(mb, true) end
            if LF.Combat then J.slung = LF.Combat.sling(mb) end
            local ticks = J.kind == "stabilise" and CFG2.stabiliseTicks or CFG2.bandageTicks
            if levelOf(mrec) == "veteran" then ticks = math.floor(ticks * CFG2.vetSpeed) end
            J.phase, J.at = "treat", LF.tick
            ISTimedActionQueue.add(LF_TreatAction:new(mb, pb, ticks,
                function() finishTreat(mid, J) end,
                function() if jobs2[mid] == J and J.phase == "treat" then endJob(mid, "interrupted") end end))
            LF.log("MEDIC #" .. mid .. " works on #" .. J.pid)
            if LF.Tactics and mrec.lastPatient ~= J.pid then
                LF.Tactics.shout(mid, J.kind == "stabilise" and "Stay with me!" or "Hold still, I've got you.")
            end
            mrec.lastPatient = J.pid
        elseif LF.tick >= J.nextPath or not moving(mb) then
            J.nextPath = LF.tick + 60
            if LF.Suppress and LF.Suppress.isPinned(mb) then
                -- Pinned on the way: he gets down and fights like anyone (not frozen in the open
                -- with his job still on); he tries again in a few seconds.
                ISTimedActionQueue.clear(mb)
                endJob(mid, "pinned down on the way")
                return
            end
            -- Beside him, on the side nearest the medic.
            local dx, dy = mb:getX() - pb:getX(), mb:getY() - pb:getY()
            local l = math.max(0.1, math.sqrt(dx * dx + dy * dy))
            local tx, ty = pb:getX() + dx / l * 0.9, pb:getY() + dy / l * 0.9
            walk(mb, tx, ty, math.floor(pb:getZ()), d > 4 and "run" or "walk")
        elseif LF.tick - J.at > 2400 then
            endJob(mid, "couldn't get to him")
        end
    end
end

local function stepCrit(id, c)
    local b = LF.Bodies.get(id)
    local rec = LF.Records.get(id)
    if not b or b:isDead() or not (rec and rec.alive) then crit[id] = nil; setBusy(id, nil); return end
    -- Held above death every tick (his bleeding can't take him before the clock does), and kept
    -- down on his back - nothing gets him up or out of it.
    if hp(b) < CFG2.floor + 3 then healTo(b, CFG2.floor + 6) end
    if LF.due(30, 0) and not busyAs(id) then
        LF.log("CRITICAL #" .. id .. " wasn't lying down - back down")
        LF.Medic.holdDown(id, b)
    end
    -- Being worked on: the clock stops.
    local treating = false
    for _, J in pairs(jobs2) do if J.pid == id and J.phase == "treat" then treating = true end end
    if treating then c.untilTick = c.untilTick + LF.dTicks() end
    if LF.tick >= c.untilTick then
        crit[id] = nil
        setBusy(id, nil)
        LF.log("CRITICAL #" .. id .. " " .. LF.Units.title(rec) .. " bled out - nobody reached him")
        pcall(function() b:setGodMod(false, true) end)
        kill(b)
    end
end

-- Stabilised: he gets up and limps off to cover - a hiding spot out of the enemy's sight, toward
-- his squad's rear - and stays down there until the fight is over; then he's himself again
-- (wounded: out of the fight).
local function limpAway(id, b, rec, s)
    s.phase = "limp"
    s.at = LF.tick
    -- A limp: his legs hurt (the game limps a man with painful legs).
    pcall(function()
        local bd = b:getBodyDamage()
        bd:getBodyPart(BodyPartType.UpperLeg_L):setAdditionalPain(60)
        bd:getBodyPart(BodyPartType.LowerLeg_L):setAdditionalPain(60)
    end)
    local tx, ty = nil, nil
    local c = LF.Squad.bestContact(s.squad, b:getX(), b:getY(), 3600, 60)
    local rx, ry = LF.Squad.rear(rec, 10)
    if c and LF.Cover.findHidingSpot then
        local threat = LF.Tactics.point(c.x, c.y, c.z or b:getZ())
        tx, ty = LF.Cover.findHidingSpot(id, b, threat, rx, ry, nil)
        if tx then tx, ty = tx + 0.5, ty + 0.5 end
    end
    if not tx then tx, ty = rx, ry end
    if tx then
        s.spot = { x = tx, y = ty }
        walk(b, tx, ty, math.floor(b:getZ()), "limp")
        LF.log(string.format("MEDIC #%d %s limps off to cover at %d,%d", id, LF.Units.title(rec), math.floor(tx), math.floor(ty)))
    else
        s.phase = "rest"
    end
end

local function stepStable(id, s)
    local b = LF.Bodies.get(id)
    local rec = LF.Records.get(id)
    if not b or b:isDead() or not (rec and rec.alive) then stable[id] = nil; setBusy(id, nil); return end
    if hp(b) < CFG2.stableFloor then healTo(b, CFG2.stableFloor) end
    if s.phase == nil then
        -- Up off his back first.
        s.phase = "rising"
        LF.Medic.getUp(id, b, function()
            setBusy(id, "resting")
            LF.guard("limp to cover", limpAway, id, b, rec, s)
        end)
        return
    end
    if s.phase == "rising" then return end
    if s.phase == "limp" then
        local there = s.spot and LF.dist(b:getX(), b:getY(), s.spot.x, s.spot.y) <= 1.5
        if there or (not moving(b) and LF.tick - s.at > 120) or LF.tick - s.at > 3600 then
            ISTimedActionQueue.clear(b)
            s.phase = "rest"
        elseif not moving(b) and s.spot then
            walk(b, s.spot.x, s.spot.y, math.floor(b:getZ()), "limp")
        end
        return
    end
    -- Resting in cover until the fight is over: sitting, tending his wounds.
    s.mind = s.mind or {}
    if LF.Idle and LF.Idle.nurse then LF.guard("nurse", LF.Idle.nurse, b, s.mind) end
    local quiet = #LF.Squad.contactPoints(s.squad, CFG2.quietRelease, 24) == 0
    if not quiet then s.quietSince = nil
    else
        s.quietSince = s.quietSince or LF.tick
        if LF.tick - s.quietSince > 120 then
            stable[id] = nil
            setBusy(id, nil)
            rec.wounded = true
            LF.log("MEDIC #" .. id .. " " .. LF.Units.title(rec) .. " - the fight's over; he comes out, wounded")
        end
    end
end

-- Dying where he stands (bleeding out, not from one hit): he may go critical too.
local function monitor()
    for id, b in pairs(LF.Bodies.all()) do
        if not crit[id] and not stable[id] and not b:isDead() then
            local r = LF.Records.get(id)
            if r and r.alive and not r.critOnce and not r.aid and r.squad and r.faction ~= "CIV" and LF.Combat.health(b) <= CFG2.dyingAt + 5 then
                LF.Medic.onHit(b, "bleeding")
            end
        end
    end
end

LF.on("OnTick", "Medic", function()
    for id, c in pairs(crit) do LF.guard("critical", stepCrit, id, c) end
    if LF.due(10, 5) then LF.guard("dying check", monitor) end
    if LF.due(30, 0) then
        for id, s in pairs(stable) do LF.guard("stabilised", stepStable, id, s) end
        for mid, J in pairs(jobs2) do LF.guard("medic job", stepJob, mid, J) end
    end
    if not LF.due(30, 15) then return end
    -- Medics without a job look for one.
    for _, squad in pairs(LF.Units.all()) do
        if squad.kind == "squad" and not squad.teamOnly then
            if not squad.medicSet then LF.guard("pick medic", LF.Medic.pick, squad) end
            local mrec = medicOf(squad.id)
            local mb = mrec and LF.Bodies.get(mrec.id)
            if mb and not mb:isDead() and not jobs2[mrec.id] and not busyAs(mrec.id) and LF.tick >= (cooldown[mrec.id] or 0)
                and LF.Combat.health(mb) >= 35 and not LF.Combat.knockedDown(mb) and not enemyClose(mrec.id, mb, mrec)
                and not (LF.Suppress and LF.Suppress.isPinned(mb)) then
                local pid, pb, kind = worstCase(mrec, mb)
                if pid then LF.guard("medic start", startJob, mrec.id, mb, mrec, pid, pb, kind) end
            end
        end
    end
end)

-- Test: the soldier nearest (x, y) whose squad has a medic takes a killing wound and goes critical.
function LF.Medic.testCritical(x, y)
    local best, bd = nil, math.huge
    for id, b in pairs(LF.Bodies.all()) do
        local r = LF.Records.get(id)
        if r and r.alive and not r.medic and r.squad and not crit[id] and not stable[id] and medicOf(r.squad) then
            local d = LF.dist(b:getX(), b:getY(), x, y)
            if d < bd then best, bd = b, d end
        end
    end
    if not best then LF.say("No soldier with a squad medic nearby"); return end
    local id = best:getModData().LF_id
    local r = LF.Records.get(id)
    r.critOnce = nil
    pcall(function() best:getBodyDamage():getBodyPart(BodyPartType.Torso_Upper):damageFromFirearm(60) end)
    pcall(function() best:getBodyDamage():ReduceGeneralHealth(LF.Combat.health(best)) end)
    LF.Medic.onHit(best, "shot", "Torso_Upper", true)
    LF.say(crit[id] and ("#" .. id .. " is down critical - his medic should come") or "Couldn't make him critical (see log)")
end
