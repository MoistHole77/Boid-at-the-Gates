-- Living Front: messages between commanders and their units (roadmap phase 5, step C1).
--
-- No messenger exists in the game: a message is just something that arrives later - as long as a
-- man running would take to cover the ground. Within earshot it is passed at once, by voice;
-- beyond, the delay is the distance at the moment it was sent over the running pace (measured in
-- play: LF.Move.RUN_PACE, else CFG.runPace). (Radio, for headquarters further up: a fixed delay
-- for the operator to get through - LF.Comms.radioDelay.) The same for both sides.
--
-- What a message says is fixed when it sets out: a report describes things as they were then, not
-- as they are when it lands. Messages in transit are saved with the game.
--
-- LF.Comms.post(kind, msg, delay)   - send; msg.platoon and msg.squad say whose it is
-- LF.Comms.on(kind, fn)             - fn(msg) when one arrives
-- LF.Comms.cancel(kind, platoonId [, squadId]) / LF.Comms.count(kind, platoonId [, squadId])

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"

LF.Comms = LF.Comms or {}

local CFG = {
    runPace = 3.0,          -- tiles a simulated second, until a run has been measured (LF_MoveAction)
    radioDelay = 45,        -- simulated seconds for a radio message to get through
    checkTicks = 15,
}
LF.Comms.CFG = CFG

local function store()
    local d = LF.Records.data()
    d.comms = d.comms or { seq = 0, list = {} }
    d.comms.list = d.comms.list or {}
    return d.comms
end

-- How fast a man runs (tiles per simulated second).
function LF.Comms.runPace()
    local m = LF.Move and LF.Move.RUN_PACE
    if type(m) == "number" and m > 0.5 then return m end
    return CFG.runPace
end

-- The delay for a message carried over d tiles (0 within earshot).
function LF.Comms.delayFor(d, earshot)
    if not d or d <= (earshot or 0) then return 0 end
    return d / LF.Comms.runPace()
end

function LF.Comms.radioDelay() return CFG.radioDelay end

local handlers = {}
function LF.Comms.on(kind, fn) handlers[kind] = fn end

-- Send msg (a table) of this kind; it arrives after delay simulated seconds (0: at once).
function LF.Comms.post(kind, msg, delay)
    msg.kind = kind
    delay = math.max(0, delay or 0)
    if delay <= 0 then
        local fn = handlers[kind]
        if fn then LF.guard("comms " .. kind, fn, msg) end
        return
    end
    local c = store()
    c.seq = (c.seq or 0) + 1
    msg.seq = c.seq
    msg.sentAt = LF.simTime
    msg.at = LF.simTime + delay
    c.list[#c.list + 1] = msg
end

local function match(m, kind, platoonId, squadId)
    return m.kind == kind and m.platoon == platoonId and (squadId == nil or m.squad == squadId)
end

-- Messages of a kind for a platoon (and squad) still on their way.
function LF.Comms.count(kind, platoonId, squadId)
    local n = 0
    for _, m in ipairs(store().list) do if match(m, kind, platoonId, squadId) then n = n + 1 end end
    return n
end

-- Call back messages not yet delivered (a new mission makes the old orders void).
function LF.Comms.cancel(kind, platoonId, squadId)
    local list = store().list
    for i = #list, 1, -1 do
        if match(list[i], kind, platoonId, squadId) then table.remove(list, i) end
    end
end

-- The soonest arrival of a kind for a platoon (and squad), or nil.
function LF.Comms.eta(kind, platoonId, squadId)
    local best = nil
    for _, m in ipairs(store().list) do
        if match(m, kind, platoonId, squadId) and (not best or m.at < best) then best = m.at end
    end
    return best
end

local function deliver()
    local list = store().list
    if #list == 0 then return end
    local due = {}
    for i = #list, 1, -1 do
        local m = list[i]
        -- (A time from before a reload that went backwards: deliver it now.)
        if m.at <= LF.simTime or (m.sentAt and m.sentAt > LF.simTime) then
            table.remove(list, i)
            due[#due + 1] = m
        end
    end
    table.sort(due, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
    for _, m in ipairs(due) do
        local fn = handlers[m.kind]
        if fn then LF.guard("comms " .. m.kind, fn, m) end
    end
end

Events.OnTick.Add(function()
    if LF.tick % CFG.checkTicks ~= 3 then return end
    LF.guard("comms", deliver)
end)
