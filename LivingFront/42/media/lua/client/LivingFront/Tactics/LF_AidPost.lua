-- Living Front: the company aid post and its surgeon (roadmap phase 5, step C3).
--
-- Where: at the company headquarters, moving with it. Outdoors the surgeon treats 4 men at a time,
-- lying on the ground, the rest sitting nearby waiting; with the headquarters inside a building he
-- sets the aid post up in it and treats 6.
-- Who comes (LF_Wounds grades the wounds; light ones heal by themselves overnight):
--   critical  sent back at once by his squad leader, limping, a buddy helping him (rec.aid
--             "toAid" / "escort"). Reaching the post stops his clock. Treated: a game day. After
--             that he waits at headquarters ("ready") until his squad comes back there; his buddy
--             goes straight back to the squad once he has got him there ("back").
--   serious   limps along behind his squad until it comes back to headquarters (LF_XO sends it);
--             it leaves him here. Treated: a game hour - if the squad is still at headquarters he
--             goes back with it, if not he waits for it.
-- Waiting at the post, a man is safe: the surgeon has him. Treatment takes medical supplies
-- (serious 2, critical 3); none left, nobody new is started until the next supply run (LF_XO).
-- With no surgeon (killed, or himself a casualty) nothing is treated until a new one comes.
-- A squad at headquarters also gets its medic's dressings made up (1 supply for 2 dressings), and
-- picks up the replacements waiting for it.
--
-- rec.aid (saved with the man):
--   toAid { company, escort, squad }     escort { company, patient, squad }    back { company, squad }
--   waiting { company, since, grade, squad }     treating { ..., left (game hours), spot }
--   ready { company, squad }      pool { company, squad (assigned by the XO, or nil), arrived, hqRole }
-- c.aid (on the company): { supplies, indoor, lastH }.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Squad"
require "LivingFront/Specialists/LF_Medic"
require "LivingFront/Soldier/LF_Wounds"
require "LivingFront/Tactics/LF_Company"

LF.AidPost = LF.AidPost or {}

local CFG = {
    bedsOutdoors = 4, bedsIndoors = 6,
    critHours = 24, seriousHours = 1,     -- game hours the surgeon needs
    cost = { critical = 3, serious = 2, light = 1 },
    supplies = 40,                         -- a new aid post's stock
    maxSupplies = 60,
    kit = 8,                               -- a squad medic's dressings
    limpPace = 0.75, walkPace = 0.9,       -- tiles a simulated second, off-screen (a critical man
                                           -- helped along keeps up a walk; on-screen he limps)
    arrive = 6,                            -- tiles from the post: there
    rejoin = 8,                            -- tiles from his squad: back with it
    surgeonWork = 600,                     -- ticks he works on a man before going to the next
}
LF.AidPost.CFG = CFG

local function title(rec) return rec and LF.Units.title(rec) or "?" end
local hours = LF.Wounds.hours

local function men()
    local d = LF.Records.data()
    d.aidMen = d.aidMen or {}
    return d.aidMen
end

local nextPath = {}          -- id -> tick he may be given a new walk (bodies)
local minds = {}             -- id -> a mind table for LF_Idle while he waits
local spotCache = {}         -- company id -> { key, treat, wait, pool }
local surgeonJob = {}        -- company id -> { pid, phase, nextAt }
Events.OnInitGlobalModData.Add(function() nextPath, minds, spotCache, surgeonJob = {}, {}, {}, {} end)

-- ---- the company, its headquarters, the post --------------------------------------------------------

-- The company a unit belongs to - its platoon's, or the one it's lent out by (garrison, probe, refit).
function LF.AidPost.companyOf(u)
    if not u then return nil end
    local c = LF.Company.of(u)
    if c then return c end
    local cid = (u.garrison and u.garrison.company) or (u.probe and u.probe.company) or (u.refit and u.refit.company)
    if cid then return LF.Units.get(cid) end
    if u.homePlatoon then return LF.Company.of(LF.Units.get(u.homePlatoon)) end
    return nil
end

local function post(c)
    c.aid = c.aid or { supplies = CFG.supplies }
    return c.aid
end
LF.AidPost.post = post

-- A staff member of the headquarters by role, alive and fit for his job (not a casualty himself).
function LF.AidPost.staff(c, role)
    local hq = LF.Company.hq(c)
    if not hq then return nil end
    for _, rid in ipairs(LF.Units.members(hq.id)) do
        local r = LF.Records.get(rid)
        if r and r.hqRole == role and r.alive and not r.wounded and not r.aid and not r.captured then return r end
    end
    return nil
