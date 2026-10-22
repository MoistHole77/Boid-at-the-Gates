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

-- Walk to a free square near (x, y). Tries a few spots. Returns true if a walk was queued.
function LF.Brain.walkNear(body, x, y, z, spread)
    local cell = getCell()
    for _ = 1, 6 do
        local sq = cell:getGridSquare(math.floor(x + ZombRand(-spread, spread + 1)),
                                      math.floor(y + ZombRand(-spread, spread + 1)), math.floor(z))
        if sq and sq:isFree(false) then
            ISTimedActionQueue.clear(body)
            ISTimedActionQueue.add(ISWalkToTimedAction:new(body, sq))
            return true
        end
    end
    return false
end
local walkNear = LF.Brain.walkNear

local function setState(id, rec, m, state, detail)
    if m.state == state then return end
    LF.log("BRAIN #" .. id .. " " .. LF.Records.fullName(rec) .. " [" .. rec.faction .. "] "
        .. m.state .. " -> " .. state .. (detail and (" (" .. detail .. ")") or ""))
    m.state = state
    m.combat = {}
    m.lastPath = -10000
end

-- Walk directly away from a point (re-pathing at most every reissueTicks).
local function fleeFrom(m, body, fromX, fromY)
    if LF.tick - m.lastPath <= CFG.reissueTicks then return end
    local dx, dy = body:getX() - fromX, body:getY() - fromY
    local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    if walkNear(body, body:getX() + dx / len * CFG.fleeDistance, body:getY() + dy / len * CFG.fleeDistance,
                body:getZ(), 2) then
        m.lastPath = LF.tick
    end
end

-- Close in on a target, stopping inside firing range rather than walking onto it.
local function approach(m, body, target)
    if LF.tick - m.lastPath <= CFG.reissueTicks then return end
    local dx, dy = body:getX() - target:getX(), body:getY() - target:getY()
    local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    local stop = CFG.fireRange - 5
    if walkNear(body, target:getX() + dx / len * stop, target:getY() + dy / len * stop, target:getZ(), 2) then
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
        setState(id, rec, m, "flee", "threat #" .. threatId .. " at " .. math.floor(dist) .. " tiles, health " .. math.floor(hp))
        m.targetId = threatId
        fleeFrom(m, body, threat:getX(), threat:getY())
        return
    end
    if not fighter then
        -- Unarmed civilians get away from any nearby gunfire, not just from enemies.
        local sx, sy, sd = LF.Combat.nearestRecentShot(body:getX(), body:getY(), CFG.gunfireRange)
        if sx then
            setState(id, rec, m, "flee", "gunfire " .. math.floor(sd) .. " tiles away")
            m.targetId = nil
            fleeFrom(m, body, sx, sy)
            return
        end
    end
    if threat and fighter then
        if m.state ~= "engage" then
            setState(id, rec, m, "engage", "target #" .. threatId .. " at " .. math.floor(dist)
                .. " tiles, sight " .. tostring(select(2, LF.Brain.canSee(body, threat))))
        end
        m.targetId = threatId
        m.targetDist = dist
        if dist > CFG.fireRange then approach(m, body, threat) end
        return
    end
    setState(id, rec, m, "idle")
    m.targetId = nil
    if not body:isPerformingAnAction() and ZombRand(100) < CFG.wanderChance then
        walkNear(body, rec.homeX, rec.homeY, rec.homeZ, CFG.wanderRadius)
    end
end

-- Per-tick behaviour for states that need it.
local function act(id, body, rec, m)
    if m.state == "engage" and m.targetId then
        local target = LF.Bodies.get(m.targetId)
        if target and not target:isDead()
            and LF.distSq(body:getX(), body:getY(), target:getX(), target:getY()) <= CFG.fireRange * CFG.fireRange then
            LF.Combat.engage(body, target, m.combat, m.combatOpts)
        end
    end
end

-- Extension point: later features (cover, running) hook in here without touching the loop.
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
            if not LF.Bodies.get(id) then minds[id] = nil end
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
            LF.log("BRAIN #" .. id .. " " .. LF.Records.fullName(rec) .. " [" .. rec.faction .. "] state="
                .. (m and m.state or "none") .. " target=" .. tostring(m and m.targetId)
                .. " health=" .. math.floor(LF.Combat.health(body)) .. " dead=" .. tostring(body:isDead()))
        end
    end
    LF.say("Brain report written to log")
end

Events.OnTick.Add(onTick)
