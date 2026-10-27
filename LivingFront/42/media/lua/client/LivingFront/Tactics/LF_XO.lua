-- Living Front: the executive officer - the company's manpower and medical supplies (roadmap phase
-- 5, step C3).
--
-- Supply runs: every CFG.runEvery game hours a run comes up from the rear to the company
-- headquarters, entering from behind it. It brings 2-3 replacement men (only as many as the
-- company is short, no more than CFG.poolMax waiting at once) and CFG.runSupplies medical supplies
-- for the aid post (LF_AidPost); a new surgeon if the company has lost its own, and a new XO if
-- he is gone. With no XO, runs come half as often.
-- Replacements wait at headquarters: they can't find their unit by themselves. The XO decides
-- where each goes - the squad furthest below strength (the headquarters' own security team is
-- filled straight away) - and that squad has to come back to headquarters to pick them up.
-- Coming back to headquarters (a "refit", at the captain's look - LF_Captain calls LF.XO.refits):
-- a squad that has men waiting for it at headquarters, seriously wounded men limping along with
-- it, or its medic short of dressings is sent back - a free squad whenever it needs to, a
-- garrison only for men (wounded or waiting) and only while its objective isn't threatened. It
-- leaves its wounded with the surgeon, takes its men back, fills its medic's satchel, waits up to
-- CFG.waitHours for the seriously wounded to be seen to (a game hour each), and goes back - a
-- garrison to its objective, a free squad to its lieutenant. Not more than CFG.maxRefits at once.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Tactics/LF_Company"
require "LivingFront/Tactics/LF_Platoon"
require "LivingFront/Tactics/LF_AidPost"
require "LivingFront/Units/LF_Objective"

LF.XO = LF.XO or {}

local CFG = {
    runEvery = 6,           -- game hours between supply runs
    runSupplies = 20,
    menMin = 2, menExtra = 1,   -- 2-3 men a run
    poolMax = 8,            -- replacements waiting at headquarters, at most
    rearDist = 40,          -- tiles behind headquarters a run comes in from
    maxRefits = 2,          -- squads coming back to headquarters at once
    kitLow = 4,             -- a medic with this many dressings or fewer needs more
    waitHours = 1.5,        -- game hours a squad waits at headquarters for its wounded
    refitAgain = 600,       -- simulated seconds before a squad is sent back again (nothing urgent)
}
LF.XO.CFG = CFG

local hours = LF.Wounds.hours
local function title(rec) return rec and LF.Units.title(rec) or "?" end
local function short(u) return u and (u.name:gsub("^.* / ", "")) or "?" end

local function xoOf(c) return LF.AidPost.staff(c, "xo") end
LF.XO.of = xoOf

local function state(c)
    c.xo = c.xo or {}
    if not c.xo.nextRun then c.xo.nextRun = hours() + CFG.runEvery end
    return c.xo
end

function LF.XO.nextRunIn(c) return math.max(0, state(c).nextRun - hours()) end

local function radio(c, who, text)
    if LF.Radio and LF.Radio.broadcast then LF.Radio.broadcast(c.faction, who and title(who) or "Battalion", c.name, text) end
end

-- The company's squads (not its headquarters), wherever they are.
local function squadsOf(c)
    local out = {}
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "squad" and not u.companyHQ and not u.joined and LF.AidPost.companyOf(u) == c then out[#out + 1] = u end
    end
    return out
end

local function poolOf(c)
    local list = {}
    local d = LF.Records.data().aidMen or {}
    for id in pairs(d) do
        local r = LF.Records.get(id)
        local A = r and r.alive and r.aid
        if A and A.company == c.id and A.state == "pool" and not A.hqRole then list[#list + 1] = r end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- Is a staff place (by role) empty - its man dead or gone?
local function staffGone(c, role)
    local hq = LF.Company.hq(c)
    if not hq then return false end
    for _, rid in ipairs(LF.Units.members(hq.id)) do
        local r = LF.Records.get(rid)
        if r and r.hqRole == role and r.alive and not r.captured then return false end
    end
    -- (One already on his way up.)
    local d = LF.Records.data().aidMen or {}
    for id in pairs(d) do
        local r = LF.Records.get(id)
        if r and r.alive and r.aid and r.aid.company == c.id and r.aid.hqRole == role then return false end
    end
    return LF.AidPost.openSlot(hq, role) ~= nil
end

-- ---- supply runs -------------------------------------------------------------------------------

local SMG = { GER = "MP40", SOV = "PPSh" }

local function newMan(c, x, y, z, fields)
    local rec = LF.Units.placeSoldier(c.faction, x + ZombRand(5) - 2, y + ZombRand(5) - 2, z, fields)
    rec.aid = { state = "pool", company = c.id, at = LF.simTime, hqRole = fields.hqRole }
    LF.Records.data().aidMen = LF.Records.data().aidMen or {}
    LF.Records.data().aidMen[rec.id] = true
    return rec
end

local function supplyRun(c)
    local S = state(c)
    local xo = xoOf(c)
    local x, y, z = LF.AidPost.anchor(c)
    if not x then return end
    local hq = LF.Company.hq(c)
    local fx, fy = (hq and hq.facingX) or 1, (hq and hq.facingY) or 0
    local rx, ry = x - fx * CFG.rearDist, y - fy * CFG.rearDist
    -- How many men the company is short, less those already waiting.
    local short = 0
    for _, sq in ipairs(squadsOf(c)) do short = short + LF.AidPost.short(sq) end
    if hq then short = short + LF.AidPost.short(hq) end
    local pool = #poolOf(c)
    local n = math.max(0, math.min(CFG.menMin + ZombRand(CFG.menExtra + 1), short - pool, CFG.poolMax - pool))
    for _ = 1, n do newMan(c, rx, ry, z, { rank = "PVT", element = "B", slot = 3 }) end
    local extra = {}
    if staffGone(c, "surgeon") then
        newMan(c, rx, ry, z, { rank = "SGT", hqRole = "surgeon", unarmed = true })
        extra[#extra + 1] = "a new surgeon"
    end
    if staffGone(c, "xo") then
        newMan(c, rx, ry, z, { rank = "LT", hqRole = "xo" })
        extra[#extra + 1] = "a new executive officer"
    end
    local P = LF.AidPost.post(c)
    local before = P.supplies
    P.supplies = math.min(LF.AidPost.CFG.maxSupplies, P.supplies + CFG.runSupplies)
    S.runs = (S.runs or 0) + 1
    S.nextRun = hours() + (xo and CFG.runEvery or CFG.runEvery * 2)
    local words = string.format("%d replacement%s, %d medical supplies", n, n == 1 and "" or "s", P.supplies - before)
    if #extra > 0 then words = words .. ", " .. table.concat(extra, " and ") end
    LF.log(string.format("XO %s: supply run %d in from the rear - %s (company short %d, %d waiting already); next in %d h%s",
        c.name, S.runs, words, short, pool, xo and CFG.runEvery or CFG.runEvery * 2, xo and "" or " (no XO)"))
    radio(c, xo, "Supply run's in: " .. words .. ". Over.")
end

-- ---- where the replacements go -------------------------------------------------------------------

local function allocate(c)
    local hq = LF.Company.hq(c)
    local pool = poolOf(c)
    if #pool == 0 then return end
    -- Already promised to each squad; squads that no longer need them lose them.
    local promised = {}
    local squads = squadsOf(c)
    local byId = {}
    for _, sq in ipairs(squads) do byId[sq.id] = sq end
    for _, r in ipairs(pool) do
        local s = r.aid.squad and byId[r.aid.squad]
        if r.aid.squad and not s then r.aid.squad = nil end
        if s then promised[s.id] = (promised[s.id] or 0) + 1 end
    end
    for _, sq in ipairs(squads) do
        if (promised[sq.id] or 0) > LF.AidPost.short(sq) then
            for _, r in ipairs(pool) do
                if r.aid.squad == sq.id and (promised[sq.id] or 0) > LF.AidPost.short(sq) then
                    r.aid.squad = nil
                    promised[sq.id] = promised[sq.id] - 1
                end
            end
        end
    end
    local xo = xoOf(c)
    for _, r in ipairs(pool) do
        if r.aid.arrived and not r.aid.squad then
            -- The headquarters' own places first: he's here already.
            if hq and LF.AidPost.short(hq) > 0 and LF.AidPost.join(r, hq) then
                LF.log("XO " .. c.name .. ": " .. title(r) .. " joins the headquarters' security team")
            elseif xo then
                local best, bn = nil, 0
                for _, sq in ipairs(squads) do
                    local need = LF.AidPost.short(sq) - (promised[sq.id] or 0)
                    if need > bn then best, bn = sq, need end
                end
                if best then
                    r.aid.squad = best.id
                    promised[best.id] = (promised[best.id] or 0) + 1
                    LF.log(string.format("XO %s: %s is for %s (%d short) - it must come in to pick him up", c.name, title(r),
                        best.name, LF.AidPost.short(best)))
                end
            end
        end
    end
end

Events.OnTick.Add(function()
    if LF.tick % 300 ~= 141 then return end
    for _, c in pairs(LF.Units.all()) do
        if c.kind == "company" and LF.Company.hq(c) then
            local S = state(c)
            if hours() >= S.nextRun then LF.guard("supply run", supplyRun, c) end
            LF.guard("allocate", allocate, c)
        end
    end
end)

-- ---- squads coming back to headquarters (refits) ---------------------------------------------------

-- Why a squad should come back to headquarters (a few words), whether it's for men (urgent), or nil.
function LF.XO.needs(c, sq)
    local ready, new = LF.AidPost.waitingFor(c, sq.id)
    local hurt, kit = 0, nil
    for _, rid in ipairs(LF.Units.members(sq.id)) do
        local r = LF.Records.get(rid)
        local g = r and r.alive and not r.aid and r.wound and r.wound.grade
        if g == "serious" or g == "critical" then hurt = hurt + 1 end
        if r and r.alive and r.medic and not r.aid then kit = r.kit or 0 end
    end
    local why = {}
    if hurt > 0 then why[#why + 1] = hurt .. " wounded for the surgeon" end
    if ready > 0 then why[#why + 1] = ready .. " of its men patched up" end
    if new > 0 then why[#why + 1] = new .. " replacement" .. (new == 1 and "" or "s") end
    local supplies = LF.AidPost.post(c).supplies
    local lowKit = kit ~= nil and kit <= CFG.kitLow and supplies > 0
    if lowKit then why[#why + 1] = "dressings for the medic" end
    if #why == 0 then return nil end
    return table.concat(why, ", "), (hurt + ready + new) > 0, hurt
end

local function refitCount(c)
    local n = 0
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "squad" and u.refit and u.refit.company == c.id then n = n + 1 end
    end
    return n
end

local function sendRefit(c, cap, e, why)
    local sq = e.sq
    local hx, hy, hz = LF.AidPost.meetPoint(c)
    if not hx then return false end
    local sx, sy = LF.Platoon.posOf(sq)
    if not sx then return false end
    local home = e.p or (sq.homePlatoon and LF.Units.get(sq.homePlatoon))
    if e.p then
        -- Off its lieutenant's hands until it's back (as a probe).
        sq.homePlatoon = sq.homePlatoon or e.p.id
        for i = #(e.p.squads or {}), 1, -1 do if e.p.squads[i] == sq.id then table.remove(e.p.squads, i) end end
        if e.p.known then e.p.known[sq.id] = nil end
        sq.platoon = nil
    end
    local pace = (LF.Move and LF.Move.PATROL_PACE) or 0.75
    sq.refit = { company = c.id, phase = "out", since = LF.simTime, why = why,
                 obj = sq.garrison and sq.garrison.obj or nil,
                 deadline = LF.simTime + LF.dist(sx, sy, hx, hy) / pace * 1.5 + 300 }
    local o = { squad = sq.id, kind = "refit", x = hx, y = hy, z = hz,
                words = short(sq) .. ", back to company headquarters - " .. why .. "!" }
    if home and home.kind == "platoon" then LF.Platoon.issue(home, o) else LF.Platoon.apply({ name = c.name }, o) end
    LF.log(string.format("XO %s: %s comes back to headquarters (%s) - %d tiles%s", c.name, sq.name, why,
        math.floor(LF.dist(sx, sy, hx, hy)), sq.garrison and ", leaving its objective for now" or ""))
    radio(c, cap, short(home) .. ", send " .. short(sq) .. " back to me - " .. why .. ". Over.")
    return true
end

-- At the captain's look (LF_Captain): send squads back to headquarters. all: his squads (state,
-- fit); take(e) takes one off his free list; safe(obj) - may a garrison leave this objective now?
function LF.XO.refits(c, cap, all, take, safe)
    if not LF.Company.hq(c) then return end
    local out = refitCount(c)
    for _, e in ipairs(all) do
        if out >= CFG.maxRefits then return end
        local sq = e.sq
        if not sq.refit and (e.state == "free" or e.state == "garrison") then
            local why, urgent, hurt = LF.XO.needs(c, sq)
            local again = not sq.refitAt or LF.simTime - sq.refitAt >= CFG.refitAgain or sq.refitAt > LF.simTime
            local go = false
            if why and e.state == "free" then go = urgent or again
            elseif why and urgent and e.state == "garrison" then
                local obj = sq.garrison and LF.Objective.get(sq.garrison.obj)
                go = obj ~= nil and safe(obj)
            end
            if go and sendRefit(c, cap, e, why) then
                out = out + 1
                if e.state == "free" then take(e) end
            end
        end
    end
end

local function finishRefit(c, sq, why)
    local R = sq.refit
    sq.refit = nil
    sq.refitAt = LF.simTime
    if sq.platoonTask == "refit" then sq.platoonTask = nil end
    local obj = R and R.obj and sq.garrison and LF.Objective.get(R.obj)
    if obj then
        LF.Platoon.apply({ name = c.name }, { squad = sq.id, kind = "hold", obj = obj.id })
        LF.log("XO " .. c.name .. ": " .. sq.name .. " goes back to hold " .. obj.name .. " (" .. why .. ")")
        return
    end
    local home = sq.homePlatoon and LF.Units.get(sq.homePlatoon)
    LF.Platoon.goHome(sq)
    local cmd = home and LF.Platoon.commander(home)
    local b = cmd and LF.Bodies.get(cmd.id)
    local lx, ly, lz = nil, nil, 0
    if b and not b:isDead() then lx, ly, lz = b:getX(), b:getY(), math.floor(b:getZ())
    elseif cmd then lx, ly, lz = cmd.x, cmd.y, cmd.z or 0 end
    if lx then LF.March.order(sq, math.floor(lx), math.floor(ly), lz, "auto", { noGather = true }) end
    LF.log("XO " .. c.name .. ": " .. sq.name .. " goes back to its platoon (" .. why .. ")")
end

-- Each captain's look: squads on their way in, at headquarters, done.
function LF.XO.updateRefits(c, cap)
    local hx, hy = LF.AidPost.meetPoint(c)
    for _, sq in pairs(LF.Units.all()) do
        local R = sq.kind == "squad" and sq.refit
        if R and R.company == c.id then
            local x, y = LF.Platoon.posOf(sq)
            local fit = 0
            for _, rid in ipairs(LF.Units.members(sq.id)) do
                local r = LF.Records.get(rid)
                if r and r.alive and not r.captured and not r.aid then fit = fit + 1 end
            end
            if fit == 0 or not hx or not x then
                sq.refit = nil
                LF.Platoon.goHome(sq)
            elseif R.phase == "out" then
                local d = LF.dist(x, y, hx, hy)
                local M = LF.March.get(sq.id)
                local marched = sq.platoonTask == "refit" and (M == nil or M.arrived == true)
                if d <= 15 or (marched and d <= 40) or (LF.simTime > R.deadline and d <= 40) then
                    R.phase, R.atH = "atHQ", hours()
                    LF.March.cancel(sq.id)
                    local adm, back, new, dressings = LF.AidPost.visit(c, sq)
                    LF.log(string.format("XO %s: %s is at headquarters - %d wounded to the surgeon, %d of its men back, "
                        .. "%d replacement(s), %d dressings for its medic", c.name, sq.name, adm, back, new, dressings))
                    local cid = LF.Units.commander(sq)
                    if cid and LF.Bodies.get(cid) and LF.Tactics then LF.Tactics.shout(cid, "Right - wounded to the aid post, new men fall in!") end
                elseif LF.simTime > R.deadline or R.since > LF.simTime + 5 then
                    if R.since > LF.simTime + 5 then R.since, R.deadline = LF.simTime, LF.simTime + 600
                    else finishRefit(c, sq, "never got there") end
                end
            elseif R.phase == "atHQ" then
                LF.AidPost.visit(c, sq)
                -- Waiting for its seriously wounded to be seen to (critical men stay behind).
                local waiting = false
                for id in pairs(LF.Records.data().aidMen or {}) do
                    local r = LF.Records.get(id)
                    local A = r and r.alive and r.aid
                    if A and A.squad == sq.id and A.grade == "serious" and (A.state == "waiting" or A.state == "treating") then waiting = true end
                end
                local h = hours()
                if not waiting or h - (R.atH or h) >= CFG.waitHours or (R.atH or 0) > h then
                    finishRefit(c, sq, waiting and "can't wait any longer for its wounded" or "done")
                end
            end
        end
    end
end

-- Test: the next supply run now.
function LF.XO.runNow()
    local n = 0
    for _, c in pairs(LF.Units.all()) do
        if c.kind == "company" and LF.Company.hq(c) then state(c).nextRun = hours(); n = n + 1 end
    end
    LF.say(n > 0 and ("Supply run due now for " .. n .. " compan" .. (n == 1 and "y" or "ies")) or "No companies")
end
