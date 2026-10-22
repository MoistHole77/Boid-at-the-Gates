-- Living Front: the NPC brain.
--
-- Every NPC with a body runs a perceive -> decide -> act loop:
--   perceive (on its think tick): the nearest hostile NPC it can actually see, plus gunfire
--   decide   (on its think tick): pick a state
--              fighters (soldiers, armed civilians): badly hurt + threat -> flee;
--                                                    threat -> engage; otherwise idle
--              unarmed civilians: threat or gunfire nearby -> flee; otherwise idle
--   act      (every tick for states that need it): engage steps combat; others act on think
-- The player is ignored (neutral) for now.
--
-- Minds are runtime-only (not saved): after a load or respawn an NPC simply re-evaluates.
-- Each NPC's step runs inside one guarded call, so one failing NPC can't stop the others and
-- no closures are allocated per tick.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Combat"
require "LivingFront/LF_Cover"
require "LivingFront/LF_MoveAction"

LF.Brain = LF.Brain or {}
LF.Brain.enabled = true

local CFG = {
    thinkTicks = 20,        -- each NPC re-decides about three times a second
    sightRange = 25,        -- tiles
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
}
LF.Brain.CFG = CFG

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

-- Line of sight between two characters, using the game's own line test.
-- Blocked and closed doors stop sight; open doors and windows don't.
local function lineResult(a, b)
    return tostring(LosUtil.lineClear(getCell(),
        math.floor(a:getX()), math.floor(a:getY()), math.floor(a:getZ()),
        math.floor(b:getX()), math.floor(b:getY()), math.floor(b:getZ()), false))
end

local losFailed = false
function LF.Brain.canSee(a, b)
    if losFailed then return true, "unknown" end
    local ok, res = pcall(lineResult, a, b)
    if not ok then
        losFailed = true
        LF.log("BRAIN line of sight check FAILED (" .. tostring(res) .. "); assuming clear sight")
        return true, "unknown"
    end
    return res ~= "Blocked" and res ~= "ClearThroughClosedDoor", res
end

-- The nearest visible hostile body: body, id, distance. Candidates are sorted by distance and
-- line of sight is only tested until the first visible one (it is the most expensive check).
local candidates = {}
local function byDist(a, b) return a.dsq < b.dsq end

local function nearestThreat(id, body, rec)
    local bx, by = body:getX(), body:getY()
    local rangeSq = CFG.sightRange * CFG.sightRange
    local n = 0
    for otherId, other in pairs(LF.Bodies.all()) do
        if otherId ~= id and not other:isDead() then
            local otherRec = LF.Records.get(otherId)
            if otherRec and LF.isHostile(rec.faction, otherRec.faction) then
                local dsq = LF.distSq(bx, by, other:getX(), other:getY())
                if dsq < rangeSq then
                    n = n + 1
                    local c = candidates[n] or {}
                    c.body, c.id, c.dsq = other, otherId, dsq
                    candidates[n] = c
                end
            end
        end
    end
    for i = #candidates, n + 1, -1 do candidates[i] = nil end
    if n > 1 then table.sort(candidates, byDist) end
    for i = 1, n do
        local c = candidates[i]
        if LF.Brain.canSee(body, c.body) then
            return c.body, c.id, math.sqrt(c.dsq)
        end
    end
    return nil
end

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
    if body:isSneaking() then body:setSneaking(false) end
end

local function setState(id, body, rec, m, state, detail)
    if m.state == state then return end
    LF.log("BRAIN #" .. id .. " " .. LF.Records.fullName(rec) .. " [" .. rec.faction .. "] "
        .. m.state .. " -> " .. state .. (detail and (" (" .. detail .. ")") or ""))
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

