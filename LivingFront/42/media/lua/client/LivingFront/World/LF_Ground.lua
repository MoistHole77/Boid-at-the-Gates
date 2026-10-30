-- Living Front: the ground - cover map and sight cache (combat overhaul, 0.71).
--
-- Two tables, filled once and read many times (Company of Heroes' cover on the ground, Killzone's
-- line-of-fire table), so the questions combat asks over and over become table reads:
--
-- COVER MAP: for every square, its cover against fire from each of 8 directions:
--   0 none · 1 light (fences, windows, cars, trees, low objects: protects a man down behind it)
--   2 heavy (walls, solid objects: hides him) · 3 garrison (inside a building, behind a wall or
--   window on that side)
-- judged by the same edge tests LF_Cover always used (LF.Cover.quality), toward a point 20 tiles
-- off in that direction. Squares around you are filled in the background, a few dozen a frame,
-- nearest first; any other square is worked out the first time it's asked for. An entry is
-- recomputed after CFG.maxAge simulated seconds (a door opened, a wall blown).
--
-- SIGHT CACHE: for a square, how far one can see out of it in each of the 8 directions (in
-- 5-tile steps, up to CFG.reachMax): the furthest point along that line the game's line test
-- (LosUtil, as LF.Sense) finds clear. "Can the enemy over there see this spot?" becomes "is he
-- closer than its reach that way?". Approximate - one line per direction - but consistent, and
-- worked out only for squares something asks about.
--
-- Directions: 0 E, 1 SE, 2 S, 3 SW, 4 W, 5 NW, 6 N, 7 NE (map x runs east, y south).

require "LivingFront/Core/LF_Core"
require "LivingFront/World/LF_Cover"

LF.Ground = LF.Ground or {}

local CFG = {
    maxAge = 300,           -- simulated seconds before an entry is worked out again
    buildRadius = 30,       -- tiles round you filled in the background
    perFrame = 12,          -- squares filled a pass at most (a pass every 3 frames; 0.71 did 40 every 2: 0.6 ms a frame)
    restSecs = 20,          -- (0.83) everything round you filled and fresh: the fill rests this long (simulated s)
    reachMax = 60,          -- tiles: sight is measured out to this
    reachStep = 5,
}
LF.Ground.CFG = CFG

local DX = { 1, 1, 0, -1, -1, -1, 0, 1 }
local DY = { 0, 1, 1, 1, 0, -1, -1, -1 }
LF.Ground.DX, LF.Ground.DY = DX, DY
LF.Ground.DIR_NAMES = { "east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east" }
local NONE, LIGHT, HEAVY, GARRISON = 0, 1, 2, 3
LF.Ground.NONE, LF.Ground.LIGHT, LF.Ground.HEAVY, LF.Ground.GARRISON = NONE, LIGHT, HEAVY, GARRISON

local cover = {}            -- key -> { v = packed 8 x 2 bits, at = simTime }
local sight = {}            -- key -> { v = packed 8 x 4 bits, at = simTime }
local nCover, nSight = 0, 0
Events.OnInitGlobalModData.Add(function() cover, sight, nCover, nSight = {}, {}, 0, 0 end)

local function key(x, y, z) return (x * 100000 + y) * 16 + z end

-- The direction (0-7) from (x, y) toward (tx, ty).
local T = 0.41421356        -- tan(22.5 degrees)
function LF.Ground.dir(x, y, tx, ty)
    local dx, dy = tx - x, ty - y
    local ax, ay = math.abs(dx), math.abs(dy)
    if ay <= ax * T then return dx >= 0 and 0 or 4 end
    if ax <= ay * T then return dy >= 0 and 2 or 6 end
    if dx >= 0 then return dy >= 0 and 1 or 7 end
    return dy >= 0 and 3 or 5
end

local function pow4(d) return 4 ^ d end
local function pow16(d) return 16 ^ d end

-- ---- cover ----------------------------------------------------------------------------------------

