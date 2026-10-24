-- Living Front: cover.
--
-- Cover is judged per square, against a threat direction, by looking at the square's edges and
-- neighbours on the threat side:
--   LOW  - protects a crouched body but can be fired over standing: hoppable fences, windows,
--          vehicles, trees, and solid-but-see-through objects (counters, crates, low walls)
--   HIGH - hides the body completely and can't be fired over: walls, solid objects, other
--          blocking edges
--   NONE - nothing between the square and the threat
--
-- Soldiers use LOW cover as firing positions (crouch behind it, pop up to shoot, drop back down)
-- and HIGH cover (or anywhere out of sight) as hiding spots when wounded.
-- Incoming fire is resolved against the target's cover from the shooter's direction
-- (LF.Combat.targetModifier / LF.Combat.hitParts, defined here).

require "LivingFront/Core/LF_Core"
require "LivingFront/Soldier/LF_Combat"

LF.Cover = LF.Cover or {}

local NONE, LOW, HIGH = 0, 1, 2
LF.Cover.NONE, LF.Cover.LOW, LF.Cover.HIGH = NONE, LOW, HIGH
local NAMES = { [NONE] = "none", [LOW] = "low", [HIGH] = "high" }
function LF.Cover.name(q) return NAMES[q] or "?" end

local CFG = {
    searchRadius = 7,       -- tiles around the soldier to look for a position
    reserveTicks = 900,     -- a claimed position stays reserved this long (about 15 s)
}

local reserved = {}         -- "x,y,z" -> { id, until }

local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- What one edge (from sq into its neighbour nb) offers as cover.
local function edgeCover(sq, nb)
    if not nb then return NONE end
    if sq:isWallTo(nb) then
        -- A wall with a window in it is something you can shoot through.
        if sq:isWindowTo(nb) then return LOW end
        return HIGH
    end
    if sq:isWindowTo(nb) or sq:isHoppableTo(nb) then return LOW end
    if nb:getVehicleContainer() ~= nil or nb:HasTree() then return LOW end
    if nb:isSolidTrans() then return LOW end
    if nb:isSolid() then return HIGH end
    if sq:isSomethingTo(nb) then return LOW end
    return NONE
end

-- Cover quality of the square at (x, y, z) against a threat at (tx, ty).
-- Judged along the actual line to him: the side of the square the line leaves through must be
-- covered (a wall, a fence, a car, a tree...). Leaving through a corner, the corner square must
-- block, or both sides of it. (Up to 0.39 the best of the neighbours on his side counted - so a
-- man at the end of a car, the car beside him but the enemy off at an angle past its bumper,
-- thought he was in cover standing in the open.)
local function blocks(nb)
    return nb and (nb:getVehicleContainer() ~= nil or nb:HasTree() or nb:isSolidTrans() or nb:isSolid())
end
function LF.Cover.quality(x, y, z, tx, ty)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, z)
    if not sq then return NONE end
    local dx, dy = tx - (x + 0.5), ty - (y + 0.5)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.75 then return NONE end
    local ux, uy = dx / len, dy / len
    local ox, oy = math.floor(x + 0.5 + ux * 0.75) - x, math.floor(y + 0.5 + uy * 0.75) - y
    if ox == 0 and oy == 0 then
        ox, oy = math.floor(x + 0.5 + ux * 1.0) - x, math.floor(y + 0.5 + uy * 1.0) - y
    end
    if ox == 0 and oy == 0 then return NONE end
    if ox ~= 0 and oy ~= 0 then
        local a = edgeCover(sq, cell:getGridSquare(x + ox, y, z))
        local b = edgeCover(sq, cell:getGridSquare(x, y + oy, z))
        local best = math.min(a, b)
        if best < LOW and blocks(cell:getGridSquare(x + ox, y + oy, z)) then best = LOW end
        return best
    end
    return edgeCover(sq, cell:getGridSquare(x + ox, y + oy, z))
end

-- Cover of a character's current square against another character.
function LF.Cover.of(body, threat)
    return LF.Cover.quality(math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ()),
        threat:getX(), threat:getY())
end

-- Line of sight between two squares (game line test; closed doors and walls block).
local function lineResult(x0, y0, z0, x1, y1, z1)
    return tostring(LosUtil.lineClear(getCell(), x0, y0, z0, x1, y1, z1, false))
end

function LF.Cover.canSeeFrom(x, y, z, target)
    local ok, res = pcall(lineResult, x, y, z,
        math.floor(target:getX()), math.floor(target:getY()), math.floor(target:getZ()))
    if not ok then return true end
    return res ~= "Blocked" and res ~= "ClearThroughClosedDoor"
end

local function isTaken(x, y, z, id)
    local r = reserved[key(x, y, z)]
    if r and r.id ~= id and r.untilTick > LF.tick then return true end
    return false
end

function LF.Cover.reserve(x, y, z, id)
    reserved[key(x, y, z)] = { id = id, untilTick = LF.tick + CFG.reserveTicks }
end

function LF.Cover.release(id)
    for k, r in pairs(reserved) do
        if r.id == id or r.untilTick <= LF.tick then reserved[k] = nil end
    end
