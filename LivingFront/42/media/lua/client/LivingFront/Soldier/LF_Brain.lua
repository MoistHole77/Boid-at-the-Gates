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

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Perf"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Soldier/LF_Combat"
require "LivingFront/World/LF_Cover"
require "LivingFront/Soldier/LF_MoveAction"
require "LivingFront/Soldier/LF_Posture"
require "LivingFront/World/LF_Sense"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Squad"
require "LivingFront/Soldier/LF_Suppress"
require "LivingFront/Tactics/LF_Command"
require "LivingFront/Soldier/LF_Aid"
require "LivingFront/Soldier/LF_Weapons"
require "LivingFront/Units/LF_Stance"
require "LivingFront/World/LF_Building"
require "LivingFront/Tactics/LF_SquadBrain"

LF.Brain = LF.Brain or {}
LF.Brain.enabled = true

local CFG = {
    thinkTicks = 20,        -- each NPC re-decides about three times a second
    quietThinkTicks = 60,   -- (0.75) ... once a second when idle or watching a quiet quarter, his squad seeing nobody
    actTicks = 3,           -- (0.75) his per-tick steps (aim, fire, crouch) every 3rd tick - 20 a second, plenty for a rifle
    -- Level of detail (0.76): the further a man is from you, the less often he steps and thinks.
    lodNear = 30,           -- within this (tiles): every 3rd tick, thinking 3 times a second
    lodFar = 45,            -- within this: every 6th tick, thinking every 2/3 s; beyond: every 9th, once a second
    sightRange = 30,        -- tiles
    fireRange = 20,         -- fighters close in to this range before shooting
    fleeHealth = 35,        -- fighters flee below this overall health when threatened
    corneredRange = 6,      -- ... but fight back from where they are when the enemy is this close
    woundedLeftBehind = 15, -- a wounded man hiding this far from his unit's rear goes back to it
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
    quietRest = 3600,       -- a man off the windows in a held building rests after ~60 s with no enemy known
    holdLeash = 4,          -- ... and within this of their spot while their unit has orders
    commandLeash = 7,       -- the sergeant looks this far from his spot for cover (his teams don't move)
    moveReissueTicks = 60,  -- a bounding soldier re-paths at most this often
    bearingsLeash = 5,      -- opening seconds of a fight: take the nearest cover within this many tiles
    stuckLeash = 7,         -- can't reach his spot: take the nearest cover within this many tiles
    blindTicks = 480,       -- holding this long (~8 s) without an enemy in his sights = no open shot
    followDistance = 2.5,   -- idle squad soldiers walk back to their slot beyond this distance
    followReissueTicks = 90,
    rearDistance = 8,       -- the squad's rear is this far behind its leader
    contactMemory = 600,    -- a squad remembers where it last saw an enemy for this long (~10 s)
    claimPenalty = 6,       -- target choice: tiles added per squad mate already on that target
    leaderBonus = 8,        -- target choice: tiles taken off for a recognised enemy leader
    lowCoverPenalty = 5,    -- target choice: tiles added for a target behind low cover
    highCoverPenalty = 12,  --                 ... behind high cover
    stickyBonus = 4,        -- target choice: tiles taken off for the current target
    clearFireRange = 10,    -- clearing a building, going in: stop and shoot at an enemy this close
    stackFireRange = 5,     -- ... on the way to the stack: only this close (the other teams cover)
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
local function moveAction(body, sq, gait, awayX, awayY)
    if not LF.Brain.running then gait = "walk" end
    return LF_MoveAction:new(body, sq, gait, awayX, awayY)
end

-- ---- claimed squares -----------------------------------------------------------------------------
-- Each soldier claims the square he is heading for (or standing on). Exact spots - a window, a
-- place in the stack, his place in a file, a cover position - are "hard" claims: he gets it, and
-- a man loitering there makes way. Loose spots (keeping near his slot, a bound, falling back) are
-- "soft": a man picking one avoids every square someone else has claimed, so two men don't head
-- for the same square and end up running into each other.
local claims = {}           -- record id -> { k = "x,y,z", hard = bool }

local function claimKey(x, y, z) return math.floor(x) .. "," .. math.floor(y) .. "," .. math.floor(z) end

local function idOfBody(body) return body:getModData().LF_id end

local function claimedByOther(k, myId, hardOnly)
    for id, c in pairs(claims) do
        if id ~= myId and c.k == k and (c.hard or not hardOnly) then
            if LF.Bodies.get(id) then return id end
            claims[id] = nil                        -- (he's gone)
        end
    end
    return nil
end

local function claim(body, sq, hard)
    local id = idOfBody(body)
    if id then claims[id] = { k = claimKey(sq:getX(), sq:getY(), sq:getZ()), hard = hard } end
end
function LF.Brain.unclaim(id) claims[id] = nil end

-- Is (x, y, z) someone else's exact spot? (A man standing there should make way.)
function LF.Brain.hardClaimed(x, y, z, myId) return claimedByOther(claimKey(x, y, z), myId, true) ~= nil end

-- Walk (or run) to a free square near (x, y) that nobody else has claimed. Tries a few spots.
-- Returns true if a move was queued.
-- awayX, awayY: this is a retreat from that point (abandoned if the route heads toward it).
function LF.Brain.walkNear(body, x, y, z, spread, gait, awayX, awayY)
    -- Sitting: get up first (the walk is asked for again next time).
    if LF.Idle and LF.Idle.standUp(body) then return false end
    local cell = getCell()
    local myId = idOfBody(body)
    local bx, by, bz = body:getX(), body:getY(), math.floor(body:getZ())
    -- Best: free, nobody else's, and no fence or wall between him and it (so he walks, not hops).
    -- Then: free and nobody else's (over a fence if he must). Last: just free.
    local fallback, overFence = nil, nil
    for i = 1, 10 do
        local r = i <= 6 and spread or spread + 1             -- a little wider if it's crowded
        local sq = cell:getGridSquare(math.floor(x + ZombRand(-r, r + 1)),
                                      math.floor(y + ZombRand(-r, r + 1)), math.floor(z))
        if sq and sq:isFree(false) then
            if not claimedByOther(claimKey(sq:getX(), sq:getY(), sq:getZ()), myId, false) then
                local clear = math.floor(z) ~= bz or LF.Cover.crossings(bx, by, sq:getX(), sq:getY(), bz, 1) == 0
                if clear then
                    ISTimedActionQueue.clear(body)
                    ISTimedActionQueue.add(moveAction(body, sq, gait, awayX, awayY))
                    claim(body, sq, false)
                    return true
                end
                overFence = overFence or sq
            end
            fallback = fallback or sq
        end
    end
    fallback = overFence or fallback
    if fallback then
        ISTimedActionQueue.clear(body)
        ISTimedActionQueue.add(moveAction(body, fallback, gait, awayX, awayY))
        claim(body, fallback, false)
        return true
    end
    return false
end
local walkNear = LF.Brain.walkNear

-- Walk (or run) to an exact square (his own spot: a hard claim).
function LF.Brain.walkTo(body, x, y, z, gait, awayX, awayY)
    if LF.Idle and LF.Idle.standUp(body) then return false end
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return false end
    ISTimedActionQueue.clear(body)
    ISTimedActionQueue.add(moveAction(body, sq, gait, awayX, awayY))
    claim(body, sq, true)
    return true
end
local walkTo = LF.Brain.walkTo

local function isAt(body, spot)
    return spot ~= nil and math.floor(body:getX()) == spot.x and math.floor(body:getY()) == spot.y
end
-- On his spot - for a machine gun's, close enough to it (a man jostled half a tile off it by the
-- man beside him is still on the gun).
local function onSpot(body, spot)
    if spot and spot.gun and LF.MG then
        return LF.distSq(body:getX(), body:getY(), spot.x + 0.5, spot.y + 0.5) <= LF.MG.CFG.atGun * LF.MG.CFG.atGun
    end
    return isAt(body, spot)
end

-- Drop any claimed position and stand up.
local function leavePosition(id, body, m)
    if m.cover or m.hide then LF.Cover.release(id) end
    m.cover, m.hide = nil, nil
    LF.Posture.set(body, false)
end

-- Posts whose men may rest when it has been quiet for a while (not windows or doors).
local REST_POSTS = { back = true, reserve = true, centre = true, watch = true }

-- States between which a soldier keeps his position (seeing / covering / watching).
local KEEP_POSITION = { engage = true, alert = true, guard = true, assist = true }

local function setState(id, body, rec, m, state, detail)
    if m.state == state then return end
    m.detail = detail
    -- (0.78 reaction test) The first man of his squad to start moving after a movement order.
    if state == "bound" and rec.squad and LF.Brain.onMoveStart then LF.Brain.onMoveStart(rec.squad) end
    -- Out of his rest (an enemy, an order): he gets up and takes his rifle back.
    if m.rest and LF.Idle then LF.guard("end rest", LF.Idle.stop, body, m) end
    if LF.Config.logVerbose then
        LF.log("BRAIN #" .. id .. " " .. title(rec) .. " [" .. rec.faction .. "] "
            .. m.state .. " -> " .. state .. (detail and (" (" .. detail .. ")") or ""))
    end
    -- Losing and regaining sight (engage <-> alert <-> guard) keeps the soldier's position and rhythm;
    -- any other change starts fresh.
    if KEEP_POSITION[m.state] and KEEP_POSITION[state] then
        m.state = state
        return
    end
    leavePosition(id, body, m)
    m.state = state
    m.combat = {}
    m.lastPath = -10000
    m.atRear, m.safeLogged = nil, nil
end

-- Claim a spot and run to it (or settle if already there).
local function takeSpot(id, body, m, field, x, y, z, label, gait, awayX, awayY)
    m[field] = { x = x, y = y, z = z, since = LF.tick, gait = gait or "run", awayX = awayX, awayY = awayY }
    LF.Cover.reserve(x, y, z, id)
    if isAt(body, m[field]) then
        if LF.Config.logVerbose then LF.log("BRAIN #" .. id .. " " .. label .. " here (" .. x .. "," .. y .. ")") end
    else
        walkTo(body, x, y, z, m[field].gait, awayX, awayY)
        m.lastPath = LF.tick
        if LF.Config.logVerbose then LF.log("BRAIN #" .. id .. " " .. m[field].gait .. " to " .. label .. " at " .. x .. "," .. y) end
    end
end

-- If the walk to a claimed spot was interrupted (a flinch clears the action queue), resume it.
local function resumeWalk(body, m, spot)
    if not isAt(body, spot) and not body:isPerformingAnAction() and LF.tick - m.lastPath > 60 then
        walkTo(body, spot.x, spot.y, spot.z, spot.gait, spot.awayX, spot.awayY)
        m.lastPath = LF.tick
    end
end

-- ---- unreachable spots ------------------------------------------------------------------
-- When the game can't find a path to a spot (a locked gate, a wall), the soldier remembers it
-- for a while and fights from where he is instead of retrying forever.
local STUCK_TICKS = 900

LF.Move = LF.Move or {}
function LF.Move.onFailed(body, x, y)
    local id = body:getModData().LF_id
    local m = id and minds[id]
    if not m then return end
    if not (m.stuck and LF.dist(m.stuck.x, m.stuck.y, x, y) < 1) then
        LF.log("BRAIN #" .. id .. " can't reach " .. math.floor(x) .. "," .. math.floor(y) .. "; taking the nearest cover instead")
    end
    m.stuck = { x = x, y = y, tick = LF.tick, fromX = body:getX(), fromY = body:getY() }
    -- Nobody picks that square as cover for a while, and this soldier looks for cover now.
    LF.Cover.reserve(math.floor(x), math.floor(y), math.floor(body:getZ()), -1)
    m.lastCoverSearch = nil
end

-- Has this soldier recently failed to reach a spot near (x, y)?
local function stuckNear(m, x, y)
    local st = m.stuck
    return st ~= nil and LF.tick - st.tick < STUCK_TICKS and LF.dist(st.x, st.y, x, y) < 3
end
-- Is this soldier holding a position without an open shot (no enemy in his own sights within
-- rifle range for a while)? Used by corporals to decide to move the team.
function LF.Brain.isBlind(id)
    local m = minds[id]
    if not (m and m.order == "hold" and (m.state == "alert" or m.state == "engage")) then return false end
    if not m.holdingSince then return false end
    return LF.tick - math.max(m.lastSight or -100000, m.holdingSince) > CFG.blindTicks
end

function LF.Brain.isStuck(id, x, y)
    local m = minds[id]
    return m ~= nil and stuckNear(m, x, y)
end

-- Where to take cover: a squad soldier is given his spot by his squad's placement (LF_SquadBrain,
-- 0.74); anyone else still looks for himself.
local function firingSpotOf(id, body, threat, maxRange, ax, ay, leash, loose)
    local rec = LF.Records.get(id)
    if rec and rec.squad and LF.SquadBrain.enabled and LF.Units.get(rec.squad) then
        return LF.SquadBrain.spotFor(id, body, rec, threat, maxRange, ax, ay, leash, loose)
    end
    return LF.Cover.findFiringPosition(id, body, threat, maxRange, ax, ay, leash, loose)
end
local function firingSpot(id, body, threat, maxRange, ax, ay, leash, loose)
    local t0 = getTimestampMs()
    local x, y, z, q = firingSpotOf(id, body, threat, maxRange, ax, ay, leash, loose)
    LF.Perf.stop("brain cover", t0)
    return x, y, z, q
end

local function withinLeash(x, y, ax, ay, extra, leash)
    if not ax then return true end
    local r = (leash or CFG.leash) + (extra or 0)
    return LF.distSq(x + 0.5, y + 0.5, ax, ay) <= r * r
end

-- Fighters: keep or find a firing position behind low cover facing the threat (a body, or a
-- last-known position). Squad soldiers pass their slot (ax, ay): positions stay on the leash.
-- sticky (defensive stance): keep a cover spot as long as it gives any cover at all, don't keep
-- hunting for a better one, and look for shelter only close to the spot.
local planCoverOf
local function planCover(id, body, m, threat, ax, ay, leash, sticky)
    local t0 = getTimestampMs()
    planCoverOf(id, body, m, threat, ax, ay, leash, sticky)
    LF.Perf.stop("brain plancover", t0)
end
planCoverOf = function(id, body, m, threat, ax, ay, leash, sticky)
    if m.cover then
        local q = LF.Cover.quality(m.cover.x, m.cover.y, m.cover.z, threat:getX(), threat:getY())
        local reached = isAt(body, m.cover)
        local usable = q == LF.Cover.LOW or ((m.cover.loose or sticky) and q ~= LF.Cover.NONE)
        if m.cover.loose and not sticky and reached and LF.tick - (m.lastCoverSearch or -10000) >= CFG.coverSearchTicks then
            -- Sheltering without a shot: keep looking for a real firing position.
            m.lastCoverSearch = LF.tick
            local x, y, z = firingSpot(id, body, threat, CFG.fireRange, ax, ay, ax and (leash or CFG.leash))
            if x then
                leavePosition(id, body, m)
                takeSpot(id, body, m, "cover", x, y, z, "firing position")
                return
            end
        end
        if not usable or (not reached and LF.tick - m.cover.since > CFG.coverGiveUpTicks)
            or (not reached and stuckNear(m, m.cover.x + 0.5, m.cover.y + 0.5))
            or not withinLeash(m.cover.x, m.cover.y, ax, ay, reached and 3 or 6, leash) then
            leavePosition(id, body, m)   -- threat moved around it, can't get there, or the squad moved on
        else
            LF.Cover.reserve(m.cover.x, m.cover.y, m.cover.z, id)   -- keep the claim while holding it
            resumeWalk(body, m, m.cover)
            return
        end
    end
    -- Already standing behind usable cover?
    -- (Only on the search beat: up to 0.74 the sight check here ran every think for every man
    -- without cover - 0.75.)
    if LF.tick - (m.lastCoverSearch or -10000) < CFG.coverSearchTicks then return end
    m.lastCoverSearch = LF.tick
    local bx, by, bz = math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ())
    if withinLeash(bx, by, ax, ay, 0, leash) and LF.Cover.of(body, threat) == LF.Cover.LOW and LF.Brain.canSee(body, threat) then
        takeSpot(id, body, m, "cover", bx, by, bz, "cover")
        return
    end
    local x, y, z = firingSpot(id, body, threat, CFG.fireRange, ax, ay, ax and (leash or CFG.leash))
    if x then takeSpot(id, body, m, "cover", x, y, z, "cover"); return end
    -- No firing position: at least get out of the open (any cover, a little further out).
    x, y, z = firingSpot(id, body, threat, CFG.sightRange + 10, ax, ay,
        ax and ((leash or CFG.leash) + (sticky and 1 or 3)), true)
    if x then
        takeSpot(id, body, m, "cover", x, y, z, "shelter")
        m.cover.loose = true
    end
