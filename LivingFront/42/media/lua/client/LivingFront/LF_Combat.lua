-- Living Front: NPC-vs-NPC gunfire.
--
-- How it works (each point was established by testing; see notes for why):
--   * The engine's own aim/fire pipeline is unusable for our NPCs: for an NPC, isAiming()
--     returns a hidden AI component value Lua cannot set.
--   * Instead, LF_ShootAction (a timed action) plays the game's rifle aim/fire clips, registered
--     as action animations, and resolves the shot when the fire clip starts.
--   * The visible model only turns through idle turning animations, so the shooter turns BEFORE
--     the aim starts, and waits until the drawn angle has caught up.
--   * The rifle clips hold the rifle 45 degrees left of the body (bladed stance), so the body
--     turns 45 degrees right of the target to put the rifle on it.
--   * Hit() does nothing to an IsoPlayer NPC; damage is a firearm wound on a body part plus an
--     immediate health loss by location, and a flinch action.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_ShootAction"

LF.Combat = LF.Combat or {}

local RIFLE = "Base.HuntingRifle"
local FIRE_TICKS = 150          -- minimum ticks between one shooter's shots (about 2.5 s)
local TURN_TIMEOUT = 180        -- fire anyway if the turn has not finished after this many ticks
local AIM_YAW_OFFSET = 45       -- see header; +45 is to the right on the map grid (y points south)

-- Where a hit lands (weighted by repetition) and the immediate health it takes, on top of
-- the bleeding wound the engine applies.
local BODY_PARTS = { "Torso_Upper", "Torso_Upper", "Torso_Lower", "Torso_Lower", "UpperArm_L", "UpperArm_R",
                     "UpperLeg_L", "UpperLeg_R", "Head" }
local IMPACT = { Head = 70, Torso_Upper = 30, Torso_Lower = 25, UpperArm_L = 10, UpperArm_R = 10,
                 UpperLeg_L = 12, UpperLeg_R = 12 }

local tick = 0

local function fmt(v)
    if type(v) ~= "number" then return tostring(v) end
    return string.format("%.1f", v)
end

function LF.Combat.health(body)
    return LF.try("overallHealth", function() return body:getBodyDamage():getOverallBodyHealth() end) or 0
end

local function idOf(body)
    return body:getModData().LF_id
end

local function angleDiff(a, b)
    return math.abs((a - b + 540) % 360 - 180)
end

local function loadGun(gun)
    LF.try("load gun", function()
        gun:setCurrentAmmoCount(gun:getMaxAmmo())
        if gun:getMagazineType() ~= nil then gun:setContainsClip(true) end
        gun:setRoundChambered(true)
        gun:setJammed(false)
        return true
    end)
end

-- Give a body a loaded rifle in both hands. Returns the gun.
function LF.Combat.arm(body)
    local gun = body:getPrimaryHandItem()
    if not (gun and instanceof(gun, "HandWeapon") and gun:isRanged()) then
        gun = LF.try("add rifle", function() return body:getInventory():AddItem(RIFLE) end)
        if not gun then return nil end
        LF.try("equip rifle", function()
            body:setPrimaryHandItem(gun)
            if gun:isTwoHandWeapon() then body:setSecondaryHandItem(gun) end
            return true
        end)
    end
    loadGun(gun)
    return gun
end

local function aimBodyAngle(shooter, target)
    local dx, dy = target:getX() - shooter:getX(), target:getY() - shooter:getY()
    return math.deg(math.atan2(dy, dx)) + AIM_YAW_OFFSET
end
LF.Combat.aimBodyAngle = aimBodyAngle

-- Degrees between where the drawn body points and where it must point to hit the target.
function LF.Combat.stanceError(shooter, target)
    return LF.try("stance error", function() return angleDiff(shooter:getAnimAngle(), aimBodyAngle(shooter, target)) end) or 999
end

-- Is this body holding a firearm?
function LF.Combat.isArmed(body)
    local item = body:getPrimaryHandItem()
    return item ~= nil and instanceof(item, "HandWeapon") and item:isRanged()
end

-- Recent gunfire, so non-combatants can react to fighting they are not part of.
local recentShots = {}   -- { x, y, tick }
local SHOT_MEMORY = 600  -- ticks (about 10 s)

function LF.Combat.now()
    return tick
end

-- The nearest shot fired within range in the last SHOT_MEMORY ticks: x, y, distance.
function LF.Combat.nearestRecentShot(x, y, range)
    local bx, by, bd = nil, nil, range
    for i = #recentShots, 1, -1 do
        local s = recentShots[i]
        if tick - s.tick > SHOT_MEMORY then
            table.remove(recentShots, i)
        else
            local d = LF.dist(x, y, s.x, s.y)
            if d < bd then bx, by, bd = s.x, s.y, d end
        end
    end
    return bx, by, bx and bd or nil
