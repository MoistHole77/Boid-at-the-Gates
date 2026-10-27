-- Living Front: suppression - one meter per squad (combat overhaul, 0.73).
--
-- Company of Heroes' way: fire coming in is felt by the squad as a whole, not man by man. Every
-- round fired at a squad's men - hit or miss - and every one landing close to them adds to its
-- meter; it drains away by itself, faster in cover and much faster once the firing stops.
--   steady     under 30
--   suppressed 30+: fires 1.6x slower and 30% less accurately, keeps low, won't advance
--   pinned     65+: down, fires 3x slower and 60% less accurately, won't move
-- A round's share of the squad's meter is bigger the fewer men it has left (1.5 / its fit men,
-- at least 0.15): one rifle round at a full squad shakes it a little; a machine gun's bursts pin
-- it in seconds. Recovery (points a second): 6 in the open, 10.5 in light cover, 15 in heavy
-- cover or a building - x4 once no round has come in for 7 seconds. So a squad's rifle fire
-- pins a squad in the open in seconds, keeps one behind a fence suppressed, and only rattles one
-- behind a wall; a machine gun pins anyone it can reach.
-- Each man still reads his squad's meter against his own thresholds: a veteran is pinned later,
-- a shaken man sooner, morale moves it (LF_Service, LF_Morale) - so a squad goes to ground
-- together, its steadiest men last.
-- Men moving under orders (bounding, a flank, running to cover) don't feel it until they're in
-- position. A man with no squad (a civilian) keeps a meter of his own, as before 0.73.
-- Off screen (LF_Clash) the same meter is fed by the rounds the enemy fires and read for how much
-- the squad can fire back. A pinned squad whose men's morale is low breaks and falls back as a
-- unit (LF_Command on screen, LF_Clash off screen).
-- The meter is runtime only.

require "LivingFront/Core/LF_Core"

LF.Suppress = LF.Suppress or {}

local CFG = {
    decayPerSecond = 10,    -- a man on his own (no squad)
    max = 100,
    suppressed = 30,
    pinned = 65,
    share = 1.5,            -- a round adds amount x (share / fit men) to the squad, ...
    shareMin = 0.15,        -- ... at least this much of it, at most all of it
    recover = 6,            -- squad meter drained per simulated second in the open
    coverRecover = { [0] = 1, [1] = 1.75, [2] = 2.5, [3] = 2.5 },
    quietAfter = 7,         -- simulated seconds with no round in: ...
    quietMul = 4,           -- ... it drains this much faster
}
LF.Suppress.CFG = CFG

local levels = {}       -- record id -> { v, tick } (men with no squad)
local immune = {}       -- record id -> true while moving under orders
local squads = {}       -- squad id -> { v, t, lastRound, sx, sy, cover, fit, state }

local function idOf(body) return body:getModData().LF_id end

local function recoverMul(id) return LF.Service and LF.Service.recoverMul(id) or 1 end
local function pinnedAt(id)
    return CFG.pinned + (LF.Service and LF.Service.pinShift(id) or 0) + (LF.Morale and LF.Morale.pinShift(id) or 0)
end
local function suppressedAt(id)
    return CFG.suppressed + (LF.Service and LF.Service.pinShift(id) or 0) * 0.5
end

-- ---- a man on his own ------------------------------------------------------------------------------

local function valueOf(id)
    local l = levels[id]
    if not l then return 0 end
    local v = l.v - (LF.tick - l.tick) * CFG.decayPerSecond * recoverMul(id) / 60
    if v <= 0 then levels[id] = nil; return 0 end
    return v
end

-- ---- the squad's meter ----------------------------------------------------------------------------

local function squadOfId(id)
    local rec = id and LF.Records.get(id)
    local sid = rec and rec.squad
    if sid and LF.Units.get(sid) then return sid end
    return nil
end

local function fitIn(sid)
    local n = 0
    for _, rid in ipairs(LF.Units.members(sid)) do
        local r = LF.Records.get(rid)
        if r and r.alive and not r.wounded and not r.aid and not r.captured then n = n + 1 end
    end
    return math.max(1, n)
end

