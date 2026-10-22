-- Living Front: unit tactics - the sergeant's intent and the corporals' drills.
--
-- When a fight breaks out, nobody gives orders for the first few seconds (CFG.bearingsTicks):
-- every soldier returns fire, gets into the nearest cover and keeps firing on his own. Only
-- then does the commander take stock and start giving orders.
-- Orders flow one level down (see the squad tactics design doc):
--   Commander (sergeant, or the corporal of a lone team) picks the unit's intent from what the
--   unit knows: ADVANCE while the enemy is out of range, HOLD once in range or when most fit men
--   are pinned, FALL BACK after heavy losses. He shouts it; corporals within earshot take it up.
--   Once his squad has fire superiority (enough of the enemy near the contact is suppressed)
--   and it is healthy and not pinned itself, a sergeant orders a FLANK: his alpha teams
--   maneuver around one side (the side with more cover) while his bravo teams hold and keep the
--   enemy pinned; when the alphas are in position, all hold. After one side starts a flank the
--   other side must wait ~25 s before it can flank in turn.
--   Corporal turns the order into a drill for his team's two elements (pairs):
--     HOLD     - both pairs take cover around their positions and fire
--     ADVANCE  - bounding: one pair runs a bound forward past the other while the other covers
--                (aimed fire at what it sees, area fire at the last-known position), then swap
--     FALLBACK - the same, backwards
--     MANEUVER - the same bounding, along a route (out to the side, then in toward the enemy)
--   A corporal whose team is holding and finds half its fit men without an open shot (no enemy
--   in their sights for ~8 s) moves the whole team to a nearby spot with a line of sight to the
--   enemy (REPOSITION). Only one team per unit does this at a time, at most once every ~30 s;
--   among the teams that want to, the one that goes is picked at random, weighted toward the
--   less suppressed. An order from the sergeant overrides it. A stalemate flank waits until
--   two repositions have been tried (or the fight has stalled twice as long).
--   A team out of earshot keeps doing its last order.
-- The brain asks LF.Tactics.place(rec) where a soldier belongs and what his role is.
-- Runtime only: after a load, units re-form from where their men stand.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Units"
require "LivingFront/LF_Squad"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Suppress"
require "LivingFront/LF_Combat"
require "LivingFront/LF_Cover"
require "LivingFront/LF_Sense"

LF.Tactics = LF.Tactics or {}

