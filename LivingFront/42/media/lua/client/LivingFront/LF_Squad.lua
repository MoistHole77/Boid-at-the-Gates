-- Living Front: what a squad knows and where its men belong (runtime only, not saved).
--
--   contacts  - enemies any member has seen, with where and when; they fade after a while, so a
--               soldier who can't see an enemy himself still knows roughly where the fight is
--   leaders   - enemies the squad has recognised as leaders (priority targets)
--   formation - each soldier's slot, placed from the squad leader's position and the squad's
--               facing; the slot is his anchor (the cohesion leash is measured from it)

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Units"
require "LivingFront/LF_Bodies"

LF.Squad = LF.Squad or {}

local know = {}     -- squad id -> { contacts = { [enemyId] = c }, leaders = { [enemyId] = true } }

local function knowledge(squadId)
    local k = know[squadId]
    if not k then
        k = { contacts = {}, leaders = {} }
        know[squadId] = k
    end
    return k
end

Events.OnInitGlobalModData.Add(function() know = {} end)

function LF.Squad.forgetAll() know = {} end

-- ---- contacts -------------------------------------------------------------------------------

-- A member saw an enemy body: remember where it was.
function LF.Squad.report(squadId, enemyId, enemy)
    local c = knowledge(squadId).contacts[enemyId]
    if not c then
        c = { id = enemyId }
        knowledge(squadId).contacts[enemyId] = c
    end
    c.x, c.y, c.z, c.tick = enemy:getX(), enemy:getY(), enemy:getZ(), LF.tick
end

-- The nearest contact to (x, y) seen within maxAge ticks and within range. Old contacts and
-- contacts on enemies now dead are dropped. Returns the contact table or nil.
function LF.Squad.bestContact(squadId, x, y, maxAge, range)
    local k = know[squadId]
    if not k then return nil end
    local best, bestSq = nil, range * range
    for enemyId, c in pairs(k.contacts) do
        local rec = LF.Records.get(enemyId)
        if LF.tick - c.tick > maxAge or not rec or not rec.alive then
            k.contacts[enemyId] = nil
        else
            local dsq = LF.distSq(x, y, c.x, c.y)
            if dsq < bestSq then best, bestSq = c, dsq end
        end
    end
    return best
end

-- ---- enemy leaders --------------------------------------------------------------------------

function LF.Squad.knowsLeader(squadId, enemyId)
    local k = know[squadId]
    return k ~= nil and k.leaders[enemyId] == true
end

function LF.Squad.markLeader(squadId, enemyId)
    knowledge(squadId).leaders[enemyId] = true
end

-- ---- formation ------------------------------------------------------------------------------

-- Where the squad is: its leader's body if he has one, else his record. x, y, z or nil.
function LF.Squad.anchor(squadId)
    local squad = LF.Units.get(squadId)
    if not (squad and squad.leader) then return nil end
    local body = LF.Bodies.get(squad.leader)
    if body and not body:isDead() then return body:getX(), body:getY(), body:getZ() end
    local rec = LF.Records.get(squad.leader)
    if rec and rec.alive then return rec.x, rec.y, rec.z end
    return nil
end

-- A soldier's formation slot in world coordinates: x, y, z (nil if his squad has no leader).
function LF.Squad.slot(rec)
    local squad = LF.Units.get(rec.squad)
    if not squad then return nil end
    local ax, ay, az = LF.Squad.anchor(rec.squad)
    if not ax then return nil end
    local fwd, lat = LF.Units.slotOffset(rec)
    local fx, fy = squad.facingX or 1, squad.facingY or 0
    return ax + fx * fwd - fy * lat, ay + fy * fwd + fx * lat, az
end

-- The squad's rear: where the wounded fall back to (behind the leader, away from the front).
function LF.Squad.rear(rec, distance)
    local squad = LF.Units.get(rec.squad)
    if not squad then return nil end
    local ax, ay, az = LF.Squad.anchor(rec.squad)
    if not ax then return nil end
    local d = distance or 8
    return ax - (squad.facingX or 1) * d, ay - (squad.facingY or 0) * d, az
end
