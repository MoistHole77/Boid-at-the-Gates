-- Living Front: the NPC brain.
--
-- Every NPC with a body runs a perceive -> decide -> act loop:
--   perceive (on its think tick): the hostile NPCs it can actually see (LF_Sense), plus gunfire.
--              Squad soldiers share what they see with their squad (LF_Squad) and may
--              recognise enemy leaders.
--   decide   (on its think tick): pick a state
--              fighters (soldiers, armed civilians): badly hurt + threat -> flee (squad soldiers
--                fall back toward their squad's rear); threat -> engage, choosing a target the
--                squad isn't already shooting, preferring known leaders and exposed men;
--                no threat but the squad knows where the enemy is -> alert (take cover facing
--                it); otherwise idle (squad soldiers keep their formation slot)
--              unarmed civilians: threat or gunfire nearby -> flee; otherwise idle
--   act      (every tick for states that need it): engage steps combat; others act on think
-- Squad soldiers stay on a leash: positions they take are within CFG.leash of their slot.
-- The player is ignored (neutral) for now.
--
-- Minds are runtime-only (not saved): after a load or respawn an NPC simply re-evaluates.
-- Each NPC's step runs inside one guarded call, so one failing NPC can't stop the others and
-- no closures are allocated per tick.

require "LivingFront/LF_Core"
require "LivingFront/LF_Perf"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Combat"
require "LivingFront/LF_Cover"
require "LivingFront/LF_MoveAction"
require "LivingFront/LF_Posture"
require "LivingFront/LF_Sense"
require "LivingFront/LF_Units"
require "LivingFront/LF_Squad"
require "LivingFront/LF_Suppress"
require "LivingFront/LF_Tactics"

LF.Brain = LF.Brain or {}
LF.Brain.enabled = true

local CFG = {
    thinkTicks = 20,        -- each NPC re-decides about three times a second
    sightRange = 30,        -- tiles
    fireRange = 20,         -- fighters close in to this range before shooting
    fleeHealth = 35,        -- fighters flee below this overall health when threatened
    civFleeRange = 20,      -- unarmed civilians flee from hostiles within this range
    gunfireRange = 25,      -- unarmed civilians flee gunfire within this range
    fleeDistance = 12,      -- how far a fleeing NPC tries to get
    reissueTicks = 180,     -- re-path a flee/approach at most this often
    wanderChance = 4,       -- percent per think, when idle
    wanderRadius = 6,       -- tiles around home
    cleanupTicks = 60,      -- forget minds of vanished bodies this often
    coverSearchTicks = 120, -- look for a new firing position / hiding spot at most this often
    coverGiveUpTicks = 420, -- abandon a position not reached within this long (about 7 s)
    runApproachExtra = 8,   -- fighters run (not walk) toward a target further than fireRange + this
    -- Squads
    leash = 7,              -- squad soldiers take positions within this many tiles of their slot
    holdLeash = 4,          -- ... and within this of their spot while their unit has orders
    moveReissueTicks = 60,  -- a bounding soldier re-paths at most this often
    followDistance = 2.5,   -- idle squad soldiers walk back to their slot beyond this distance
    followReissueTicks = 90,
    rearDistance = 8,       -- the squad's rear is this far behind its leader
    contactMemory = 600,    -- a squad remembers where it last saw an enemy for this long (~10 s)
    claimPenalty = 6,       -- target choice: tiles added per squad mate already on that target
    leaderBonus = 8,        -- target choice: tiles taken off for a recognised enemy leader
    lowCoverPenalty = 5,    -- target choice: tiles added for a target behind low cover
    highCoverPenalty = 12,  --                 ... behind high cover
    stickyBonus = 4,        -- target choice: tiles taken off for the current target
    spotRange = 12,         -- enemy leaders closer than this are recognised faster
    spotChanceNear = 10,    -- percent per think to recognise a visible enemy leader (near)
    spotChanceFar = 4,      -- ... (far)
}
LF.Brain.CFG = CFG
LF.Units.woundedHealth = CFG.fleeHealth

local minds = {}   -- record id -> mind

local function mindOf(id)
    local m = minds[id]
    if not m then
        m = { state = "idle", combat = {}, lastPath = -10000 }
        minds[id] = m
    end
    return m
end
LF.Brain.mindOf = mindOf

LF.Brain.canSee = function(a, b) return LF.Sense.canSee(a, b) end

-- A last-known enemy position that cover and aiming code can treat like a body.
local GHOST = {}
GHOST.__index = GHOST
function GHOST:getX() return self.x end
function GHOST:getY() return self.y end
function GHOST:getZ() return self.z end
function GHOST:isDead() return false end
local function ghostOf(m, c)
    local g = m.ghost
    if not g then g = setmetatable({}, GHOST); m.ghost = g end
    g.x, g.y, g.z = c.x, c.y, c.z
    return g
end

local function title(rec) return LF.Units.title(rec) end

-- Gaits: "walk", "run" or "sprint" (LF_MoveAction). Running is off unless LF.Brain.running.
LF.Brain.running = true
local function moveAction(body, sq, gait)
    if not LF.Brain.running then gait = "walk" end
    return LF_MoveAction:new(body, sq, gait)
end

-- Walk (or run) to a free square near (x, y). Tries a few spots. Returns true if a move was queued.
function LF.Brain.walkNear(body, x, y, z, spread, gait)
    local cell = getCell()
    for _ = 1, 6 do
        local sq = cell:getGridSquare(math.floor(x + ZombRand(-spread, spread + 1)),
                                      math.floor(y + ZombRand(-spread, spread + 1)), math.floor(z))
        if sq and sq:isFree(false) then
            ISTimedActionQueue.clear(body)
            ISTimedActionQueue.add(moveAction(body, sq, gait))
            return true
        end
    end
    return false
end
local walkNear = LF.Brain.walkNear

-- Walk (or run) to an exact square.
function LF.Brain.walkTo(body, x, y, z, gait)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return false end
    ISTimedActionQueue.clear(body)
    ISTimedActionQueue.add(moveAction(body, sq, gait))
    return true
end
local walkTo = LF.Brain.walkTo

local function isAt(body, spot)
    return spot ~= nil and math.floor(body:getX()) == spot.x and math.floor(body:getY()) == spot.y
end

-- Drop any claimed position and stand up.
local function leavePosition(id, body, m)
    if m.cover or m.hide then LF.Cover.release(id) end
    m.cover, m.hide = nil, nil
    LF.Posture.set(body, false)
end

local function setState(id, body, rec, m, state, detail)
    if m.state == state then return end
    LF.log("BRAIN #" .. id .. " " .. title(rec) .. " [" .. rec.faction .. "] "
        .. m.state .. " -> " .. state .. (detail and (" (" .. detail .. ")") or ""))
    -- Losing and regaining sight (engage <-> alert) keeps the soldier's position and rhythm;
    -- any other change starts fresh.
    if (m.state == "engage" or m.state == "alert") and (state == "engage" or state == "alert") then
        m.state = state
        return
    end
    leavePosition(id, body, m)
    m.state = state
    m.combat = {}
    m.lastPath = -10000
end

-- Claim a spot and run to it (or settle if already there).
local function takeSpot(id, body, m, field, x, y, z, label, gait)
    m[field] = { x = x, y = y, z = z, since = LF.tick, gait = gait or "run" }
    LF.Cover.reserve(x, y, z, id)
    if isAt(body, m[field]) then
        LF.log("BRAIN #" .. id .. " " .. label .. " here (" .. x .. "," .. y .. ")")
    else
        walkTo(body, x, y, z, m[field].gait)
        m.lastPath = LF.tick
        LF.log("BRAIN #" .. id .. " " .. m[field].gait .. " to " .. label .. " at " .. x .. "," .. y)
    end
end

-- If the walk to a claimed spot was interrupted (a flinch clears the action queue), resume it.
local function resumeWalk(body, m, spot)
    if not isAt(body, spot) and not body:isPerformingAnAction() and LF.tick - m.lastPath > 60 then
        walkTo(body, spot.x, spot.y, spot.z, spot.gait)
        m.lastPath = LF.tick
    end
end

local function withinLeash(x, y, ax, ay, extra, leash)
    if not ax then return true end
    local r = (leash or CFG.leash) + (extra or 0)
    return LF.distSq(x + 0.5, y + 0.5, ax, ay) <= r * r
end

-- Fighters: keep or find a firing position behind low cover facing the threat (a body, or a
-- last-known position). Squad soldiers pass their slot (ax, ay): positions stay on the leash.
local function planCover(id, body, m, threat, ax, ay, leash)
    if m.cover then
        local q = LF.Cover.quality(m.cover.x, m.cover.y, m.cover.z, threat:getX(), threat:getY())
        local reached = isAt(body, m.cover)
        if q ~= LF.Cover.LOW or (not reached and LF.tick - m.cover.since > CFG.coverGiveUpTicks)
            or not withinLeash(m.cover.x, m.cover.y, ax, ay, 3, leash) then
            leavePosition(id, body, m)   -- threat moved around it, can't get there, or the squad moved on
        else
            resumeWalk(body, m, m.cover)
            return
        end
    end
    -- Already standing behind usable cover?
    local bx, by, bz = math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ())
    if withinLeash(bx, by, ax, ay, 0, leash) and LF.Cover.of(body, threat) == LF.Cover.LOW and LF.Brain.canSee(body, threat) then
        takeSpot(id, body, m, "cover", bx, by, bz, "cover")
        return
    end
    if LF.tick - (m.lastCoverSearch or -10000) < CFG.coverSearchTicks then return end
    m.lastCoverSearch = LF.tick
    local x, y, z = LF.Cover.findFiringPosition(id, body, threat, CFG.fireRange, ax, ay, ax and (leash or CFG.leash))
    if x then takeSpot(id, body, m, "cover", x, y, z, "cover") end
