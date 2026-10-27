-- Living Front: what each man remembers (roadmap phase 4).
--
-- Every event of the war - a man killed or wounded, a unit breaking, an objective changing
-- hands, a prisoner taken, contact made - is written to the event log (LF.Clash.note) with the
-- men who saw it. Off-screen fights write their own (LF_Clash); this file adds the ones that
-- happen in front of you. Nothing is kept per man: his memory is simply the events he saw, so it
-- is saved with the game and rolls back with a reload, as the war does.
--
-- LF.Memory.of(rec, n) gives a man's last n memories as sentences in the second person, from his
-- point of view ("Pvt. Lorenz from your squad was killed at Objective Anton, about 20 minutes
-- ago") - what the radio operator reports and what a man talks about when you speak to him.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/World/LF_Clash"

LF.Memory = LF.Memory or {}

local CFG = {
    sightRange = 30,        -- men this close to an event in front of you saw it
    placeRange = 40,        -- an event this close to an objective happened "at" it
}

local FACTION_PLURAL = { GER = "the Germans", SOV = "the Soviets", CIV = "civilians" }

local function bodyPos(r)
    local b = LF.Bodies and LF.Bodies.get(r.id)
    if b and not b:isDead() then return b:getX(), b:getY() end
    return r.x, r.y
end

-- Everyone alive within range of (x, y): who saw it.
local function witnessesAt(x, y, except)
    local ids = {}
    for id, r in pairs(LF.Records.all()) do
        if r.alive and id ~= except then
            local rx, ry = bodyPos(r)
            if LF.dist(rx, ry, x, y) <= CFG.sightRange then ids[#ids + 1] = id end
        end
    end
    return ids
end
LF.Memory.witnessesAt = witnessesAt

local function note(kind, fields)
    if LF.Clash and LF.Clash.note then LF.Clash.note(kind, fields) end
end

-- ---- events in front of you ---------------------------------------------------------------------

-- A man died with a body (LF_Bodies calls this).
function LF.Memory.died(rec)
    if rec.diedOffscreen or rec.captured then return end
    note("killed", { who = rec.id, unit = rec.squad, x = math.floor(rec.x), y = math.floor(rec.y),
                     seen = witnessesAt(rec.x, rec.y, rec.id) })
end

-- An objective changed hands (LF_Objective calls this).
function LF.Memory.objective(obj, to, from)
    note("objective", { obj = obj.id, to = to, from = from, x = math.floor(obj.x), y = math.floor(obj.y),
                        seen = witnessesAt(obj.x, obj.y) })
end

-- ---- memories as words --------------------------------------------------------------------------

local function nowHours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and h or nil
end

local function ago(ev)
    local now = nowHours()
    if not (now and ev.hours) then return "" end
    local mins = math.floor((now - ev.hours) * 60 + 0.5)
    if mins < 2 then return "just now" end
    if mins < 60 then return "about " .. mins .. " minutes ago" end
    local hrs = math.floor(mins / 60 + 0.5)
    if hrs < 24 then return "about " .. hrs .. (hrs == 1 and " hour ago" or " hours ago") end
    local days = math.floor(hrs / 24 + 0.5)
    return days .. (days == 1 and " day ago" or " days ago")
end

-- Where it happened, in words: "at Objective Anton", or "in the open".
local function place(ev)
    local best, bd = nil, CFG.placeRange
    if LF.Objective and ev.x then
        for _, o in pairs(LF.Objective.all()) do
            local d = LF.dist(o.x, o.y, ev.x, ev.y)
            if d < bd then best, bd = o, d end
        end
    end
    if best then return (bd < 12 and "at " or "near ") .. best.name end
    return "in the open"
end
LF.Memory.place = place

local function unitWords(unitId, rec)
    if not unitId then return "a unit" end
    if unitId == rec.squad then return "your squad" end
    local u = LF.Units.get(unitId)
    if not u then return "a unit" end
    if u.faction ~= rec.faction then return (FACTION_PLURAL[u.faction] or "the enemy") .. "' " .. (u.name:gsub("^%u+ ", "")) end
    return u.name
end

local function manWords(id, rec)
    local r = LF.Records.get(id)
    if not r then return "a man" end
    local who = LF.Units.title(r)
    if r.faction ~= rec.faction then return "one of " .. (FACTION_PLURAL[r.faction] or "the enemy") .. " (" .. who .. ")" end
    if r.squad == rec.squad then return who .. " from your squad" end
    local u = r.squad and LF.Units.get(r.squad)
    return who .. (u and (" of " .. u.name) or "")
end

-- One event as a sentence from rec's point of view (nil for ones he wouldn't put into words).
local function sentence(ev, rec)
    local where, when = place(ev), ago(ev)
    local tail = " " .. where .. (when ~= "" and (", " .. when) or "") .. "."
    if ev.kind == "killed" then
        if ev.who == rec.id then return nil end
        return manWords(ev.who, rec) .. " was killed" .. tail
    elseif ev.kind == "wounded" then
        if ev.who == rec.id then return "You were wounded" .. tail end
        return manWords(ev.who, rec) .. " was wounded" .. tail
    elseif ev.kind == "diedOfWounds" then
        if ev.who == rec.id then return nil end
        return manWords(ev.who, rec) .. " died of his wounds" .. tail
    elseif ev.kind == "captured" then
        return manWords(ev.who, rec) .. " was taken prisoner" .. tail
    elseif ev.kind == "broke" then
        local u = LF.Units.get(ev.unit)
        if ev.unit == rec.squad then return "Your squad broke and fell back" .. tail end
        if u and u.faction ~= rec.faction then return unitWords(ev.unit, rec):gsub("^%l", string.upper) .. " broke and ran" .. tail end
        return (u and u.name or "A unit") .. " broke and fell back" .. tail
    elseif ev.kind == "contact" then
        local u = LF.Units.get(ev.unit)
        if not u or u.faction ~= rec.faction then return nil end
        return (ev.unit == rec.squad and "Your squad" or u.name) .. " ran into " .. unitWords(ev.by, rec) .. tail
    elseif ev.kind == "objective" then
        local o = LF.Objective and LF.Objective.get(ev.obj)
        local name = o and o.name or "an objective"
        if ev.to == rec.faction then return name .. " was taken by your side" .. tail end
        return name .. " fell to " .. (FACTION_PLURAL[ev.to] or "the enemy") .. tail
    end
    return nil
end

-- His last n memories (newest first), as sentences; and the events behind them.
function LF.Memory.of(rec, n)
    n = n or 6
    local out, evs = {}, {}
    local list = LF.Clash and LF.Clash.events() or {}
    for i = #list, 1, -1 do
        local ev = list[i]
        local saw = false
        for _, id in ipairs(ev.seen or {}) do if id == rec.id then saw = true; break end end
        if saw then
            local s = sentence(ev, rec)
            if s then out[#out + 1] = s; evs[#evs + 1] = ev end
            if #out >= n then break end
        end
    end
    return out, evs
end

-- What he is like now, in a few words (for talking to him).
function LF.Memory.profile(rec)
    local u = rec.squad and LF.Units.get(rec.squad)
    local p = u and u.platoon and LF.Units.get(u.platoon)
    local svc = rec.svc or {}
    local morale = LF.Morale and LF.Morale.get(rec) or 60
    local word = LF.Morale and LF.Morale.word and LF.Morale.word(morale) or tostring(math.floor(morale))
    return {
        id = rec.id, name = LF.Records.fullName(rec), title = LF.Units.title(rec), rank = rec.rank,
        faction = rec.faction, side = rec.faction == "GER" and "German" or (rec.faction == "SOV" and "Soviet" or "civilian"),
        unit = u and u.name or "", platoon = p and p.name or "",
        role = rec.hqRole or rec.mgRole or (LF.Units.leads(rec) and "leader") or "rifleman",
        morale = word, wounded = rec.wounded and true or false,
        wound = LF.Wounds and LF.Wounds.words(rec) or nil,
        kills = svc.kills or 0, lost = svc.lost or 0,
    }
end