end

-- Turn the body into the bladed aiming stance; ready once the drawn body has caught up.
function LF.Combat.readyToFire(shooter, target)
    local want = aimBodyAngle(shooter, target)
    LF.try("face aim point", function()
        local r = math.rad(want)
        shooter:faceLocation(shooter:getX() + math.cos(r) * 5, shooter:getY() + math.sin(r) * 5)
        return true
    end)
    local err = LF.try("anim angle", function() return angleDiff(shooter:getAnimAngle(), want) end) or 999
    local turning = LF.try("turning", function() return shooter:isTurning() or shooter:shouldBeTurning() end)
    return (err < 15 and not turning), err
end

-- Hit chance falls off with distance and drops when the shooter is badly hurt.
local function hitChance(shooter, dist)
    local chance = 75 - dist * 2.5
    if chance < 20 then chance = 20 end
    if chance > 75 then chance = 75 end
    local hp = LF.Combat.health(shooter)
    if hp < 50 then chance = chance * (0.5 + hp / 100) end
    return chance
end

-- Resolve one shot: sound, noise, hit roll, and on a hit a wound, impact damage and a flinch.
function LF.Combat.resolveShot(shooter, target, gun)
    LF.try("shot sound", function() shooter:playSound(gun:getSwingSound()); return true end)
    LF.try("shot noise", function() shooter:addWorldSoundUnlessInvisible(40, 100, false); return true end)
    recentShots[#recentShots + 1] = { x = shooter:getX(), y = shooter:getY(), tick = tick }
    local stanceErr = LF.Combat.stanceError(shooter, target)

    local dist = LF.dist(shooter:getX(), shooter:getY(), target:getX(), target:getY())
    local chance = hitChance(shooter, dist)
    local result = "MISS"
    if ZombRand(100) < chance then
        local partName = LF.pick(BODY_PARTS)
        LF.try("firearm wound", function()
            target:getBodyDamage():getBodyPart(BodyPartType[partName]):damageFromFirearm(gun:getMaxDamage() * 25)
            return true
        end)
        LF.try("impact damage", function()
            target:getBodyDamage():ReduceGeneralHealth(IMPACT[partName] or 15)
            return true
        end)
        LF.try("flinch", function()
            ISTimedActionQueue.clear(target)
            ISTimedActionQueue.add(LF_FlinchAction:new(target))
            return true
        end)
        result = "HIT " .. partName
    end
    LF.log("SHOT #" .. tostring(idOf(shooter)) .. " -> #" .. tostring(idOf(target)) .. " dist=" .. fmt(dist)
        .. " chance=" .. fmt(chance) .. " " .. result .. " stanceErr=" .. fmt(stanceErr)
        .. " targetHealth=" .. fmt(LF.Combat.health(target)))
end

-- One engagement step, called every tick while an NPC is fighting a target.
-- state is a per-shooter table owned by the caller ({} to start).
function LF.Combat.engage(shooter, target, state)
    if shooter:isPerformingAnAction() then return end
    if state.nextFire and tick < state.nextFire then
        -- Between shots: hold the aiming stance, only correcting for target movement.
        LF.Combat.readyToFire(shooter, target)
        return
    end
    state.turnStart = state.turnStart or tick
    local ready, err = LF.Combat.readyToFire(shooter, target)
    if not ready and tick - state.turnStart < TURN_TIMEOUT then return end
    if not ready then
        LF.log("TURN TIMEOUT #" .. tostring(idOf(shooter)) .. " firing anyway, stanceErr=" .. fmt(err))
    end

    state.turnStart = nil
    state.nextFire = tick + FIRE_TICKS + ZombRand(60)
    local gun = LF.Combat.arm(shooter)
    if not gun then return end
    LF.try("queue shoot action", function()
        ISTimedActionQueue.add(LF_ShootAction:new(shooter, target, gun, function(s, t)
            LF.Combat.resolveShot(s, t, gun)
        end))
        return true
    end)
end

function LF.Combat.armAllSoldiers()
    local n = 0
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and rec.faction ~= "CIV" and LF.Combat.arm(body) then n = n + 1 end
    end
    LF.log("COMBAT armed " .. n .. " soldiers with " .. RIFLE)
    LF.say("Armed " .. n .. " soldiers")
end

Events.OnTick.Add(function() tick = tick + 1 end)