end

-- Wounded fighters: find somewhere out of the threat's sight before simply running.
-- (rx, ry): the squad's rear, preferred so the wounded stay near their own men.
local function planHide(id, body, m, threat, rx, ry)
    if m.hide then
        if isAt(body, m.hide) then return true end
        if LF.tick - m.hide.since <= CFG.coverGiveUpTicks then
            resumeWalk(body, m, m.hide)
            return true
        end
        leavePosition(id, body, m)
    end
    if LF.tick - (m.lastCoverSearch or -10000) < CFG.coverSearchTicks then return false end
    m.lastCoverSearch = LF.tick
    local x, y, z = LF.Cover.findHidingSpot(id, body, threat, rx, ry)
    if x then
        takeSpot(id, body, m, "hide", x, y, z, "hiding spot")
        return true
    end
    return false
end

-- Get directly away from a point (re-pathing at most every reissueTicks).
local function fleeFrom(m, body, fromX, fromY, gait)
    if LF.tick - m.lastPath <= CFG.reissueTicks then return end
    local dx, dy = body:getX() - fromX, body:getY() - fromY
    local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    if walkNear(body, body:getX() + dx / len * CFG.fleeDistance, body:getY() + dy / len * CFG.fleeDistance,
                body:getZ(), 2, gait) then
        m.lastPath = LF.tick
    end