local CFG = {
    updateTicks = 30,       -- commanders and corporals re-evaluate twice a second
    bound = 6,              -- tiles each bound gains on the covering pair
    arriveDistance = 1.8,   -- a moving soldier within this of his spot has arrived
    phaseTimeout = 600,     -- a bound that hasn't finished in ~10 s is called done anyway
    earshot = 30,           -- tiles a shouted order carries
    contactMemory = 600,
    contactRange = 45,
    advanceStop = 16,       -- the leading pair stops advancing this close to the enemy
    advanceResume = 22,     -- ... and starts again beyond this
    fallbackFit = 0.5,      -- fall back when fewer than this share of the unit is fit to fight
    fallbackClear = 26,     -- ... until the leading pair is this far from the enemy
    pinnedHold = 0.5,       -- hold when this share of the fit men is pinned
    fitHealth = 35,
    shoutTicks = 150,       -- how long shouted words stay over a head
    bearingsTicks = 300,    -- the first ~5 s of a fight: everyone for himself, no orders
    -- Flanking (squads only)
    flankMinHold = 180,     -- HOLD at least ~3 s before considering a flank
    flankSuperiority = 0.3, -- ... and at least this share of the enemy near the contact suppressed
    superiorityRadius = 25, -- enemies within this of the contact count toward that share
    flankCooldown = 1800,   -- ... at most once per 30 s
    flankFit = 0.6,         -- ... only while at least this share of the squad is fit
    flankPinned = 0.34,     -- ... and less than this share of the fit men is pinned
    flankOut = 14,          -- first waypoint: this far out to the side
    flankStandoff = 10,     -- final waypoint: this far short of the enemy (along the squad's facing) ...
    flankWide = 16,         -- ... and this far off to the side of him
    counterFlankTicks = 1500, -- after one side starts a flank, the other must wait this long (~25 s)
    flankPushes = 2,
    -- Stalemate: if neither side reaches fire superiority for this long, the side with the better
    -- share of the enemy suppressed flanks anyway (battles should still last a while).
    stalemateTicks = 2700,  -- ~45 s of holding in range with no flank by either side
    stalemateRadius = 45,   -- enemy squads whose last contact is within this of our commander count
    -- Corporal's reposition (team without an open shot)
    blindShare = 0.5,       -- this share of the team's fit men without a shot -> the team wants to move
    shiftInterval = 1800,   -- one team per unit repositions at most once per ~30 s
    shiftsBeforeStalemate = 2, -- repositions tried before a stalemate flank (or 2x stalemateTicks)        -- a flanking team that can't see the enemy at the end pushes on this many times
    flankTimeout = 5400,    -- give up on a flank after ~90 s
}
LF.Tactics.CFG = CFG

local squads = {}   -- squad id -> { intent, contact (point), broken }
local teams = {}    -- team id -> { order, heard, moving, pos = { A = {x,y}, B = {x,y} }, phaseStart }
local shouts = {}   -- record id -> { text, untilTick }

-- A point that aiming and cover code can treat like a body.
local POINT = {}
POINT.__index = POINT
function POINT:getX() return self.x end
function POINT:getY() return self.y end
function POINT:getZ() return self.z end
function POINT:isDead() return false end
function LF.Tactics.point(x, y, z) return setmetatable({ x = x, y = y, z = z or 0 }, POINT) end

local ELEMENT_NAME = { A = "Alpha", B = "Bravo" }
local OTHER = { A = "B", B = "A" }

-- ---- shouting -------------------------------------------------------------------------------

function LF.Tactics.shout(id, text)
    local rec = LF.Records.get(id)
    shouts[id] = { text = text, untilTick = LF.tick + CFG.shoutTicks }
    LF.log("SHOUT #" .. id .. " " .. (rec and LF.Units.title(rec) or "?") .. ": " .. text)
end

local COLORS = { GER = { 0.75, 0.8, 0.9 }, SOV = { 1.0, 0.55, 0.5 }, CIV = { 0.9, 0.9, 0.7 } }

local function drawShouts()
    local core = getCore()
    local zoom = core:getZoom(0)
    local tm = getTextManager()
    for id, s in pairs(shouts) do
        local body = LF.Bodies.get(id)
        if LF.tick > s.untilTick or not body or body:isDead() then
            shouts[id] = nil
        elseif body:isOnScreen() then
            local x, y, z = body:getX(), body:getY(), body:getZ()
            local sx, sy = isoToScreenX(0, x, y, z), isoToScreenY(0, x, y, z)
            local rec = LF.Records.get(id)
            local c = COLORS[rec and rec.faction or "CIV"] or COLORS.CIV
            local left = (s.untilTick - LF.tick) / CFG.shoutTicks
            tm:DrawStringCentre(UIFont.Medium, sx, sy - 135 / zoom, s.text, c[1], c[2], c[3], math.min(1, left * 3))
        end
    end
end

Events.OnPostUIDraw.Add(function() LF.guard("draw shouts", drawShouts) end)

-- ---- helpers --------------------------------------------------------------------------------

-- Fit to fight: alive, not relieved for wounds, and (if he has a body here) not badly hurt.
-- A soldier without a body (out of range of the player) counts as fit, so a unit that is
-- only partly near the player doesn't think it has lost half its men.
local function fit(rec)
    if not (rec and rec.alive and not rec.wounded) then return false end
    local body = LF.Bodies.get(rec.id)
    return body == nil or LF.Combat.health(body) >= CFG.fitHealth
end

local function facing(squad) return squad.facingX or 1, squad.facingY or 0 end

-- Centroid of a team's living members in one element, from their bodies.
local function elementCentre(team, el)
    local sx, sy, n = 0, 0, 0
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.alive and r.element == el and r.team == team.id then
            local b = LF.Bodies.get(rid)
            if b then sx, sy, n = sx + b:getX(), sy + b:getY(), n + 1 end
        end
    end
    if n == 0 then return nil end
    return sx / n, sy / n
end

-- ---- placement (asked by the brain) ---------------------------------------------------------

-- Where a soldier belongs right now and his role:
--   "move" (run to x, y without stopping to fight), "hold" (take cover near x, y and fight),
--   "command" (the sergeant: stay behind his teams and fight).
-- Returns role, x, y, z, point (the enemy's last-known position), or nil when the unit has no
-- intent (no contact): the brain then keeps the plain formation.
function LF.Tactics.place(rec)
    local sq = rec.squad and squads[rec.squad]
    if not (sq and sq.intent) then return nil end
    local squad = LF.Units.get(rec.squad)
    if not squad then return nil end
    local fx, fy = facing(squad)
    local z = rec.z or 0

    if squad.leader == rec.id then
        -- The sergeant keeps a few tiles behind the middle of his teams.
        local sx, sy, n = 0, 0, 0
        for _, tid in ipairs(squad.teams) do
            local t = teams[tid]
            if t and t.pos then
                for _, el in ipairs({ "A", "B" }) do
                    local p = t.pos[el]
                    if p then sx, sy, n = sx + p.x, sy + p.y, n + 1 end
                end
            end
        end
        if n == 0 then return nil end
        return "command", sx / n - fx * 3, sy / n - fy * 3, z, sq.contact
    end

    local t = rec.team and teams[rec.team]
    if not (t and t.pos and t.pos[rec.element]) then
        local x, y, sz = LF.Squad.slot(rec)
        if not x then return nil end
        return "hold", x, y, sz, sq.contact
    end
    local p = t.pos[rec.element]
    local lat = LF.Units.slotLat(rec)
    local x, y = p.x - fy * lat, p.y + fx * lat
    return (t.moving == rec.element or t.shifting) and "move" or "hold", x, y, z, sq.contact
end

function LF.Tactics.intent(squadId)
    local sq = squads[squadId]
    return sq and sq.intent
end

-- Is this unit in the opening seconds of a fight (no orders yet; everyone returns fire and
-- takes cover on his own)?
function LF.Tactics.bearings(squadId)
    local sq = squads[squadId]
    return sq ~= nil and sq.fightStart ~= nil and not sq.intent and LF.tick - sq.fightStart < CFG.bearingsTicks
end

-- ---- corporal: drills -----------------------------------------------------------------------

-- Has the moving pair finished its bound? Every fit, unpinned man in it must have reached his
-- spot (or found he can't get there). If all its fit men are pinned, it waits; a pair with no
-- fit men left is done at once (the other pair carries on alone).
local function boundDone(team, t, squad)
    if LF.tick - t.phaseStart > CFG.phaseTimeout then return true end
    local fx, fy = facing(squad)
    local p = t.pos[t.moving]
    local movers, pinned = 0, 0
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.team == team.id and r.element == t.moving and fit(r) then
            local b = LF.Bodies.get(rid)
            if b then
                if LF.Suppress.isPinned(b) then
                    pinned = pinned + 1
                else
                    movers = movers + 1
                    local lat = LF.Units.slotLat(r)
                    local x, y = p.x - fy * lat, p.y + fx * lat
                    if LF.dist(b:getX(), b:getY(), x, y) > CFG.arriveDistance and not (LF.Brain and LF.Brain.isStuck and LF.Brain.isStuck(rid, x, y)) then
                        return false
                    end
                end
            end
        end
    end
    if movers == 0 and pinned > 0 then return false end
    return true
end

-- Start a bound: element `el` moves (dx, dy) * bound past the covering pair, or onto
-- (tx, ty) if that is nearer.
local function startBound(team, t, el, dx, dy, tx, ty, contact)
    local other = t.pos[OTHER[el]]
    local mine = t.pos[el]
    if not (other and mine) then return end
    local len = CFG.bound
    if contact then
        -- An advance never puts a pair closer to the enemy than the stopping distance.
        local room = LF.dist(other.x, other.y, contact.x, contact.y) - (CFG.advanceStop - 2)
        if room < len then len = room end
        if len < 1 then t.moving = nil; return end
    end
    t.moving = el
    t.phaseStart = LF.tick
    local nx, ny = other.x + dx * len, other.y + dy * len
    if tx and LF.dist(other.x, other.y, tx, ty) <= len then nx, ny = tx, ty end
    mine.x, mine.y = nx, ny
    if team.leader then
        LF.Tactics.shout(team.leader, ELEMENT_NAME[el] .. ", move! " .. ELEMENT_NAME[OTHER[el]] .. ", cover!")
    end
end

-- Direction from the team's leading pair toward its current route waypoint: dx, dy, tx, ty.
local function routeHeading(t)
    local wp = t.route and t.route[t.routeIdx]
    if not wp then return nil end
    local lead = t.pos[t.moving and OTHER[t.moving] or "A"]
    -- The pair nearer the waypoint leads.
    for _, el in ipairs({ "A", "B" }) do
        local p = t.pos[el]
        if p and LF.dist(p.x, p.y, wp.x, wp.y) < LF.dist(lead.x, lead.y, wp.x, wp.y) then lead = p end
    end
    local dx, dy = wp.x - lead.x, wp.y - lead.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.5 then return 0, 0, wp.x, wp.y end
    return dx / len, dy / len, wp.x, wp.y
end

-- ---- corporal: reposition when the team has no shot -----------------------------------------

-- Has every fit, unpinned man of the team reached his new spot (or found he can't)?
local function shiftDone(team, t, squad)
    if LF.tick - t.phaseStart > CFG.phaseTimeout then return true end
    local fx, fy = facing(squad)
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        local p = r and t.pos[r.element]
        if p and r.team == team.id and fit(r) then
            local b = LF.Bodies.get(rid)
            if b and not LF.Suppress.isPinned(b) then
                local lat = LF.Units.slotLat(r)
                local x, y = p.x - fy * lat, p.y + fx * lat
                if LF.dist(b:getX(), b:getY(), x, y) > CFG.arriveDistance
                    and not (LF.Brain and LF.Brain.isStuck and LF.Brain.isStuck(rid, x, y)) then
                    return false
                end
            end
        end
    end
    return true
end

-- Offsets tried for a new team position, in the squad's frame (forward, right): sideways
-- first, then sideways and a little forward, then further out, then a step back.
local SHIFT_TRIES = { { 0, 7 }, { 0, -7 }, { 3, 6 }, { 3, -6 }, { 0, 11 }, { 0, -11 }, { -3, 4 }, { -3, -4 } }

-- Find a spot near the team with a line of sight to the enemy and move the whole team there.
local function planShift(team, t, squad, sq)
    local cp = sq.contact
    if not cp then return false end
    local fx, fy = facing(squad)
    local rx, ry = -fy, fx
    local cx, cy = (t.pos.A.x + t.pos.B.x) / 2, (t.pos.A.y + t.pos.B.y) / 2
    local z = cp.z or 0
    local cell = getCell()
    for _, o in ipairs(SHIFT_TRIES) do
        local nx, ny = cx + fx * o[1] + rx * o[2], cy + fy * o[1] + ry * o[2]
        local sqr = cell:getGridSquare(math.floor(nx), math.floor(ny), z)
        if sqr and sqr:isFree(false) and LF.dist(nx, ny, cp.x, cp.y) >= CFG.advanceStop - 2
            and LF.Cover.canSeeFrom(math.floor(nx), math.floor(ny), z, cp) then
            local dx, dy = nx - cx, ny - cy
            t.pos.A.x, t.pos.A.y = t.pos.A.x + dx, t.pos.A.y + dy
            t.pos.B.x, t.pos.B.y = t.pos.B.x + dx, t.pos.B.y + dy
            t.shifting, t.moving, t.phaseStart = true, nil, LF.tick
            LF.log("REPOSITION " .. team.name .. " of " .. squad.name .. ": no open shot, moving "
                .. math.floor(LF.dist(0, 0, dx, dy)) .. " tiles to " .. math.floor(nx) .. "," .. math.floor(ny))
            if team.leader then LF.Tactics.shout(team.leader, "Can't see them - move! Find a shot!") end
            return true
        end
    end
    return false
end

-- While holding, a team that is repositioning finishes when its men are in place.
local function corporalCheck(team, t, squad, sq)
    if t.shifting and shiftDone(team, t, squad) then t.shifting = nil end
end

-- Does this team want to reposition (half its fit men without an open shot)? Returns wants,
-- average suppression of its fit men.
local function teamWantsShift(team)
    local fitN, blind, supp = 0, 0, 0
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        local b = r and LF.Bodies.get(rid)
        if b and r.team == team.id and fit(r) then
            fitN = fitN + 1
            supp = supp + LF.Suppress.value(b)
            if LF.Brain.isBlind(rid) then blind = blind + 1 end
        end
    end
    if fitN < 2 then return false, 0 end
    return blind / fitN >= CFG.blindShare, supp / fitN
end

-- One reposition per unit at a time, at most every ~30 s: of the holding teams that want to
-- move, pick one at random, weighted toward the less suppressed.
local function chooseShift(squad, sq)
    if sq.intent ~= "HOLD" or not (LF.Brain and LF.Brain.isBlind) then return end
    if LF.tick - (sq.lastShift or -100000) < CFG.shiftInterval then return end
    local cands, weights, total = {}, {}, 0
    for _, tid in ipairs(squad.teams) do
        local team, t = LF.Units.get(tid), teams[tid]
        if team and t then
            if t.shifting then return end                -- one at a time
            if t.order == "HOLD" and team.leader and LF.Bodies.get(team.leader) then
                local wants, supp = teamWantsShift(team)
                if wants then
                    local w = math.max(5, 105 - supp)    -- less suppressed -> more likely
                    cands[#cands + 1], weights[#weights + 1] = team, w
                    total = total + w
                end
            end
        end
    end
    if #cands == 0 then return end
    local roll = ZombRand(math.floor(total)) + 1
    local pick = cands[#cands]
    for i, w in ipairs(weights) do
        roll = roll - w
        if roll <= 0 then pick = cands[i]; break end
    end
    if planShift(pick, teams[pick.id], squad, sq) then
        sq.lastShift = LF.tick
        sq.shiftsSinceFlank = (sq.shiftsSinceFlank or 0) + 1
    else
        sq.lastShift = LF.tick - CFG.shiftInterval + 300   -- nowhere better from there; ask again in ~5 s
    end
end

local function driveTeam(team, t, squad, sq)
    local order = t.heard
    local fx, fy = facing(squad)
    -- An order from the sergeant (anything but HOLD) overrides the corporal's own reposition.
    if order ~= "HOLD" then t.shifting = nil end
    if order == "ADVANCE" or order == "FALLBACK" then
        local dir = order == "ADVANCE" and 1 or -1
        local contact = (dir > 0) and sq.contact or nil
        if t.order ~= order then
            t.order = order
            startBound(team, t, "A", fx * dir, fy * dir, nil, nil, contact)
        elseif t.moving and boundDone(team, t, squad) then
            startBound(team, t, OTHER[t.moving], fx * dir, fy * dir, nil, nil, contact)
        end
    elseif order == "MANEUVER" then
        if t.maneuverDone then
            t.order, t.moving = "HOLD", nil      -- already in position; wait for new orders
            return
        end
        if t.order ~= order then
            t.order = order
            t.route = sq.flank and sq.flank.routes[team.id]
            t.routeIdx = 1
            t.moving = nil
        end
        if not t.route then t.order, t.moving = "HOLD", nil; return end
        if t.moving and not boundDone(team, t, squad) then return end
        -- Waypoint reached once the leading pair is on it.
        local wp = t.route[t.routeIdx]
        while wp and math.min(LF.dist(t.pos.A.x, t.pos.A.y, wp.x, wp.y), LF.dist(t.pos.B.x, t.pos.B.y, wp.x, wp.y)) < 2.5 do
            t.routeIdx = t.routeIdx + 1
            wp = t.route[t.routeIdx]
        end
        if not wp then
            -- At the end of the route: if neither pair can see where the enemy is, the spot is no
            -- good - keep working round his side (up to twice).
            local cp = sq.contact
            local z = cp and cp.z or 0
            local seen = not cp
                or LF.Cover.canSeeFrom(math.floor(t.pos.A.x), math.floor(t.pos.A.y), z, cp)
                or LF.Cover.canSeeFrom(math.floor(t.pos.B.x), math.floor(t.pos.B.y), z, cp)
            if not seen and (t.pushes or 0) < CFG.flankPushes then
                t.pushes = (t.pushes or 0) + 1
                local lead = LF.dist(t.pos.A.x, t.pos.A.y, cp.x, cp.y) < LF.dist(t.pos.B.x, t.pos.B.y, cp.x, cp.y) and t.pos.A or t.pos.B
                -- Work round him: half toward the enemy, half sideways toward his rear.
                local fx, fy = facing(squad)
                local dx, dy = cp.x - lead.x, cp.y - lead.y
                local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
                dx, dy = dx / len, dy / len
                local tx, ty = -dy, dx
                if tx * fx + ty * fy < 0 then tx, ty = -tx, -ty end
                local mx, my = dx * 0.5 + tx, dy * 0.5 + ty
                local ml = math.sqrt(mx * mx + my * my)
                local step = CFG.bound
                if len - step * 0.5 < 8 then mx, my, ml = tx, ty, 1 end    -- close already: only sideways
                if step >= 2 then
                    t.route[#t.route + 1] = { x = lead.x + mx / ml * step, y = lead.y + my / ml * step }
                    wp = t.route[t.routeIdx]
                    LF.log("FLANK " .. team.name .. " can't see the enemy from its position; pushing on (" .. t.pushes .. ")")
                    if team.leader then LF.Tactics.shout(team.leader, "No good here - keep moving!") end
                end
            end
        end
        if not wp then
            t.order, t.moving, t.maneuverDone = "HOLD", nil, true
            if team.leader then LF.Tactics.shout(team.leader, "In position!") end
            return
        end
        local dx, dy, tx, ty = routeHeading(t)
        -- Leapfrog: the pair further from the waypoint moves past the nearer one.
        local el = t.moving and OTHER[t.moving]
        if not el then
            el = LF.dist(t.pos.A.x, t.pos.A.y, wp.x, wp.y) > LF.dist(t.pos.B.x, t.pos.B.y, wp.x, wp.y) and "A" or "B"
        end
        startBound(team, t, el, dx, dy, tx, ty)
    elseif order == "HOLD" then
        if t.order ~= "HOLD" then
            -- Hold where the men are: a pair caught mid-bound stops where it is rather than
            -- finishing the run alone.
            if t.moving then
                local x, y = elementCentre(team, t.moving)
                if x then t.pos[t.moving].x, t.pos[t.moving].y = x, y end
            end
            t.order, t.moving = "HOLD", nil
        end
        corporalCheck(team, t, squad, sq)
    end
end

-- How much cover there is around (x, y) against a threat at (cx, cy): squares with any cover
-- within 4 tiles.
local function coverAround(x, y, z, cx, cy)
    local n = 0
    for ix = math.floor(x) - 4, math.floor(x) + 4 do
        for iy = math.floor(y) - 4, math.floor(y) + 4 do
            if LF.Cover.quality(ix, iy, z, cx, cy) ~= LF.Cover.NONE then n = n + 1 end
        end
    end
    return n
end

-- Where the enemy's line ends on one side, in the squad's frame (forward along its facing,
-- lateral to the right): the known enemy furthest out to that side. Returns forward, lateral
-- (lateral is signed by side, so bigger = further out) for that soldier, or the contact's.
local function enemyEdge(squad, sx, sy, side, c)
    local fx, fy = facing(squad)
    local rx, ry = -fy, fx
    local bestF = (c.x - sx) * fx + (c.y - sy) * fy
    local bestL = ((c.x - sx) * rx + (c.y - sy) * ry) * side
    for _, e in ipairs(LF.Squad.contactPoints(squad.id, CFG.contactMemory, 24)) do
        local L = ((e.x - sx) * rx + (e.y - sy) * ry) * side
        if L > bestL then bestL, bestF = L, (e.x - sx) * fx + (e.y - sy) * fy end
    end
    return bestF, bestL
end

-- Plan a flank: pick the side with more cover near the final position, and a route for each
-- alpha team: out to the side, then to a spot beside and short of the end of the enemy's line,
-- then wrapping in toward his side. Each further flank in the same fight pushes deeper.
-- Returns the flank plan or nil.
local function planFlank(squad, c, sq)
    local fx, fy = facing(squad)
    local rx, ry = -fy, fx
    local alphas = {}
    local sx, sy, n = 0, 0, 0
    for _, tid in ipairs(squad.teams) do
        local team, t = LF.Units.get(tid), teams[tid]
        if team and t then
            for _, el in ipairs({ "A", "B" }) do sx, sy, n = sx + t.pos[el].x, sy + t.pos[el].y, n + 1 end
            local cpl = team.leader and LF.Records.get(team.leader)
            if team.element == "A" and cpl and fit(cpl) then alphas[#alphas + 1] = team end
        end
    end
    if #alphas == 0 or n == 0 then return nil end
    sx, sy = sx / n, sy / n
    local z = c.z or 0
    local depth = (sq.flankCount or 0) * 3          -- later flanks go further forward
    local function at(F, L, side) return sx + fx * F + rx * side * L, sy + fy * F + ry * side * L end

    local best, bestCover = nil, -1
    for _, side in ipairs({ -1, 1 }) do
        local eF, eL = enemyEdge(squad, sx, sy, side, c)
        local wx, wy = at(eF - CFG.flankStandoff + depth, eL + CFG.flankWide / 2, side)
        local cov = coverAround(wx, wy, z, c.x, c.y)
        if cov > bestCover then best, bestCover = side, cov end
    end
    local side = best
    local eF, eL = enemyEdge(squad, sx, sy, side, c)
    local plan = { side = side, started = LF.tick, routes = {}, teams = {} }
    for k, team in ipairs(alphas) do
        local t = teams[team.id]
        local cx = (t.pos.A.x + t.pos.B.x) / 2
        local cy = (t.pos.A.y + t.pos.B.y) / 2
        local spread = (k - 1) * 4                  -- the second team swings wider
        local w2x, w2y = at(eF - CFG.flankStandoff + depth, eL + CFG.flankWide / 2 + spread, side)
        local w3x, w3y = at(eF - CFG.flankStandoff / 2 + depth, eL + 4 + spread, side)
        plan.routes[team.id] = {
            { x = cx + rx * side * CFG.flankOut, y = cy + ry * side * CFG.flankOut },
            { x = w2x, y = w2y },
            { x = w3x, y = w3y },
        }
        plan.teams[#plan.teams + 1] = team.id
        t.maneuverDone, t.pushes, t.side = nil, 0, side
    end
    sq.flankCount = (sq.flankCount or 0) + 1
    LF.log("FLANK " .. squad.name .. " going " .. (side < 0 and "left" or "right") .. " with " .. #alphas
        .. " alpha team(s); cover score " .. bestCover .. ", enemy line ends " .. math.floor(eL)
        .. " tiles out, flank #" .. sq.flankCount)
    return plan
end

-- Fire superiority: the share of enemy soldiers near the contact who are suppressed.
local supCtx = {}
local function countSuppressed(e, _dsq, ctx)
    if LF.isHostile(ctx.faction, e.rec.faction) and not e.body:isDead() then
        ctx.total = ctx.total + 1
        if LF.Suppress.isSuppressed(e.body) then ctx.supp = ctx.supp + 1 end
    end
end
local function enemySuppression(squad, c)
    supCtx.faction, supCtx.total, supCtx.supp = squad.faction, 0, 0
    LF.Sense.near(c.x, c.y, CFG.superiorityRadius, countSuppressed, supCtx)
    return supCtx.supp, supCtx.total
end

-- Did a squad of another faction start a flank recently? (The other side must wait its turn.)
local function otherSideFlanking(faction)
    for sid, s in pairs(squads) do
        if s.flankStartTick and LF.tick - s.flankStartTick < CFG.counterFlankTicks then
            local u = LF.Units.get(sid)
            if u and u.faction ~= faction then return true end
        end
    end
    return false
end

-- Stalemate check: has this fight gone ~45 s with no flank by either side, and does this squad
-- have at least as much fire superiority as any enemy squad facing it? Returns ok, enemy best.
local function stalemate(squad, sq, x, y)
    local quietSince = math.max(sq.holdSince or LF.tick, sq.flankStartTick or -100000)
    local enemyBest = 0
    for sid, s in pairs(squads) do
        local u = LF.Units.get(sid)
        if u and u.faction ~= squad.faction and s.intent and s.contact
            and LF.dist(s.contact.x, s.contact.y, x, y) < CFG.stalemateRadius then
            if s.flankStartTick and s.flankStartTick > quietSince then quietSince = s.flankStartTick end
            if (s.supShare or 0) > enemyBest then enemyBest = s.supShare or 0 end
        end
    end
    local quiet = LF.tick - quietSince
    if quiet < CFG.stalemateTicks then return false, enemyBest end
    -- Give the teams' own repositions a chance first (unless it has stalled twice as long).
    if (sq.shiftsSinceFlank or 0) < CFG.shiftsBeforeStalemate and quiet < CFG.stalemateTicks * 2 then
        return false, enemyBest
    end
    return (sq.supShare or 0) >= enemyBest, enemyBest
end

-- What a team should do under the squad's intent.
local function orderFor(team, sq)
    if sq.intent == "FLANK" then
        if sq.flank and sq.flank.routes[team.id] then return "MANEUVER" end
        return "HOLD"
    end
    return sq.intent
end

-- ---- commander: intent ----------------------------------------------------------------------

local INTENT_WORDS = { ADVANCE = "Advance!", HOLD = "Hold! Open fire!", FALLBACK = "Fall back!" }

local function setIntent(squad, sq, cid, intent, why)
    if sq.intent == intent then return end
    LF.log("INTENT " .. squad.name .. " " .. tostring(sq.intent) .. " -> " .. tostring(intent) .. " (" .. why .. ")")
    if sq.intent == "FLANK" then sq.lastFlank, sq.flank = LF.tick, nil end
    sq.intent = intent
    if intent == "HOLD" then sq.holdSince = LF.tick end
    if intent and cid then
        local words = INTENT_WORDS[intent]
        if intent == "FLANK" and sq.flank then
            words = "Alpha teams, flank " .. (sq.flank.side < 0 and "left" or "right") .. "! Bravo teams, cover!"
        end
        LF.Tactics.shout(cid, words)
    end
end

local function updateSquad(squad)
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    if not cmd or cmd:isDead() then return end   -- no commander here: everyone keeps their last order
    local sq = squads[squad.id]
    if not sq then sq = {}; squads[squad.id] = sq end

    local c = LF.Squad.bestContact(squad.id, cmd:getX(), cmd:getY(), CFG.contactMemory, CFG.contactRange)
    if not c then
        if sq.intent then
            setIntent(squad, sq, cid, nil, "no contact")
            for _, tid in ipairs(squad.teams) do teams[tid] = nil end
        end
        sq.fightStart = nil
        return
    end
    -- A fight has just broken out: no orders until the men have got their bearings.
    if not sq.intent then
        if not sq.fightStart then
            sq.fightStart = LF.tick
            LF.log("CONTACT " .. squad.name .. ": fight breaks out, every man returns fire and takes cover")
        end
        if LF.tick - sq.fightStart < CFG.bearingsTicks then return end
    end
    if not sq.contact then sq.contact = LF.Tactics.point(c.x, c.y, c.z)
    else sq.contact.x, sq.contact.y, sq.contact.z = c.x, c.y, c.z end

    -- Team positions start from where the men stand when the fight begins.
    for _, tid in ipairs(squad.teams) do
        local team = LF.Units.get(tid)
        if team and not teams[tid] then
            local ax, ay = elementCentre(team, "A")
            local bx, by = elementCentre(team, "B")
            if ax or bx then
                ax, ay = ax or bx, ay or by
                bx, by = bx or ax, by or ay
                teams[tid] = { order = nil, pos = { A = { x = ax, y = ay }, B = { x = bx, y = by } } }
            end
        end
    end

    -- How the unit stands.
    local total, fitN, pinnedN = 0, 0, 0
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r then
            total = total + 1
            if fit(r) then
                fitN = fitN + 1
                local b = LF.Bodies.get(rid)
                if b and LF.Suppress.isPinned(b) then pinnedN = pinnedN + 1 end
            end
        end
    end
    local front = math.huge
    for _, tid in ipairs(squad.teams) do
        local t = teams[tid]
        if t then
            for _, p in pairs(t.pos) do
                local d = LF.dist(p.x, p.y, c.x, c.y)
                if d < front then front = d end
            end
        end
    end

    -- Fire superiority: how much of the enemy near the contact this squad has suppressed
    -- (kept, so enemy squads can compare in a stalemate).
    local supp, enemies = enemySuppression(squad, c)
    sq.supShare = enemies > 0 and supp / enemies or 0

    local intent = sq.intent
    local why
    if total > 0 and fitN / total < CFG.fallbackFit then
        sq.broken = true
        if front < CFG.fallbackClear then intent, why = "FALLBACK", fitN .. "/" .. total .. " fit"
        else intent, why = "HOLD", "fallen back out of range" end
    elseif intent ~= "HOLD" and intent ~= "FLANK" and fitN > 0 and pinnedN / fitN >= CFG.pinnedHold then
        -- Too many men pinned to keep advancing. (A squad already holding still goes on to the
        -- flank checks below, and a flank under way carries on.)
        intent, why = "HOLD", pinnedN .. "/" .. fitN .. " pinned"
    elseif intent == "FLANK" then
        -- Carry on until every flanking team is in position (or it takes too long).
        local done = true
        for _, tid in ipairs(sq.flank and sq.flank.teams or {}) do
            local t = teams[tid]
            local team = LF.Units.get(tid)
            local cpl = team and team.leader and LF.Bodies.get(team.leader)
            if t and cpl and not cpl:isDead() and not t.maneuverDone then done = false end
        end
        if done then intent, why = "HOLD", "flankers in position"
        elseif sq.flank and LF.tick - sq.flank.started > CFG.flankTimeout then intent, why = "HOLD", "flank took too long" end
    elseif intent == "HOLD" and squad.leader and front <= CFG.advanceResume
        and LF.tick - (sq.holdSince or LF.tick) >= CFG.flankMinHold
        and LF.tick - (sq.lastFlank or -100000) >= CFG.flankCooldown
        and total > 0 and fitN / total >= CFG.flankFit
        and not otherSideFlanking(squad.faction) then
        local reason = nil
        local steady = fitN == 0 or pinnedN / fitN < CFG.flankPinned
        if steady and enemies > 0 and sq.supShare >= CFG.flankSuperiority then
            reason = "fire superiority: " .. supp .. "/" .. enemies .. " enemy suppressed"
        else
            local ok, enemyBest = stalemate(squad, sq, cmd:getX(), cmd:getY())
            if ok then
                reason = string.format("stalemate: our fire superiority %.0f%% vs theirs %.0f%%",
                    sq.supShare * 100, enemyBest * 100)
            end
        end
        if reason then
            local plan = planFlank(squad, c, sq)
            if plan then
                sq.flank = plan
                sq.flankStartTick = LF.tick
                sq.shiftsSinceFlank = 0
                intent, why = "FLANK", reason
            else
                sq.lastFlank = LF.tick
            end
        end
    elseif intent == "ADVANCE" and front <= CFG.advanceStop then
        intent, why = "HOLD", "in range (" .. math.floor(front) .. " tiles)"
    elseif intent ~= "ADVANCE" and front > CFG.advanceResume and not sq.broken
        and not (fitN > 0 and pinnedN / fitN >= CFG.pinnedHold) then
        intent, why = "ADVANCE", "enemy at " .. math.floor(front) .. " tiles"
    elseif not intent then
        intent, why = "HOLD", "contact at " .. math.floor(front) .. " tiles"
    end
    setIntent(squad, sq, cid, intent, why or "")

    -- Pass it on: corporals within earshot take up the intent, then run their drills.
    for _, tid in ipairs(squad.teams) do
        local team = LF.Units.get(tid)
        local t = teams[tid]
        if team and t then
            local cpl = team.leader and LF.Bodies.get(team.leader)
            if cpl and not cpl:isDead() then
                if LF.dist(cpl:getX(), cpl:getY(), cmd:getX(), cmd:getY()) <= CFG.earshot then
                    t.heard = orderFor(team, sq)
                end
                driveTeam(team, t, squad, sq)
            end
        end
    end
    chooseShift(squad, sq)
end

local function onTick()
    if LF.tick % CFG.updateTicks ~= 0 then return end
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "squad" then LF.guard("tactics", updateSquad, u) end
    end
end

Events.OnTick.Add(onTick)

function LF.Tactics.forgetAll()
    squads, teams, shouts = {}, {}, {}
end
Events.OnInitGlobalModData.Add(function() LF.Tactics.forgetAll() end)