end

-- Wounded fighters: find somewhere out of the threat's sight before simply running.
-- (rx, ry): the squad's rear, preferred so the wounded stay near their own men.
local function planHide(id, body, m, threat, rx, ry, others)
    if m.hide then
        if isAt(body, m.hide) then return true end
        if LF.tick - m.hide.since <= CFG.coverGiveUpTicks and not stuckNear(m, m.hide.x + 0.5, m.hide.y + 0.5) then
            resumeWalk(body, m, m.hide)
            return true
        end
        leavePosition(id, body, m)
    end
    if LF.tick - (m.lastCoverSearch or -10000) < CFG.coverSearchTicks then return false end
    m.lastCoverSearch = LF.tick
    local x, y, z = LF.Cover.findHidingSpot(id, body, threat, rx, ry, others)
    if x then
        takeSpot(id, body, m, "hide", x, y, z, "hiding spot", "run", threat:getX(), threat:getY())
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
                body:getZ(), 2, gait, fromX, fromY) then
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
    -- Standing on another man's spot (his window, his place in the stack): make way.
    if not isMoving(body) and LF.tick - m.lastPath > 60
        and LF.Brain.hardClaimed(body:getX(), body:getY(), body:getZ(), rec.id) then
        if walkNear(body, sx, sy, sz, 2, "walk") then m.lastPath = LF.tick end
        return false
    end
    if d <= CFG.followDistance or stuckNear(m, sx, sy) then return true end
    if body:isPerformingAnAction() and not isMoving(body) then return false end   -- busy (shooting, flinching)
    if LF.tick - m.lastPath < CFG.followReissueTicks then return false end
    if walkNear(body, sx, sy, sz, 1, d > 10 and "run" or "walk") then m.lastPath = LF.tick end
    return false
end

