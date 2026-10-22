-- Living Front: the NPC brain, version 1.
--
-- Every NPC with a body runs a small perceive -> decide -> act loop:
--   perceive: the nearest hostile NPC it can actually see (in range, line of sight clear)
--   decide:   soldiers: badly hurt + threat -> flee; threat -> engage; otherwise idle
--             civilians: threat nearby -> flee; otherwise idle
--   act:      engage = LF.Combat.engage every tick; flee = walk away from the threat;
--             idle = occasionally wander near home
-- The player is ignored (neutral) for now.
--
-- Minds are runtime-only (not saved): after a load or respawn an NPC simply re-evaluates.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Combat"

LF.Brain = LF.Brain or {}
LF.Brain.enabled = true

local CFG = {
    thinkTicks = 20,        -- each NPC re-decides about three times a second
    sightRange = 25,        -- tiles
    fireRange = 20,         -- soldiers close in to this range before shooting
    fleeHealth = 35,        -- soldiers flee below this overall health when threatened
    civFleeRange = 20,      -- civilians flee from hostiles within this range
    gunfireRange = 25,      -- unarmed civilians flee gunfire within this range
    fleeDistance = 12,      -- how far a fleeing NPC tries to get
    reissueTicks = 180,     -- re-path a flee/approach at most this often
    wanderChance = 4,       -- percent per think, when idle
    wanderRadius = 6,       -- tiles around home
}

local minds = {}   -- record id -> { state, targetId, combat = {}, lastPath }
local tick = 0

local function mindOf(id)
    local m = minds[id]
    if not m then
        m = { state = "idle", combat = {}, lastPath = -10000 }
        minds[id] = m
    end
    return m
end

-- Line of sight between two characters, using the game's own line test.
-- Blocked and closed doors stop sight; open doors and windows don't.
local losFailed = false
function LF.Brain.canSee(a, b)
    if losFailed then return true end
    local ok, res = pcall(function()
        return tostring(LosUtil.lineClear(getCell(),
            math.floor(a:getX()), math.floor(a:getY()), math.floor(a:getZ()),
            math.floor(b:getX()), math.floor(b:getY()), math.floor(b:getZ()), false))
    end)
    if not ok then
        losFailed = true
        LF.log("BRAIN line of sight check FAILED (" .. tostring(res) .. "); assuming clear sight")
        return true
    end
    return res ~= "Blocked" and res ~= "ClearThroughClosedDoor", res
end

-- The nearest visible hostile body, its id and distance.
local function nearestThreat(id, body, rec)
    local best, bestId, bestD = nil, nil, CFG.sightRange
    for otherId, other in pairs(LF.Bodies.all()) do
        if otherId ~= id and not other:isDead() then
            local otherRec = LF.Records.get(otherId)
            if otherRec and LF.isHostile(rec.faction, otherRec.faction) then
                local d = LF.dist(body:getX(), body:getY(), other:getX(), other:getY())
                if d < bestD and LF.Brain.canSee(body, other) then
                    best, bestId, bestD = other, otherId, d
                end
            end
        end
    end
    return best, bestId, bestD
end

-- Walk to a free square near (x, y). Tries a few spots. Returns true if a walk was queued.
local function walkNear(body, x, y, z, spread)
    local cell = getCell()
    for _ = 1, 6 do
        local tx = math.floor(x + ZombRand(-spread, spread + 1))
        local ty = math.floor(y + ZombRand(-spread, spread + 1))
        local sq = cell:getGridSquare(tx, ty, math.floor(z))
        if sq and LF.try("isFree", function() return sq:isFree(false) end) then
            LF.try("walk", function()
                ISTimedActionQueue.clear(body)
                ISTimedActionQueue.add(ISWalkToTimedAction:new(body, sq))
                return true
            end)
            return true
        end
    end
    return false
end

