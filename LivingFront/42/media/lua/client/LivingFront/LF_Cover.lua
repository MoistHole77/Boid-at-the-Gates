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

require "LivingFront/LF_Core"
require "LivingFront/LF_Combat"

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
-- Looks at the cardinal neighbours on the threat side (both, for a diagonal threat), and the
-- diagonal neighbour. The best edge counts.
function LF.Cover.quality(x, y, z, tx, ty)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, z)
    if not sq then return NONE end
    local dx, dy = tx - (x + 0.5), ty - (y + 0.5)
    local sx = (dx > 0.5 and 1) or (dx < -0.5 and -1) or 0
    local sy = (dy > 0.5 and 1) or (dy < -0.5 and -1) or 0
    local best = NONE
    if sx ~= 0 then
        local q = edgeCover(sq, cell:getGridSquare(x + sx, y, z))
        if q > best then best = q end
    end
    if sy ~= 0 then
        local q = edgeCover(sq, cell:getGridSquare(x, y + sy, z))
        if q > best then best = q end
    end
    if sx ~= 0 and sy ~= 0 and best < HIGH then
        local nb = cell:getGridSquare(x + sx, y + sy, z)
        if nb and (nb:getVehicleContainer() ~= nil or nb:HasTree() or nb:isSolidTrans()) and best < LOW then
            best = LOW
        end
    end
    return best
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

-- Best firing position for a fighter against a threat: LOW cover toward the threat, line of
-- sight over it, within maxRange of the threat, preferring nearby squares and ones that don't
-- walk toward the enemy. Returns x, y, z, quality or nil.
function LF.Cover.findFiringPosition(id, body, threat, maxRange)
    local cell = getCell()
    local bx, by, bz = math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ())
    local tx, ty = threat:getX(), threat:getY()
    local r = CFG.searchRadius
    local maxRangeSq = maxRange * maxRange
    local myThreatDist = LF.dist(bx, by, tx, ty)
    local bestScore, best = nil, nil
    for x = bx - r, bx + r do
        for y = by - r, by + r do
            local tdsq = LF.distSq(x + 0.5, y + 0.5, tx, ty)
            if tdsq <= maxRangeSq and tdsq > 9 then
                local q = LF.Cover.quality(x, y, bz, tx, ty)
                if q == LOW and not isTaken(x, y, bz, id) then
                    local sq = cell:getGridSquare(x, y, bz)
                    if sq and standable(sq, body) and LF.Cover.canSeeFrom(x, y, bz, threat) then
                        local travel = LF.dist(bx, by, x, y)
                        local closer = myThreatDist - math.sqrt(tdsq)   -- > 0 means toward the enemy
                        local score = -travel - math.max(0, closer) * 0.5
                        if not bestScore or score > bestScore then
                            bestScore, best = score, { x, y, bz }
                        end
                    end
                end
            end
        end
    end
    if best then return best[1], best[2], best[3], LOW end
    return nil
end

-- Best hiding spot for a wounded or unarmed NPC: out of the threat's sight (or behind HIGH
-- cover), not closer to the threat. Returns x, y, z or nil.
function LF.Cover.findHidingSpot(id, body, threat)
    local cell = getCell()
    local bx, by, bz = math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ())
    local tx, ty = threat:getX(), threat:getY()
    local r = CFG.searchRadius
    local myThreatDistSq = LF.distSq(bx, by, tx, ty)
    local bestScore, best = nil, nil
    for x = bx - r, bx + r do
        for y = by - r, by + r do
            local tdsq = LF.distSq(x + 0.5, y + 0.5, tx, ty)
            if tdsq >= myThreatDistSq and not isTaken(x, y, bz, id) then
                local sq = cell:getGridSquare(x, y, bz)
                if sq and standable(sq, body) then
                    local hidden = LF.Cover.quality(x, y, bz, tx, ty) == HIGH or not LF.Cover.canSeeFrom(x, y, bz, threat)
                    if hidden then
                        local score = -LF.dist(bx, by, x, y)
                        if not bestScore or score > bestScore then
                            bestScore, best = score, { x, y, bz }
                        end
                    end
                end
            end
        end
    end
    if best then return best[1], best[2], best[3] end
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