end
local function surgeonOf(c) return LF.AidPost.staff(c, "surgeon") end

-- Where the post is: the headquarters (its commander, or the last place it was).
function LF.AidPost.anchor(c)
    local P = post(c)
    local hq = LF.Company.hq(c)
    local x, y, z = nil, nil, nil
    if hq then x, y, z = LF.Squad.anchor(hq.id) end
    if not x and hq then
        for _, rid in ipairs(LF.Units.members(hq.id)) do
            local r = LF.Records.get(rid)
            if r and r.alive and not r.aid then x, y, z = r.x, r.y, r.z or 0; break end
        end
    end
    if x then P.x, P.y, P.z = x, y, math.floor(z or 0) end
    return P.x, P.y, P.z
end

local function facing(c)
    local hq = LF.Company.hq(c)
    local fx, fy = (hq and hq.facingX) or c.facingX or 1, (hq and hq.facingY) or c.facingY or 0
    local l = math.sqrt(fx * fx + fy * fy)
    if l < 0.01 then return 1, 0 end
    return fx / l, fy / l
end

-- Where a squad coming in to headquarters goes: beside it.
function LF.AidPost.meetPoint(c)
    local x, y, z = LF.AidPost.anchor(c)
    if not x then return nil end
    local fx, fy = facing(c)
    return math.floor(x - fy * 12), math.floor(y + fx * 12), z or 0
end

local function beds(c) return post(c).indoor and CFG.bedsIndoors or CFG.bedsOutdoors end
LF.AidPost.beds = beds

local function posOf(rec)
    local b = LF.Bodies.get(rec.id)
    if b and not b:isDead() then return b:getX(), b:getY(), math.floor(b:getZ()) end
    return rec.x, rec.y, rec.z or 0
end

-- ---- the men in its care ------------------------------------------------------------------------------

local function mark(rec, A)
    rec.aid = A
    men()[rec.id] = true
    if LF.Bodies.get(rec.id) and not LF.Medic.busyAs(rec.id) then LF.Medic.setBusy(rec.id, "aid") end
end

-- Done with: the aid post lets him go (dead, rejoined, joined).
function LF.AidPost.forget(rec)
    rec.aid = nil
    men()[rec.id] = nil
    nextPath[rec.id], minds[rec.id] = nil, nil
    if LF.Medic.busyAs(rec.id) == "aid" then LF.Medic.setBusy(rec.id, nil) end
end

-- Up off his back if he's lying there (a new body never is).
local function upIfLying(rec)
    local b = LF.Bodies.get(rec.id)
    if not b or b:isDead() then return end
    local md = b:getModData()
    if md.LF_aidLying then
        md.LF_aidLying = nil
        LF.Medic.getUp(rec.id, b, function() if rec.aid then LF.Medic.setBusy(rec.id, "aid") end end)
    end
end

-- Back to his squad: the brain has him again.
function LF.AidPost.rejoin(rec, why)
    upIfLying(rec)
    local b = LF.Bodies.get(rec.id)
    if b and minds[rec.id] and LF.Idle then LF.Idle.stop(b, minds[rec.id]) end
    LF.AidPost.forget(rec)
    if LF.Medic.busyAs(rec.id) == "aid" then LF.Medic.setBusy(rec.id, nil) end
    LF.log("AID #" .. rec.id .. " " .. title(rec) .. " rejoins his squad (" .. (why or "?") .. ")")
end

local function near(c, spread)
    local x, y, z = LF.AidPost.anchor(c)
    if not x then return nil end
    return x + ZombRand(spread * 2 + 1) - spread, y + ZombRand(spread * 2 + 1) - spread, z
end

-- He is at the post now: in the surgeon's care.
function LF.AidPost.admit(c, rec, why)
    local w = rec.wound
    if w then w.dieAt = nil end
    local A = { state = "waiting", company = c.id, since = hours(), grade = w and w.grade or "serious", squad = rec.squad }
    mark(rec, A)
    if not LF.Bodies.get(rec.id) then
        local x, y, z = near(c, 4)
        if x then rec.x, rec.y, rec.z = x, y, z end
    end
    LF.log(string.format("AID %s: %s (%s) is at the aid post - %s", c.name, title(rec), A.grade, why or "?"))
end

