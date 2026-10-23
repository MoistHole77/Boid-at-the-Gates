-- Living Front: suppression.
--
-- Every shot that lands near a soldier adds suppression; it fades by itself.
--   suppressed (30+): fires 1.6x slower and 30% less accurately
--   pinned     (65+): stays crouched, fires 3x slower and 60% less accurately, won't move
-- Aimed shots suppress their target (more on a hit) and anyone hostile to the shooter right next
-- to it; area fire (shooting at where the enemy was last seen) suppresses everyone near that
-- point. Soldiers moving under orders (bounding, a flank, running to their cover) can't be
-- suppressed or pinned until they are in position: they don't pick up suppression on the way,
-- and any they had doesn't count until they arrive. Runtime only.

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
local immune = {}       -- record id -> true while moving under orders

local function idOf(body) return body:getModData().LF_id end

-- Earned traits (LF_Service): a veteran shakes suppression off faster and is pinned later; a
-- shaken man is pinned sooner.
local function recoverMul(id) return LF.Service and LF.Service.recoverMul(id) or 1 end
local function pinnedAt(id) return CFG.pinned + (LF.Service and LF.Service.pinShift(id) or 0) end

local function valueOf(id)
    local l = levels[id]
    if not l then return 0 end
    local v = l.v - (LF.tick - l.tick) * CFG.decayPerSecond * recoverMul(id) / 60
    if v <= 0 then levels[id] = nil; return 0 end
    return v
end

function LF.Suppress.value(body)
    local id = idOf(body)
    if not id or immune[id] then return 0 end
    return valueOf(id)
end

-- Moving under orders: no suppression picked up or felt until in position.
function LF.Suppress.setMoving(id, moving)
    immune[id] = moving or nil
end

function LF.Suppress.add(body, amount)
    local id = idOf(body)
    if not id or immune[id] then return end
    local was = valueOf(id)
    if LF.Service then amount = amount * LF.Service.suppressMul(id) end
    local v = math.min(CFG.max, was + amount)
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
function LF.Suppress.isSuppressed(body) return LF.Suppress.value(body) >= CFG.suppressed end

-- Multiplier on the time between this soldier's shots.
function LF.Suppress.cadence(body)
    local v = LF.Suppress.value(body)
    if LF.Suppress.isPinned(body) then return 3 end
    if v >= CFG.suppressed then return 1.6 end
    return 1
end

-- Multiplier on this soldier's hit chance.
function LF.Suppress.accuracy(body)
    local v = LF.Suppress.value(body)
    if LF.Suppress.isPinned(body) then return 0.4 end
    if v >= CFG.suppressed then return 0.7 end
    return 1
end

function LF.Suppress.forget(id) levels[id] = nil; immune[id] = nil end
function LF.Suppress.forgetAll() levels = {}; immune = {} end
