-- Living Front: talking to Chasm through the LF bridge (roadmap phase 4).
--
-- The game's Lua can't make web calls or play sound files, so a small helper program, the LF
-- bridge (tools/lf_bridge), sits between the game and Chasm. They talk through files in
-- Zomboid\Lua\LivingFront\chasm\ (the only folder the game's Lua may write):
--   bridge.txt    - the bridge rewrites it every second (alive=<n>, llm=..., tts=...); the mod
--                   counts the bridge as there while it keeps changing
--   out/req_N.json - a request from the mod (a man to talk to, a radio report to word and voice)
--   in/res_N.txt   - the bridge's answer, key=value lines (status, text, voiced); the mod reads it
--                   and overwrites it with done=1 (Lua can't delete files; the bridge clears them)
--   state.json    - the mod rewrites it twice a second: where you are, whether the game is
--                   paused, and where the men who are speaking stand (the bridge sets each
--                   voice's volume and left/right balance from it)
-- Everything here is optional: with no bridge running, the mod words reports and replies itself
-- and shows them as text.

require "LivingFront/Core/LF_Core"

LF.Chasm = LF.Chasm or {}

local DIR = "LivingFront/chasm/"
local CFG = {
    aliveFor = 300,         -- ticks: the bridge counts as there this long after bridge.txt last changed
    pollTicks = 30,
    stateTicks = 30,
    timeout = 3600,         -- ticks: an answer that hasn't come by then is given up on
}

local status = { alive = false, lastText = nil, changedAt = -100000, llm = "?", tts = "?" }
local pending = {}          -- request id -> { cb, at, speaker }
local speakers = {}         -- record id -> tick until which his position goes into state.json

-- ---- JSON (out) ----------------------------------------------------------------------------------

local function esc(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return s
end

local function encode(v)
    local t = type(v)
    if t == "string" then return '"' .. esc(v) .. '"' end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.3f", v)
    end
    if t == "boolean" then return v and "true" or "false" end
    if t ~= "table" then return "null" end
    local n = #v
    if n > 0 then
        local parts = {}
        for i = 1, n do parts[i] = encode(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do parts[#parts + 1] = '"' .. esc(tostring(k)) .. '":' .. encode(val) end
    if #parts == 0 then return "{}" end
    return "{" .. table.concat(parts, ",") .. "}"
end
LF.Chasm.encode = encode

-- ---- files -----------------------------------------------------------------------------------------

local function writeFile(path, text)
    return LF.try("chasm write", function()
        local w = getFileWriter(path, true, false)
        if not w then return false end
        w:write(text)
        w:close()
        return true
    end)
end

local function readFile(path)
    return LF.try("chasm read", function()
        local r = getFileReader(path, false)
        if not r then return nil end
        local lines = {}
        local line = r:readLine()
        while line do
            lines[#lines + 1] = line
            line = r:readLine()
        end
        r:close()
        return lines
    end)
end

local function unescape(s)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n" end
        if c == "t" then return "\t" end
        return c
    end))
end

local function parse(lines)
    local out = {}
    for _, line in ipairs(lines or {}) do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then out[k] = unescape(v) end
    end
    return out
end

-- ---- the bridge --------------------------------------------------------------------------------

function LF.Chasm.alive() return status.alive end
function LF.Chasm.status() return status end

local function checkBridge()
    local lines = readFile(DIR .. "bridge.txt")
    local text = lines and table.concat(lines, "\n") or nil
    if text and text ~= status.lastText then
        if not status.alive then LF.log("CHASM the LF bridge is running - " .. text:gsub("\n", ", ")) end
        status.lastText, status.changedAt = text, LF.tick
        local kv = parse(lines)
        status.llm, status.tts = kv.llm or "?", kv.tts or "?"
    end
    local alive = text ~= nil and LF.tick - status.changedAt < CFG.aliveFor
    if status.alive and not alive then LF.log("CHASM the LF bridge has stopped - words and voices from Living Front itself") end
    status.alive = alive
end

local function nextId()
    local data = LF.Records.data()
    data.chasmSeq = (data.chasmSeq or 0) + 1
    return data.chasmSeq
end

-- Send a request (a table; kind = "talk" / "report" / ...). cb(answer) is called with the
-- parsed answer (status, text, voiced, ...) - or with nil if no answer comes. Returns false
-- (and doesn't send) when the bridge isn't running.
function LF.Chasm.request(req, cb, speakerId)
    if not status.alive then return false end
    local id = nextId()
    req.id = id
    if not writeFile(DIR .. "out/req_" .. id .. ".json", encode(req)) then return false end
    pending[id] = { cb = cb, at = LF.tick, speaker = speakerId }
    if speakerId then speakers[speakerId] = LF.tick + 3600 end
    return true
end

local function pollAnswers()
    for id, p in pairs(pending) do
        local lines = readFile(DIR .. "in/res_" .. id .. ".txt")
        local kv = lines and parse(lines)
        if kv and kv.status then
            pending[id] = nil
            writeFile(DIR .. "in/res_" .. id .. ".txt", "done=1\n")
            if p.speaker and kv.voiced == "yes" then speakers[p.speaker] = LF.tick + 1800 end
            if p.cb then LF.guard("chasm answer", p.cb, kv) end
        elseif LF.tick - p.at > CFG.timeout then
            pending[id] = nil
            if p.cb then LF.guard("chasm answer", p.cb, nil) end
        end
    end
end

-- Where you are and who is speaking, for the bridge's voices.
local function writeState()
    local p = getPlayer()
    if not p then return end
    local spk = {}
    for id, untilTick in pairs(speakers) do
        if untilTick < LF.tick then speakers[id] = nil
        else
            local b = LF.Bodies and LF.Bodies.get(id)
            local r = LF.Records.get(id)
            local x, y = r and r.x, r and r.y
            if b and not b:isDead() then x, y = b:getX(), b:getY() end
            if x then spk[tostring(id)] = { x = x, y = y } end
        end
    end
    local paused = false
    pcall(function() paused = isGamePaused() or getGameSpeed() == 0 end)
    local state = {
        listener = { x = p:getX(), y = p:getY(), z = p:getZ() },
        paused = paused,
        speakers = spk,
    }
    writeFile(DIR .. "state.json", encode(state))
end

Events.OnTick.Add(function()
    if LF.tick % CFG.pollTicks == 5 then
        LF.guard("chasm bridge", checkBridge)
        if status.alive or next(pending) then LF.guard("chasm answers", pollAnswers) end
    end
    if status.alive and LF.tick % CFG.stateTicks == 20 then LF.guard("chasm state", writeState) end
end)
Events.OnInitGlobalModData.Add(function() pending = {}; speakers = {} end)
