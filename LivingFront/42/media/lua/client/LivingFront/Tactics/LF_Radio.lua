-- Living Front: the radio net (roadmap phase 4).
--
-- Each platoon's radio operator reports what happens to it - contact, casualties, a squad
-- breaking, the enemy falling back, an objective taken or lost - wherever it is, on- or
-- off-screen. A squad on its own reports through its leader. Reports are gathered for a few
-- seconds and sent as one (at most one every CFG.minGap seconds per unit), so a firefight is a
-- handful of transmissions, not one per bullet.
-- You hear the net of the side(s) you choose (debug tools: German, Soviet, both or off): each
-- transmission appears at the top of the screen. With the LF bridge and Chasm running, the
-- radio operator words it himself (the language model, from the facts) and you hear it in his
-- voice over the radio; without, Living Front words it and it is text only.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/World/LF_Clash"
require "LivingFront/World/LF_Chasm"
require "LivingFront/Soldier/LF_Memory"

LF.Radio = LF.Radio or {}

local CFG = {
    updateTicks = 30,
    gather = 6,             -- simulated seconds of quiet before a report goes out ...
    gatherMax = 20,         -- ... or this long after its first item
    minGap = 30,            -- seconds between one unit's reports
    show = 12,              -- real seconds a transmission stays on screen
    shown = 4,              -- transmissions on screen at once
    contactEvery = 120,     -- a unit reports the same contact again only after this
}

local lastSeq = nil
local queue = {}            -- reporter unit id -> { items = {}, kills = {}, first, last }
local lastSent = {}         -- reporter unit id -> sim time
local lastContact = {}      -- reporter unit id -> sim time
local lines = {}            -- on screen: { text, speaker, faction, untilMs }
local waiting = {}          -- transmissions still to come on screen (the net is busy)
Events.OnInitGlobalModData.Add(function() lastSeq = nil; queue = {}; lastSent = {}; lastContact = {}; waiting = {} end)

local SIDES = { both = "both sides", GER = "the German net", SOV = "the Soviet net", off = "nothing" }
local ORDER = { "both", "GER", "SOV", "off" }

function LF.Radio.listening()
    local d = LF.Records.data()
    return d.radioListen or "both"
