-- Living Front: the influence map (combat overhaul, 0.77).
--
-- An RTS commander's map of where the strength is. For each side, a grid of 10-tile cells, redrawn
-- once a simulated second:
--   strength  its own fit men, where its units are (it knows its own)
--   threat    the enemy's fit men where it believes they are - its sightings (LF_Front), so the fog
--             of war holds: a unit nobody has seen isn't on it, one seen an hour ago is where it
--             was then
-- Each unit is stamped on its cell (raw: the count, for "how many within r tiles") and spread to the
-- cells round it (influence: 1 on its cell, 0.5 a cell away, 0.25 two cells away - for "how strongly
-- is this ground held or threatened").
-- What the commanders read from it, instead of going through the units or the reports one by one:
--   LF.Influence.threatNear(side, x, y, r)    enemy fit men believed within r tiles
--   LF.Influence.strengthNear(side, x, y, r)  own fit men within r tiles
--   LF.Influence.threatAt / strengthAt        the influence on the cell at (x, y)
--   LF.Influence.safe(side, x, y)             no enemy influence on that cell
--   LF.Influence.front(side)                  the cells where its strength and the enemy's threat meet
-- Runtime only: it's redrawn from the units and the sightings.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/World/LF_Front"

LF.Influence = LF.Influence or {}

local CFG = {
    cell = 10,              -- tiles
    every = 1,              -- simulated seconds between redraws
    stale = 1800,           -- simulated seconds: a sighting older than this isn't on the map (LF_Captain's "no news")
    spread = { [0] = 1, [1] = 0.5, [2] = 0.25 },
}
LF.Influence.CFG = CFG

local SIDES = { "GER", "SOV" }
local ENEMY = { GER = "SOV", SOV = "GER" }

-- side -> { strength = { raw, inf }, threat = { raw, inf } }; raw/inf: key -> value
local maps = {}
local drawnAt = nil
local stats = { draws = 0, ms = 0 }
LF.Influence.stats = stats

local function key(cx, cy) return cx * 65536 + cy end
local function cellOf(x, y) return math.floor(x / CFG.cell), math.floor(y / CFG.cell) end

local function fresh()
    local m = {}
    for _, side in ipairs(SIDES) do
        m[side] = { strength = { raw = {}, inf = {} }, threat = { raw = {}, inf = {} } }
    end
    return m
end
maps = fresh()

local function stamp(layer, x, y, men)
    if men <= 0 then return end
    local cx, cy = cellOf(x, y)
    local k = key(cx, cy)
    layer.raw[k] = (layer.raw[k] or 0) + men
    for dx = -2, 2 do
        for dy = -2, 2 do
            local w = CFG.spread[math.max(math.abs(dx), math.abs(dy))]
            local kk = key(cx + dx, cy + dy)
            layer.inf[kk] = (layer.inf[kk] or 0) + men * w
        end
    end
end

-- Own units: where their men are, how many fit (bodies where they have them).
local function stampOwn(m)
    for _, u in pairs(LF.Units.all()) do
        if ((u.kind == "squad" and not u.joined) or u.kind == "hq") and m[u.faction] then
            local sx, sy, n, fit = 0, 0, 0, 0
            for _, rid in ipairs(LF.Units.members(u.id)) do
                local r = LF.Records.get(rid)
                if r and r.alive and not r.captured and not r.aid then
                    local b = LF.Bodies and LF.Bodies.get(rid)
                    local x, y = r.x, r.y
                    if b and not b:isDead() then x, y = b:getX(), b:getY() end
                    if x and y then
                        sx, sy, n = sx + x, sy + y, n + 1
                        if not r.wounded then fit = fit + 1 end
                    end
                end
            end
            if n > 0 then stamp(m[u.faction].strength, sx / n, sy / n, fit) end
        end
    end
end

-- The enemy as each side believes it: its sightings (LF_Front), not the truth.
local function stampThreat(m)
    for _, side in ipairs(SIDES) do
        for _, s in pairs(LF.Front.sightings(side)) do
            local age = LF.simTime - (s.at or 0)
            if age >= 0 and age <= CFG.stale and s.x then stamp(m[side].threat, s.x, s.y, s.men or 0) end
        end
    end
end

