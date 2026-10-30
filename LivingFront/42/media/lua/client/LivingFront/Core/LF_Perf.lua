-- Living Front: performance logging for stress tests.
--
-- Every LF.Config.perfWindowMs it logs one PERF line: frames per second, how many NPC bodies
-- exist, how many milliseconds per frame the mod's own work took (every module's per-frame
-- handlers, timed by LF.on in LF_Core, plus drawing the bodies) and how much is left for the
-- game itself. That tells apart "our Lua is slow" from "the game is slow with this many
-- characters".
--
-- Timing uses getTimestampMs (whole milliseconds). A single short call usually reads 0 or 1 ms,
-- but the rounding at the start and end of each call cancels out on average, so totals over a
-- window are accurate.

require "LivingFront/Core/LF_Core"

LF.Perf = LF.Perf or {}

local sections = {}        -- name -> ms this window
local frames = 0
local windowStart = nil

-- Add elapsed milliseconds to a section. Usage: local t0 = LF.Perf.start() ... LF.Perf.stop("brain", t0)
function LF.Perf.start()
    return getTimestampMs()
end

function LF.Perf.stop(name, t0)
    sections[name] = (sections[name] or 0) + (getTimestampMs() - t0)
end

-- One PERF line per window:
--   fps, bodies, frame (ms), mod (ms: ALL of the mod's per-frame work - every module's handlers,
--   timed by LF.on - plus drawing the bodies), rest (frame - mod: the game itself), then the
--   modules, costliest first. (Up to 0.69 "mod" was four sections - brain, draw, manager, spawn -
--   and 29 modules ran untimed.)
-- Old sections still timed inside a module (brain, manager, spawn) are logged as detail only.
local INNER = { brain = true, manager = true, spawn = true,
    -- (0.74.1: the brain's parts - its decision, its per-tick acting, its look, its cover search.
    -- Timed per call in whole milliseconds: over thousands of calls the average comes out right.)
    ["brain decide"] = true, ["brain act"] = true, ["brain look"] = true, ["brain cover"] = true,
    ["brain place"] = true, ["brain target"] = true, ["brain plancover"] = true, ["squad spot"] = true, ["draw render"] = true }

local last = nil            -- the last window's figures (LF.Perf.last(): the stress test reads them)
function LF.Perf.last() return last end

local function report(now)
    local secs = (now - windowStart) / 1000
    local fps = frames / secs
    local bodies, alive = 0, 0
    for _, body in pairs(LF.Bodies.all()) do
        bodies = bodies + 1
        if not body:isDead() then alive = alive + 1 end
    end
    local frameMs = frames > 0 and (now - windowStart) / frames or 0
    local per = function(ms) return frames > 0 and ms / frames or 0 end
    local mods = {}
    local ours = 0
    for label, ms in pairs(LF.perfMs) do
        mods[#mods + 1] = { label = label, ms = per(ms) }
        ours = ours + per(ms)
    end
    local draw = per(sections.draw or 0)
    if draw > 0 then mods[#mods + 1] = { label = "draw bodies", ms = draw }; ours = ours + draw end
    table.sort(mods, function(a, b) return a.ms > b.ms end)
    local parts = {}
    for i, m in ipairs(mods) do
        if i <= 12 and m.ms >= 0.01 then parts[#parts + 1] = m.label .. "=" .. string.format("%.2f", m.ms) end
    end
    local inner = {}
    for name in pairs(INNER) do
        if (sections[name] or 0) > 0 then inner[#inner + 1] = name .. "=" .. string.format("%.2f", per(sections[name])) end
    end
    table.sort(inner)
    local cell = getCell()
    local okC, cellObjects = pcall(function() return cell:getObjectList():size() end)
    if not okC then cellObjects = -1 end
    local rest = math.max(0, frameMs - ours)
    last = { fps = fps, bodies = alive, frame = frameMs, mod = ours, rest = rest, top = parts }
    LF.log("PERF fps=" .. string.format("%.1f", fps) .. " bodies=" .. alive .. " frame=" .. string.format("%.1f", frameMs)
        .. "ms mod=" .. string.format("%.2f", ours) .. "ms (" .. string.format("%.0f", frameMs > 0 and ours / frameMs * 100 or 0)
        .. "%) rest=" .. string.format("%.1f", rest) .. "ms | " .. table.concat(parts, " ")
        .. (#inner > 0 and (" | inside: " .. table.concat(inner, " ")) or "")
        .. " | worldObjects=" .. cellObjects .. " (ms per frame)")
    for k in pairs(LF.perfMs) do LF.perfMs[k] = 0 end
end

-- One frame = one render tick.
local function onRenderTick()
    if not LF.Config.logPerf then return end
    frames = frames + 1
    local now = getTimestampMs()
    if not windowStart then
        windowStart = now
        frames = 0
        for k in pairs(LF.perfMs) do LF.perfMs[k] = 0 end
        for k in pairs(sections) do sections[k] = 0 end
        return
    end
    if now - windowStart >= LF.Config.perfWindowMs then
        LF.guard("perf report", report, now)
        windowStart, frames = now, 0
        for k in pairs(sections) do sections[k] = 0 end
    end
end

function LF.Perf.toggle()
    LF.Config.logPerf = not LF.Config.logPerf
    windowStart = nil
    LF.log("PERF logging=" .. tostring(LF.Config.logPerf))
    LF.say("Performance log " .. (LF.Config.logPerf and "ON" or "OFF"))
end

LF.on("OnRenderTick", "Perf", onRenderTick)