-- His squad leader sends a critical man back (with a buddy) - or, at headquarters, he's there.
function LF.AidPost.send(c, rec, escort, why)
    if LF.Medic.release then LF.Medic.release(rec.id) end
    local x, y = LF.AidPost.anchor(c)
    local px, py = posOf(rec)
    if not escort and x and LF.dist(px, py, x, y) <= 30 then
        LF.AidPost.admit(c, rec, why)
        return
    end
    mark(rec, { state = "toAid", company = c.id, escort = escort and escort.id or nil, squad = rec.squad, at = LF.simTime })
    if escort then
        if LF.Medic.release then LF.Medic.release(escort.id) end
        mark(escort, { state = "escort", company = c.id, patient = rec.id, squad = escort.squad, at = LF.simTime })
    end
    LF.log(string.format("AID %s: %s (critical) goes back to the aid post, %d tiles%s (%s)", c.name, title(rec),
        x and math.floor(LF.dist(px, py, x, y)) or -1, escort and (", helped by " .. title(escort)) or ", alone", why or "?"))
end

-- A slot in the squad for a new man: a dead (or taken) man's place.
local function openSlot(squad, role)
    -- (At the company headquarters a plain replacement only fills the security team's places.)
    if squad.companyHQ and not role then role = "security" end
    for _, tid in ipairs(squad.teams or {}) do
        local t = LF.Units.get(tid)
        if t then
            for i, rid in ipairs(t.members) do
                local r = LF.Records.get(rid)
                if (not r or not r.alive or r.captured) and (role == nil or (r and r.hqRole == role)) then return t, i, r end
            end
        end
    end
    return nil
end
LF.AidPost.openSlot = openSlot

-- Places in a squad no living man fills.
function LF.AidPost.short(squad)
    local n = 0
    for _, tid in ipairs(squad.teams or {}) do
        local t = LF.Units.get(tid)
        if t then
            for _, rid in ipairs(t.members) do
                local r = LF.Records.get(rid)
                if (not r or not r.alive or r.captured) and not (squad.companyHQ and r and r.hqRole ~= "security") then n = n + 1 end
            end
        end
    end
    return n
end

-- A replacement takes a place in the squad. True if there was one.
function LF.AidPost.join(rec, squad, role)
    if squad.companyHQ and not role then role = "security" end
    local t, i, old = openSlot(squad, role)
    if not t then return false end
    t.members[i] = rec.id
    rec.squad, rec.team = squad.id, t.id
    rec.slot = (old and old.slot) or i
    rec.element = (old and old.element) or (i <= 2 and "A" or "B")
    if role then rec.hqRole = role end
    if squad.mg or (squad.name and squad.name:find("MG squad", 1, true)) then rec.mgRole = rec.mgRole or "ammo" end
    -- (His place was the medic's: the squad picks a new medic.)
    local hasMedic = false
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r and r.alive and r.medic then hasMedic = true end
    end
    LF.Units.dirty(squad.id)
    if not hasMedic and not squad.companyHQ then squad.medicSet = nil end
    upIfLying(rec)
    LF.AidPost.forget(rec)
    LF.log("AID " .. title(rec) .. " #" .. rec.id .. " joins " .. squad.name .. " (" .. t.name .. ", in "
        .. (old and title(old) or "an empty place") .. "'s place)")
    return true
end

-- Men waiting at headquarters for this squad: patched up, and new men for it.
function LF.AidPost.waitingFor(c, squadId)
    local ready, new = 0, 0
    for id in pairs(men()) do
        local r = LF.Records.get(id)
        local A = r and r.aid
        if A and A.company == c.id and A.squad == squadId then
            if A.state == "ready" then ready = ready + 1 elseif A.state == "pool" and not A.hqRole then new = new + 1 end
        end
    end
    return ready, new
end

-- A squad has come in to headquarters: its wounded go to the surgeon, its men waiting here go back
-- with it, its medic's satchel is filled. Returns a few words for the log.
function LF.AidPost.visit(c, squad)
    local P = post(c)
    local adm, back, new, dressings = 0, 0, 0, 0
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        local g = r and r.wound and r.wound.grade
        if r and r.alive and not r.aid and not r.captured and (g == "serious" or g == "critical") then
            LF.AidPost.admit(c, r, "brought in by " .. squad.name)
            adm = adm + 1
        end
    end
    for id in pairs(men()) do
        local r = LF.Records.get(id)
        local A = r and r.aid
        if A and A.company == c.id and A.squad == squad.id then
            if A.state == "ready" then
                LF.AidPost.rejoin(r, "his squad came for him")
                back = back + 1
            elseif A.state == "pool" and A.arrived and not A.hqRole then
                if LF.AidPost.join(r, squad) then new = new + 1 else A.squad = nil end
            end
        end
    end
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r and r.alive and r.medic and not r.aid and (r.kit or 0) < CFG.kit then
            local want = CFG.kit - (r.kit or 0)
            local cost = math.ceil(want / 2)
            if cost > P.supplies then want, cost = P.supplies * 2, P.supplies end
            if want > 0 then
                r.kit = math.min(CFG.kit, (r.kit or 0) + want)
                P.supplies = P.supplies - cost
                dressings = dressings + want
            end
        end
    end
    return adm, back, new, dressings
end

-- ---- spots on the ground (bodies only) --------------------------------------------------------------

local function key(x, y) return math.floor(x) .. "," .. math.floor(y) end

local function freeNear(x, y, z, taken)
    local cell = getCell()
    local bx, by = math.floor(x), math.floor(y)
    for r = 0, 3 do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local sq = cell:getGridSquare(bx + dx, by + dy, z)
                    local k = (bx + dx) .. "," .. (by + dy)
                    if sq and not taken[k] and sq:isFree(false) then
                        taken[k] = true
                        return { x = bx + dx + 0.5, y = by + dy + 0.5, z = z }
                    end
                end
            end
        end
    end
    return nil
end

local function spaced(list, s, gap)
    for _, o in ipairs(list) do
        if LF.distSq(o.x, o.y, s.x, s.y) < gap * gap then return false end
    end
    return true
end

local function buildSpots(c, x, y, z)
    local fx, fy = facing(c)
    local rx, ry = -fy, fx
    local taken = {}
    local S = { treat = {}, wait = {}, pool = {} }
    local P = post(c)
    local L = P.indoor and LF.Building and LF.Building.at(x, y, z) or nil
    if L and L.inside then
        -- Inside: beds spread through the rooms, nearest the headquarters first; the waiting
        -- along with them.
        local list = {}
        for _, s in ipairs(L.inside) do list[#list + 1] = { x = s.x + 0.5, y = s.y + 0.5, z = z, d = LF.distSq(s.x, s.y, x, y) } end
        table.sort(list, function(a, b) return a.d < b.d end)
        for _, s in ipairs(list) do
            if #S.treat < CFG.bedsIndoors and spaced(S.treat, s, 2) then S.treat[#S.treat + 1] = s; taken[key(s.x, s.y)] = true end
        end
        for _, s in ipairs(list) do
            if #S.wait < 8 and not taken[key(s.x, s.y)] and spaced(S.treat, s, 1) and spaced(S.wait, s, 1.4) then
                S.wait[#S.wait + 1] = s; taken[key(s.x, s.y)] = true
            end
        end
    else
        for i = 1, CFG.bedsOutdoors do
            local s = freeNear(x - fx * 6 + rx * (i - 2.5) * 2, y - fy * 6 + ry * (i - 2.5) * 2, z, taken)
            if s then S.treat[#S.treat + 1] = s end
        end
    end
    for i = #S.wait + 1, 8 do
        local s = freeNear(x - fx * 10 + rx * (i - 4.5) * 1.5, y - fy * 10 + ry * (i - 4.5) * 1.5, z, taken)
        if s then S.wait[#S.wait + 1] = s end
    end
    for i = 1, 10 do
        local a, b = (i - 1) % 5 - 2, math.floor((i - 1) / 5)
        local s = freeNear(x + rx * (9 + b * 1.5) + fx * a * 1.5, y + ry * (9 + b * 1.5) + fy * a * 1.5, z, taken)
        if s then S.pool[#S.pool + 1] = s end
    end
    return S
end

-- The spots, if the ground there is loaded (nil if not).
local function spotsOf(c)
    local x, y, z = LF.AidPost.anchor(c)
    if not x then return nil end
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), z or 0)
    if not sq then return nil end
    local P = post(c)
    local indoor = sq:getBuilding() ~= nil
    if indoor ~= (P.indoor or false) then
        P.indoor = indoor or nil
        LF.log("AID " .. c.name .. ": the aid post is " .. (indoor and "set up inside the headquarters' building (6 beds)"
            or "in the open by the headquarters (4 men on the ground)"))
    end
    local k = math.floor(x / 4) .. "," .. math.floor(y / 4) .. "," .. tostring(indoor)
    local S = spotCache[c.id]
    if not S or S.key ~= k then
        S = buildSpots(c, x, y, z or 0)
        S.key = k
        spotCache[c.id] = S
    end
    return S
end

-- ---- moving the men --------------------------------------------------------------------------------

local function towards(x, y, tx, ty, maxD)
    local d = LF.dist(x, y, tx, ty)
    if d <= maxD then return tx, ty end
    return x + (tx - x) / d * maxD, y + (ty - y) / d * maxD
end

-- Walk him toward (tx, ty): his body if he has one, else his record. Returns his distance from it.
local function moveTo(rec, A, tx, ty, tz, pace, gait)
    local b = LF.Bodies.get(rec.id)
    if b and not b:isDead() then
        A.at = LF.simTime
        local d = LF.dist(b:getX(), b:getY(), tx, ty)
        if d <= 1.2 or LF.Medic.busyAs(rec.id) == "rising" then return d end
        if LF.Idle and LF.Idle.isSitting(b) then
            if minds[rec.id] then LF.Idle.stop(b, minds[rec.id]) else LF.Idle.standUp(b) end
            return d
        end
        if not LF.Medic.moving(b) and LF.tick >= (nextPath[rec.id] or 0) then
            nextPath[rec.id] = LF.tick + 90
            local z = math.floor(tz or b:getZ())
            local wx, wy = towards(b:getX(), b:getY(), tx, ty, 40)
            if not LF.Medic.walk(b, wx, wy, z, gait) then
                wx, wy = towards(b:getX(), b:getY(), tx, ty, 12)
                LF.Medic.walk(b, wx, wy, z, gait)
            end
        end
        return d
    end
    local dt = LF.simTime - (A.at or LF.simTime)
    A.at = LF.simTime
    if dt > 0 then
        dt = math.min(dt, 60)
        local d = LF.dist(rec.x, rec.y, tx, ty)
        local step = math.min(d, pace * dt)
        if d > 0.01 then rec.x, rec.y = rec.x + (tx - rec.x) / d * step, rec.y + (ty - rec.y) / d * step end
        rec.z = tz or rec.z
    end
    return LF.dist(rec.x, rec.y, tx, ty)
end

-- Settle a waiting man on his spot (bodies): lying for the surgeon, sitting while waiting,
-- standing about otherwise.
local function settle(rec, A, spot, how)
    local b = LF.Bodies.get(rec.id)
    if not (b and spot) or b:isDead() then return end
    if not LF.Medic.busyAs(rec.id) then LF.Medic.setBusy(rec.id, "aid") end
    local md = b:getModData()
    if how ~= "lie" and md.LF_aidLying then upIfLying(rec); return end
    if LF.dist(b:getX(), b:getY(), spot.x, spot.y) > 1.2 then
        if minds[rec.id] and minds[rec.id].rest and LF.Idle then LF.Idle.stop(b, minds[rec.id]) end
        moveTo(rec, A, spot.x, spot.y, spot.z, CFG.walkPace, how == "stand" and "walk" or "limp")
        return
    end
    if LF.Medic.moving(b) then return end
    if how == "lie" then
        if not md.LF_aidLying then
            md.LF_aidLying = true
            LF.Medic.lieDown(rec.id, b)
        end
        return
    end
    minds[rec.id] = minds[rec.id] or {}
    if how == "sit" and LF.Idle and LF.Idle.nurse then LF.guard("aid nurse", LF.Idle.nurse, b, minds[rec.id])
    elseif LF.Idle and LF.Idle.tick then LF.guard("aid rest", LF.Idle.tick, b, minds[rec.id]) end
end

-- Keep a man at the post near it (off-screen: if it has moved on, he follows).
local function stayNear(c, rec, A)
    if LF.Bodies.get(rec.id) then return end
    local x, y, z = LF.AidPost.anchor(c)
    if x and LF.dist(rec.x, rec.y, x, y) > 15 then moveTo(rec, A, x, y, z, CFG.walkPace, "walk")
    else A.at = LF.simTime end
end

-- (Bodies only) an enemy in sight within 25 tiles?
local function enemyInSight(rec)
    local b = LF.Bodies.get(rec.id)
    if not b or b:isDead() or not LF.Sense then return false end
    local ok, seen = pcall(LF.Sense.look, rec.id, b, rec, 25)
    return ok and seen ~= nil and #seen > 0
end

local function walkers(c, list, S)
    local x, y, z = LF.AidPost.anchor(c)
    if not x then return end
    local wi, pi = 0, 0
    local treatN = 0
    for _, rec in ipairs(list) do
        local A = rec.aid or {}
        if LF.Bodies.get(rec.id) and rec.aid and not LF.Medic.busyAs(rec.id) then LF.Medic.setBusy(rec.id, "aid") end
        if not rec.aid then
            -- (let go earlier in this pass)
        elseif (A.state == "toAid" or A.state == "escort" or A.state == "back") and enemyInSight(rec) then
            -- Walking back with the enemy in sight: down, and wait for it to pass.
            local b = LF.Bodies.get(rec.id)
            if LF.Medic.moving(b) then ISTimedActionQueue.clear(b) end
            if LF.Posture and not LF.Posture.crouched(b) then LF.Posture.set(b, true) end
            A.at = LF.simTime
        elseif A.state == "toAid" then
            if LF.Bodies.get(rec.id) and LF.Medic.busyAs(rec.id) == "lying" then
                local b = LF.Bodies.get(rec.id)
                LF.Medic.getUp(rec.id, b, function() if rec.aid then LF.Medic.setBusy(rec.id, "aid") end end)
            elseif moveTo(rec, A, x, y, z, CFG.limpPace, "limp") <= CFG.arrive then
                LF.AidPost.admit(c, rec, A.escort and "helped in by his buddy" or "made it in")
            end
        elseif A.state == "escort" then
            local p = LF.Records.get(A.patient)
            if not (p and p.alive and p.aid and p.aid.state == "toAid") then
                mark(rec, { state = "back", company = c.id, squad = A.squad, at = LF.simTime })
                LF.log("AID " .. title(rec) .. " #" .. rec.id .. " heads back to his squad" ..
                    ((p and p.alive) and (" - " .. title(p) .. " is at the aid post") or " - the man he was helping has died"))
            else
                local px, py, pz = posOf(p)
                local d = LF.dist(rec.x, rec.y, px, py)
                if LF.Bodies.get(rec.id) then
                    local b = LF.Bodies.get(rec.id)
                    d = LF.dist(b:getX(), b:getY(), px, py)
                    if d > 2.5 then moveTo(rec, A, px + 0.8, py, pz, CFG.walkPace, d > 8 and "run" or "walk") end
                else
                    A.at = LF.simTime
                    rec.x, rec.y, rec.z = px + 0.8, py, pz
                end
            end
        elseif A.state == "back" then
            local sq = A.squad and LF.Units.get(A.squad)
            local sx, sy, sz = nil, nil, nil
            if sq then sx, sy, sz = LF.Squad.anchor(sq.id) end
            if not sx then
                mark(rec, { state = "pool", company = c.id, at = LF.simTime })
                LF.log("AID " .. title(rec) .. " #" .. rec.id .. " has no squad to go back to - he waits at headquarters")
            elseif moveTo(rec, A, sx, sy, sz, CFG.walkPace, "walk") <= CFG.rejoin then
                LF.AidPost.rejoin(rec, "back from the aid post")
            end
        elseif A.state == "pool" and not A.arrived then
            local tx, ty, tz = x, y, z
            if S and S.pool[1] then tx, ty = S.pool[1].x, S.pool[1].y end
            if moveTo(rec, A, tx, ty, tz, CFG.walkPace, "walk") <= 10 then
                A.arrived = true
                LF.log("AID " .. c.name .. ": " .. title(rec) .. " #" .. rec.id .. " reports at headquarters"
                    .. (A.hqRole and (" - the new " .. A.hqRole) or " - a replacement"))
                if A.hqRole then
                    local hq = LF.Company.hq(c)
                    if hq and LF.AidPost.join(rec, hq, A.hqRole) then
                        if A.hqRole == "surgeon" then rec.unarmed = true end
                    else
                        A.hqRole = nil
                    end
                end
            end
        elseif A.state == "treating" then
            treatN = treatN + 1
            stayNear(c, rec, A)
            if S then settle(rec, A, S.treat[A.spot or 1] or S.treat[1], "lie") end
        elseif A.state == "waiting" then
            wi = wi + 1
            stayNear(c, rec, A)
            if S then settle(rec, A, S.wait[(wi - 1) % math.max(1, #S.wait) + 1], "sit") end
        else    -- ready, pool (arrived)
            pi = pi + 1
            stayNear(c, rec, A)
            if S then settle(rec, A, S.pool[(pi - 1) % math.max(1, #S.pool) + 1], "stand") end
        end
    end
end

-- ---- the surgeon at work (his body: going from man to man) ---------------------------------------

local function surgeonAtWork(c, list, S)
    local s = surgeonOf(c)
    local sb = s and LF.Bodies.get(s.id)
    local J = surgeonJob[c.id]
    local patients = {}
    if sb and not sb:isDead() and S then
        for _, rec in ipairs(list) do
            local pb = LF.Bodies.get(rec.id)
            if rec.aid and rec.aid.state == "treating" and pb and not pb:isDead() and pb:getModData().LF_aidLying then patients[#patients + 1] = rec end
        end
    end
    local hq = LF.Company.hq(c)
    local fight = hq and LF.Squad and #LF.Squad.contactPoints(hq.id, 900, 1) > 0
    if #patients == 0 or fight then
        if s and LF.Medic.busyAs(s.id) == "surgeon" then
            LF.Medic.setBusy(s.id, nil)
            if sb and LF.Posture then LF.Posture.set(sb, false) end
        end
        surgeonJob[c.id] = nil
        return
    end
    LF.Medic.setBusy(s.id, "surgeon")
    if not J or J.phase == "done" then
        if J and LF.tick < (J.nextAt or 0) then return end
        local last = J and J.pid
        local pick = patients[1]
        for i, p in ipairs(patients) do
            if p.id == last then pick = patients[i % #patients + 1] end
        end
        J = { pid = pick.id, phase = "go", at = LF.tick }
        surgeonJob[c.id] = J
    end
    local pb = LF.Bodies.get(J.pid)
    if not pb or pb:isDead() then J.phase, J.nextAt = "done", LF.tick; return end
    if J.phase == "go" then
        local d = LF.dist(sb:getX(), sb:getY(), pb:getX(), pb:getY())
        if d <= 1.4 then
            ISTimedActionQueue.clear(sb)
            if LF.Posture then LF.Posture.set(sb, true) end
            J.phase = "treat"
            ISTimedActionQueue.add(LF_TreatAction:new(sb, pb, CFG.surgeonWork,
                function() J.phase, J.nextAt = "done", LF.tick + 90; if LF.Posture then LF.Posture.set(sb, false) end end,
                function() J.phase, J.nextAt = "done", LF.tick + 90; if LF.Posture then LF.Posture.set(sb, false) end end))
        elseif not LF.Medic.moving(sb) then
            if LF.tick - J.at > 1800 then J.phase, J.nextAt = "done", LF.tick; return end
            LF.Medic.walk(sb, pb:getX() + 0.9, pb:getY(), math.floor(pb:getZ()), "walk")
        end
    end
end

-- ---- treatment ----------------------------------------------------------------------------------------

local function finish(c, rec)
    local A = rec.aid
    local grade = A.grade or "serious"
    LF.Wounds.heal(rec, "treated by the surgeon")
    local sq = A.squad and LF.Units.get(A.squad)
    LF.log(string.format("AID %s: the surgeon is done with %s (%s)", c.name, title(rec), grade))
    if sq and (sq.companyHQ or (sq.refit and sq.refit.phase == "atHQ" and grade ~= "critical")) then
        LF.AidPost.rejoin(rec, sq.companyHQ and "back to his duties" or "his squad is still here")
        return
    end
    upIfLying(rec)
    mark(rec, { state = "ready", company = c.id, squad = A.squad })
end

local function treat(c, list)
    local P = post(c)
    local h = hours()
    local dH = math.max(0, h - (P.lastH or h))
    P.lastH = h
    local surgeon = surgeonOf(c)
    local treating, waiting, used = {}, {}, {}
    for _, rec in ipairs(list) do
        local A = rec.aid
        if A.state == "treating" then treating[#treating + 1] = rec; used[A.spot or 0] = true
        elseif A.state == "waiting" then waiting[#waiting + 1] = rec
        elseif (A.state == "ready" or (A.state == "pool" and A.arrived)) and rec.wound
            and (rec.wound.grade == "serious" or rec.wound.grade == "critical") then
            -- (Hit again waiting at headquarters: back to the surgeon.)
            LF.AidPost.admit(c, rec, "wounded at headquarters")
        end
    end
    if not surgeon then
        if (#treating + #waiting) > 0 and not P.noSurgeonLogged then
            P.noSurgeonLogged = true
            LF.log("AID " .. c.name .. ": no surgeon - " .. (#treating + #waiting) .. " men wait untreated")
        end
        return
    end
    P.noSurgeonLogged = nil
    for i = #treating, 1, -1 do
        local rec = treating[i]
        rec.aid.left = (rec.aid.left or 1) - dH
        if rec.aid.left <= 0 then
            used[rec.aid.spot or 0] = nil
            finish(c, rec)
            table.remove(treating, i)
        end
    end
    table.sort(waiting, function(a, b)
        local ga, gb = a.aid.grade == "critical", b.aid.grade == "critical"
        if ga ~= gb then return ga end
        return (a.aid.since or 0) < (b.aid.since or 0)
    end)
    local cap = beds(c)
    for _, rec in ipairs(waiting) do
        if #treating >= cap then break end
        local A = rec.aid
        local cost = CFG.cost[A.grade] or 2
        if P.supplies < cost then
            if not P.outLogged then
                P.outLogged = true
                LF.log("AID " .. c.name .. ": out of medical supplies (" .. P.supplies .. " left) - nobody new can be treated")
            end
            break
        end
        P.outLogged = nil
        P.supplies = P.supplies - cost
        local spot = 1
        while used[spot] do spot = spot + 1 end
        used[spot] = true
        A.state, A.left, A.spot = "treating", A.grade == "critical" and CFG.critHours or CFG.seriousHours, spot
        treating[#treating + 1] = rec
        LF.log(string.format("AID %s: %s starts on %s (%s, %d h; supplies %d)", c.name, title(surgeon), title(rec),
            A.grade, A.left, P.supplies))
    end
end

-- ---- running -----------------------------------------------------------------------------------------

local function byCompany()
    local out, order = {}, {}
    local M = men()
    local gone = {}
    for id in pairs(M) do
        local r = LF.Records.get(id)
        local A = r and r.aid
        local c = A and LF.Units.get(A.company)
        if not (r and r.alive and A and c) or r.captured then gone[#gone + 1] = id
        else
            if not out[c.id] then out[c.id] = {}; order[#order + 1] = c end
            local l = out[c.id]
            l[#l + 1] = r
        end
    end
    for _, id in ipairs(gone) do
        local r = LF.Records.get(id)
        if r and r.alive and r.aid then
            -- (His company is gone: he's on his own again.)
            LF.AidPost.forget(r)
        else
            M[id] = nil
        end
    end
    for _, l in pairs(out) do table.sort(l, function(a, b) return a.id < b.id end) end
    return out, order
end

-- (Only the men still in its care: one let go earlier in the same pass - rejoined, died - is
-- left out. Up to 0.69.1 that was an error, "attempted index: state of non-table".)
local function live(list)
    local out = {}
    for _, r in ipairs(list) do if r.alive and r.aid then out[#out + 1] = r end end
    return out
end

LF.on("OnTick", "AidPost", function()
    if not LF.due(30, 23) then return end
    local slow = LF.due(120, 83)
    local lists, order = byCompany()
    for _, c in ipairs(order) do
        local list = lists[c.id]
        if slow then LF.guard("aid treat", treat, c, live(list)) end
        local S = LF.guard("aid spots", spotsOf, c)
        LF.guard("aid walkers", walkers, c, live(list), S)
        LF.guard("aid surgeon", surgeonAtWork, c, live(list), S)
    end
end)

-- ---- what it's like (map, debug) --------------------------------------------------------------------

function LF.AidPost.status(c)
    local P = post(c)
    local n = { critT = 0, serT = 0, wait = 0, ready = 0, pool = 0, toAid = 0 }
    for id in pairs(men()) do
        local r = LF.Records.get(id)
        local A = r and r.alive and r.aid
        if A and A.company == c.id then
            if A.state == "treating" then
                if A.grade == "critical" then n.critT = n.critT + 1 else n.serT = n.serT + 1 end
            elseif A.state == "waiting" then n.wait = n.wait + 1
            elseif A.state == "ready" then n.ready = n.ready + 1
            elseif A.state == "pool" then n.pool = n.pool + 1
            elseif A.state == "toAid" then n.toAid = n.toAid + 1 end
        end
    end
    local s = surgeonOf(c)
    local lines = {
        "Aid post - " .. c.name,
        (P.indoor and "In a building, " or "In the open, ") .. beds(c) .. " beds; " .. (s and title(s) or "NO SURGEON"),
        string.format("Being treated: %d critical, %d serious; waiting: %d", n.critT, n.serT, n.wait),
        string.format("On the way in: %d; patched up, waiting for their squads: %d", n.toAid, n.ready),
        string.format("Replacements at headquarters: %d; medical supplies: %d", n.pool, P.supplies),
    }
    if LF.XO and LF.XO.nextRunIn then
        local h = LF.XO.nextRunIn(c)
        if h then lines[#lines + 1] = string.format("Next supply run in %.1f h", h) end
    end
    return lines, n
end