end

-- Is the square free to stand in (walkable, nobody else on it)?
local function standable(sq, body)
    if not sq:isFree(false) then return false end
    local movers = sq:getMovingObjects()
    for i = 0, movers:size() - 1 do
        if movers:get(i) ~= body then return false end
    end
    return true
end

-- How many walls, fences, hedges or windows a straight walk from (x1, y1) to (x2, y2) crosses
-- (stepping square by square). A man who has to vault or climb to get somewhere isn't moving
-- tactically, so the searches prefer spots with nothing in the way. Stops counting at `cap`.
function LF.Cover.crossings(x1, y1, x2, y2, z, cap)
    local cell = getCell()
    cap = cap or 3
    local ax, ay = math.floor(x1), math.floor(y1)
    local bx, by = math.floor(x2), math.floor(y2)
    local n = 0
    local cur = cell:getGridSquare(ax, ay, z)
    local steps = math.max(math.abs(bx - ax), math.abs(by - ay))
    if steps == 0 or not cur then return 0 end
    local px, py = ax, ay
    for i = 1, steps do
        local nx = math.floor(ax + (bx - ax) * i / steps + 0.5)
        local ny = math.floor(ay + (by - ay) * i / steps + 0.5)
        -- Move one axis at a time so a diagonal step can't slip between two fence edges.
        local hops = { { nx, py }, { nx, ny } }
        for _, h in ipairs(hops) do
            if h[1] ~= px or h[2] ~= py then
                local nxt = cell:getGridSquare(h[1], h[2], z)
                if not nxt then return n end
                if cur:isWallTo(nxt) or cur:isHoppableTo(nxt) or cur:isWindowTo(nxt) or cur:isBlockedTo(nxt) then
                    n = n + 1
                    if n >= cap then return n end
                end
                cur, px, py = nxt, h[1], h[2]
            end
        end
    end
    return n
end

local fireCands = {}
local function byFireScore(a, b) return a.score > b.score end
local FIRE_CHECKS = 120     -- at most this many candidate squares get the (costly) cover checks

-- Best firing position for a fighter against a threat: LOW cover toward the threat, line of
-- sight over it, within maxRange of the threat, preferring nearby squares and ones that don't
-- walk toward the enemy. With an anchor (ax, ay) and leash, only squares within leash tiles of
-- the anchor count, and the search is centred there (a soldier stays near his team).
-- `threat` may be a body or anything with getX/getY/getZ (a last-known position).
-- Squares are ranked by distance alone first (cheap), and the cover and sight-line checks run
-- from the best down until one passes, so most squares never cost an engine call.
-- With `loose`, any cover (LOW or HIGH) will do and no line of sight is needed: somewhere to get
-- out of the open when no firing position exists.
-- Returns x, y, z, quality or nil.
function LF.Cover.findFiringPosition(id, body, threat, maxRange, ax, ay, leash, loose)
    local cell = getCell()
    local bx, by, bz = math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ())
    local tx, ty = threat:getX(), threat:getY()
    local r = CFG.searchRadius
    local cx, cy = bx, by
    local leashSq = nil
    if ax and leash then
        cx, cy = math.floor(ax), math.floor(ay)
        leashSq = leash * leash
        if leash < r then r = math.ceil(leash) end
    end
    local maxRangeSq = maxRange * maxRange
    -- "Toward the enemy" is measured from his anchor when he has one (the spot his team was
    -- sent to), so a soldier sent forward doesn't pick the squares behind it.
    local myThreatDist = (ax and LF.dist(ax, ay, tx, ty)) or LF.dist(bx, by, tx, ty)
    local n = 0
    for x = cx - r, cx + r do
        for y = cy - r, cy + r do
            local tdsq = LF.distSq(x + 0.5, y + 0.5, tx, ty)
            if tdsq <= maxRangeSq and tdsq > 9
                and (not leashSq or LF.distSq(x + 0.5, y + 0.5, ax, ay) <= leashSq) then
                local travel = LF.dist(bx, by, x, y)
                local closer = myThreatDist - math.sqrt(tdsq)   -- > 0 means toward the enemy
                n = n + 1
                local c = fireCands[n]
                if not c then c = {}; fireCands[n] = c end
                c.x, c.y, c.score = x, y, -travel - math.max(0, closer) * 0.5
            end
        end
    end
    for i = #fireCands, n + 1, -1 do fireCands[i] = nil end
    table.sort(fireCands, byFireScore)
    -- Never into the building the enemy is in (unless he's in it already - clearing it): a man
    -- looking for cover outside its door doesn't wander in among the defenders.
    local tsq = cell:getGridSquare(math.floor(tx), math.floor(ty), bz)
    local tb = tsq and tsq:getBuilding()
    local enemyB = tb and tb:getID() or nil
    if enemyB then
        local msq = cell:getGridSquare(bx, by, bz)
        local mb = msq and msq:getBuilding()
        if mb and mb:getID() == enemyB then enemyB = nil end
    end
    -- The best spot he can walk straight to; failing that, the best one behind a fence or wall.
    local fallX, fallY, fallQ = nil, nil, nil
    for i = 1, math.min(n, FIRE_CHECKS) do
        local c = fireCands[i]
        local q = LF.Cover.quality(c.x, c.y, bz, tx, ty)
        if (q == LOW or (loose and q == HIGH)) and not isTaken(c.x, c.y, bz, id) then
            local sq = cell:getGridSquare(c.x, c.y, bz)
            local sb = sq and enemyB and sq:getBuilding()
            if sq and not (sb and sb:getID() == enemyB) and standable(sq, body) and (loose or LF.Cover.canSeeFrom(c.x, c.y, bz, threat)) then
                if LF.Cover.crossings(bx, by, c.x, c.y, bz, 1) == 0 then return c.x, c.y, bz, q end
                if not fallX then fallX, fallY, fallQ = c.x, c.y, q end
            end
        end
    end
    if fallX then return fallX, fallY, bz, fallQ end
    return nil
end

-- Is anyone else's spot within a tile of (x, y)? (Two wounded men don't share a corner.)
local function crowded(x, y, z, id)
    for dx = -1, 1 do
        for dy = -1, 1 do
            if isTaken(x + dx, y + dy, z, id) then return true end
        end
    end
    return false
