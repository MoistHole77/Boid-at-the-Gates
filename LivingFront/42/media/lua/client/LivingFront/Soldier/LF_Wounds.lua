-- Living Front: wounds - light, serious and critical (roadmap phase 5, step C3).
--
-- Every wound a man takes is graded, and a grade only ever gets worse (until it is healed):
--   light     health 60 or more (off-screen: a light wound). He fights on; it heals overnight -
--             at the first dawn (06:00) at least 6 game hours after he was hit.
--   serious   health 30-59. Out of the fight: he limps along behind his squad, keeps out of the
--             enemy's sight and doesn't shoot, until his squad takes him back to the company's
--             surgeon (LF_AidPost, LF_XO). Not seen by him within 2 game days, he dies of his wounds.
--   critical  health under 30, or a man the squad medic saved from death's door (LF_Medic). He must
--             go back to the surgeon at once, limping, a buddy from his squad helping him - when
--             his squad leader can spare the man. Not at the aid post within 6 game hours, he dies.
-- On a body the grade comes from his health (looked at every second); off-screen from the wound
-- itself (LF_Clash). A man whose body is put away and given a new one keeps his grade: the new
-- body is brought down to match.
--
-- The squad leader's call, every 2 s for each critical man of his: a buddy goes back with him once
-- the squad is out of contact and keeps CFG.sendQuiet fit men without the buddy. Nobody is sent
-- back across a fight (0.69 did: men limped and walked through the middle of it). Until then the
-- man waits under cover (and his clock runs).
--
-- rec.wound = { grade, at, healAt, dieAt } (game hours); rec.wounded = true while serious or
-- critical (out of the fight, as before). What he is doing about it is rec.aid (LF_AidPost).

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Units/LF_Units"

LF.Wounds = LF.Wounds or {}

local CFG = {
    lightAt = 60,           -- health: this or more is a light wound
    seriousAt = 30,         -- ... this or more serious; under it critical
    seriousHours = 48,      -- game hours a serious wound can wait for the surgeon
    criticalHours = 6,      -- ... a critical one
    dawn = 6,               -- light wounds heal at this hour ...
    nightMin = 6,           -- ... at least this many hours after the wound
    sendQuiet = 2,          -- fit men the squad keeps (besides the buddy) to spare one, out of contact
    floorAid = 15,          -- health a man on his way to (or at) the aid post is kept above
    contactTicks = 1800,    -- an enemy seen this recently (~30 s) means "in contact"
    showSerious = 45,       -- a new body for a seriously wounded man: health brought down to this
    showCritical = 22,      -- ... critically
}
LF.Wounds.CFG = CFG

local GRADE = { light = 1, serious = 2, critical = 3 }
LF.Wounds.GRADE = GRADE

local function title(rec) return rec and LF.Units.title(rec) or "?" end

local function hours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and h or 0
end
LF.Wounds.hours = hours

-- The first dawn at least CFG.nightMin hours after game hour h.
local function nextDawn(h)
    local ok, tod = pcall(function() return getGameTime():getTimeOfDay() end)
    if not ok or not tod then tod = h % 24 end
    local wait = CFG.dawn - tod
    while wait < CFG.nightMin do wait = wait + 24 end
    return h + wait
end

function LF.Wounds.gradeOf(rec) return rec and rec.wound and rec.wound.grade or nil end

-- Seriously or critically wounded and still with his squad: out of the fight (LF_Brain).
function LF.Wounds.outOfFight(rec)
    local g = rec and rec.wound and rec.wound.grade
    return (g == "serious" or g == "critical") and rec.aid == nil
end

-- The grade for a body's health.
local function byHealth(hp)
    if hp >= CFG.lightAt then return "light" end
    if hp >= CFG.seriousAt then return "serious" end
    return "critical"
end
LF.Wounds.byHealth = byHealth