local function draw()
    local t0 = getTimestampMs()
    local m = fresh()
    stampOwn(m)
    stampThreat(m)
    maps = m
    stats.draws = stats.draws + 1
    stats.ms = stats.ms + (getTimestampMs() - t0)
end

LF.on("OnTick", "Influence", function()
    if not LF.due(60, 41) then return end
    if drawnAt and LF.simTime - drawnAt < CFG.every and drawnAt <= LF.simTime then return end
    drawnAt = LF.simTime
    LF.guard("influence", draw)
end)
Events.OnInitGlobalModData.Add(function() maps, drawnAt = fresh(), nil end)

-- ---- reading it ----------------------------------------------------------------------------------

-- Sum of a layer's raw counts over the cells whose middles are within r tiles of (x, y).
local function rawNear(layer, x, y, r)
    local cx0, cy0 = cellOf(x - r, y - r)
    local cx1, cy1 = cellOf(x + r, y + r)
    local rsq = (r + CFG.cell * 0.5) * (r + CFG.cell * 0.5)
    local half = CFG.cell * 0.5
    local n = 0
    for cx = cx0, cx1 do
        for cy = cy0, cy1 do
            local v = layer.raw[key(cx, cy)]
            if v and LF.distSq(cx * CFG.cell + half, cy * CFG.cell + half, x, y) <= rsq then n = n + v end
        end
    end
    return n
end

function LF.Influence.threatNear(side, x, y, r)
    local m = maps[side]
    return m and rawNear(m.threat, x, y, r) or 0
end
function LF.Influence.strengthNear(side, x, y, r)
    local m = maps[side]
    return m and rawNear(m.strength, x, y, r) or 0
end
function LF.Influence.threatAt(side, x, y)
    local m = maps[side]
    if not m then return 0 end
    local cx, cy = cellOf(x, y)
    return m.threat.inf[key(cx, cy)] or 0
end
function LF.Influence.strengthAt(side, x, y)
    local m = maps[side]
    if not m then return 0 end
    local cx, cy = cellOf(x, y)
    return m.strength.inf[key(cx, cy)] or 0
end
function LF.Influence.safe(side, x, y) return LF.Influence.threatAt(side, x, y) < 0.5 end

-- The cells where a side's strength and the threat it believes meet: { x, y (cell middle), strength, threat }.
function LF.Influence.front(side)
    local m = maps[side]
    local out = {}
    if not m then return out end
    local half = CFG.cell * 0.5
    for k, t in pairs(m.threat.inf) do
        local s = m.strength.inf[k]
        if s and s >= 1 and t >= 1 then
            local cx, cy = math.floor(k / 65536), k % 65536
            out[#out + 1] = { x = cx * CFG.cell + half, y = cy * CFG.cell + half, strength = s, threat = t }
        end
    end
    return out
end

-- (Debug) The map round (x, y) as text, one line per row of cells: own strength / believed threat.
function LF.Influence.dump(side, x, y, r)
    local cx0, cy0 = cellOf(x - r, y - r)
    local cx1, cy1 = cellOf(x + r, y + r)
    local m = maps[side]
    LF.log(string.format("INFLUENCE %s round %d,%d (%d-tile cells; each cell: strength/threat, '.' nothing, [..] where you are):",
        side, math.floor(x), math.floor(y), CFG.cell))
    local pcx, pcy = cellOf(x, y)
    for cy = cy0, cy1 do
        local row = {}
        for cx = cx0, cx1 do
            local s = m and m.strength.inf[key(cx, cy)] or 0
            local t = m and m.threat.inf[key(cx, cy)] or 0
            local txt = (s < 0.5 and t < 0.5) and "  .  " or string.format("%2d/%-2d", math.floor(s + 0.5), math.floor(t + 0.5))
            if cx == pcx and cy == pcy then txt = "[" .. txt:sub(2, 4) .. "]" end
            row[#row + 1] = txt
        end
        LF.log("INFLUENCE " .. table.concat(row, " "))
    end
    local f = LF.Influence.front(side)
    LF.log(string.format("INFLUENCE %s: %d front cells; redrawn %d times, %.2f ms each", side, #f, stats.draws,
        stats.draws > 0 and stats.ms / stats.draws or 0))
end
