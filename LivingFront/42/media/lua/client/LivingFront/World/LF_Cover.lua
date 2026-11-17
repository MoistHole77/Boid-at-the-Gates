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
require "LivingFront/Soldier/LF_Shot"

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

-- (0.89) Is the edge between sq and its neighbour nb (one square N/S/E/W) a window FRAME - a wall
-- with a window hole in it but no window: smashed out, burnt out, the ruins of Stalingrad (the
-- map's ruined walls are frame sprites, "WindowN" / "WindowW")? The game's isWindowTo only knows
-- frames that still hold a window, so up to 0.88 every empty frame was a blank wall: buildings
-- had no openings to defend from and men behind a sill counted as behind a wall.
-- (0.89.1: B42's PropertyContainer has has(IsoFlagType), not the old Is(name) - 0.89 threw on
-- every edge it asked about.)
local function frameProp(owner, prop)
    if not owner then return false end
    local flag = IsoFlagType and IsoFlagType[prop]
    if not flag then return false end
    local objs = owner:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local spr = o and o:getSprite()
        local pr = spr and spr:getProperties()
        if pr and pr:has(flag) then return true end
    end
    return false
end
function LF.Cover.frameTo(sq, nb)
    if not (sq and nb) then return false end
    local dx, dy = nb:getX() - sq:getX(), nb:getY() - sq:getY()
    if dy == -1 and dx == 0 then return frameProp(sq, "WindowN") end
    if dy == 1 and dx == 0 then return frameProp(nb, "WindowN") end
    if dx == -1 and dy == 0 then return frameProp(sq, "WindowW") end
    if dx == 1 and dy == 0 then return frameProp(nb, "WindowW") end
    return false
end
local function frameTo(sq, nb)
    local ok, r = pcall(LF.Cover.frameTo, sq, nb)
    return ok and r
end

-- What one edge (from sq into its neighbour nb) offers as cover.
local function edgeCover(sq, nb)
    if not nb then return NONE end
    if sq:isWallTo(nb) then
        -- A wall with a window in it (or an empty frame) is something you can shoot through.
        if sq:isWindowTo(nb) or frameTo(sq, nb) then return LOW end
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

-- Squares near (x, y) in rings out to r, nearest first; fn(sq) returns true to take one.
local function searchNear(x, y, z, r, fn)
    local cell = getCell()
    if not cell then return nil end
    local bx, by = math.floor(x), math.floor(y)
    for d = 0, r do
        for dx = -d, d do
            for dy = -d, d do
                if math.max(math.abs(dx), math.abs(dy)) == d then
                    local sq = cell:getGridSquare(bx + dx, by + dy, z)
                    if sq and sq:isFree(false) and fn(sq) then return sq end
                end
            end
        end
    end
    return nil
end

-- A square near (x, y) with a clear line to (tx, ty) - outdoors, or by an opening if indoors -
-- for a gun to fire from. nil if none within r (or the ground isn't loaded).
function LF.Cover.viewPointNear(x, y, z, tx, ty, r)
    local t = LF.Tactics.point(tx + 0.5, ty + 0.5, z)
    local sq = searchNear(x, y, z, r or 4, function(q)
        return LF.Cover.canSeeFrom(q:getX(), q:getY(), z, t)
    end)
    if sq then return sq:getX(), sq:getY(), z end
    return nil
end

-- A square near (x, y) out of sight of (fx, fy) - dead ground behind a building or a wall - for
-- men waiting their turn. nil if none within r (or the ground isn't loaded).
function LF.Cover.hiddenNear(x, y, z, fx, fy, r)
    local t = LF.Tactics.point(fx + 0.5, fy + 0.5, z)
    local sq = searchNear(x, y, z, r or 12, function(q)
        return not LF.Cover.canSeeFrom(q:getX(), q:getY(), z, t)
    end)
    if sq then return sq:getX(), sq:getY(), z end
    return nil
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

function LF.Cover.takenExactly(x, y, z, id) return isTaken(x, y, z, id) end

-- (For the squad's placement, LF_SquadBrain: is this square, or one beside it, someone else's spot?)
function LF.Cover.taken(x, y, z, id)
    for dx = -1, 1 do
        for dy = -1, 1 do
            if isTaken(x + dx, y + dy, z, id) then return true end
        end
    end
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

-- (0.89) Firing positions and hiding spots come from the tactical position system (LF_TPS); these
-- two keep their old names for the callers that ask them.
function LF.Cover.findFiringPosition(id, body, threat, maxRange, ax, ay, leash, loose)
    return LF.TPS.spot(id, body, threat, maxRange, ax, ay, leash, loose and "shelter" or "fight")
end
function LF.Cover.findHidingSpot(id, body, threat, rx, ry, others)
    return LF.TPS.hideSpot(id, body, threat, rx, ry, others)
end

local function hunkered(target)
    return target:isSneaking() and not target:isPerformingAnAction()
end

-- The target's cover class against the shooter (0.72: read from the cover map, LF_Ground - one
-- table read instead of the edge tests per round).
function LF.Combat.coverClass(shooter, target)
    if LF.Ground then
        return LF.Ground.cover(target:getX(), target:getY(), math.floor(target:getZ()), shooter:getX(), shooter:getY())
    end
    local q = LF.Cover.of(target, shooter)
    return q == HIGH and 2 or (q == LOW and 1 or 0)
end

-- Hit-chance multiplier for a shot at target, from the target's cover and posture (the shot
-- table's numbers, LF_Shot).
function LF.Combat.targetModifier(shooter, target)
    local m = LF.Shot.COVER[LF.Combat.coverClass(shooter, target)] or 1
    if hunkered(target) then m = m * LF.Shot.CFG.down
    elseif target:isPlayerMoving() then m = m * LF.Shot.CFG.moving end
    return m
end

-- Which body parts can be hit: behind cover, only what shows above it.
local UPPER = { "Torso_Upper", "Torso_Upper", "UpperArm_L", "UpperArm_R", "Head" }
function LF.Combat.hitParts(shooter, target)
    if LF.Combat.coverClass(shooter, target) ~= NONE then return UPPER end
    return nil
end