-- Give rec (at least) grade g. True if it got worse.
function LF.Wounds.grade(rec, g, why)
    if not (rec and rec.alive and GRADE[g]) or rec.faction == "CIV" or rec.captured then return false end
    local w = rec.wound
    if w and GRADE[w.grade] >= GRADE[g] then return false end
    local h = hours()
    local was = w and w.grade
    w = w or {}
    w.grade, w.at = g, h
    if g == "light" then
        w.healAt, w.dieAt = nextDawn(h), nil
    else
        w.healAt = nil
        w.dieAt = h + (g == "critical" and CFG.criticalHours or CFG.seriousHours)
        -- (Already in the surgeon's hands: no clock.)
        local A = rec.aid
        if A and (A.state == "waiting" or A.state == "treating") then w.dieAt = nil end
    end
    rec.wound = w
    if g ~= "light" then
        if not rec.wounded and LF.Units.leads(rec) then LF.Units.relieve(rec) end
        rec.wounded = true
    end
    LF.log(string.format("WOUND #%d %s: %s%s (%s)%s", rec.id, title(rec), g, was and (" (was " .. was .. ")") or "",
        why or "?", w.dieAt and string.format(" - %d h to reach the surgeon", math.floor(w.dieAt - h + 0.5))
            or (w.healAt and string.format(" - heals in %.0f h", w.healAt - h) or "")))
    return true
end

-- Healed (overnight, or by the surgeon): fit again.
function LF.Wounds.heal(rec, why)
    rec.wound, rec.wounded, rec.critOnce, rec.offWound = nil, nil, nil, nil
    local b = LF.Bodies.get(rec.id)
    if b and not b:isDead() then
        pcall(function() b:getBodyDamage():RestoreToFullHealth() end)
        pcall(function() b:getModData().LF_woundShown = nil end)
    end
    LF.log("WOUND #" .. rec.id .. " " .. title(rec) .. " is fit again (" .. (why or "healed") .. ")")
end

-- He dies of his wounds.
function LF.Wounds.die(rec, why)
    -- (A body dies on the next pass of LF_Bodies: until then nobody sends him anywhere - 0.69
    -- sent four dead men back to the aid post.)
    if rec.wound then rec.wound.dead, rec.wound.dieAt = true, nil end
    LF.log("WOUND #" .. rec.id .. " " .. title(rec) .. " DIES of his wounds (" .. (why or "?") .. ")")
    local seen = {}
    if rec.squad then
        for _, rid in ipairs(LF.Units.members(rec.squad)) do
            local r = LF.Records.get(rid)
            if r and r.alive and rid ~= rec.id then seen[#seen + 1] = rid end
        end
    end
    if LF.Clash and LF.Clash.note then
        LF.Clash.note("diedOfWounds", { who = rec.id, unit = rec.squad, x = math.floor(rec.x), y = math.floor(rec.y), seen = seen })
    end
    if LF.AidPost and LF.AidPost.forget then LF.AidPost.forget(rec) end
    local b = LF.Bodies.get(rec.id)
    if b and not b:isDead() then
        pcall(function() b:setGodMod(false, true) end)
        pcall(function() b:setHealth(0) end)
        pcall(function() b:Kill(nil) end)
        return
    end
    rec.alive = false
    rec.diedOffscreen = { x = rec.x, y = rec.y, z = rec.z or 0 }
    if LF.Service then LF.guard("service record", LF.Service.died, rec) end
    LF.guard("succession", LF.Units.onDeath, rec)
end

-- ---- bodies: grading from health, and a new body matching its grade -----------------------------

local function injured(body)
    local ok, res = pcall(function()
        local parts = body:getBodyDamage():getBodyParts()
        for i = 0, parts:size() - 1 do
            if parts:get(i):HasInjury() then return true end
        end
        return false
    end)
    return ok and res == true
end

local function healthOf(body)
    if LF.Medic and LF.Medic.hp then return LF.Medic.hp(body) end
    return LF.Combat.health(body)
end

local function stopBleeding(body)
    pcall(function()
        local parts = body:getBodyDamage():getBodyParts()
        for i = 0, parts:size() - 1 do
            local p = parts:get(i)
            if p:bleeding() then
                p:setBleeding(false)
                p:setBleedingTime(0)
                p:setBandaged(true, 10)
            end
        end
    end)
end
LF.Wounds.stopBleeding = stopBleeding

local function bringDown(body, to)
    local hp = healthOf(body)
    if hp <= to + 5 then return end
    pcall(function()
        local bd = body:getBodyDamage()
        bd:getBodyPart(BodyPartType.Torso_Lower):setBandaged(true, 10)
        bd:getBodyPart(BodyPartType.UpperLeg_L):setAdditionalPain(60)
        bd:getBodyPart(BodyPartType.LowerLeg_L):setAdditionalPain(60)
        bd:ReduceGeneralHealth(hp - to)
    end)
end

local function checkBody(id, body)
    if body:isDead() then return end
    local rec = LF.Records.get(id)
    if not (rec and rec.alive and rec.faction ~= "CIV" and not rec.captured) then return end
    if not (rec.squad or rec.aid) then return end
    local w = rec.wound
    local md = body:getModData()
    -- A new body for a man already wounded: it shows it - and for a few seconds what the new
    -- body's health says doesn't make it worse (the wound put on him at spawn - LF_Bodies - can
    -- read a little lower than his grade).
    if w and md.LF_woundShown ~= w.grade then
        md.LF_woundShown = w.grade
        md.LF_gradeHold = LF.tick + 600
        if w.grade ~= "light" then
            -- (His wounds were dressed where he fell, off-screen: the new body doesn't bleed to
            -- death in its first minute - up to 0.69.1 men at the aid post died the moment you came.)
            stopBleeding(body)
            bringDown(body, w.grade == "critical" and CFG.showCritical or CFG.showSerious)
        end
        return
    end
    if rec.aid then
        -- In the aid post's care (on the way, waiting, treated): his buddy or the surgeon keeps
        -- the bleeding stopped; he dies of his wounds only by his clock (or the enemy).
        if LF.tick % 300 < 60 then stopBleeding(body) end
        local hp = healthOf(body)
        if hp < CFG.floorAid then pcall(function() for _ = 1, 4 do body:getBodyDamage():AddGeneralHealth(5) end end) end
    end
    if w and md.LF_gradeHold then
        if LF.tick < md.LF_gradeHold and LF.tick + 1200 > md.LF_gradeHold then
            local floor = w.grade == "light" and CFG.lightAt or (w.grade == "serious" and CFG.seriousAt or 5)
            if healthOf(body) < floor + 2 then
                pcall(function() for _ = 1, 6 do body:getBodyDamage():AddGeneralHealth(5) end end)
            end
            return
        end
        md.LF_gradeHold = nil
    end
    -- (Down and dying under the squad medic's eyes - LF_Medic - his grade comes when he's saved.)
    if LF.Medic and LF.Medic.isCritical and LF.Medic.isCritical(id) then return end
    local hp = healthOf(body)
    local g = byHealth(hp)
    if not w then
        if hp < 90 or injured(body) then
            md.LF_woundShown = g
            LF.Wounds.grade(rec, g, "hit - health " .. math.floor(hp))
        end
    elseif GRADE[g] > GRADE[w.grade] then
        md.LF_woundShown = g
        LF.Wounds.grade(rec, g, "worse - health " .. math.floor(hp))
    end
end

-- ---- clocks ---------------------------------------------------------------------------------------

local function clocks()
    local h = hours()
    for _, rec in pairs(LF.Records.all()) do
        local w = rec.wound
        if w and rec.alive then
            -- (Saved before 0.69: a man out of the fight with no grade is seriously wounded.)
            if not GRADE[w.grade] then rec.wound = nil
            elseif w.healAt and h >= w.healAt then
                LF.Wounds.heal(rec, "a light wound, healed overnight")
            elseif w.dieAt and h >= w.dieAt and not rec.captured and not w.dead then
                LF.Wounds.die(rec, w.grade == "critical" and "critical, never reached the surgeon"
                    or "serious, not seen by the surgeon in time")
            end
        elseif rec.alive and rec.wounded and not rec.wound and rec.faction ~= "CIV" then
            rec.wounded = nil
            LF.Wounds.grade(rec, "serious", "wounded before grades existed")
        end
    end
end

-- ---- the squad leader's call: who takes a critical man back ------------------------------------

local function fitMan(r)
    return r and r.alive and not r.wounded and not r.aid and not r.captured
        and not (LF.Medic and LF.Medic.busy and LF.Medic.busy(r.id))
end

local function posOf(id)
    local b = LF.Bodies.get(id)
    if b and not b:isDead() then return b:getX(), b:getY() end
    local r = LF.Records.get(id)
    return r and r.x, r and r.y
end

local function inContact(u)
    if LF.Clash and LF.Clash.inContact(u) then return true end
    return LF.Squad and #LF.Squad.contactPoints(u.id, CFG.contactTicks, 1) > 0
end

-- The buddy: a fit private, not the leader, a corporal, the medic or a gun crew - nearest first;
-- failing that any fit man but the leader.
local function pickEscort(u, patient, cmd)
    local px, py = posOf(patient.id)
    local best, bd, any, ad = nil, math.huge, nil, math.huge
    for _, rid in ipairs(LF.Units.members(u.id)) do
        local r = LF.Records.get(rid)
        if rid ~= patient.id and rid ~= cmd and fitMan(r) then
            local x, y = posOf(rid)
            local d = (x and px) and LF.dist(x, y, px, py) or 1000
            if d < ad then any, ad = r, d end
            local plain = not LF.Units.leads(r) and not r.medic and r.mgRole ~= "gunner" and r.mgRole ~= "assistant"
                and r.hqRole ~= "lt" and r.hqRole ~= "cpt"
            if plain and d < bd then best, bd = r, d end
        end
    end
    return best or any
end

local function decideFor(u, c)
    local cmd = LF.Units.commander(u)
    local contact = nil
    for _, rid in ipairs(LF.Units.members(u.id)) do
        local r = LF.Records.get(rid)
        local w = r and r.wound
        local walker = w and w.grade == "serious" and (u.companyHQ or u.kind == "hq")
        if w and not w.dead and r.alive and not r.aid and not r.captured and (w.grade == "critical" or walker)
            and not (LF.Medic and LF.Medic.isCritical and LF.Medic.isCritical(rid)) then
            -- (Just saved by the medic, still on his back or getting up: once he's on his feet.)
            local phase = LF.Medic and LF.Medic.stablePhase and LF.Medic.stablePhase(rid)
            if phase == nil or phase == "limp" or phase == "rest" then
                if u.companyHQ then
                    -- At the company headquarters already: straight to the surgeon.
                    LF.AidPost.send(c, r, nil, "at headquarters")
                elseif walker then
                    -- (A platoon headquarters never goes back to the company's: its lieutenant
                    -- sends a seriously wounded man back on his own once it's quiet.)
                    if contact == nil then contact = inContact(u) end
                    if not contact then LF.AidPost.send(c, r, nil, "sent back on his own by his lieutenant") end
                else
                    if contact == nil then contact = inContact(u) end
                    local fit = 0
                    for _, mid in ipairs(LF.Units.members(u.id)) do
                        if mid ~= rid and fitMan(LF.Records.get(mid)) then fit = fit + 1 end
                    end
                    local esc = not contact and fit - 1 >= CFG.sendQuiet and pickEscort(u, r, cmd) or nil
                    if esc then
                        LF.AidPost.send(c, r, esc, "out of contact")
                        if cmd and LF.Bodies.get(cmd) and LF.Tactics then
                            LF.Tactics.shout(cmd, (esc.forename or "You") .. ", get " .. (r.surname or "him")
                                .. " back to the aid post - go!")
                        end
                    elseif not w.waitLogged then
                        w.waitLogged = true
                        LF.log(string.format("WOUND %s: %s can't send %s back yet (%d fit, %s)", u.name,
                            cmd and title(LF.Records.get(cmd)) or "the squad", title(r), fit, contact and "in contact" or "too few men"))
                    end
                end
            end
        end
    end
end

local function calls()
    if not LF.AidPost then return end
    for _, u in pairs(LF.Units.all()) do
        if (u.kind == "squad" or u.kind == "hq") and not u.joined then
            local c = LF.AidPost.companyOf(u)
            if c and LF.Company.hq(c) then LF.guard("wound call", decideFor, u, c) end
        end
    end
end

Events.OnTick.Add(function()
    if LF.tick % 60 == 41 then
        for id, b in pairs(LF.Bodies.all()) do LF.guard("wound check", checkBody, id, b) end
    end
    if LF.tick % 120 == 77 then
        LF.guard("wound clocks", clocks)
        LF.guard("wound calls", calls)
    end
end)

-- Off-screen (LF_Clash): a wound of this severity (40-79) - its grade, and how hard it hits.
function LF.Wounds.offscreen(severity)
    if severity < 55 then return "light", 10 + ZombRand(15) end
    if severity < 70 then return "serious", 45 + ZombRand(12) end
    return "critical", 72 + ZombRand(6)
end

-- Words for his wound (the talk panel, his own sense of it).
function LF.Wounds.words(rec)
    local g = LF.Wounds.gradeOf(rec)
    local A = rec.aid
    if A then
        if A.state == "toAid" then return (g == "critical" and "critically" or "seriously") .. " wounded - making his way back to the aid post" end
        if A.state == "waiting" then return (g or "wounded") .. " - waiting for the surgeon" end
        if A.state == "treating" then return (g or "wounded") .. " - under the surgeon's care" end
        if A.state == "ready" then return "patched up by the surgeon - waiting at headquarters for his squad" end
        if A.state == "pool" then return "a replacement - waiting at headquarters to join his squad" end
    end
    if g == "light" then return "lightly wounded - it should heal overnight" end
    if g == "serious" then return "seriously wounded - out of the fight until the surgeon sees him" end
    if g == "critical" then return "critically wounded - he needs the surgeon, fast" end
    return nil
end

-- Test: wound the soldier nearest (x, y) - grade g.
function LF.Wounds.test(x, y, g)
    local best, bd = nil, math.huge
    for _, rec in pairs(LF.Records.all()) do
        if rec.alive and rec.squad and rec.faction ~= "CIV" and not rec.wound and not rec.aid then
            local px, py = posOf(rec.id)
            local d = px and LF.dist(px, py, x, y) or math.huge
            if d < bd then best, bd = rec, d end
        end
    end
    if not best then LF.say("No unwounded soldier nearby"); return end
    local b = LF.Bodies.get(best.id)
    if b then
        pcall(function() b:getBodyDamage():getBodyPart(BodyPartType.Torso_Lower):damageFromFirearm(30) end)
        bringDown(b, g == "critical" and CFG.showCritical or (g == "serious" and CFG.showSerious or 75))
        b:getModData().LF_woundShown = g
    end
    LF.Wounds.grade(best, g, "test")
    LF.say(title(best) .. " - " .. g .. " wound")
end