end

-- Close in on a target, stopping inside firing range rather than walking onto it.
-- Far away: run; nearly in range: walk, rifle ready.
local function approach(m, body, target, dist)
    if LF.tick - m.lastPath <= CFG.reissueTicks then return end
    local dx, dy = body:getX() - target:getX(), body:getY() - target:getY()
    local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    local stop = CFG.fireRange - 5
    local gait = dist > CFG.fireRange + CFG.runApproachExtra and "run" or "walk"
    if walkNear(body, target:getX() + dx / len * stop, target:getY() + dy / len * stop, target:getZ(), 2, gait) then
        m.lastPath = LF.tick
    end
end

-- Is the body's current action a move (so it may be replaced by a new move)?
local function isMoving(body)
    local q = ISTimedActionQueue.getTimedActionQueue(body)
    local a = q and q.queue and q.queue[1]
    return a ~= nil and (a.Type == "LF_MoveAction" or a.Type == "ISWalkToTimedAction")
end

-- Squad soldiers: get back to the formation slot. Returns true when there.
local function followSlot(m, body, rec, sx, sy, sz)
    if not sx then return false end
    local d = LF.dist(body:getX(), body:getY(), sx, sy)
    if d <= CFG.followDistance then return true end
    if body:isPerformingAnAction() and not isMoving(body) then return false end   -- busy (shooting, flinching)
    if LF.tick - m.lastPath < CFG.followReissueTicks then return false end
    if walkNear(body, sx, sy, sz, 1, d > 10 and "run" or "walk") then m.lastPath = LF.tick end
    return false