-- Wounded squad soldiers with nowhere to hide: run back to the squad's rear. If the way back is
-- blocked (or only leads past the enemy), stay down where he is instead.
local function fallBack(m, body, rx, ry, rz, threat)
    if LF.dist(body:getX(), body:getY(), rx, ry) < 3 or stuckNear(m, rx, ry) then m.atRear = true; return end
    if LF.tick - m.lastPath <= CFG.reissueTicks then return end
    local tx, ty = nil, nil
    if threat then tx, ty = threat:getX(), threat:getY() end
    if walkNear(body, rx, ry, rz, 2, "run", tx, ty) then m.lastPath = LF.tick end
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
    -- (0.78) The target his sergeant gave him, if he can see it and it isn't behind a wall from here.
    local given = rec.squad and LF.SquadBrain.enabled and LF.SquadBrain.targetOf(rec.squad, id)
    if given then
        for i = 1, #visible do
            local s = visible[i]
            if s.id == given then
                if not (LF.Cover.of(s.body, body) == LF.Cover.HIGH and s.dist > 2) then return s end
                break
            end
        end
    end
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
        -- (Behind a wall from here - the sight line only grazes a corner: not a target. Up to
        -- 0.46 a man could spend half a minute firing into the wall in front of one.)
        if q == LF.Cover.HIGH and s.dist > 2 then score = math.huge end
        -- A machine gun firing on us: its crew first.
        if LF.MG and LF.MG.isFiring(s.id) then score = score - LF.MG.CFG.gunBonus end
        if score < math.huge and (not bestScore or score < bestScore) then best, bestScore = s, score end
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
    if LF.dist(body:getX(), body:getY(), x, y) <= 1.5 or stuckNear(m, x, y) then return true end
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

-- Defensive stance: hold his place in the perimeter (LF_Tactics.perimeterPlace). He gets into
-- cover facing out of his quarter and stays there; he fires at any enemy he sees, covers enemies
-- in his own arc and otherwise watches it. With the enemy in his arc but no shot for a while, he
-- may shift to another covered square close by in his quarter (rarely).
local function holdSector(id, body, rec, m, sx, sy, sz, point, watching, coverPoint, pick, threat, threatId, dist)
    local st = LF.Stance.of(rec)
    if m.prevOrder ~= "sector" or not m.sectorSince then m.sectorSince = LF.tick end
    m.order, m.point = "sector", point
    if pick and dist <= CFG.fireRange then
        if m.state ~= "engage" then
            setState(id, body, rec, m, "engage", "target #" .. threatId .. " " .. title(pick.rec) .. " at "
                .. math.floor(dist) .. " tiles")
        elseif m.targetId ~= threatId then
            if LF.Config.logVerbose then LF.log("BRAIN #" .. id .. " " .. title(rec) .. " switches target to #" .. threatId .. " "
                .. title(pick.rec) .. " at " .. math.floor(dist) .. " tiles") end
        end
        m.targetId, m.targetDist = threatId, dist
    elseif watching then
        setState(id, body, rec, m, "guard", "watching his quarter toward " .. math.floor(point.x) .. "," .. math.floor(point.y))
        m.targetId = nil
    else
        setState(id, body, rec, m, "alert", "covering " .. math.floor(point.x) .. "," .. math.floor(point.y))
        m.targetId = nil
    end
    -- Cover against the enemy (or out of his quarter when none is known). The sergeant, having
    -- called the defence, looks further afield for cover; the perimeter stays where he called it.
    local squad = LF.Units.get(rec.squad)
    local leash = (squad and squad.leader == rec.id) and st.sgtLeash or st.sectorLeash
    planCover(id, body, m, watching and coverPoint or point, sx, sy, leash, true)
    if not m.cover and not LF.Suppress.isPinned(body) then followSlot(m, body, rec, sx, sy, sz) end
    -- No shot for a while with the enemy in his arc: look for a covered square with a shot,
    -- close by in his quarter.
    if not watching and m.cover and isAt(body, m.cover)
        and LF.tick - math.max(m.lastSight or -100000, m.sectorSince) > CFG.blindTicks
        and LF.tick - (m.lastSectorShift or -100000) >= st.shiftInterval then
        m.lastSectorShift = LF.tick
        local x, y, z = firingSpot(id, body, point, CFG.fireRange + 10, sx, sy, st.shiftLeash)
        if x and not (x == m.cover.x and y == m.cover.y) then
            LF.log("BRAIN #" .. id .. " " .. title(rec) .. " has no shot from his cover; shifting within his quarter")
            leavePosition(id, body, m)
            takeSpot(id, body, m, "cover", x, y, z, "better shot in his quarter")
        end
    end
end

-- At his window, once there and not shooting: shove any furniture out of it, then smash the
-- glass out with his rifle butt.
local function windowWork(body, rec, m, sz, win, shove, shooting)
    if not (win and isAt(body, m.cover)) or body:isPerformingAnAction() or shooting then return end
    local k = win.x .. "," .. win.y
    if shove then
        if m.shoved ~= k then
            m.shoved = k
            ISTimedActionQueue.add(LF_ShoveAction:new(body, rec, win, LF.Tactics.shoveWindow, LF.Combat.arm(body)))
        end
    elseif m.smashed ~= k then
        m.smashed = k
        if LF.Building.windowIntact(win, math.floor(sz)) then
            ISTimedActionQueue.add(LF_SmashAction:new(body, win, math.floor(sz), LF.Combat.arm(body)))
        end
    end
end

-- Defending a building (LF_Tactics.buildingPlace): go to the exact square of his post - in a
-- window, covering a door from inside, or on the back line - and fight from there. The post is
-- his cover; he doesn't go looking for anything better. At a window he stands to fire (ducking
-- only under fire); elsewhere he stays down and doesn't fire blind through the walls.
local function holdPost(id, body, rec, m, sx, sy, sz, point, watching, stand, win, shove, pick, threatId, dist)
    m.order, m.point = "post", point
    -- Nothing to shoot at: a man without a window shuts the building's open doors first.
    if not (pick and dist <= CFG.fireRange) and LF.Tactics.doorDuty then
        local job = m.doorJob
        if job and (LF.tick - job.at > 900 or not LF.Building.isOpen(job.d)) then
            LF.Tactics.doorDone(rec, job.o)
            m.doorJob, job = nil, nil
        end
        if not job and LF.tick - (m.doorCheck or -1000) >= 60 then
            m.doorCheck = LF.tick
            local o, d, z = LF.Tactics.doorDuty(rec, body)
            if o then
                job = { o = o, d = d, z = z, at = LF.tick }
                m.doorJob = job
                LF.log("BUILDING #" .. id .. " " .. title(rec) .. " goes to shut the door at " .. o.x .. "," .. o.y)
            end
        end
        if job then
            if m.rest and LF.Idle then LF.Idle.stop(body, m) end
            setState(id, body, rec, m, "guard", "shutting the door at " .. job.o.x .. "," .. job.o.y)
            m.targetId = nil
            if LF.dist(body:getX(), body:getY(), job.o.x + 0.5, job.o.y + 0.5) <= 1.4 then
                if not body:isPerformingAnAction() then
                    if isMoving(body) then ISTimedActionQueue.clear(body) end
                    pcall(function() job.d:ToggleDoor(body) end)
                    LF.Tactics.doorDone(rec, job.o)
                    m.doorJob = nil
                    m.lastPath = -10000
                end
            elseif not isMoving(body) and LF.tick - m.lastPath > 60 then
                walkTo(body, job.o.x, job.o.y, job.z, "walk")
                m.lastPath = LF.tick
            end
            return
        end
    elseif m.doorJob then
        LF.Tactics.doorDone(rec, m.doorJob.o)
        m.doorJob = nil
    end
    -- All quiet for a good while in the building his unit holds: a man who isn't at a window or a
    -- door takes his ease near his post - a chair or a couch if there's one (LF_Idle).
    local unit = LF.Units.get(rec.squad)
    local post = unit and LF.Tactics.state(unit)
    post = post and post.posts and post.posts[id]
    local quiet = not pick and post and REST_POSTS[post.kind]
        and not LF.Squad.bestContact(rec.squad, body:getX(), body:getY(), CFG.quietRest, 80)
    -- (Resting means resting near his post: a man still at his ease somewhere else - he was
    -- standing by outside when the order to hold came - gets up and goes to it. A seat a few tiles
    -- off counts as near.)
    local fromPost = LF.dist(body:getX(), body:getY(), sx, sy)
    if quiet and LF.Idle and (fromPost <= 2 or (m.rest and fromPost <= (LF.Idle.SEAT_RANGE or 6) + 1)) then
        if not m.keepPost then
            m.keepPost = function() local mm = minds[id]; return mm ~= nil and mm.rest ~= nil end
        end
        if m.state ~= "guard" then setState(id, body, rec, m, "guard", "resting near his post") end
        m.targetId = nil
        LF.guard("rest at post", LF.Idle.tick, body, m, m.keepPost)
        return
    elseif m.rest and LF.Idle then
        LF.Idle.stop(body, m)
    end
    local where = stand and "at his window" or "at his post"
    if pick and dist <= CFG.fireRange then
        if m.state ~= "engage" then
            setState(id, body, rec, m, "engage", where .. ", target #" .. threatId .. " " .. title(pick.rec) .. " at "
                .. math.floor(dist) .. " tiles")
        elseif m.targetId ~= threatId then
            if LF.Config.logVerbose then LF.log("BRAIN #" .. id .. " " .. title(rec) .. " switches target to #" .. threatId .. " "
                .. title(pick.rec) .. " at " .. math.floor(dist) .. " tiles") end
        end
        m.targetId, m.targetDist = threatId, dist
    elseif watching then
        setState(id, body, rec, m, "guard", where .. ", watching toward " .. math.floor(point.x) .. "," .. math.floor(point.y))
        m.targetId = nil
    else
        setState(id, body, rec, m, "alert", where .. ", covering " .. math.floor(point.x) .. "," .. math.floor(point.y))
        m.targetId = nil
    end
    local px, py, pz = math.floor(sx), math.floor(sy), math.floor(sz)
    local spot = m.cover
    if spot and spot.post and spot.x == px and spot.y == py then
        LF.Cover.reserve(px, py, pz, id)
        if not onSpot(body, spot) then resumeWalk(body, m, spot) end
    else
        leavePosition(id, body, m)
        takeSpot(id, body, m, "cover", px, py, pz, stand and "window" or "post", "run")
        m.cover.post = true
    end
    m.cover.stand = stand
    m.cover.loose = not stand
    windowWork(body, rec, m, sz, win, shove, pick and dist <= CFG.fireRange)