local function computeCover(x, y, z)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return nil end
    local inside = sq:getBuilding() ~= nil
    local v = 0
    for d = 0, 7 do
        local q = LF.Cover.quality(x, y, z, x + 0.5 + DX[d + 1] * 20, y + 0.5 + DY[d + 1] * 20)
        local c = NONE
        if q == LF.Cover.HIGH then c = inside and GARRISON or HEAVY
        elseif q == LF.Cover.LOW then c = inside and GARRISON or LIGHT
        elseif inside then c = GARRISON end         -- (0.73.5: in the middle of a room he still has the building's walls round him - up to 0.73.4 he counted as in the open)
        v = v + c * pow4(d)
    end
    return v
end

local function coverEntry(x, y, z)
    local k = key(x, y, z)
    local e = cover[k]
    if e and LF.simTime - e.at <= CFG.maxAge and e.at <= LF.simTime then return e end
    local v = computeCover(x, y, z)
    if not v then return nil end
    if not e then nCover = nCover + 1; e = {} ; cover[k] = e end
    e.v, e.at = v, LF.simTime
    return e
end

-- Cover of square (x, y, z) against fire from direction d (0-7): 0 none - 3 garrison.
function LF.Ground.coverDir(x, y, z, d)
    local e = coverEntry(math.floor(x), math.floor(y), math.floor(z))
    if not e then return NONE end
    return math.floor(e.v / pow4(d)) % 4
end

-- Cover of square (x, y, z) against a shooter at (sx, sy).
function LF.Ground.cover(x, y, z, sx, sy)
    x, y = math.floor(x), math.floor(y)
    return LF.Ground.coverDir(x, y, z, LF.Ground.dir(x + 0.5, y + 0.5, sx, sy))
end

-- (0.81) The cover of a square against a shooter at (sx, sy) if the map already has it fresh, else
-- nil - for the squad's placement, which then runs the live test instead of filling 8 directions.
function LF.Ground.peekCover(x, y, z, sx, sy)
    x, y = math.floor(x), math.floor(y)
    local e = cover[key(x, y, z)]
    if not e or LF.simTime - e.at > CFG.maxAge or e.at > LF.simTime then return nil end
    return math.floor(e.v / pow4(LF.Ground.dir(x + 0.5, y + 0.5, sx, sy))) % 4
end

-- (0.82.1) Has the square cover against fire from any direction - light anywhere, or heavy? From the
-- map if it has the square fresh: hasLight, hasHeavy; nil if not known.
function LF.Ground.peekAny(x, y, z)
    local e = cover[key(math.floor(x), math.floor(y), z)]
    if not e or LF.simTime - e.at > CFG.maxAge or e.at > LF.simTime then return nil end
    local light, heavy = false, false
    for d = 0, 7 do
        local c = math.floor(e.v / pow4(d)) % 4
        if c == LIGHT then light = true elseif c == HEAVY then heavy = true end
    end
    return light, heavy
end

-- (0.81) Forget what the map knows round (x, y, z) - cover placed or taken away (the arena tools).
function LF.Ground.forget(x, y, z, r)
    for dx = -r, r do
        for dy = -r, r do
            local k = key(math.floor(x) + dx, math.floor(y) + dy, z)
            if cover[k] then cover[k] = nil; nCover = nCover - 1 end
            if sight[k] then sight[k] = nil; nSight = nSight - 1 end
        end
    end
    if LF.Ground.overlay then LF.Ground.overlay.dirty = true end
end

-- ---- sight ----------------------------------------------------------------------------------------

local function clear(x, y, z, tx, ty)
    local ok, res = pcall(function()
        return tostring(LosUtil.lineClear(getCell(), x, y, z, tx, ty, z, false))
    end)
    if not ok then return true end
    return res ~= "Blocked" and res ~= "ClearThroughClosedDoor"
end

local function loaded(x, y, z) return getCell():getGridSquare(x, y, z) ~= nil end

-- How far along direction d one sees out of (x, y, z): the furthest step clear (binary search -
-- a line blocked at some distance is blocked beyond it).
local function reachOf(x, y, z, d)
    local steps = CFG.reachMax / CFG.reachStep
    local lo, hi = 0, steps
    -- (Only as far as the ground is loaded: beyond it the game can't say.)
    while hi > 0 and not loaded(x + DX[d + 1] * hi * CFG.reachStep, y + DY[d + 1] * hi * CFG.reachStep, z) do hi = hi - 1 end
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local s = mid * CFG.reachStep
        if clear(x, y, z, x + DX[d + 1] * s, y + DY[d + 1] * s) then lo = mid else hi = mid - 1 end
    end
    return lo
end

local function sightEntry(x, y, z)
    local k = key(x, y, z)
    local e = sight[k]
    if e and LF.simTime - e.at <= CFG.maxAge and e.at <= LF.simTime then return e end
    if not loaded(x, y, z) then return nil end
    local v = 0
    for d = 0, 7 do v = v + reachOf(x, y, z, d) * pow16(d) end
    if not e then nSight = nSight + 1; e = {}; sight[k] = e end
    e.v, e.at = v, LF.simTime
    return e
end

-- How far (tiles) one sees out of square (x, y, z) in direction d. nil if the ground isn't loaded.
function LF.Ground.reach(x, y, z, d)
    local e = sightEntry(math.floor(x), math.floor(y), math.floor(z))
    if not e then return nil end
    return (math.floor(e.v / pow16(d)) % 16) * CFG.reachStep
end

-- Is the cached reach of this square already worked out (the overlay doesn't force it)?
function LF.Ground.hasSight(x, y, z)
    local e = sight[key(math.floor(x), math.floor(y), math.floor(z))]
    return e ~= nil and LF.simTime - e.at <= CFG.maxAge
end

-- (0.81) seenFrom if the sight cache already has that square fresh, else nil.
function LF.Ground.peekSeen(x, y, z, ex, ey)
    if not LF.Ground.hasSight(x, y, z) then return nil end
    return LF.Ground.seenFrom(x, y, z, ex, ey)
end

-- Could someone at (ex, ey) see (and fire at) square (x, y, z)? From the sight cache.
function LF.Ground.seenFrom(x, y, z, ex, ey)
    x, y = math.floor(x), math.floor(y)
    local r = LF.Ground.reach(x, y, z, LF.Ground.dir(x + 0.5, y + 0.5, ex, ey))
    if not r then return true end
    return LF.dist(x + 0.5, y + 0.5, ex, ey) <= r + CFG.reachStep / 2
end

-- ---- filling the cover map round you, a little each frame ------------------------------------------

local ring = { r = 0, i = 0, cx = nil, cy = nil, z = 0 }

local function fill()
    local p = getPlayer()
    if not p then return end
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    -- (Moved far: start again round where you are now.)
    if not ring.cx or LF.dist(px, py, ring.cx, ring.cy) > 10 or pz ~= ring.z then
        ring.cx, ring.cy, ring.z, ring.r, ring.i = px, py, pz, 0, 0
        ring.restUntil, ring.work = nil, 0
    end
    -- (0.83) A whole round with nothing to fill: rest. Up to 0.82 it walked 400 squares every 3
    -- frames for good, finding nothing (0.38 ms a frame).
    if ring.restUntil and LF.simTime < ring.restUntil and ring.restUntil - LF.simTime <= CFG.restSecs then return end
    ring.restUntil = nil
    local t0 = getTimestampMs()
    local done, looked = 0, 0
    -- (A bounded walk: once everything round you is filled, it moves on 400 squares a pass,
    -- refreshing what has gone stale, rather than running the whole area every frame.)
    while done < CFG.perFrame and looked < 400 and ring.r <= CFG.buildRadius do
        looked = looked + 1
        local r = ring.r
        local side = math.max(1, r * 8)                 -- squares on ring r
        if ring.i >= side then
            ring.r, ring.i = r + 1, 0
        else
            local i = ring.i
            ring.i = i + 1
            local x, y
            if r == 0 then x, y = 0, 0
            else
                local s = math.floor(i / (2 * r))       -- which side of the ring
                local o = i % (2 * r) - r
                if s == 0 then x, y = o, -r elseif s == 1 then x, y = r, o
                elseif s == 2 then x, y = -o, r else x, y = -r, -o end
            end
            local k = key(ring.cx + x, ring.cy + y, ring.z)
            local e = cover[k]
            if not e or LF.simTime - e.at > CFG.maxAge then
                coverEntry(ring.cx + x, ring.cy + y, ring.z)
                done = done + 1
                ring.work = (ring.work or 0) + 1
                if getTimestampMs() - t0 >= 1 then return end
            end
        end
    end
    -- (All round you filled: start over, so stale entries are refreshed in their turn.)
    if ring.r > CFG.buildRadius then
        ring.r, ring.i = 0, 0
        if (ring.work or 0) == 0 then ring.restUntil = LF.simTime + CFG.restSecs end
        ring.work = 0
    end
end

LF.onTick("Ground", function()
    if LF.frame % 3 ~= 0 then return end
    LF.guard("ground fill", fill)
end)

function LF.Ground.size() return nCover, nSight end

-- ---- the overlay (debug tools) ------------------------------------------------------------------
-- Letters on the ground round you: cover against fire from the chosen direction (L light, H heavy,
-- G garrison; nothing for none), or how far one sees that way from each square (in tiles).

local OV = { mode = "off", dir = 0 }
LF.Ground.overlay = OV
local MODES = { "off", "cover", "sight" }
function LF.Ground.cycleMode()
    local i = 1
    for k, v in ipairs(MODES) do if v == OV.mode then i = k end end
    OV.mode = MODES[i % #MODES + 1]
    OV.dirty = true
    return OV.mode
end
function LF.Ground.cycleDir()
    OV.dir = (OV.dir + 1) % 8
    OV.dirty = true
    return OV.dir
end

local LETTER = { [LIGHT] = "L", [HEAVY] = "H", [GARRISON] = "G" }
local COLOR = { [LIGHT] = { 1, 0.85, 0.2 }, [HEAVY] = { 0.3, 1, 0.3 }, [GARRISON] = { 0.4, 0.7, 1 } }
local sightBudget = 0

-- (0.71 looked every square up and placed it on screen the careful way each frame: 6-10 ms. Now
-- what to show is worked out four times a second, and each frame only places the letters.)
local shown = {}            -- { x, y, text, r, g, b }
local shownN, shownAt = 0, -1000

local function collect(px, py, pz)
    shownN = 0
    local R = OV.mode == "sight" and 8 or 10
    sightBudget = 12                     -- squares whose sight is worked out per refresh (it's costly)
    for dx = -R, R do
        for dy = -R, R do
            local x, y = px + dx, py + dy
            local text, r, g, b = nil, 1, 1, 1
            if OV.mode == "cover" then
                local c = LF.Ground.coverDir(x, y, pz, OV.dir)
                if c > NONE then text = LETTER[c]; r, g, b = COLOR[c][1], COLOR[c][2], COLOR[c][3] end
            elseif LF.Ground.hasSight(x, y, pz) or sightBudget > 0 then
                if not LF.Ground.hasSight(x, y, pz) then sightBudget = sightBudget - 1 end
                local reach = LF.Ground.reach(x, y, pz, OV.dir)
                if reach then
                    local f = reach / CFG.reachMax
                    text, r, g, b = tostring(reach), 1 - f, 0.4 + f * 0.6, 0.3
                end
            end
            if text then
                shownN = shownN + 1
                local e = shown[shownN]
                if not e then e = {}; shown[shownN] = e end
                e.x, e.y, e.text, e.r, e.g, e.b = x + 0.5, y + 0.5, text, r, g, b
            end
        end
    end
end

local function draw()
    if OV.mode == "off" then return end
    local p = getPlayer()
    if not p then return end
    local pz = math.floor(p:getZ())
    if OV.dirty or LF.frame - shownAt >= 15 or LF.frame < shownAt then
        shownAt, OV.dirty = LF.frame, nil
        collect(math.floor(p:getX()), math.floor(p:getY()), pz)
    end
    local tm = getTextManager()
    local font = UIFont.Small
    for i = 1, shownN do
        local e = shown[i]
        local sx, sy = isoToScreenX(0, e.x, e.y, pz), isoToScreenY(0, e.x, e.y, pz)
        tm:DrawStringCentre(font, sx + 1, sy + 1, e.text, 0, 0, 0, 0.8)
        tm:DrawStringCentre(font, sx, sy, e.text, e.r, e.g, e.b, 1)
    end
    local title = OV.mode == "cover"
        and ("Cover against fire from the " .. LF.Ground.DIR_NAMES[OV.dir + 1] .. ": L light, H heavy, G garrison")
        or ("How far you can see to the " .. LF.Ground.DIR_NAMES[OV.dir + 1] .. " from each square (tiles)")
    local w = getCore():getScreenWidth()
    tm:DrawStringCentre(UIFont.Medium, w / 2 + 1, 101, title, 0, 0, 0, 0.8)
    tm:DrawStringCentre(UIFont.Medium, w / 2, 100, title, 1, 1, 1, 1)
end

LF.on("OnPostUIDraw", "Ground overlay", function() LF.guard("ground overlay", draw) end)
