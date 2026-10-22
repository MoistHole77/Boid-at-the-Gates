-- Living Front: suppression.
--
-- Every shot that lands near a soldier adds suppression; it fades by itself.
--   suppressed (30+): fires 1.6x slower and 30% less accurately
--   pinned     (65+): stays crouched, fires 3x slower and 60% less accurately, won't move
-- Aimed shots suppress their target (more on a hit) and anyone hostile to the shooter right next
-- to it; area fire (shooting at where the enemy was last seen) suppresses everyone near that
-- point. Runtime only.

require "LivingFront/LF_Core"

LF.Suppress = LF.Suppress or {}

local CFG = {
    decayPerSecond = 10,
    max = 100,
    suppressed = 30,
    pinned = 65,
}
LF.Suppress.CFG = CFG

local levels = {}       -- record id -> { v, tick }

local function idOf(body) return body:getModData().LF_id end

local function valueOf(id)
    local l = levels[id]
    if not l then return 0 end
    local v = l.v - (LF.tick - l.tick) * CFG.decayPerSecond / 60
    if v <= 0 then levels[id] = nil; return 0 end
    return v
end

function LF.Suppress.value(body)
    local id = idOf(body)
    return id and valueOf(id) or 0
end

function LF.Suppress.add(body, amount)
    local id = idOf(body)
    if not id then return end
    local was = valueOf(id)
    local v = math.min(CFG.max, was + amount)
    local l = levels[id]
    if not l then l = {}; levels[id] = l end
    l.v, l.tick = v, LF.tick
    if was < CFG.pinned and v >= CFG.pinned then
        LF.log("PINNED #" .. id .. " suppression " .. math.floor(v))
    end
end

function LF.Suppress.isPinned(body) return LF.Suppress.value(body) >= CFG.pinned end
function LF.Suppress.isSuppressed(body) return LF.Suppress.value(body) >= CFG.suppressed end

-- Multiplier on the time between this soldier's shots.
function LF.Suppress.cadence(body)
    local v = LF.Suppress.value(body)
    if v >= CFG.pinned then return 3 end
    if v >= CFG.suppressed then return 1.6 end
    return 1
end

-- Multiplier on this soldier's hit chance.
function LF.Suppress.accuracy(body)
    local v = LF.Suppress.value(body)
    if v >= CFG.pinned then return 0.4 end
    if v >= CFG.suppressed then return 0.7 end
    return 1
end

function LF.Suppress.forget(id) levels[id] = nil end
function LF.Suppress.forgetAll() levels = {} end
