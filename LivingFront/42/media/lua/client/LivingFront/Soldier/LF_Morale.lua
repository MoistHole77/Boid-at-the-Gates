-- Living Front: morale.
--
-- Every soldier has a morale from 0 to 100 (saved with him, rec.morale). It starts at 60 (a
-- veteran 70, a shaken man 45) and moves with what happens around him:
--   down - a man of his own squad killed (-8; -3 for the rest of the platoon), his lieutenant
--          killed (-12 across the platoon), his squad breaking (-10), a withdrawal (-5), being
--          pinned down (-1 every second or so)
--   up   - his squad carrying out a task the lieutenant gave it (+15; +6 for the rest of the
--          platoon), his officers close by: the lieutenant within sight (~25 tiles) steadies him
--          toward 75, the platoon sergeant beside his squad (~12 tiles) toward 80
--   drift - out of a fight it slowly settles back toward 60
-- What it does:
--   * the suppression at which he is pinned: 9 higher at 80, 9 lower at 20 (on top of Veteran /
--     Shaken)
--   * suppression builds up 15% faster below 35, 10% slower above 70
--   * his squad falls back sooner when its average is low (at 60% fit with an average of 20,
--     at 40% with 80, against the usual 50%)
-- Morale events are logged per squad ("MORALE ..."), not per man.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"

LF.Morale = LF.Morale or {}

local CFG = {
    base = 60, veteran = 70, shaken = 45,
    squadDeath = -8, platoonDeath = -3, ltDeath = -12, broke = -10, withdraw = -5,
    pinned = -1,
    task = 15, taskPlatoon = 6,
    ltRange = 25, ltTo = 75, ltRate = 1.0,
    ssgtRange = 12, ssgtTo = 80, ssgtRate = 1.5,
    settleRate = 0.3,
    updateTicks = 60,
    pinPerPoint = 0.3,      -- pinned-at shift per point of morale away from 50
}
LF.Morale.CFG = CFG

local function startOf(rec)
    local s = rec.svc
    if s and s.shaken then return CFG.shaken end
    if s and s.veteran then return CFG.veteran end
    return CFG.base
end

function LF.Morale.get(rec)
    if not rec then return CFG.base end
    if rec.morale == nil then rec.morale = startOf(rec) end
    return rec.morale
end

local function clamp(v) return math.max(0, math.min(100, v)) end

function LF.Morale.add(rec, delta)
    if not (rec and rec.alive) then return end
    rec.morale = clamp(LF.Morale.get(rec) + delta)
end

-- Every living soldier of a unit (squad or platoon headquarters).
local function eachIn(unitId, fn)
    for _, r in pairs(LF.Records.all()) do
        if r.alive and r.squad == unitId then fn(r) end
    end
end