end
function LF.Radio.cycle()
    local cur = LF.Radio.listening()
    local i = 1
    for k, v in ipairs(ORDER) do if v == cur then i = k end end
    local nxt = ORDER[i % #ORDER + 1]
    LF.Records.data().radioListen = nxt
    return nxt, SIDES[nxt]
end
LF.Radio.SIDES = SIDES

-- Who reports for a unit: its platoon (through the radio operator), or the squad itself.
local function reporterOf(unitId)
    local u = unitId and LF.Units.get(unitId)
    if not u then return nil end
    if u.platoon then return LF.Units.get(u.platoon) end
    if u.kind == "hq" then return nil end
    return u
end

local function speakerOf(rep)
    if rep.kind == "platoon" then
        local hq = LF.Units.get(rep.hq)
        local best = nil
        for _, rid in ipairs(hq and LF.Units.members(hq.id) or {}) do
            local r = LF.Records.get(rid)
            if r and r.alive then
                if r.hqRole == "rto" then return r end
                best = best or r
            end
        end
        if best then return best end
        local cid = LF.Units.commander(rep)
        return cid and LF.Records.get(cid)
    end
    local cid = LF.Units.commander(rep)
    return cid and LF.Records.get(cid)
end

local function short(u) return u and (u.name:gsub("^.* / ", "")) or "a unit" end

local function q(rep)
    local e = queue[rep.id]
    if not e then
        e = { items = {}, losses = {}, first = LF.simTime }
        queue[rep.id] = e
    end
    e.last = LF.simTime
    return e
end

local function addItem(rep, text)
    local e = q(rep)
    for _, t in ipairs(e.items) do if t == text then return end end
    e.items[#e.items + 1] = text
end

local function addLoss(rep, unitId, kind)
    local e = q(rep)
    local u = LF.Units.get(unitId)
    local key = u and (u.kind == "hq" and "headquarters" or short(u)) or "?"
    e.losses[key] = e.losses[key] or { killed = 0, wounded = 0, captured = 0 }
    e.losses[key][kind] = e.losses[key][kind] + 1
end

local NUM = { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten" }
local function num(n) return NUM[n] or tostring(n) end

local function consume(ev)
    local where = LF.Memory.place(ev)
    if ev.kind == "killed" or ev.kind == "wounded" or ev.kind == "captured" then
        local rep = reporterOf(ev.unit)
        if rep then addLoss(rep, ev.unit, ev.kind) end
    elseif ev.kind == "broke" then
        local rep = reporterOf(ev.unit)
        local u = LF.Units.get(ev.unit)
        if rep and u then
            addItem(rep, (rep == u and "We have broken and are" or (short(u) .. " has broken and is")) .. " falling back " .. where)
        end
        local foe = reporterOf(ev.by)
        if foe then addItem(foe, "The enemy is falling back " .. where) end
    elseif ev.kind == "contact" then
        local rep = reporterOf(ev.unit)
        if rep and (not lastContact[rep.id] or LF.simTime - lastContact[rep.id] > CFG.contactEvery or lastContact[rep.id] > LF.simTime) then
            lastContact[rep.id] = LF.simTime
            addItem(rep, "Contact " .. where)
        end
    elseif ev.kind == "objective" then
        local o = LF.Objective and LF.Objective.get(ev.obj)
        local name = o and o.name or "the objective"
        for _, u in pairs(LF.Units.all()) do
            local t = u.objTask
            if t and t.obj == ev.obj and u.kind == "squad" then
                local rep = reporterOf(u.id)
                if rep then
                    if u.faction == ev.to then addItem(rep, "We have taken " .. name)
                    elseif u.faction == ev.from then addItem(rep, "We have lost " .. name) end
                end
            end
        end
    end
end

-- The facts of a report, in words: { "Contact near Objective Anton", "2 squad: one killed" ... }.
local function facts(e)
    local out = {}
    for _, t in ipairs(e.items) do out[#out + 1] = t end
    for who, l in pairs(e.losses) do
        local parts = {}
        if l.killed > 0 then parts[#parts + 1] = num(l.killed) .. " killed" end
        if l.wounded > 0 then parts[#parts + 1] = num(l.wounded) .. " wounded" end
        if l.captured > 0 then parts[#parts + 1] = num(l.captured) .. " taken prisoner" end
        if #parts > 0 then out[#out + 1] = (who:gsub("^%l", string.upper)) .. ": " .. table.concat(parts, ", ") end
    end
    return out
end

local function hears(faction)
    local l = LF.Radio.listening()
    return l == "both" or l == faction
end

-- A transmission to the screen: at once if there's room, else after the ones before it (up to
-- 0.69 a burst of orders pushed each other off the screen before they could be read).
local function put(line)
    if #lines < CFG.shown then
        line.untilMs = getTimestampMs() + CFG.show * 1000
        lines[#lines + 1] = line
    else
        waiting[#waiting + 1] = line
        while #waiting > 12 do table.remove(waiting, 1) end
    end
    return line
end

local function show(text, speakerTitle, rep)
    return put({ text = text, who = speakerTitle .. " (" .. rep.name .. ")", faction = rep.faction })
end

local function send(rep, e)
    local fs = facts(e)
    if #fs == 0 then return end
    lastSent[rep.id] = LF.simTime
    local sp = speakerOf(rep)
    local title = sp and LF.Units.title(sp) or "Radio"
    local text = rep.name .. ": " .. table.concat(fs, ". ") .. ". Over."
    LF.log("RADIO " .. title .. " (" .. rep.faction .. "): " .. text)
    if not hears(rep.faction) then return end
    local line = show(text, title, rep)
    -- With the bridge: the radio operator words it himself and it is voiced over the radio.
    if sp and LF.Chasm.alive() then
        LF.Chasm.request({ kind = "report", speaker = LF.Memory.profile(sp), unit = rep.name, facts = fs, fallback = text },
            function(ans)
                if ans and ans.text and ans.text ~= "" then
                    line.text = ans.text
                    line.untilMs = getTimestampMs() + CFG.show * 1000
                    LF.log("RADIO (worded by Chasm) " .. title .. ": " .. ans.text .. (ans.voiced == "yes" and " [voiced]" or ""))
                end
            end)
    end
end

-- A transmission from outside the event log (a captain's orders, the XO's supply runs): on screen
-- if you listen to that side's net, always in the log. speaker (a record): with the bridge, he
-- words it himself, as the radio operators word their reports.
function LF.Radio.broadcast(faction, whoTitle, unitName, text, speaker)
    LF.log("RADIO " .. whoTitle .. " (" .. faction .. "): " .. text)
    if not hears(faction) then return end
    local line = put({ text = text, who = whoTitle .. " (" .. unitName .. ")", faction = faction })
    if speaker and LF.Chasm.alive() then
        LF.Chasm.request({ kind = "order", speaker = LF.Memory.profile(speaker), unit = unitName, facts = { text }, fallback = text },
            function(ans)
                if ans and ans.text and ans.text ~= "" and ans.text ~= text then
                    line.text = ans.text
                    if line.untilMs then line.untilMs = math.max(line.untilMs, getTimestampMs() + CFG.show * 1000) end
                    LF.log("RADIO (worded by Chasm) " .. whoTitle .. ": " .. ans.text)
                end
            end)
    end
end

local function update()
    local data = LF.Records.data()
    local seq = data.lfEventSeq or 0
    if lastSeq == nil then lastSeq = seq end            -- (nothing from before this session)
    if seq > lastSeq then
        local evs = LF.Clash.events()
        for _, ev in ipairs(evs) do
            if ev.seq and ev.seq > lastSeq then LF.guard("radio event", consume, ev) end
        end
        lastSeq = seq
    end
    for rid, e in pairs(queue) do
        local rep = LF.Units.get(rid)
        if not rep then queue[rid] = nil
        else
            local quiet = LF.simTime - (e.last or 0) >= CFG.gather or LF.simTime - e.first >= CFG.gatherMax
            local gap = not lastSent[rid] or lastSent[rid] > LF.simTime or LF.simTime - lastSent[rid] >= CFG.minGap
            if quiet and gap then
                queue[rid] = nil
                send(rep, e)
            end
        end
    end
end

LF.on("OnTick", "Radio", function()
    if not LF.due(CFG.updateTicks, 13) then return end
    LF.guard("radio", update)
end)

-- ---- on screen ---------------------------------------------------------------------------------------

local COLORS = { GER = { 0.75, 0.82, 0.95 }, SOV = { 1.0, 0.62, 0.55 } }

local function draw()
    if #lines == 0 and #waiting == 0 then return end
    local now = getTimestampMs()
    local tm = getTextManager()
    local font = UIFont.Small
    local h = tm:getFontHeight(font)
    local cx = getCore():getScreenWidth() / 2
    local y = 60
    for i = #lines, 1, -1 do
        local l = lines[i]
        if now > l.untilMs then table.remove(lines, i) end
    end
    while #lines < CFG.shown and #waiting > 0 do
        local l = table.remove(waiting, 1)
        l.untilMs = now + CFG.show * 1000
        lines[#lines + 1] = l
    end
    for _, l in ipairs(lines) do
        local a = math.min(1, (l.untilMs - now) / 2000)
        local c = COLORS[l.faction] or { 1, 1, 1 }
        local head = "[Radio] " .. l.who .. ":"
        tm:DrawStringCentre(font, cx + 1, y + 1, head, 0, 0, 0, a * 0.8)
        tm:DrawStringCentre(font, cx, y, head, c[1], c[2], c[3], a)
        y = y + h
        for _, part in ipairs(LF.Tactics and LF.Tactics.wrap and LF.Tactics.wrap(l.text, 90) or { l.text }) do
            tm:DrawStringCentre(font, cx + 1, y + 1, part, 0, 0, 0, a * 0.8)
            tm:DrawStringCentre(font, cx, y, part, 1, 1, 1, a)
            y = y + h
        end
        y = y + 4
    end
end
LF.on("OnPostUIDraw", "Radio", function() LF.guard("radio draw", draw) end)
