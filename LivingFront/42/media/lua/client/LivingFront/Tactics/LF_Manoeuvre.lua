-- Living Front: tactics - manoeuvre. The fire team's drills (bounding, the pair covering the pair
-- that moves), moving to get a shot (reposition, flanking - the sergeant's and the corporal's), and
-- a corporal fighting his team on his own when his sergeant is out of earshot.

require "LivingFront/Tactics/LF_Tactics"

local I = LF.Tactics.I
local CFG, ELEMENT_NAME, OTHER, elementCentre, facing, fit = I.CFG, I.ELEMENT_NAME, I.OTHER, I.elementCentre, I.facing, I.fit
local squads, teams = I.squads, I.teams
local PLANS, bark = I.PLANS, I.bark

-- ---- corporal: drills -----------------------------------------------------------------------

-- Has the moving pair finished its bound? Every fit, unpinned man in it must have reached his
-- spot (or found he can't get there). If all its fit men are pinned, it waits; a pair with no
-- fit men left is done at once (the other pair carries on alone).
local function boundArrived(team, t, squad)
    if LF.tick - t.phaseStart > CFG.phaseTimeout then return true end
    local fx, fy = facing(squad)
    local p = t.pos[t.moving]
    local movers, pinned = 0, 0
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.team == team.id and r.element == t.moving and fit(r) then
            local b = LF.Bodies.get(rid)
            if b then
                if LF.Suppress.isPinned(b) and not (PLANS[t.order] and PLANS[t.order].pinnedMove) then     -- (falling back: pinned or not, 0.73.6)
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

-- Is the bound over? A rush lasts at least CFG.boundMin; then the pair gets down and fires for
-- CFG.boundSettle before the other pair goes ("I'm up - he sees me - I'm down"), so the bounds
-- have a steady rhythm instead of the pairs flicking back and forth.
local function boundDone(team, t, squad)
    if LF.tick - t.phaseStart < (t.boundMin or CFG.boundMin) then return false end
    if not t.settleAt then
        if not boundArrived(team, t, squad) then return false end
        t.settleAt = LF.tick
    end
    return LF.tick - t.settleAt >= CFG.boundSettle
end

-- Start a bound: element `el` moves (dx, dy) * bound past the covering pair, or onto
-- (tx, ty) if that is nearer.
local function startBound(team, t, el, dx, dy, tx, ty, contact, P)
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
    t.settleAt, t.boundMin = nil, nil
    local nx, ny = other.x + dx * len, other.y + dy * len
    if tx and LF.dist(other.x, other.y, tx, ty) <= len then nx, ny = tx, ty end
    -- Already (nearly) there: no rush - the pair just gets down, and the other goes next.
    if LF.dist(mine.x, mine.y, nx, ny) < 2 then t.boundMin, t.settleAt = 0, LF.tick end
    mine.x, mine.y = nx, ny
    -- (No orders shouted to a pair with nobody left in it to move.)
    local anyone = false
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.team == team.id and r.element == el and fit(r) and LF.Bodies.get(rid) then anyone = true end
    end
    if team.leader and anyone then
        LF.Tactics.shout(team.leader, bark((P or PLANS.ADVANCE).moveBark, { mover = ELEMENT_NAME[el], cover = ELEMENT_NAME[OTHER[el]] }))
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

-- Offsets tried for a new team position, in the frame from the team toward the enemy (forward,
-- out to the team's side): leaning forward and well out, so a team that keeps looking for a shot
-- works its way round the enemy rather than running back and forth on one spot.
local SHIFT_TRIES = { { 4, 8 }, { 6, 11 }, { 2, 12 }, { 8, 14 }, { 0, 15 }, { 3, 6 } }

-- Find a spot with a line of sight to the enemy and move the whole team there. A team keeps
-- working round the same side (first time: its outer side, away from the rest of the unit) and
-- never goes back to a spot it has already tried.
local function planShift(team, t, squad, sq)
    local cp = (t.alone and t.contact) or sq.contact
    if not cp then return false end
    local cx, cy = (t.pos.A.x + t.pos.B.x) / 2, (t.pos.A.y + t.pos.B.y) / 2
    local fx, fy = cp.x - cx, cp.y - cy
    local flen = math.max(0.1, math.sqrt(fx * fx + fy * fy))
    fx, fy = fx / flen, fy / flen
    local rx, ry = -fy, fx
    if not t.shiftSide then
        local sx, sy, n = 0, 0, 0
        for _, tid in ipairs(squad.teams) do
            local o = teams[tid]
            if o then sx, sy, n = sx + o.pos.A.x + o.pos.B.x, sy + o.pos.A.y + o.pos.B.y, n + 2 end
        end
        local out = n > 0 and ((cx - sx / n) * rx + (cy - sy / n) * ry) or 0
        if math.abs(out) < 1 then out = ZombRand(2) == 0 and -1 or 1 end
        t.shiftSide = out > 0 and 1 or -1
    end
    t.shiftHist = t.shiftHist or {}
    local z = cp.z or 0
    local cell = getCell()
    for pass = 1, 2 do
        local side = pass == 1 and t.shiftSide or -t.shiftSide
        for _, o in ipairs(SHIFT_TRIES) do
            local nx, ny = cx + fx * o[1] + rx * side * o[2], cy + fy * o[1] + ry * side * o[2]
            local tried = false
            for _, h in ipairs(t.shiftHist) do
                if LF.dist(h.x, h.y, nx, ny) < 4 then tried = true; break end
            end
            local sqr = not tried and cell:getGridSquare(math.floor(nx), math.floor(ny), z)
            if sqr and sqr:isFree(false) and LF.dist(nx, ny, cp.x, cp.y) >= CFG.advanceStop - 2
                and LF.Cover.canSeeFrom(math.floor(nx), math.floor(ny), z, cp) then
                t.shiftSide = side
                table.insert(t.shiftHist, { x = cx, y = cy })
                table.insert(t.shiftHist, { x = nx, y = ny })
                while #t.shiftHist > 6 do table.remove(t.shiftHist, 1) end
                local dx, dy = nx - cx, ny - cy
                t.pos.A.x, t.pos.A.y = t.pos.A.x + dx, t.pos.A.y + dy
                t.pos.B.x, t.pos.B.y = t.pos.B.x + dx, t.pos.B.y + dy
                t.shifting, t.moving, t.phaseStart = true, nil, LF.tick
                LF.log("REPOSITION " .. team.name .. " of " .. squad.name .. ": no open shot, moving "
                    .. math.floor(LF.dist(0, 0, dx, dy)) .. " tiles out and round to the "
                    .. (side > 0 and "right" or "left") .. " (" .. math.floor(nx) .. "," .. math.floor(ny) .. ")")
                if team.leader then LF.Tactics.shout(team.leader, PLANS.HOLD.shiftBark) end
                return true
            end
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
    if team.mg then return false, 0 end       -- (a gun team moves its gun itself - LF_MG)
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
    -- Whether or not the team found somewhere better, that was this unit's try for the next
    -- ~30 s (a failed try counts toward the stalemate flank too).
    planShift(pick, teams[pick.id], squad, sq)
    sq.lastShift = LF.tick
    sq.shiftsSinceFlank = (sq.shiftsSinceFlank or 0) + 1
end

-- ---- the drills: what a fire team does under each plan (LF.Tactics.PLANS, 0.75) ------------------
local DRILLS = {}

-- bound: the pairs leapfrog along the squad's front (P.dir), one moving while the other covers.
DRILLS.bound = function(team, t, squad, sq, order, P)
    local fx, fy = facing(squad)
    local dir = P.dir or 1
    local contact = P.toContact and ((t.alone and t.contact) or sq.contact) or nil
    if t.order ~= order then
        t.order = order
        startBound(team, t, "A", fx * dir, fy * dir, nil, nil, contact, P)
    elseif t.moving and boundDone(team, t, squad) then
        startBound(team, t, OTHER[t.moving], fx * dir, fy * dir, nil, nil, contact, P)
    end
end

-- route: the same leapfrog along the flank route the sergeant gave the team.
DRILLS.route = function(team, t, squad, sq, order, P)
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
                    if team.leader then LF.Tactics.shout(team.leader, P.pushBark) end
                end
            end
        end
        if not wp then
            t.order, t.moving, t.maneuverDone = "HOLD", nil, true
            if team.leader then LF.Tactics.shout(team.leader, P.doneBark) end
            return
        end
        local dx, dy, tx, ty = routeHeading(t)
        -- Leapfrog: the pair further from the waypoint moves past the nearer one.
        local el = t.moving and OTHER[t.moving]
        if not el then
            el = LF.dist(t.pos.A.x, t.pos.A.y, wp.x, wp.y) > LF.dist(t.pos.B.x, t.pos.B.y, wp.x, wp.y) and "A" or "B"
        end
        startBound(team, t, el, dx, dy, tx, ty, nil, P)
end

-- hold: both pairs where they are, in cover, firing (a team with no shot repositions - chooseShift).
DRILLS.hold = function(team, t, squad, sq, order, P)
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

-- gather (0.75): each pair runs to its place round the sergeant - a squad that has fallen back
-- comes together again before it fights on.
DRILLS.gather = function(team, t, squad, sq, order, P)
    if t.order ~= order then
        t.order, t.moving, t.gathered = order, nil, nil
        local fx, fy = facing(squad)
        for _, el in ipairs({ "A", "B" }) do
            local sx, sy, n = 0, 0, 0
            for _, rid in ipairs(team.members) do
                local r = LF.Records.get(rid)
                if r and r.alive and r.team == team.id and r.element == el then
                    local x, y = LF.Squad.slot(r)
                    if x then
                        local lat = LF.Units.slotLat(r)
                        sx, sy, n = sx + x + fy * lat, sy + y - fx * lat, n + 1     -- (the pair's middle: his slot less his place in it)
                    end
                end
            end
            if n > 0 and t.pos[el] then t.pos[el].x, t.pos[el].y = sx / n, sy / n end
        end
        t.shifting, t.phaseStart = true, LF.tick
        return
    end
    if t.shifting and shiftDone(team, t, squad) then
        t.shifting, t.gathered = nil, true
    end
end

local function driveTeam(team, t, squad, sq)
    local order = t.heard
    -- An order from the sergeant (anything but HOLD) overrides the corporal's own reposition.
    if order ~= "HOLD" and order ~= "REGROUP" then t.shifting = nil end
    local P = PLANS[order]
    local drill = P and P.drill and DRILLS[P.drill]
    if drill then drill(team, t, squad, sq, order, P) end
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
-- A flank on an enemy in a building: round it in an arc at a steady distance. From the team's
-- bearing to the building, each waypoint swings further round (35, 70, then ~95 degrees off),
-- closing to ~10 tiles from the building's side - never a long run out sideways. Each waypoint
-- is snapped to a free outdoor square. The side is chosen by what's in the way (walls, fences
-- and hedges to cross count heavily) and then by the cover at the final spot.
local ARC = { { 35, 1.0 }, { 70, 0.75 }, { 95, 0.0 } }    -- degrees round, share of the way in
local function freeOutdoor(x, y, z, bid)
    local cell = getCell()
    local bx, by = math.floor(x), math.floor(y)
    for r = 0, 3 do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local q = cell:getGridSquare(bx + dx, by + dy, z)
                    if q and q:isFree(false) and not q:getBuilding() then return bx + dx + 0.5, by + dy + 0.5 end
                end
            end
        end
    end
    return nil
end
local function arcFlank(squad, c, sq, alphas, L)
    local z = c.z or 0
    local ox, oy = L.cx, L.cy
    local best, bestScore, bestRoutes = nil, -math.huge, nil
    for _, side in ipairs({ -1, 1 }) do
        local routes, score = {}, 0
        for k, team in ipairs(alphas) do
            local t = teams[team.id]
            local cx, cy = (t.pos.A.x + t.pos.B.x) / 2, (t.pos.A.y + t.pos.B.y) / 2
            local r0 = math.max(12, math.min(30, LF.dist(cx, cy, ox, oy)))
            local rEnd = 10 + (k - 1) * 2                 -- the second team stays a little wider
            local b0 = math.atan2(cy - oy, cx - ox)
            local route, px, py = {}, cx, cy
            for _, a in ipairs(ARC) do
                local ang = b0 + side * math.rad(a[1] + (k - 1) * 10)
                local rad = rEnd + (r0 - rEnd) * a[2]
                local wx, wy = freeOutdoor(ox + math.cos(ang) * rad, oy + math.sin(ang) * rad, z)
                if not wx then score = score - 20; break end
                score = score - 6 * LF.Cover.crossings(px, py, wx, wy, z, 3)
                route[#route + 1] = { x = wx, y = wy }
                px, py = wx, wy
            end
            if #route > 0 then score = score + coverAround(px, py, z, ox, oy) * 0.5 end
            routes[team.id] = route
        end
        if score > bestScore then best, bestScore, bestRoutes = side, score, routes end
    end
    return best, bestScore, bestRoutes
end

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
            -- (Gun teams never go round: a machine-gun squad is a base of fire.)
            if team.element == "A" and not team.mg and cpl and fit(cpl) and not t.clear then alphas[#alphas + 1] = team end
        end
    end
    if #alphas == 0 or n == 0 then return nil end
    sx, sy = sx / n, sy / n
    local z = c.z or 0
    -- The enemy is in a building: round it in an arc.
    local L = LF.Building.idAt(c.x, c.y, z) and LF.Building.at(c.x, c.y, z)
    if L then
        local side, score, routes = arcFlank(squad, c, sq, alphas, L)
        if side and routes then
            local plan = { side = side, started = LF.tick, routes = {}, teams = {} }
            for _, team in ipairs(alphas) do
                if routes[team.id] and #routes[team.id] > 0 then
                    local t = teams[team.id]
                    plan.routes[team.id] = routes[team.id]
                    plan.teams[#plan.teams + 1] = team.id
                    t.maneuverDone, t.pushes, t.side = nil, 0, side
                end
            end
            if #plan.teams > 0 then
                sq.flankCount = (sq.flankCount or 0) + 1
                LF.log("FLANK " .. squad.name .. " going " .. (side < 0 and "left" or "right") .. " round the building with "
                    .. #plan.teams .. " alpha team(s); route score " .. math.floor(score) .. ", flank #" .. sq.flankCount)
                return plan
            end
        end
    end
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
            { x = cx + rx * side * CFG.flankOut + fx * CFG.flankLean, y = cy + ry * side * CFG.flankOut + fy * CFG.flankLean },
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

-- Is one of the squad's teams clearing a building (no new flank while they're going in)?
local function clearing(squad)
    for _, tid in ipairs(squad.teams) do
        if teams[tid] and teams[tid].clear then return true end
    end
    return false
end

-- What a team should do under the squad's intent.
-- A "hold" is for teams already in rifle range: a team still out of range (the rear of a column
-- that met the enemy, say) keeps bounding forward until it is, instead of sheltering far back.
local function teamFront(team, sq)
    local t, c = teams[team.id], sq.contact
    if not (t and c and t.pos) then return 0 end
    local f = math.huge
    for _, p in pairs(t.pos) do
        local d = LF.dist(p.x, p.y, c.x, c.y)
        if d < f then f = d end
    end
    return f
end
local function closeUp(team, sq)
    if sq.broken then return false end
    local t = teams[team.id]
    local f = teamFront(team, sq)
    return f > CFG.advanceResume or (t ~= nil and t.heard == "ADVANCE" and f > CFG.advanceStop)
end

local function orderFor(team, sq)
    if sq.intent == "FLANK" then
        if sq.flank and sq.flank.routes[team.id] then return "MANEUVER" end
        return closeUp(team, sq) and "ADVANCE" or "HOLD"
    end
    if sq.intent == "HOLD" and closeUp(team, sq) then return "ADVANCE" end
    return sq.intent
end

-- ---- corporal on his own ----------------------------------------------------------------------
--
-- A corporal out of earshot of his commander (or with no commander here) runs his team himself:
-- advance into rifle range, hold there, fall back when the team is shot up - the same rules his
-- sergeant uses, applied to his team. A maneuver already under way is finished first.


local function corporalAlone(team, t, squad, sq)
    local cpl = LF.Bodies.get(team.leader)
    local c = LF.Squad.bestContact(squad.id, cpl:getX(), cpl:getY(), CFG.contactMemory, CFG.contactRange)
    if not c then return end                     -- nothing known: carry on with the last order
    t.contact = t.contact or LF.Tactics.point(0, 0, 0)
    t.contact.x, t.contact.y, t.contact.z = c.x, c.y, c.z
    local total, fitN, pinnedN = 0, 0, 0
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.team == team.id then
            total = total + 1
            if fit(r) then
                fitN = fitN + 1
                local b = LF.Bodies.get(rid)
                if b and LF.Suppress.isPinned(b) then pinnedN = pinnedN + 1 end
            end
        end
    end
    local front = math.min(LF.dist(t.pos.A.x, t.pos.A.y, c.x, c.y), LF.dist(t.pos.B.x, t.pos.B.y, c.x, c.y))
    local cur = t.heard
    local want = cur
    if cur == "MANEUVER" and not t.maneuverDone then
        want = cur
    elseif total > 0 and fitN / total < CFG.fallbackFit then
        want = front < CFG.fallbackClear and "FALLBACK" or "HOLD"
    elseif fitN > 0 and pinnedN / fitN >= CFG.pinnedHold then
        want = "HOLD"
    elseif cur == "ADVANCE" and front <= CFG.advanceStop then
        want = "HOLD"
    elseif cur ~= "ADVANCE" and front > CFG.advanceResume then
        want = "ADVANCE"
    elseif cur ~= "HOLD" and cur ~= "ADVANCE" then
        want = "HOLD"
    end
    if want ~= cur then
        LF.log("CORPORAL " .. team.name .. " of " .. squad.name .. " on his own: " .. tostring(cur) .. " -> " .. want
            .. " (enemy at " .. math.floor(front) .. " tiles, " .. fitN .. "/" .. total .. " fit)")
        LF.Tactics.shout(team.leader, (PLANS[want] and PLANS[want].aloneBark) or PLANS.HOLD.aloneBark)
        t.heard = want
    end
end

-- Team positions start from where the men stand when the fight begins.
local function initTeams(squad)
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
end

-- Corporals within earshot of the commander take up his intent; the others decide for
-- themselves. Then each runs his drill. cmd may be nil (no commander here).
local function passOrders(squad, sq, cmd)
    for _, tid in ipairs(squad.teams) do
        local team = LF.Units.get(tid)
        local t = teams[tid]
        if team and t then
            local cpl = team.leader and LF.Bodies.get(team.leader)
            if t.clear or t.inside then
                -- busy clearing a building, or holding the part of it it has cleared (on its own)
            elseif cpl and not cpl:isDead() then
                -- (A corporal on his own comes back under his commander only well inside earshot, and
                -- goes it alone only well outside it - on the edge, 0.43 flipped every second or two.)
                local d = cmd and LF.dist(cpl:getX(), cpl:getY(), cmd:getX(), cmd:getY())
                if cmd and sq.intent and d <= CFG.earshot - (t.alone and 4 or -4) then
                    if t.alone then LF.log("CORPORAL " .. team.name .. " of " .. squad.name .. " back under his commander") end
                    t.heard, t.alone = orderFor(team, sq), nil
                else
                    if not t.alone then
                        LF.log("CORPORAL " .. team.name .. " of " .. squad.name .. " has no commander in earshot; acting on his own")
                    end
                    t.alone = true
                    corporalAlone(team, t, squad, sq)
                end
                if team.mg and LF.MG then LF.MG.driveTeam(team, t, squad, sq) else driveTeam(team, t, squad, sq) end
            end
        end
    end
end

-- ---- shared with the other tactics files ----------------------------------------------------
I.chooseShift = chooseShift I.clearing = clearing I.enemySuppression = enemySuppression I.initTeams = initTeams I.otherSideFlanking = otherSideFlanking
I.passOrders = passOrders I.planFlank = planFlank I.stalemate = stalemate