-- Drained to now; returns the entry (or nil if there's nothing on the meter).
local function squadNow(sid)
    local S = squads[sid]
    if not S then return nil end
    local now = LF.simTime
    local dt = now - (S.t or now)
    if dt < 0 then dt = 0 end                       -- (simulated time restarts with a load)
    if dt > 0 then
        local rate = CFG.recover * (CFG.coverRecover[S.cover or 0] or 1)
        if now - (S.lastRound or now) >= CFG.quietAfter or (S.lastRound or 0) > now then rate = rate * CFG.quietMul end
        S.v = S.v - rate * dt
        S.t = now
    end
    if S.v <= 0 then
        if S.state and S.state ~= "steady" then
            LF.log("SUPPRESS " .. ((LF.Units.get(sid) or {}).name or sid) .. " is steady again")
        end
        squads[sid] = nil
        return nil
    end
    return S
end

local STATE_WORDS = { suppressed = "suppressed", pinned = "PINNED" }
local SHOUT = { suppressed = "Keep your heads down!", pinned = "We're pinned - get down!" }

local function stateOf(v)
    if v >= CFG.pinned then return "pinned" end
    if v >= CFG.suppressed then return "suppressed" end
    return "steady"
end

-- Add to a squad's meter. (sx, sy): where the fire comes from (for its cover while it recovers).
function LF.Suppress.addSquad(sid, amount, sx, sy, mul)
    local S = squadNow(sid)
    if not S then
        S = { v = 0, t = LF.simTime, cover = 0 }
        squads[sid] = S
    end
    if not S.fit or LF.simTime - (S.fitAt or -1000) > 2 or (S.fitAt or 0) > LF.simTime then
        S.fit, S.fitAt = fitIn(sid), LF.simTime
    end
    local share = math.max(CFG.shareMin, math.min(1, CFG.share / S.fit))
    S.v = math.min(CFG.max, S.v + amount * share * (mul or 1))
    S.lastRound = LF.simTime
    if sx then S.sx, S.sy = sx, sy end
    local st = stateOf(S.v)
    if st ~= (S.state or "steady") then
        local worse = st == "pinned" or (st == "suppressed" and (S.state or "steady") == "steady")
        S.state = st
        if worse then
            local u = LF.Units.get(sid)
            LF.log(string.format("SUPPRESS %s is %s (%.0f)", u and u.name or tostring(sid), STATE_WORDS[st] or st, S.v))
            local cid = u and LF.Units.commander(u)
            if cid and LF.Bodies and LF.Bodies.get(cid) and LF.Tactics and LF.Tactics.shout and SHOUT[st] then
                LF.Tactics.shout(cid, SHOUT[st])
            end
        end
    end
end

-- Off screen (LF_Clash): how covered the squad is while it recovers (0-3, LF_Ground's classes).
function LF.Suppress.setCover(sid, cls)
    local S = squads[sid]
    if S then S.cover = cls end
end

function LF.Suppress.squadValue(sid)
    local S = squadNow(sid)
    return S and S.v or 0
end
function LF.Suppress.squadState(sid) return stateOf(LF.Suppress.squadValue(sid)) end

-- On screen: each squad's cover while it recovers - what most of its men have between them and
-- where the fire came from (the cover map), looked at once a second.
local function coverPass()
    if not LF.Ground then return end
    for sid, S in pairs(squads) do
        if S.sx then
            local counts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
            local n = 0
            for _, rid in ipairs(LF.Units.members(sid)) do
                local b = LF.Bodies and LF.Bodies.get(rid)
                if b and not b:isDead() and n < 6 then
                    n = n + 1
                    local c = LF.Ground.cover(b:getX(), b:getY(), math.floor(b:getZ()), S.sx, S.sy)
                    counts[c] = counts[c] + 1
                end
            end
            if n > 0 then
                local best, bc = 0, -1
                for c = 0, 3 do if counts[c] > bc then best, bc = c, counts[c] end end
                S.cover = best
            end
        end
    end
end
LF.onTick("Suppress", function()
    if LF.due(60, 37) then LF.guard("suppress cover", coverPass) end
end)

-- ---- what each man feels (the API the rest of the mod uses) ---------------------------------------

function LF.Suppress.value(body)
    local id = idOf(body)
    if not id or immune[id] then return 0 end
    local sid = squadOfId(id)
    if sid then return LF.Suppress.squadValue(sid) end
    return valueOf(id)
end

-- Moving under orders: no suppression picked up or felt until in position.
function LF.Suppress.setMoving(id, moving)
    immune[id] = moving or nil
end

-- A round at (or close to) this man. from (optional): the shooter's body.
function LF.Suppress.add(body, amount, from)
    local id = idOf(body)
    if not id or immune[id] then return end
    local mul = 1
    if LF.Service then mul = mul * LF.Service.suppressMul(id) end
    if LF.Morale then mul = mul * LF.Morale.suppressMul(id) end
    local sid = squadOfId(id)
    if sid then
        local sx, sy = nil, nil
        if from then sx, sy = from:getX(), from:getY() end
        LF.Suppress.addSquad(sid, amount, sx, sy, mul)
        return
    end
    local was = valueOf(id)
    local v = math.min(CFG.max, was + amount * mul)
    local l = levels[id]
    if not l then l = {}; levels[id] = l end
    l.v, l.tick = v, LF.tick
    local pin = pinnedAt(id)
    if was < pin and v >= pin then
        LF.log("PINNED #" .. id .. " suppression " .. math.floor(v))
    end
end

function LF.Suppress.isPinned(body)
    local id = idOf(body)
    return id ~= nil and LF.Suppress.value(body) >= pinnedAt(id)
end
function LF.Suppress.isSuppressed(body)
    local id = idOf(body)
    return id ~= nil and LF.Suppress.value(body) >= suppressedAt(id)
end

-- Multiplier on the time between this soldier's shots.
function LF.Suppress.cadence(body)
    if LF.Suppress.isPinned(body) then return 3 end
    if LF.Suppress.isSuppressed(body) then return 1.6 end
    return 1
end

-- Multiplier on this soldier's hit chance.
function LF.Suppress.accuracy(body)
    if LF.Suppress.isPinned(body) then return 0.4 end
    if LF.Suppress.isSuppressed(body) then return 0.7 end
    return 1
end

function LF.Suppress.forget(id) levels[id] = nil; immune[id] = nil end
function LF.Suppress.forgetAll() levels = {}; immune = {}; squads = {} end
Events.OnInitGlobalModData.Add(function() levels, immune, squads = {}, {}, {} end)