local function setState(id, rec, m, state, detail)
    if m.state ~= state then
        LF.log("BRAIN #" .. id .. " " .. LF.Records.fullName(rec) .. " [" .. rec.faction .. "] "
            .. m.state .. " -> " .. state .. (detail and (" (" .. detail .. ")") or ""))
        m.state = state
        m.combat = {}
        m.lastPath = -10000
    end
end

-- Walk directly away from a point.
local function fleeFrom(m, body, fromX, fromY)
    if tick - m.lastPath <= CFG.reissueTicks then return end
    local dx, dy = body:getX() - fromX, body:getY() - fromY
    local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    local fx = body:getX() + dx / len * CFG.fleeDistance
    local fy = body:getY() + dy / len * CFG.fleeDistance
    if walkNear(body, fx, fy, body:getZ(), 2) then m.lastPath = tick end
end

local function think(id, body, rec)
    local m = mindOf(id)
    local threat, threatId, dist = nearestThreat(id, body, rec)
    local hp = LF.Combat.health(body)
    -- Fighters: soldiers, and civilians who are holding a gun (resistance).
    local fighter = rec.faction ~= "CIV" or LF.Combat.isArmed(body)

    -- Unarmed civilians get away from any nearby gunfire, not just from enemies.
    local shotX, shotY, shotDist = nil, nil, nil
    if not fighter then
        shotX, shotY, shotDist = LF.Combat.nearestRecentShot(body:getX(), body:getY(), CFG.gunfireRange)
    end

    if threat and ((not fighter and dist < CFG.civFleeRange) or (fighter and hp < CFG.fleeHealth)) then
        setState(id, rec, m, "flee", "threat #" .. threatId .. " at " .. math.floor(dist) .. " tiles, health " .. math.floor(hp))
        m.targetId = threatId
        fleeFrom(m, body, threat:getX(), threat:getY())
    elseif shotX then
        setState(id, rec, m, "flee", "gunfire " .. math.floor(shotDist) .. " tiles away")
        m.targetId = nil
        fleeFrom(m, body, shotX, shotY)
    elseif threat and fighter then
        setState(id, rec, m, "engage", "target #" .. threatId .. " at " .. math.floor(dist) .. " tiles, sight "
            .. tostring(select(2, LF.Brain.canSee(body, threat))))
        m.targetId = threatId
        if dist > CFG.fireRange and tick - m.lastPath > CFG.reissueTicks then
            -- Too far to shoot well: close in to a point inside firing range, not onto the target.
            local dx, dy = body:getX() - threat:getX(), body:getY() - threat:getY()
            local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
            local stop = CFG.fireRange - 5
            if walkNear(body, threat:getX() + dx / len * stop, threat:getY() + dy / len * stop, threat:getZ(), 2) then
                m.lastPath = tick
            end
        end
    else
        setState(id, rec, m, "idle")
        m.targetId = nil
        if not body:isPerformingAnAction() and ZombRand(100) < CFG.wanderChance then
            walkNear(body, rec.homeX, rec.homeY, rec.homeZ, CFG.wanderRadius)
        end
    end
end

local function onTick()
    tick = tick + 1
    if not LF.Brain.enabled then return end
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and not body:isDead() then
            if (tick + id) % CFG.thinkTicks == 0 then
                think(id, body, rec)
            end
            -- Engaged soldiers step their combat every tick (turning needs it).
            local m = minds[id]
            if m and m.state == "engage" and m.targetId then
                local target = LF.Bodies.get(m.targetId)
                if target and not target:isDead() then
                    local d = LF.dist(body:getX(), body:getY(), target:getX(), target:getY())
                    if d <= CFG.fireRange then LF.Combat.engage(body, target, m.combat) end
                end
            end
        end
    end
    -- Forget minds whose body is gone.
    for id in pairs(minds) do
        if not LF.Bodies.get(id) then minds[id] = nil end
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

Events.OnTick.Add(function()
    LF.try("brain tick", function() onTick(); return true end)
end)