-- The units of a squad's platoon (its squads and headquarters), or just the squad.
local function platoonUnits(unitId)
    local u = LF.Units and LF.Units.get(unitId)
    local p = u and u.platoon and LF.Units.get(u.platoon)
    if not p then return { unitId } end
    local list = { p.hq }
    for _, sid in ipairs(p.squads or {}) do list[#list + 1] = sid end
    return list
end

local function average(unitId)
    local sum, n = 0, 0
    eachIn(unitId, function(r) sum, n = sum + LF.Morale.get(r), n + 1 end)
    return n > 0 and sum / n or CFG.base
end
LF.Morale.average = average

local function unitName(id)
    local u = LF.Units and LF.Units.get(id)
    return u and u.name or ("unit " .. tostring(id))
end

-- Add delta to a whole unit, and platoonDelta to the rest of its platoon. Logged once.
function LF.Morale.unitEvent(unitId, delta, why, platoonDelta)
    if not unitId then return end
    eachIn(unitId, function(r) LF.Morale.add(r, delta) end)
    if platoonDelta and platoonDelta ~= 0 then
        for _, uid in ipairs(platoonUnits(unitId)) do
            if uid ~= unitId then eachIn(uid, function(r) LF.Morale.add(r, platoonDelta) end) end
        end
    end
    LF.log("MORALE " .. unitName(unitId) .. " " .. (delta >= 0 and "+" or "") .. delta .. " (" .. why .. "), average now "
        .. math.floor(average(unitId)) .. (platoonDelta and (", rest of the platoon " .. (platoonDelta >= 0 and "+" or "") .. platoonDelta) or ""))
end

-- ---- events ----------------------------------------------------------------------------------

function LF.Morale.died(rec)
    if not rec.squad then return end
    if rec.rank == "LT" and rec.hqRole ~= "xo" then
        for _, uid in ipairs(platoonUnits(rec.squad)) do eachIn(uid, function(r) LF.Morale.add(r, CFG.ltDeath) end) end
        LF.log("MORALE the platoon " .. CFG.ltDeath .. " (" .. LF.Units.title(rec) .. " killed)")
        return
    end
    LF.Morale.unitEvent(rec.squad, CFG.squadDeath, LF.Units.title(rec) .. " killed", CFG.platoonDeath)
end

function LF.Morale.broke(squad) LF.Morale.unitEvent(squad.id, CFG.broke, "the squad broke") end

-- A squad carried out a task its lieutenant gave it.
function LF.Morale.taskDone(squad, what)
    LF.Morale.unitEvent(squad.id, CFG.task, what, CFG.taskPlatoon)
end

function LF.Morale.withdraw(squad) LF.Morale.unitEvent(squad.id, CFG.withdraw, "ordered to withdraw") end

-- ---- leadership and the strain of being pinned ------------------------------------------------

local function bodyOf(id) return id and LF.Bodies and LF.Bodies.get(id) end

local function update()
    if not (LF.Units and LF.Bodies) then return end
    -- Where each platoon's officers are.
    local officers = {}            -- platoon id -> { lt = body, ssgt = body, ssgtWith = squad id }
    for _, p in pairs(LF.Units.all()) do
        if p.kind == "platoon" then
            local hq = LF.Units.get(p.hq)
            local o = {}
            if hq then
                for _, rid in ipairs(LF.Units.members(hq.id)) do
                    local r = LF.Records.get(rid)
                    local b = r and r.alive and bodyOf(rid)
                    if b and not b:isDead() then
                        if r.rank == "LT" or rid == hq.leader then o.lt = o.lt or b end
                        if r.hqRole == "ssgt" and rid ~= hq.leader then o.ssgt = b end
                    end
                end
            end
            o.ssgtWith = p.mainEffort
            officers[p.id] = o
        end
    end
    for id, body in pairs(LF.Bodies.all()) do
        local r = LF.Records.get(id)
        if r and r.alive and r.squad and r.faction ~= "CIV" and not body:isDead() then
            local m = LF.Morale.get(r)
            local x, y = body:getX(), body:getY()
            local u = LF.Units.get(r.squad)
            local o = u and u.platoon and officers[u.platoon]
            local pinned = LF.Suppress and LF.Suppress.isPinned(body)
            local lifted = false
            if o and o.lt and o.lt ~= body and LF.distSq(x, y, o.lt:getX(), o.lt:getY()) <= CFG.ltRange * CFG.ltRange and m < CFG.ltTo then
                m = math.min(CFG.ltTo, m + CFG.ltRate); lifted = true
            end
            if o and o.ssgt and o.ssgt ~= body and r.squad == o.ssgtWith
                and LF.distSq(x, y, o.ssgt:getX(), o.ssgt:getY()) <= CFG.ssgtRange * CFG.ssgtRange and m < CFG.ssgtTo then
                m = math.min(CFG.ssgtTo, m + CFG.ssgtRate); lifted = true
            end
            if pinned then
                m = m + CFG.pinned
            elseif not lifted and LF.Suppress and LF.Suppress.value(body) <= 0 then
                local to = startOf(r)
                if m < to then m = math.min(to, m + CFG.settleRate) elseif m > to then m = math.max(to, m - CFG.settleRate) end
            end
            r.morale = clamp(m)
        end
    end
end

Events.OnTick.Add(function()
    if LF.tick % CFG.updateTicks == 0 then LF.guard("morale", update) end
end)

-- ---- effects ---------------------------------------------------------------------------------

-- Change to the suppression level at which he is pinned.
function LF.Morale.pinShift(id)
    local r = LF.Records.get(id)
    if not r then return 0 end
    return (LF.Morale.get(r) - 50) * CFG.pinPerPoint
end

-- Multiplier on suppression he picks up.
function LF.Morale.suppressMul(id)
    local r = LF.Records.get(id)
    if not r then return 1 end
    local m = LF.Morale.get(r)
    if m < 35 then return 1.15 end
    if m > 70 then return 0.9 end
    return 1
end

-- The share of fit men below which a squad falls back (the usual one, moved by its morale).
function LF.Morale.fallbackShare(squad, usual)
    local avg = average(squad.id)
    return math.max(0.3, math.min(0.65, usual + (50 - avg) / 300))
end

-- A word for it (the inspect window).
function LF.Morale.word(v)
    if v >= 80 then return "high" elseif v >= 60 then return "steady" elseif v >= 40 then return "uneasy"
    elseif v >= 20 then return "shaken" end
    return "breaking"
end