end

local hideCands = {}
local function byScoreDesc(a, b) return a.score > b.score end

-- Best hiding spot for a wounded or unarmed NPC. It must be hidden (behind HIGH cover or out of
-- sight) from the threat AND from every other known enemy position in `others` (points with
-- getX/getY/getZ), no closer to the threat, and - when (rx, ry), the squad's rear, is given -
-- no further from the rear than the soldier already is: the wounded fall back toward their own
-- men, never across the field. Candidates are scored cheaply first and sight lines are only
-- checked from the best down, so extra enemies cost little. Returns x, y, z or nil.
function LF.Cover.findHidingSpot(id, body, threat, rx, ry, others)
    local cell = getCell()
    local bx, by, bz = math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ())
    local tx, ty = threat:getX(), threat:getY()
    local r = CFG.searchRadius
    local myThreatDistSq = LF.distSq(bx, by, tx, ty)
    local myRear = rx and LF.dist(bx, by, rx, ry)
    -- Never hide in the building the enemy is in.
    local tsq = cell:getGridSquare(math.floor(tx), math.floor(ty), math.floor(threat:getZ()))
    local tb = tsq and tsq:getBuilding()
    local enemyBuilding = tb and tb:getID() or nil
    local n = 0
    for x = bx - r, bx + r do
        for y = by - r, by + r do
            if LF.distSq(x + 0.5, y + 0.5, tx, ty) >= myThreatDistSq
                and (not rx or LF.dist(x, y, rx, ry) <= myRear + 1)
                and not crowded(x, y, bz, id) then
                local sq = cell:getGridSquare(x, y, bz)
                local sb = sq and enemyBuilding and sq:getBuilding()
                if sq and standable(sq, body) and not (sb and sb:getID() == enemyBuilding) then
                    n = n + 1
                    local c = hideCands[n]
                    if not c then c = {}; hideCands[n] = c end
                    c.x, c.y = x, y
                    c.score = -LF.dist(bx, by, x, y) - (rx and 0.5 * LF.dist(x, y, rx, ry) or 0)
                end
            end
        end
    end
    for i = #hideCands, n + 1, -1 do hideCands[i] = nil end
    table.sort(hideCands, byScoreDesc)
    for i = 1, math.min(n, 25) do        -- sight checks only for the 25 best candidates
        local c = hideCands[i]
        local hidden = LF.Cover.quality(c.x, c.y, bz, tx, ty) == HIGH or not LF.Cover.canSeeFrom(c.x, c.y, bz, threat)
        if hidden and others then
            for j = 1, #others do
                local o = others[j]
                if not (LF.Cover.quality(c.x, c.y, bz, o:getX(), o:getY()) == HIGH or not LF.Cover.canSeeFrom(c.x, c.y, bz, o)) then
                    hidden = false
                    break
                end
            end
        end
        if hidden then return c.x, c.y, bz end
    end
    return nil
end

-- ---- Incoming fire ----------------------------------------------------------------------

-- Is the target hunkered down (crouched and not up aiming / reacting)?
local function hunkered(target)
    return target:isSneaking() and not target:isPerformingAnAction()
end

-- Hit-chance multiplier for a shot at target, from the target's cover and posture.
function LF.Combat.targetModifier(shooter, target)
    local q = LF.Cover.of(target, shooter)
    local down = hunkered(target)
    if q == HIGH then return 0.15 end
    if q == LOW then return down and 0.3 or 0.65 end
    return down and 0.7 or 1.0
end

-- Which body parts can be hit: behind cover, only what shows above it.
local UPPER = { "Torso_Upper", "Torso_Upper", "UpperArm_L", "UpperArm_R", "Head" }
function LF.Combat.hitParts(shooter, target)
    if LF.Cover.of(target, shooter) ~= NONE then return UPPER end
    return nil
end