end

-- Wounded squad soldiers with nowhere to hide: run back to the squad's rear.
local function fallBack(m, body, rx, ry, rz)
    if LF.tick - m.lastPath <= CFG.reissueTicks then return end
    if LF.dist(body:getX(), body:getY(), rx, ry) < 3 then return end
    if walkNear(body, rx, ry, rz, 2, "run") then m.lastPath = LF.tick end
end

-- How many of this soldier's squad mates are engaging that enemy.
local function claimCount(squadId, enemyId, selfId)
    local n = 0
    local members = LF.Units.members(squadId)
    for i = 1, #members do
        local rid = members[i]
        if rid ~= selfId then
            local mm = minds[rid]
            if mm and mm.state == "engage" and mm.targetId == enemyId then n = n + 1 end
        end
    end
    return n
end

-- Pick a target among the visible enemies: near, not already covered by squad mates, exposed
-- rather than behind cover, recognised leaders first. Lowest score wins.
local function chooseTarget(id, body, rec, m, visible)
    local best, bestScore = nil, nil
    for i = 1, #visible do
        local s = visible[i]
        local score = s.dist
        if rec.squad then
            score = score + CFG.claimPenalty * claimCount(rec.squad, s.id, id)
            if LF.Squad.knowsLeader(rec.squad, s.id) then score = score - CFG.leaderBonus end
        end
        local q = LF.Cover.of(s.body, body)
        if q == LF.Cover.HIGH then score = score + CFG.highCoverPenalty
        elseif q == LF.Cover.LOW then score = score + CFG.lowCoverPenalty end
        if s.id == m.targetId then score = score - CFG.stickyBonus end
        if not bestScore or score < bestScore then best, bestScore = s, score end
    end
    return best
end

-- Tell the squad what this soldier sees; maybe recognise an enemy leader.
local function shareSightings(id, rec, visible)
    for i = 1, #visible do
        local s = visible[i]
        LF.Squad.report(rec.squad, s.id, s.body)
        local rank = s.rec.rank
        if (rank == "SGT" or rank == "CPL") and not LF.Squad.knowsLeader(rec.squad, s.id) then
            local chance = s.dist < CFG.spotRange and CFG.spotChanceNear or CFG.spotChanceFar
            if ZombRand(100) < chance then
                LF.Squad.markLeader(rec.squad, s.id)
                LF.log("SPOTTED #" .. id .. " " .. title(rec) .. " recognised enemy leader #" .. s.id .. " "
                    .. title(s.rec) .. " at " .. math.floor(s.dist) .. " tiles")
            end
        end
    end
end