-- Fighters: keep or find a firing position behind low cover facing the threat.
local function planCover(id, body, m, threat)
    if m.cover then
        local q = LF.Cover.quality(m.cover.x, m.cover.y, m.cover.z, threat:getX(), threat:getY())
        local reached = isAt(body, m.cover)
        if q ~= LF.Cover.LOW or (not reached and LF.tick - m.cover.since > CFG.coverGiveUpTicks) then
            leavePosition(id, body, m)   -- threat moved around it, or we can't get there
        else
            resumeWalk(body, m, m.cover)
            return
        end
    end
    -- Already standing behind usable cover?
    local bx, by, bz = math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ())
    if LF.Cover.of(body, threat) == LF.Cover.LOW and LF.Brain.canSee(body, threat) then
        takeSpot(id, body, m, "cover", bx, by, bz, "cover")
        return
    end
    if LF.tick - (m.lastCoverSearch or -10000) < CFG.coverSearchTicks then return end
    m.lastCoverSearch = LF.tick
    local x, y, z = LF.Cover.findFiringPosition(id, body, threat, CFG.fireRange)
    if x then takeSpot(id, body, m, "cover", x, y, z, "cover") end
end

-- Wounded fighters: find somewhere out of the threat's sight before simply running.
local function planHide(id, body, m, threat)
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
    local x, y, z = LF.Cover.findHidingSpot(id, body, threat)
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

local function decide(id, body, rec, m)
    local threat, threatId, dist = nearestThreat(id, body, rec)
    local hp = LF.Combat.health(body)
    -- Fighters: soldiers, and civilians who are holding a gun (resistance).
    local fighter = rec.faction ~= "CIV" or LF.Combat.isArmed(body)
    m.fighter = fighter

    if threat and ((not fighter and dist < CFG.civFleeRange) or (fighter and hp < CFG.fleeHealth)) then
        setState(id, body, rec, m, "flee", "threat #" .. threatId .. " at " .. math.floor(dist) .. " tiles, health " .. math.floor(hp))
        m.targetId = threatId
        if not (fighter and planHide(id, body, m, threat)) then
            -- Civilians sprint for it; a wounded soldier runs (the engine turns an injured
            -- sprint into a run anyway).
            fleeFrom(m, body, threat:getX(), threat:getY(), fighter and "run" or "sprint")
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
    if threat and fighter then
        if m.state ~= "engage" then
            setState(id, body, rec, m, "engage", "target #" .. threatId .. " at " .. math.floor(dist)
                .. " tiles, sight " .. tostring(select(2, LF.Brain.canSee(body, threat))))
        end
        m.targetId = threatId
        m.targetDist = dist
        planCover(id, body, m, threat)
        if not m.cover and dist > CFG.fireRange then approach(m, body, threat, dist) end
        return
    end
    setState(id, body, rec, m, "idle")
    m.targetId = nil
    if not body:isPerformingAnAction() and ZombRand(100) < CFG.wanderChance then
        walkNear(body, rec.homeX, rec.homeY, rec.homeZ, CFG.wanderRadius, "walk")
    end
end

-- Crouch while holding a position, but only when not mid-action: the aim/fire actions play
-- standing clips, so a crouched soldier pops up to shoot and drops back down afterwards.
local function hunkerDown(body)
    if not body:isPerformingAnAction() and not body:isSneaking() then body:setSneaking(true) end
end

-- Per-tick behaviour for states that need it.
local function act(id, body, rec, m)
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
                minds[id] = nil
            end
        end
    end
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
            LF.log("BRAIN #" .. id .. " " .. LF.Records.fullName(rec) .. " [" .. rec.faction .. "] state="
                .. (m and m.state or "none") .. " target=" .. tostring(m and m.targetId)
                .. " position=" .. (spot and (spot.x .. "," .. spot.y .. (isAt(body, spot) and " (there)" or " (en route)")) or "none")
                .. " crouched=" .. tostring(body:isSneaking())
                .. " running=" .. tostring(body:isRunning()) .. " sprinting=" .. tostring(body:isSprinting())
                .. " anim=" .. tostring(body:getCurrentActionContextStateName())
                .. " health=" .. math.floor(LF.Combat.health(body)) .. " dead=" .. tostring(body:isDead()))
        end
    end
    LF.say("Brain report written to log")
end

Events.OnTick.Add(onTick)