end

-- His exact square (a post, the gun's spot, beside the gun): claim it and go there.
local function exactSpot(id, body, m, sx, sy, sz, label)
    local px, py, pz = math.floor(sx), math.floor(sy), math.floor(sz)
    local spot = m.cover
    if spot and spot.post and spot.x == px and spot.y == py then
        LF.Cover.reserve(px, py, pz, id)
        if not onSpot(body, spot) then resumeWalk(body, m, spot) end
    else
        leavePosition(id, body, m)
        takeSpot(id, body, m, "cover", px, py, pz, label, "run")
        m.cover.post = true
    end
end

-- Machine gunner (LF_MG): on the gun's spot - in a window, or behind cover in the open - firing at
-- what he can see out to the gun's range, or at where the enemy was (area fire); in a defence with
-- nothing in his arc, watching it. The firing itself is LF.MG.fire (from act).
local function holdGun(id, body, rec, m, sx, sy, sz, point, watching, stand, win, shove, pick, threatId, dist)
    if m.prevOrder ~= "gun" or not m.gunSince then m.gunSince = LF.tick end
    m.order, m.point = "gun", point
    local range = LF.MG.CFG.range
    if pick and dist <= range then
        if m.state ~= "engage" then
            setState(id, body, rec, m, "engage", "on the gun, target #" .. threatId .. " " .. title(pick.rec) .. " at "
                .. math.floor(dist) .. " tiles")
        end
        m.targetId, m.targetDist = threatId, dist
    elseif watching then
        setState(id, body, rec, m, "guard", "on the gun, watching toward " .. math.floor(point.x) .. "," .. math.floor(point.y))
        m.targetId = nil
    else
        setState(id, body, rec, m, "alert", "on the gun, firing on " .. math.floor(point.x) .. "," .. math.floor(point.y))
        m.targetId = nil
    end
    -- Held up on the way with the enemy in front of him: the gun goes where he is.
    local c = m.cover
    if c and c.gun and not stand and (pick or not watching) and not onSpot(body, c)
        and LF.tick - (c.since or LF.tick) > LF.MG.CFG.settleTicks and not body:isPerformingAnAction() then
        LF.MG.settleHere(rec, body)
        sx, sy = body:getX(), body:getY()
    end
    exactSpot(id, body, m, sx, sy, sz, stand and "gun in the window" or "gun position")
    -- Over low cover the gun is rested on it, and he stands behind it (as at a window).
    local over = point and LF.Cover.quality(m.cover.x, m.cover.y, m.cover.z, point.x, point.y) == LF.Cover.LOW
    stand = stand or over or false
    m.cover.stand = stand
    m.cover.loose = false
    m.cover.gun = true
    windowWork(body, rec, m, sz, win, shove, pick and dist <= range)
end

-- Assistant gunner: down beside the gun, feeding it (LF_MG queues the work), watching what it
-- fires at. His rifle only for an enemy close by, when the gun doesn't need him.
local function holdAssist(id, body, rec, m, sx, sy, sz, point, pick, threatId, dist)
    m.order, m.point = "assist", point
    if pick and dist <= LF.MG.CFG.assistRange and not LF.MG.needsAssistant(rec) then
        if m.state ~= "engage" then
            setState(id, body, rec, m, "engage", "at the gun, enemy close - #" .. threatId .. " at " .. math.floor(dist) .. " tiles")
        end
        m.targetId, m.targetDist = threatId, dist
    else
        setState(id, body, rec, m, "assist", "at the gun")
        m.targetId = nil
    end
    exactSpot(id, body, m, sx, sy, sz, "beside the gun")
    m.cover.stand = false
    m.cover.loose = true
end

-- Clearing a building (LF_Tactics.clearPlace): walk (or run) to his place in the file - the
-- stack by the door, then his spot in the room, rifle up - and face where he's told. An enemy
-- in view close by: stop and shoot, then carry on.
-- Is he holding an aim (a halt), or with holdOnly false also a quick scan?
local function holdingAim(body, holdOnly)
    local q = ISTimedActionQueue.getTimedActionQueue(body)
    local a = q and q.queue and q.queue[1]
    return a ~= nil and a.Type == "LF_HoldAimAction" and not (holdOnly and a.untilTick)
end

-- An ongoing scan rides on whichever patrol walk he is on (a re-path makes a new one).
local function carryScan(body, m)
    local q = ISTimedActionQueue.getTimedActionQueue(body)
    local a = q and q.queue and q.queue[1]
    if a and a.Type == "LF_MoveAction" and a.gait == "patrol" then a.scan, a.scanUntil = m.scanDir, m.scanUntil end
end

local FILE_WORDS = { aim = "going in", march = "on patrol", point = "on point", wait = "waiting to fall in",
                     catchup = "catching up",
                     halt = "halted - down, aiming outboard" }

local function holdFile(id, body, rec, m, sx, sy, sz, face, gait, pick, threatId, dist, scanDir)
    m.order, m.point = "file", nil
    local range = gait == "aim" and CFG.clearFireRange
        or ((gait == "halt" or gait == "wait") and CFG.fireRange or CFG.stackFireRange)
    if pick and dist <= range then
        local q = ISTimedActionQueue.getTimedActionQueue(body)
        local a = q and q.queue and q.queue[1]
        local charging = a ~= nil and a.charging == true            -- (rushing an enemy, empty: let him)
        if (isMoving(body) and not charging) or holdingAim(body) then ISTimedActionQueue.clear(body) end
        if m.state ~= "engage" then
            setState(id, body, rec, m, "engage", "clearing - target #" .. threatId .. " " .. title(pick.rec) .. " at "
                .. math.floor(dist) .. " tiles")
        end
        m.targetId, m.targetDist = threatId, dist
        return
    end
    setState(id, body, rec, m, "file", FILE_WORDS[gait] or "stacking up")
    m.targetId = nil
    m.fileFace, m.fileGait = face, gait
    local tx, ty = math.floor(sx), math.floor(sy)
    local there = math.floor(body:getX()) == tx and math.floor(body:getY()) == ty
    if gait == "wait" then there = true end         -- he waits where he stands
    m.fileThere = there
    if there then
        -- Halted: crouch, rifle up, aiming outboard.
        if gait == "halt" and not body:isPerformingAnAction() then
            LF.Posture.set(body, true)
            ISTimedActionQueue.add(LF_HoldAimAction:new(body, face, LF.Combat.arm(body)))
        end
        return
    end
    if holdingAim(body, true) then ISTimedActionQueue.clear(body) end -- his place has moved: get up
    local key = tx .. "," .. ty .. "," .. gait
    local walkGait = (gait == "march" or gait == "point") and "patrol"
        or ((gait == "halt" or gait == "catchup") and "walk" or gait)
    local moving = gait == "march" or gait == "point" or gait == "catchup"
    if (gait == "march" or gait == "point") and scanDir and LF.tick >= (m.nextScan or 0) then
        -- Now and then: keep walking but bring the rifle up and scan his own outboard side (the
        -- way he would face at a halt) for a second or two.
        local first = m.nextScan == nil
        m.nextScan = LF.tick + 360 + ZombRand(540)           -- every ~6-15 s (0.56: was 10-30 s)
        if not first then
            m.scanDir, m.scanUntil = scanDir, LF.tick + 120 + ZombRand(120)   -- for 2-4 s
            LF.Brain.scans = (LF.Brain.scans or 0) + 1
        end
    end
    if m.scanUntil and LF.tick < m.scanUntil then carryScan(body, m) end
    if walkGait == "patrol" then
        -- Hold the patrol pace: step a little faster or slower by where he is against his mark.
        local q = ISTimedActionQueue.getTimedActionQueue(body)
        local a = q and q.queue and q.queue[1]
        if a and a.Type == "LF_MoveAction" then a.paceMul = LF.March.paceMul(rec, body) end
    end
    if moving and m.marchGait ~= walkGait then
        -- Changing pace (falling behind / caught up): a new walk at the new pace.
        if m.marchGait and isMoving(body) then ISTimedActionQueue.clear(body); m.lastPath = -10000 end
        m.marchGait = walkGait
    end
    if moving then
        -- On the march his place moves up the road: the walk he is on is re-aimed at it as it
        -- moves (no stopping and starting a new walk), so he keeps a steady pace.
        local d = m.marchDest and LF.dist(m.marchDest.x, m.marchDest.y, tx, ty) or math.huge
        if d >= 1.5 then
            local q = ISTimedActionQueue.getTimedActionQueue(body)
            local a = q and q.queue and q.queue[1]
            local sq = getCell():getGridSquare(tx, ty, math.floor(sz))
            local reaimed = a and a.Type == "LF_MoveAction" and a.gait == walkGait and a.retarget
                and sq and sq:isFree(false) and a:retarget(tx, ty, sz)
            if not reaimed then
                if isMoving(body) then ISTimedActionQueue.clear(body) end
                m.lastPath = -10000
            end
            m.marchDest = m.marchDest or {}
            m.marchDest.x, m.marchDest.y = tx, ty
        end
    elseif m.fileDest ~= key then
        m.fileDest = key
        if isMoving(body) then ISTimedActionQueue.clear(body) end
        m.lastPath = -10000
    end
    if body:isPerformingAnAction() and not isMoving(body) then return end
    if not isMoving(body) and LF.tick - m.lastPath > (moving and 10 or 60) then
        if LF.Posture.crouched(body) then LF.Posture.set(body, false) end
        -- His exact square if he can stand there and got there last time; otherwise near it.
        local sq = getCell():getGridSquare(tx, ty, math.floor(sz))
        if sq and sq:isFree(false) and not stuckNear(m, tx + 0.5, ty + 0.5) then
            walkTo(body, tx, ty, math.floor(sz), walkGait)
        else
            walkNear(body, tx + 0.5, ty + 0.5, sz, 2, walkGait)
        end
        m.lastPath = LF.tick
        if m.scanUntil and LF.tick < m.scanUntil then carryScan(body, m) end
    end
end

-- A grenade landing next to him: he throws himself clear (a few tiles away from it) and does
-- nothing else for a moment.
function LF.Brain.dodge(id, body, gx, gy)
    local m = minds[id]
    if not m then return end
    local dx, dy = body:getX() - gx, body:getY() - gy
    local len = math.max(0.3, math.sqrt(dx * dx + dy * dy))
    if m.rest and LF.Idle then LF.Idle.stop(body, m) end
    ISTimedActionQueue.clear(body)
    if LF.Brain.walkNear(body, body:getX() + dx / len * 5, body:getY() + dy / len * 5, body:getZ(), 1, "run") then
        m.dodgeUntil = LF.tick + 120
        m.detail = "diving clear of a grenade"
    end
end

local function decide(id, body, rec, m)
    if m.dodgeUntil and LF.tick < m.dodgeUntil then return end    -- diving clear of a grenade
    m.prevOrder = m.order
    m.order, m.point = nil, nil
    -- Fighters: soldiers, and civilians who are holding a gun (resistance).
    local fighter = rec.faction ~= "CIV" or LF.Combat.isArmed(body)
    m.fighter = fighter
    local inSquad = rec.squad ~= nil and LF.Units.get(rec.squad) ~= nil
    local leader = inSquad and isSquadLeader(id, rec)
    -- A machine gunner fights out to the gun's range, not a rifle's.
    local gunner = rec.mgRole == "gunner" and LF.MG ~= nil
    local fireRange = gunner and LF.MG.CFG.range or CFG.fireRange

    -- (A squad soldier sees what his squad has seen and he has a line to - LF_SquadBrain, 0.74.)
    local visible
    local tLook = getTimestampMs()
    if inSquad and LF.SquadBrain.enabled then visible = LF.SquadBrain.look(id, body, rec, CFG.sightRange)
    else visible = LF.Sense.look(id, body, rec, CFG.sightRange) end
    LF.Perf.stop("brain look", tLook)
    local tT = getTimestampMs()
    -- (A squad soldier's sightings go into the squad's picture with its look - LF_SquadBrain, 0.78.)
    if inSquad and #visible > 0 and not LF.SquadBrain.enabled then shareSightings(id, rec, visible) end
    local pick = nil
    if #visible > 0 then pick = fighter and chooseTarget(id, body, rec, m, visible) or visible[1] end
    LF.Perf.stop("brain target", tT)
    local threat, threatId, dist = nil, nil, nil
    if pick then threat, threatId, dist = pick.body, pick.id, pick.dist end
    if pick and fighter and dist <= fireRange then m.lastSight = LF.tick end
    local hp = LF.Combat.health(body)
    -- Legs too badly hurt to walk: he counts as badly wounded - he crawls away (or, in a
    -- defence, stays down where he is).
    if m.crawl and fighter then hp = math.min(hp, CFG.fleeHealth - 1) end

    -- Seriously or critically wounded (LF_Wounds): out of the fight. He doesn't shoot; with the
    -- enemy about he gets into cover, otherwise he limps along behind his squad and, when it
    -- stops, sits down there nursing his wound - until he gets to the surgeon.
    if fighter and inSquad and LF.Wounds and LF.Wounds.outOfFight(rec) then
        m.targetId = nil
        local rx, ry, rz = LF.Squad.rear(rec, CFG.rearDistance)
        if leader then rx = nil end          -- (nobody fit to take over: he stays where he is)
        local c = threat or nil
        if not c and rx then
            local k = LF.Squad.bestContact(rec.squad, body:getX(), body:getY(), CFG.contactMemory, CFG.sightRange)
            if k then c = LF.Tactics.point(k.x, k.y, k.z or body:getZ()) end
        end
        if c then
            if m.state ~= "flee" then setState(id, body, rec, m, "flee", "wounded, out of the fight - into cover") end
            local others = LF.Squad.contactPoints(rec.squad, CFG.contactMemory, 6)
            if not planHide(id, body, m, c, rx, ry, others) and rx then fallBack(m, body, rx, ry, rz, c) end
            return
        end
        if m.hide then leavePosition(id, body, m) end
        if rx and LF.dist(body:getX(), body:getY(), rx, ry) > 4 then
            if m.state ~= "wounded" then setState(id, body, rec, m, "wounded", "wounded - limping after his squad") end
            if m.rest and LF.Idle then LF.Idle.stop(body, m) end
            if not isMoving(body) and LF.tick - m.lastPath > 90 then
                if walkNear(body, rx, ry, rz, 2, "limp") then m.lastPath = LF.tick end
            end
            return
        end
        if m.state ~= "wounded" then setState(id, body, rec, m, "wounded", "wounded - waiting with his squad") end
        if isMoving(body) then ISTimedActionQueue.clear(body) end
        if LF.Idle and LF.Idle.nurse then LF.Idle.nurse(body, m) end
        return
    end

    -- The slot this soldier is leashed to (none for the squad leader, who sets the pace).
    local ax, ay, az = nil, nil, nil
    if inSquad and not leader then ax, ay, az = LF.Squad.slot(rec) end

    -- Defensive stance: a badly wounded man goes down where he is (no pulling back), patches
    -- himself up and fires at what comes into view. A leader hands over command.
    -- (So does a man of a team clearing a building, inside it: running out through the rooms
    -- they've just cleared and across the yard under the enemy's windows is no way out.)
    if fighter and inSquad and hp < CFG.fleeHealth and (not LF.Stance.of(rec).woundedWithdraw
        or (LF.Tactics and LF.Tactics.clearingInside and LF.Tactics.clearingInside(rec, body))) then
        if LF.Units.relieve(rec) then leader = false end
        -- Holding a building, but outside it (he was wounded out there, or wandered off before
        -- the stand): back in to his post first, then down there.
        local px, py, pz = nil, nil, nil       -- (not "x and f()": that keeps only f's first value)
        if LF.Tactics.insidePost then px, py, pz = LF.Tactics.insidePost(rec, body) end
        if px then
            if m.state ~= "down" then setState(id, body, rec, m, "down", "wounded - back inside the building") end
            if not isMoving(body) and LF.tick - m.lastPath > 120 then
                walkTo(body, px, py, pz, "limp")
                m.lastPath = LF.tick
            end
            m.targetId = nil
            return
        end
        if m.state ~= "down" then
            setState(id, body, rec, m, "down", "wounded, health " .. math.floor(hp) .. "; stays where he is")
            if isMoving(body) then ISTimedActionQueue.clear(body) end
        end
        m.targetId = (pick and dist <= fireRange) and threatId or nil
        return
    end
    -- Badly wounded with the enemy right on top of him: no getting away - he fights back from
    -- where he is (like a man down in a defence).
    if fighter and threat and hp < CFG.fleeHealth and dist <= CFG.corneredRange then
        if m.state ~= "down" then
            setState(id, body, rec, m, "down", "wounded and cornered, enemy at " .. math.floor(dist) .. " tiles")
            if isMoving(body) then ISTimedActionQueue.clear(body) end
        end
        m.targetId = threatId
        return
    end
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
        local others = inSquad and LF.Squad.contactPoints(rec.squad, CFG.contactMemory, 6) or nil
        if not (fighter and planHide(id, body, m, threat, rx, ry, others)) then
            if rx then
                fallBack(m, body, rx, ry, rz, threat)
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
    if fighter and hp < CFG.fleeHealth and (m.state == "flee" or m.state == "down") and LF.Stance.of(rec).woundedWithdraw then
        -- Badly hurt and already hiding: stay down out of sight instead of rejoining the fight
        -- the moment the enemy drops out of view - unless his unit has moved off without him:
        -- then he leaves his hiding place and makes his way back to it.
        -- (Only with an enemy known: with nobody about, a wounded man stays where he is - up to
        -- 0.44 a man wounded at his window went out of the building to the squad's "rear" as soon
        -- as his unit stood down, and stayed out there.)
        local known = inSquad and LF.Squad.bestContact(rec.squad, body:getX(), body:getY(), CFG.contactMemory, CFG.sightRange + 15)
        if not known and not (m.hide and not isAt(body, m.hide)) then
            if m.state ~= "down" then setState(id, body, rec, m, "down", "wounded, nobody about - stays where he is") end
            if isMoving(body) then ISTimedActionQueue.clear(body) end
            return
        end
        if m.state == "down" then setState(id, body, rec, m, "flee", "wounded, back to cover") end
        if m.hide and inSquad then
            local rx, ry = LF.Squad.rear(rec, CFG.rearDistance)
            if rx and LF.dist(m.hide.x, m.hide.y, rx, ry) > CFG.woundedLeftBehind then
                LF.log("BRAIN #" .. id .. " " .. title(rec) .. " leaves his hiding place - his unit has moved on")
                leavePosition(id, body, m)
                m.hide, m.atRear = nil, nil
            end
        end
        if not (m.hide and isAt(body, m.hide)) and inSquad then
            local rx, ry, rz = LF.Squad.rear(rec, CFG.rearDistance)
            if rx and not m.hide then
                local c = LF.Squad.bestContact(rec.squad, body:getX(), body:getY(), CFG.contactMemory, CFG.sightRange + 15)
                if c then fallBack(m, body, rx, ry, rz, c) end
            end
        end
        return
    end
    -- The opening seconds of a fight, before any orders: return fire at once, then get into the
    -- nearest cover and keep firing from there.
    local bearings = fighter and inSquad and LF.Tactics.bearings(rec.squad)
    if not bearings then
        m.bearX = nil
    else
        if not m.bearX then
            m.bearX, m.bearY = body:getX(), body:getY()
            if isMoving(body) then ISTimedActionQueue.clear(body) end   -- stop and shoot
        end
        if pick and dist <= fireRange then
            if m.state ~= "engage" then
                setState(id, body, rec, m, "engage", "returning fire at #" .. threatId .. " " .. title(pick.rec))
            end
            m.targetId, m.targetDist = threatId, dist
            -- First shot first; then the nearest cover.
            if m.combat.nextFire then planCover(id, body, m, threat, m.bearX, m.bearY, CFG.bearingsLeash) end
            return
        end
        local c = pick and { x = threat:getX(), y = threat:getY(), z = threat:getZ() }
            or LF.Squad.bestContact(rec.squad, body:getX(), body:getY(), CFG.contactMemory, CFG.sightRange + 15)
        if c then
            local g = ghostOf(m, c)
            setState(id, body, rec, m, "alert", "taking cover facing " .. math.floor(c.x) .. "," .. math.floor(c.y))
            m.targetId, m.order, m.point = nil, "bearings", g
            -- No enemy in his own sights: get into cover straight away (and fire from there).
            planCover(id, body, m, g, m.bearX, m.bearY, CFG.bearingsLeash)
            return
        end
    end
    if fighter and inSquad then
        -- The unit has orders (LF_Tactics): go where the corporal or sergeant puts you.
        local tP = getTimestampMs()
        local role, sx, sy, sz, point, watching, coverPoint, stand, win, shove = LF.Tactics.place(rec)
        LF.Perf.stop("brain place", tP)
        local scanDir = role == "file" and coverPoint or nil     -- (patrol: his outboard side)
        local leash = CFG.holdLeash
        if role == "file" then
            -- (place returns the face point and gait in the point / watching slots)
            holdFile(id, body, rec, m, sx, sy, sz, point, watching, pick, threatId, dist, scanDir)
            return
        end
        if (role == "post" or (role == "gun" and stand)) and stuckNear(m, sx, sy) and not LF.Tactics.postUnreachable(rec)
            and LF.Tactics.repostInside and LF.Tactics.repostInside(rec, body) then
            -- (His window can't be reached at all: a square of his own inside, not the yard.)
            m.stuck = nil
            return
        end
        if (role == "post" or (role == "gun" and stand)) and stuckNear(m, sx, sy) and LF.Tactics.postUnreachable(rec) then
            -- A window he can't get to: he'll fire out of it from further back (next think).
            m.stuck = nil
            return
        end
        if role and role ~= "file" and stuckNear(m, sx, sy) then
            -- Can't get there: take the nearest cover around where he got stuck.
            if role == "gun" then
                -- (A gun doesn't go off to some other cover: it sets up where he got to.)
                LF.MG.settleHere(rec, body)
                m.stuck = nil
                return
            end
            sx, sy, leash = m.stuck.fromX, m.stuck.fromY, CFG.stuckLeash
            if role == "move" then role = "hold" end
        end
        if role == "command" then leash = CFG.commandLeash end
        if role == "assist" then
            holdAssist(id, body, rec, m, sx, sy, sz, point, pick, threatId, dist)
            return
        end
        if role == "post" or role == "gun" then
            -- At a window: only what's out of his own wall (or close, or inside the building).
            -- (A gun in a window: only what's out of the window itself - LF_MG.)
            local function covers(x, y)
                if LF.Tactics.postCovers and not LF.Tactics.postCovers(rec, x, y) then return false end
                return role ~= "gun" or LF.MG.gunCovers(rec, x, y)
            end
            if pick and not covers(pick.body:getX(), pick.body:getY()) then
                local alt = {}
                for i = 1, #visible do
                    local v = visible[i]
                    if covers(v.body:getX(), v.body:getY()) then alt[#alt + 1] = v end
                end
                pick = #alt > 0 and chooseTarget(id, body, rec, m, alt) or nil
                threatId, dist = pick and pick.id, pick and pick.dist
            end
            if role == "gun" then
                holdGun(id, body, rec, m, sx, sy, sz, point, watching, stand, win, shove, pick, threatId, dist)
            else
                holdPost(id, body, rec, m, sx, sy, sz, point, watching, stand, win, shove, pick, threatId, dist)
            end
            return
        end
        if role == "sector" then
            holdSector(id, body, rec, m, sx, sy, sz, point, watching, coverPoint, pick, threat, threatId, dist)
            return
        end
        if role then
            if role ~= "hold" then
                m.holdingSince = nil
            elseif m.prevOrder ~= "hold" or not m.holdingSince then
                m.holdingSince = LF.tick
            end
            m.order, m.point = role, point
            local pinned = LF.Suppress.isPinned(body)
            -- (0.73.6: a squad falling back goes back pinned or not - a broken squad gets out from
            -- under the fire; up to 0.73.5 its pinned men stayed put and were shot to pieces.)
            -- (And under any plan whose men go pinned or not - falling back, regrouping: 0.75.)
            if pinned and rec.squad and LF.Tactics and LF.Tactics.movesPinned and LF.Tactics.movesPinned(rec.squad) then pinned = false end
            if role == "move" and not pinned then
                setState(id, body, rec, m, "bound", "running to " .. math.floor(sx) .. "," .. math.floor(sy))
                if LF.Posture.crouched(body) then LF.Posture.set(body, false) end
                moveTo(m, body, sx, sy, sz)
                return
            end
            if pick and dist <= fireRange then
                if m.state ~= "engage" then
                    setState(id, body, rec, m, "engage", "target #" .. threatId .. " " .. title(pick.rec) .. " at "
                        .. math.floor(dist) .. " tiles")
                elseif m.targetId ~= threatId then
                    if LF.Config.logVerbose then LF.log("BRAIN #" .. id .. " " .. title(rec) .. " switches target to #" .. threatId .. " "
                        .. title(pick.rec) .. " at " .. math.floor(dist) .. " tiles") end
                end
                m.targetId, m.targetDist = threatId, dist
            else
                setState(id, body, rec, m, "alert", "covering " .. math.floor(point.x) .. "," .. math.floor(point.y))
                m.targetId = nil
            end
            planCover(id, body, m, pick and threat or point, sx, sy, leash)
            if not m.cover and not pinned then followSlot(m, body, rec, sx, sy, sz) end
            return
        end
    end
    if threat and fighter then
        if m.state ~= "engage" then
            setState(id, body, rec, m, "engage", "target #" .. threatId .. " " .. title(pick.rec) .. " at "
                .. math.floor(dist) .. " tiles")
        elseif m.targetId ~= threatId then
            if LF.Config.logVerbose then LF.log("BRAIN #" .. id .. " " .. title(rec) .. " switches target to #" .. threatId .. " "
                .. title(pick.rec) .. " at " .. math.floor(dist) .. " tiles") end
        end
        m.targetId = threatId
        m.targetDist = dist
        planCover(id, body, m, threat, ax, ay)
        if not m.cover then
            if ax then
                followSlot(m, body, rec, ax, ay, az)      -- no cover near the slot: fight from the slot
            elseif dist > fireRange then
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
                if d > fireRange - 2 then approach(m, body, g, d) end
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
        local placed = true
        -- (A man going to, or on, a seat near his place stays there - LF_Idle.)
        if ax and not (m.rest and m.rest.seat) then placed = followSlot(m, body, rec, ax, ay, az) end   -- the leader holds; the squad keeps formation
        -- Standing by: on his spot, he passes the time (sits, smokes, checks his rifle...).
        if placed and fighter and LF.Idle and LF.Stance.of(rec).idle and not isMoving(body) then
            if not m.keepIdle then
                m.keepIdle = function()
                    local mm = minds[id]
                    return mm ~= nil and mm.state == "idle" and LF.Stance.of(rec).idle == true
                end
            end
            LF.guard("rest", LF.Idle.tick, body, m, m.keepIdle)
        elseif m.rest and LF.Idle and not LF.Stance.of(rec).idle then
            LF.guard("end rest", LF.Idle.stop, body, m)       -- the unit has something to do now
        end
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

-- In a lull (nothing in his own sights), top up a magazine that is half empty or worse - or any
-- part-used one when there is no fight at all. (A machine gunner: a new belt, out of the fight.)
local function topUp(body, m, full, rec)
    if body:isPerformingAnAction() or LF.tick - (m.lastTopUp or -10000) < 120 then return false end
    if rec and rec.mgRole == "gunner" and LF.MG then
        if not full then return false end
        m.lastTopUp = LF.tick
        return LF.MG.topUp(body, rec)
    end
    local profile = LF.Weapons.profileOf(body)
    local left = LF.Weapons.rounds(body)
    if left >= profile.clip or (not full and left > profile.clip * 0.5) then return false end
    m.lastTopUp = LF.tick
    return LF.Weapons.reload(body, LF.Combat.arm(body), "topping up")
end

-- Firing: a machine gunner works his gun (LF_MG); everyone else, the rifle drill (LF_Combat).
local function fireAt(body, rec, m, target)
    if rec.mgRole == "gunner" and LF.MG then return LF.MG.fire(body, rec, m, target, false) end
    return LF.Combat.engage(body, target, m.combat, m.combatOpts)
end
local function fireArea(body, rec, m, p)
    if rec.mgRole == "gunner" and LF.MG then return LF.MG.fire(body, rec, m, p, true) end
    return LF.Combat.engageArea(body, p, m.combat)
end

-- Once every n ticks for this man (his act runs every few ticks, so a shared "LF.due" beat
-- would land for only some men - 0.75).
local function every(m, key, n)
    if LF.tick - (m[key] or -100000) >= n or (m[key] or 0) > LF.tick then m[key] = LF.tick; return true end
    return false
end

-- Per-tick behaviour for states that need it.
local function act(id, body, rec, m)
    local st = m.state
    local gunner = rec.mgRole == "gunner" and LF.MG ~= nil
    local fireRange = gunner and LF.MG.CFG.range or CFG.fireRange
    local areaRange = gunner and LF.MG.CFG.areaRange or CFG.sightRange
    -- A defender at a window stands to fire out of it (ducking only under fire).
    local c = m.cover
    local standing = c ~= nil and c.post and c.stand and onSpot(body, c)
    -- (A machine gunner on his gun - at a window, or over low cover - stays up behind it between
    -- bursts, under fire or not: the gun is rested on the sill or the wall, and so is he.)
    local gunUp = standing and c.gun
    if standing and (gunUp or not LF.Suppress.isSuppressed(body)) and LF.Posture.crouched(body) and not body:isPerformingAnAction() then
        LF.Posture.set(body, false)
    end
    -- Under fire, soldiers keep their heads down between shots (and pinned men stay down).
    if (st == "engage" or st == "alert") and LF.Suppress.isSuppressed(body) and not gunUp then hunkerDown(body) end
    -- Holding with no cover at all: crouch rather than stand in the open.
    if (st == "engage" or st == "alert") and not m.cover and m.order and not isMoving(body) then hunkerDown(body) end
    if st == "alert" and m.point then
        -- Covering: area fire on where the enemy was last seen (not from a blind shelter).
        if m.cover then
            if not onSpot(body, m.cover) then return end
            if not standing then hunkerDown(body) end
            if m.cover.loose then return end
        end
        if m.fighter and topUp(body, m, false, rec) then return end
        local p = m.point
        if LF.distSq(body:getX(), body:getY(), p.x, p.y) <= areaRange * areaRange then
            fireArea(body, rec, m, p)
        end
        return
    end
    if m.state == "engage" and m.targetId then
        if m.cover then
            if not onSpot(body, m.cover) then return end   -- still moving into position
            if not standing then hunkerDown(body) end
        end
        local target = LF.Bodies.get(m.targetId)
        if target and not target:isDead()
            and LF.distSq(body:getX(), body:getY(), target:getX(), target:getY()) <= fireRange * fireRange then
            fireAt(body, rec, m, target)
        end
    elseif m.state == "alert" and m.cover and isAt(body, m.cover) then
        hunkerDown(body)
        if m.fighter then topUp(body, m, false, rec) end
    elseif m.state == "idle" and m.fighter and LF.Combat.isArmed(body) then
        topUp(body, m, true, rec)
    elseif m.state == "guard" then
        -- Watching his quarter: down in cover, facing out.
        if m.cover and isAt(body, m.cover) and not standing then hunkerDown(body) end
        local p = m.point
        if p and every(m, "faceAt", 40) and not body:isPerformingAnAction() then body:faceLocation(p.x, p.y) end
        if m.fighter then topUp(body, m, false, rec) end
    elseif m.state == "assist" then
        -- Down beside the gun, watching what it fires at.
        if m.cover and isAt(body, m.cover) then hunkerDown(body) end
        if every(m, "faceAt", 30) and not body:isPerformingAnAction() and LF.MG then
            local ax, ay = LF.MG.aimOf(rec)
            if ax then body:faceLocation(ax, ay) end
        end
    elseif m.state == "file" then
        -- In the stack (kneeling, facing the door) or on his spot in the room (standing, facing on).
        if m.fileThere and not body:isPerformingAnAction() then
            if m.fileGait ~= "aim" and m.fileGait ~= "march" and m.fileGait ~= "wait" then hunkerDown(body) end
            local f = m.fileFace
            if f and every(m, "faceAt", 20) then body:faceLocation(f.x, f.y) end
        end
    elseif m.state == "down" then
        -- Wounded in a defence: stays down where he is, bandages himself, fires at what he sees.
        hunkerDown(body)
        if not body:isPerformingAnAction() and LF.tick - (m.lastAid or -10000) > 90 then
            m.lastAid = LF.tick
            local part = LF.Aid.bleedingPart(body)
            if part then ISTimedActionQueue.add(LF_AidAction:new(body, part)); return end
        end
        local target = m.targetId and LF.Bodies.get(m.targetId)
        if target and not target:isDead()
            and LF.distSq(body:getX(), body:getY(), target:getX(), target:getY()) <= fireRange * fireRange then
            fireAt(body, rec, m, target)
        end
    elseif m.state == "flee" then
        local safe = (m.hide and isAt(body, m.hide)) or m.atRear
        if m.hide and isAt(body, m.hide) and not m.rest then hunkerDown(body) end
        if safe and m.fighter and not m.safeLogged then
            m.safeLogged = true
            LF.log("BRAIN #" .. id .. " " .. title(rec) .. " reached safety (" .. (m.atRear and "squad rear" or "hiding spot")
                .. "), health " .. math.floor(LF.Combat.health(body)))
        end
        -- Got back to the squad's rear: out of the open first - a hiding spot close by.
        if safe and m.fighter and m.atRear and not m.hide and not m.rearHideTried then
            m.rearHideTried = true
            local c = rec.squad and LF.Squad.bestContact(rec.squad, body:getX(), body:getY(), 3600, 60)
            if c then
                local threat = LF.Tactics.point(c.x, c.y, c.z or body:getZ())
                local hx, hy, hz = LF.Cover.findHidingSpot(id, body, threat, body:getX(), body:getY(), nil)
                if hx and LF.dist(body:getX(), body:getY(), hx + 0.5, hy + 0.5) <= 10 then
                    takeSpot(id, body, m, "hide", hx, hy, hz, "hiding spot", "limp", c.x, c.y)
                    m.atRear = nil
                    return
                end
            end
        end
        -- Out of the fight and safe: he sits down and tends his wounds - dressing the bleeding
        -- ones, seeing to the others - until he's needed or it's over.
        if safe and m.fighter and not isMoving(body) and LF.Idle and LF.Idle.nurse then
            LF.guard("nurse", LF.Idle.nurse, body, m)
        end
    end
end

-- ---- reaction times (0.78 test) ----------------------------------------------------------------------
-- How long a man takes to fire his first shot once his squad's contact begins (LF_SquadBrain), and
-- how long a squad takes to start moving once it is given a movement order (LF_Tactics.setIntent).
-- Kept as plain lists of seconds for the test to read.
LF.Brain.reactions = { shot = {}, move = {} }
function LF.Brain.onShot(body)
    local id = body:getModData().LF_id
    local m = id and minds[id]
    local rec = id and LF.Records.get(id)
    if not (m and rec and rec.squad and LF.SquadBrain.contactSince) then return end
    local cs = LF.SquadBrain.contactSince(rec.squad)
    if not cs or m.reactFor == cs then return end
    m.reactFor = cs
    local secs = (LF.tick - cs) / 60
    local list = LF.Brain.reactions.shot
    if secs >= 0 and secs <= 15 and #list < 2000 then list[#list + 1] = secs end
end
function LF.Brain.onMoveStart(sid)
    local sq = LF.Tactics.state(LF.Units.get(sid))
    if not (sq and sq.moveOrderAt) or sq.moveOrderMet then return end
    sq.moveOrderMet = true
    local secs = (LF.tick - sq.moveOrderAt) / 60
    local list = LF.Brain.reactions.move
    if secs >= 0 and secs <= 15 and #list < 2000 then list[#list + 1] = secs end
end

-- Extension points: later features hook in here without touching the loop.
LF.Brain.decide = decide
LF.Brain.act = act

-- A body whose health has sat at zero for two seconds without the engine finishing it off.
local function finishOff(body)
    body:setHealth(0)
    body:Kill(nil)
end

-- Climbing over a fence, through a window, over a wall: the game's own climb runs him. Nothing is
-- started on top of it (an aim or a shot would replace the climb's animation, and the climb waits
-- for that animation to finish - up to 0.44 a man could be left frozen on top of a fence).
local CLIMB_STATES = { ClimbOverFenceState = true, ClimbThroughWindowState = true, ClimbOverWallState = true,
                       ClimbSheetRopeState = true, ClimbDownSheetRopeState = true }
-- (Plain functions handed to pcall: nothing is created per body per tick.)
local function stateNameOf(body) return body:getCurrentStateName() end
local function bumpedUp(body) return body:isBumped() and not body:isOnFloor() end
local function climbing(body)
    local ok, name = pcall(stateNameOf, body)
    return ok and name ~= nil and CLIMB_STATES[name] == true, ok and name or nil
end
LF.Brain.climbing = climbing

-- Stuck: in a climb, or down on the ground, for far longer than it takes - the game's state got
-- stuck. He's put back on his feet.
local STUCK_CLIMB, STUCK_DOWN = 300, 900
local function unstick(id, body, m, why)
    LF.log("BRAIN #" .. id .. " stuck " .. why .. " - put back on his feet")
    ISTimedActionQueue.clear(body)
    pcall(function()
        for _, v in ipairs({ "ClimbFenceFinished", "ClimbWindowFinished", "ClimbWallFinished", "BumpDone" }) do body:setVariable(v, true) end
        body:setVariable("ClimbFenceStarted", false)
        body:setBumpDone(true)
        body:setBumpType("")
        body:reportEvent("ActiveAnimFinishing")
        body:setOnFloor(false)
        body:setKnockedDown(false)
    end)
    m.stuckSince, m.lastPath = nil, -10000
end

local function bumpFallOf(b) return b:getVariableBoolean("BumpFall") end

-- One step for a man: every CFG.actTicks ticks (0.75 - up to 0.74 every tick), his think on
-- its own timer inside it.
local function stepNpc(id, body, rec, lod)
    -- Down and being looked after, or dragging a man (LF_Medic): that runs him, not the brain.
    if LF.Medic and LF.Medic.busy(id) then return end
    local m = mindOf(id)
    local climb, st = climbing(body)
    if climb then
        -- No shooting from the top of a fence: anything queued (but the walk) waits.
        local q = ISTimedActionQueue.getTimedActionQueue(body)
        local a = q and q.queue and q.queue[1]
        if a and a.Type ~= "LF_MoveAction" and a.Type ~= "ISWalkToTimedAction" then ISTimedActionQueue.clear(body) end
        m.climbSince = m.climbSince or LF.tick
        if LF.tick - m.climbSince > STUCK_CLIMB then
            unstick(id, body, m, "climbing for " .. math.floor((LF.tick - m.climbSince) / 60) .. " s")
            m.climbSince = nil
        end
        return
    end
    m.climbSince = nil
    -- (Not a man crawling on ruined legs, or one too badly hurt to stand: they're down for good
    -- reason - 0.45 kept "unsticking" a crawling man every 15 s.)
    -- A stagger the game never finished (its animation was cut short): he isn't on the ground,
    -- just stuck "bumped" - cleared after about a second, the length of the stagger itself (0.46
    -- left a man standing frozen mid-room for good; 0.47 cleared it after 3 s, and every stagger
    -- from a hit ran the full 3 s - men stood frozen in the open under fire).
    -- The game only leaves its "bumped" state when the stagger animation finishes - so clearing
    -- the stagger alone left the man in that state with no animation to finish, frozen for good
    -- (0.52: Cpl. Kozlov, Pvt. Smirnov). He's watched by the state itself, not just the flag, and
    -- let out of it by telling the state machine the animation has finished.
    -- (Stagger and down-too-long: checked every 6 ticks - their limits are 70 ticks and more.)
    if every(m, "bumpAt", 6) then
    local okB, bumped = pcall(bumpedUp, body)
    local inBump = st == "BumpedState"
    if ((okB and bumped) or inBump) and not (LF.Medic and LF.Medic.busy(id)) then
        m.bumpSince = m.bumpSince or LF.tick
        local okF, falling = pcall(bumpFallOf, body)
        if LF.tick - m.bumpSince > ((okF and falling) and 150 or 70) then
            LF.log("BRAIN #" .. id .. " stagger over - back on his feet (state " .. tostring(st) .. ")")
            pcall(function()
                body:setBumpType("")
                body:setBumpDone(true)
                body:setVariable("BumpDone", true)
                if not body:isOnFloor() then
                    body:setBumpFall(false)
                    body:setVariable("BumpFall", false)
                end
                body:reportEvent("ActiveAnimFinishing")
            end)
            m.bumpSince = LF.tick - 30          -- (still stuck in a second: again)
        end
    else
        m.bumpSince = nil
    end
    if LF.Combat.knockedDown(body) and not (LF.Medic and LF.Medic.isCritical(id)) and not m.crawl
        and LF.Combat.health(body) >= 20 and not (LF.Combat.legsOut and LF.Combat.legsOut(body)) then
        m.downSince = m.downSince or LF.tick
        if LF.tick - m.downSince > STUCK_DOWN then
            unstick(id, body, m, "on the ground for " .. math.floor((LF.tick - m.downSince) / 60) .. " s")
            m.downSince = nil
        end
    else
        m.downSince = nil
    end
    end
    -- (Idle, or watching a quiet quarter, with his squad seeing nobody: he thinks once a second.)
    local quiet = (m.state == "idle" or m.state == "guard") and rec.squad and LF.SquadBrain.enabled
        and not LF.SquadBrain.seesAny(rec.squad)
    if every(m, "thinkAt", (quiet and CFG.quietThinkTicks or CFG.thinkTicks) * (lod or 1)) then
        if LF.Combat.health(body) <= 0 then
            m.zeroSince = m.zeroSince or LF.tick
            if LF.tick - m.zeroSince > 120 then
                LF.log("BRAIN #" .. id .. " health 0 but still standing; finishing off")
                LF.guard("finish off", finishOff, body)
                return
            end
        else
            m.zeroSince = nil
        end
        -- Staggering, down on the ground or getting up: nothing else until he's on his feet.
        if LF.Combat.knockedDown(body) then return end
        m.crawl = LF.Combat.updateCrawl(body)
        local tD = getTimestampMs()
        LF.Brain.decide(id, body, rec, m)
        LF.Perf.stop("brain decide", tD)
        -- Moving under orders (a bound, a flank, the run to his cover): can't be pinned until
        -- he is in position.
        local moving = m.state == "bound" or m.state == "file" or (m.order ~= nil and m.order ~= "bearings" and m.cover ~= nil and not isAt(body, m.cover))
        LF.Suppress.setMoving(id, moving)
    end
    if LF.Combat.knockedDown(body) then return end
    local tA = getTimestampMs()
    LF.Brain.act(id, body, rec, m)
    LF.Perf.stop("brain act", tA)
end

local lodCount = {}     -- record id -> beats counted (level of detail, 0.76)
LF.Brain.lodStats = { 0, 0, 0 }
local function onTick()
    if not LF.Brain.enabled then return end
    local t0 = LF.Perf.start()
    local p = getPlayer()
    local px, py = nil, nil
    if p then px, py = p:getX(), p:getY() end
    local nearSq, farSq = CFG.lodNear * CFG.lodNear, CFG.lodFar * CFG.lodFar
    for id, body in pairs(LF.Bodies.all()) do
        if LF.due(CFG.actTicks, -id) then
            local rec = LF.Records.get(id)
            if rec and not body:isDead() then
                -- (Level of detail: a man far from you steps on every 2nd or 3rd of his beats.)
                local lod = 1
                if px then
                    local d2 = LF.distSq(body:getX(), body:getY(), px, py)
                    if d2 > farSq then lod = 3 elseif d2 > nearSq then lod = 2 end
                end
                local n = (lodCount[id] or 0) + 1
                lodCount[id] = n
                if n % lod == 0 then
                    LF.Brain.lodStats[lod] = LF.Brain.lodStats[lod] + 1
                    LF.guard("brain step", stepNpc, id, body, rec, lod)
                end
            end
        end
    end
    if LF.due(CFG.cleanupTicks, 0) then
        for id in pairs(minds) do
            if not LF.Bodies.get(id) then
                LF.Cover.release(id)
                LF.Posture.forget(id)
                LF.Suppress.forget(id)
                LF.Weapons.forget(id)
                claims[id] = nil
                minds[id] = nil
                lodCount[id] = nil
            end
        end
    end
    LF.Perf.stop("brain", t0)
end

-- What a soldier is doing right now: state, detail (for the inspect window). nil if unknown.
function LF.Brain.stateOf(id)
    local m = minds[id]
    if not m then return nil end
    return m.state, m.detail
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
                .. ((rec.faction ~= "CIV" or LF.Combat.isArmed(body))
                    and (" weapon=" .. LF.Weapons.profile(rec).name .. " rounds=" .. LF.Weapons.rounds(body)) or "")
                .. " crouched=" .. tostring(body:isSneaking())
                .. " running=" .. tostring(body:isRunning()) .. " sprinting=" .. tostring(body:isSprinting())
                .. " anim=" .. tostring(body:getCurrentActionContextStateName())
                .. " health=" .. math.floor(LF.Combat.health(body)) .. " dead=" .. tostring(body:isDead()))
        end
    end
    LF.say("Brain report written to log")
end

LF.on("OnTick", "Brain", onTick)

-- Once a minute: how many scans marching men started (to check patrols scan as they walk).
LF.on("OnTick", "Brain", function()
    if not LF.due(3600, 1800) then return end
    local n = LF.Brain.scans or 0
    if n > 0 then LF.log("PATROL " .. n .. " scans started by marching men in the last minute") end
    LF.Brain.scans = 0
end)