-- Does this soldier command his unit (its sergeant, or a lone team's corporal)?
local function isSquadLeader(id, rec)
    local squad = rec.squad and LF.Units.get(rec.squad)
    return squad ~= nil and LF.Units.commander(squad) == id
end

-- Bounding: run to the spot the corporal gave, re-pathing when the spot moves.
local function moveTo(m, body, x, y, z)
    if LF.dist(body:getX(), body:getY(), x, y) <= 1.5 then return true end
    if body:isPerformingAnAction() and not isMoving(body) then return false end   -- finishing a shot
    local moved = not m.dest or LF.dist(m.dest.x, m.dest.y, x, y) > 1.5
    if not moved and isMoving(body) then return false end
    if LF.tick - m.lastPath < CFG.moveReissueTicks and not moved then return false end
    if walkNear(body, x, y, z, 1, "run") then
        m.lastPath = LF.tick
        m.dest = m.dest or {}
        m.dest.x, m.dest.y = x, y
    end
    return false
end

local function decide(id, body, rec, m)
    m.order, m.point = nil, nil
    -- Fighters: soldiers, and civilians who are holding a gun (resistance).
    local fighter = rec.faction ~= "CIV" or LF.Combat.isArmed(body)
    m.fighter = fighter
    local inSquad = rec.squad ~= nil and LF.Units.get(rec.squad) ~= nil
    local leader = inSquad and isSquadLeader(id, rec)

    local visible = LF.Sense.look(id, body, rec, CFG.sightRange)
    if inSquad and #visible > 0 then shareSightings(id, rec, visible) end
    local pick = nil
    if #visible > 0 then pick = fighter and chooseTarget(id, body, rec, m, visible) or visible[1] end
    local threat, threatId, dist = nil, nil, nil
    if pick then threat, threatId, dist = pick.body, pick.id, pick.dist end
    local hp = LF.Combat.health(body)

    -- The slot this soldier is leashed to (none for the squad leader, who sets the pace).
    local ax, ay, az = nil, nil, nil
    if inSquad and not leader then ax, ay, az = LF.Squad.slot(rec) end

    if threat and ((not fighter and dist < CFG.civFleeRange) or (fighter and hp < CFG.fleeHealth)) then
        setState(id, body, rec, m, "flee", "threat #" .. threatId .. " at " .. math.floor(dist) .. " tiles, health " .. math.floor(hp))
        m.targetId = threatId
        -- A leader this badly hurt hands over command now instead of his men waiting on him.
        if fighter and inSquad and LF.Units.relieve(rec) then
            leader = false
            ax, ay, az = LF.Squad.slot(rec)
        end
        local rx, ry, rz = nil, nil, nil
        if inSquad then rx, ry, rz = LF.Squad.rear(rec, CFG.rearDistance) end
        if not (fighter and planHide(id, body, m, threat, rx, ry)) then
            if rx then
                fallBack(m, body, rx, ry, rz)
            else
                -- Civilians sprint for it; a wounded soldier runs (the engine turns an injured
                -- sprint into a run anyway).
                fleeFrom(m, body, threat:getX(), threat:getY(), fighter and "run" or "sprint")
            end
        end
        return
    end
    if not fighter then
        -- Unarmed civilians get away from any nearby gunfire, not just from enemies.
        local sx, sy, sd = LF.Combat.nearestRecentShot(body:getX(), body:getY(), CFG.gunfireRange)
        if sx then
            setState(id, body, rec, m, "flee", "gunfire " .. math.floor(sd) .. " tiles away")
            m.targetId = nil
            fleeFrom(m, body, sx, sy, "run")
            return
        end
    end
    if fighter and hp < CFG.fleeHealth and m.state == "flee" then
        -- Badly hurt and already hiding: stay down out of sight instead of rejoining the fight
        -- the moment the enemy drops out of view.
        if not (m.hide and isAt(body, m.hide)) and inSquad then
            local rx, ry, rz = LF.Squad.rear(rec, CFG.rearDistance)
            if rx and not m.hide then fallBack(m, body, rx, ry, rz) end
        end
        return
    end
    if fighter and inSquad then
        -- The unit has orders (LF_Tactics): go where the corporal or sergeant puts you.
        local role, sx, sy, sz, point = LF.Tactics.place(rec)
        if role then
            m.order, m.point = role, point
            local pinned = LF.Suppress.isPinned(body)
            if role == "move" and not pinned then
                setState(id, body, rec, m, "bound", "running to " .. math.floor(sx) .. "," .. math.floor(sy))
                if LF.Posture.crouched(body) then LF.Posture.set(body, false) end
                moveTo(m, body, sx, sy, sz)
                return
            end
            if pick and dist <= CFG.fireRange then
                if m.state ~= "engage" then
                    setState(id, body, rec, m, "engage", "target #" .. threatId .. " " .. title(pick.rec) .. " at "
                        .. math.floor(dist) .. " tiles")
                elseif m.targetId ~= threatId then
                    LF.log("BRAIN #" .. id .. " " .. title(rec) .. " switches target to #" .. threatId .. " "
                        .. title(pick.rec) .. " at " .. math.floor(dist) .. " tiles")
                end
                m.targetId, m.targetDist = threatId, dist
            else
                setState(id, body, rec, m, "alert", "covering " .. math.floor(point.x) .. "," .. math.floor(point.y))
                m.targetId = nil
            end
            planCover(id, body, m, pick and threat or point, sx, sy, CFG.holdLeash)
            if not m.cover and not pinned then followSlot(m, body, rec, sx, sy, sz) end
            return
        end
    end
    if threat and fighter then
        if m.state ~= "engage" then
            setState(id, body, rec, m, "engage", "target #" .. threatId .. " " .. title(pick.rec) .. " at "
                .. math.floor(dist) .. " tiles")
        elseif m.targetId ~= threatId then
            LF.log("BRAIN #" .. id .. " " .. title(rec) .. " switches target to #" .. threatId .. " "
                .. title(pick.rec) .. " at " .. math.floor(dist) .. " tiles")
        end
        m.targetId = threatId
        m.targetDist = dist
        planCover(id, body, m, threat, ax, ay)
        if not m.cover then
            if ax then
                followSlot(m, body, rec, ax, ay, az)      -- no cover near the slot: fight from the slot
            elseif dist > CFG.fireRange then
                approach(m, body, threat, dist)           -- squad leader (or a lone fighter) closes in
            end
        end
        return
    end
    if fighter and inSquad then
        -- Nothing in sight, but the squad knows where the enemy was: take cover facing it.
        local c = LF.Squad.bestContact(rec.squad, body:getX(), body:getY(), CFG.contactMemory, CFG.sightRange + 15)
        if c then
            setState(id, body, rec, m, "alert", "squad contact on #" .. c.id)
            m.targetId = nil
            local g = ghostOf(m, c)
            planCover(id, body, m, g, ax, ay)
            local placed = m.cover and isAt(body, m.cover)
            if not m.cover and ax then placed = followSlot(m, body, rec, ax, ay, az) end
            if not m.cover and leader then
                -- The squad leader closes in on the contact; his squad follows on its slots.
                local d = LF.dist(body:getX(), body:getY(), c.x, c.y)
                if d > CFG.fireRange - 2 then approach(m, body, g, d) end
            end
            if (placed or (not m.cover and not ax)) and not body:isPerformingAnAction() then
                LF.Combat.readyToFire(body, g)            -- rifle on the last-known position
            end
            return
        end
    end
    setState(id, body, rec, m, "idle")
    m.targetId = nil
    if inSquad then
        if ax then followSlot(m, body, rec, ax, ay, az) end   -- the leader holds; the squad keeps formation
        return
    end
    if not body:isPerformingAnAction() and ZombRand(100) < CFG.wanderChance then
        walkNear(body, rec.homeX, rec.homeY, rec.homeZ, CFG.wanderRadius, "walk")
    end
end

-- Crouch while holding a position, but only when not mid-action: the aim/fire actions play
-- standing clips, so a crouched soldier pops up to shoot and drops back down afterwards.
local function hunkerDown(body)
    if not body:isPerformingAnAction() and not LF.Posture.crouched(body) then LF.Posture.set(body, true) end
end

-- Per-tick behaviour for states that need it.
local function act(id, body, rec, m)
    local st = m.state
    -- Under fire, soldiers keep their heads down between shots (and pinned men stay down).
    if (st == "engage" or st == "alert") and LF.Suppress.isSuppressed(body) then hunkerDown(body) end
    if st == "alert" and m.point then
        -- Covering: area fire on where the enemy was last seen.
        if m.cover then
            if not isAt(body, m.cover) then return end
            hunkerDown(body)
        end
        local p = m.point
        if LF.distSq(body:getX(), body:getY(), p.x, p.y) <= (CFG.fireRange + 5) * (CFG.fireRange + 5) then
            LF.Combat.engageArea(body, p, m.combat)
        end
        return
    end
    if m.state == "engage" and m.targetId then
        if m.cover then
            if not isAt(body, m.cover) then return end   -- still moving into position
            hunkerDown(body)
        end
        local target = LF.Bodies.get(m.targetId)
        if target and not target:isDead()
            and LF.distSq(body:getX(), body:getY(), target:getX(), target:getY()) <= CFG.fireRange * CFG.fireRange then
            LF.Combat.engage(body, target, m.combat, m.combatOpts)
        end
    elseif m.state == "alert" and m.cover and isAt(body, m.cover) then
        hunkerDown(body)
    elseif m.state == "flee" and m.hide and isAt(body, m.hide) then
        hunkerDown(body)
    end
end

-- Extension points: later features hook in here without touching the loop.
LF.Brain.decide = decide
LF.Brain.act = act

local function stepNpc(id, body, rec)
    local m = mindOf(id)
    if (LF.tick + id) % CFG.thinkTicks == 0 then
        LF.Brain.decide(id, body, rec, m)
    end
    LF.Brain.act(id, body, rec, m)
end

local function onTick()
    if not LF.Brain.enabled then return end
    local t0 = LF.Perf.start()
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and not body:isDead() then
            LF.guard("brain step", stepNpc, id, body, rec)
        end
    end
    if LF.tick % CFG.cleanupTicks == 0 then
        for id in pairs(minds) do
            if not LF.Bodies.get(id) then
                LF.Cover.release(id)
                LF.Posture.forget(id)
                LF.Suppress.forget(id)
                minds[id] = nil
            end
        end
    end
    LF.Perf.stop("brain", t0)
end

function LF.Brain.toggle()
    LF.Brain.enabled = not LF.Brain.enabled
    LF.log("BRAIN enabled=" .. tostring(LF.Brain.enabled))
    LF.say("NPC brains " .. (LF.Brain.enabled and "ON" or "OFF"))
end

function LF.Brain.report()
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        local m = minds[id]
        if rec then
            local spot = m and (m.cover or m.hide)
            LF.log("BRAIN #" .. id .. " " .. title(rec) .. " [" .. rec.faction .. "]"
                .. (rec.squad and (" squad#" .. rec.squad .. (isSquadLeader(id, rec) and " (leader)" or "")) or "")
                .. " state="
                .. (m and m.state or "none") .. " target=" .. tostring(m and m.targetId)
                .. " position=" .. (spot and (spot.x .. "," .. spot.y .. (isAt(body, spot) and " (there)" or " (en route)")) or "none")
                .. " order=" .. tostring(m and m.order) .. " suppression=" .. math.floor(LF.Suppress.value(body))
                .. " crouched=" .. tostring(body:isSneaking())
                .. " running=" .. tostring(body:isRunning()) .. " sprinting=" .. tostring(body:isSprinting())
                .. " anim=" .. tostring(body:getCurrentActionContextStateName())
                .. " health=" .. math.floor(LF.Combat.health(body)) .. " dead=" .. tostring(body:isDead()))
        end
    end
    LF.say("Brain report written to log")
end

Events.OnTick.Add(onTick)
