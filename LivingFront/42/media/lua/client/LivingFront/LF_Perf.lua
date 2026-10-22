-- Living Front: performance logging for stress tests.
--
-- Every LF.Config.perfWindowMs it logs one PERF line: frames per second, how many NPC bodies
-- exist, and how many milliseconds per frame the mod's own work took, split by section
-- (brain, drawing bodies, body manager). That tells apart "our Lua is slow" from "the game is
-- slow drawing this many characters".
--
-- Timing uses getTimestampMs (whole milliseconds). A single short call usually reads 0 or 1 ms,
-- but the rounding at the start and end of each call cancels out on average, so totals over a
-- window are accurate.

require "LivingFront/LF_Core"

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

local ORDER = { "brain", "draw", "manager", "spawn" }

local function report(now)
    local secs = (now - windowStart) / 1000
    local fps = frames / secs
    local bodies, alive = 0, 0
    for _, body in pairs(LF.Bodies.all()) do
        bodies = bodies + 1
        if not body:isDead() then alive = alive + 1 end
    end
    local frameMs = frames > 0 and (now - windowStart) / frames or 0
    local ours = 0
    local parts = {}
    for _, name in ipairs(ORDER) do
        local perFrame = frames > 0 and (sections[name] or 0) / frames or 0
        ours = ours + perFrame
        parts[#parts + 1] = name .. "=" .. string.format("%.2f", perFrame)
    end
    local bleeding = LF.Aid and LF.Aid.countBleeding(LF.Bodies.all()) or -1
    local cellObjects = LF.guard("object count", function() return getCell():getObjectList():size() end) or -1
    LF.log("PERF fps=" .. string.format("%.1f", fps) .. " bodies=" .. bodies .. " alive=" .. alive
        .. " bleeding=" .. bleeding .. " worldObjects=" .. cellObjects .. " shots=" .. (LF.Combat and LF.Combat.shotCount or 0)
        .. " frame=" .. string.format("%.1f", frameMs) .. "ms mod=" .. string.format("%.2f", ours) .. "ms ("
        .. string.format("%.0f", frameMs > 0 and ours / frameMs * 100 or 0) .. "% of frame) "
        .. table.concat(parts, " ") .. " (ms per frame)")
end

-- One frame = one render tick.
local function onRenderTick()
    if not LF.Config.logPerf then return end
    frames = frames + 1
    local now = getTimestampMs()
    if not windowStart then
        windowStart = now
        frames = 0
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

Events.OnRenderTick.Add(onRenderTick)
