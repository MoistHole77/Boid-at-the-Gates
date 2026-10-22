-- Living Front: NPC-vs-NPC gunfire.
--
-- How it works (each point was established by testing; see README "Engine findings"):
--   * The engine's own aim/fire pipeline is unusable for NPCs, so LF_ShootAction plays the
--     game's rifle clips and resolves the shot itself.
--   * The shooter turns into the aiming stance with the normal turning animation first, and
--     only starts aiming once the drawn body has caught up; while aiming it tracks the target.
--   * The rifle clips hold the rifle 45 degrees left of the body (bladed stance), so the body
--     turns 45 degrees right of the target to put the rifle on it.
--   * Hit() does nothing to an IsoPlayer NPC; damage is a firearm wound on a body part plus an
--     immediate health loss by location, and a flinch action.
--
-- Hot-path functions here (readyToFire, engage, stanceError) make direct engine calls: the
-- brain runs each NPC's step inside one guarded call, which is far cheaper than wrapping every
-- call in its own pcall closure.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_ShootAction"
require "LivingFront/LF_Suppress"
require "LivingFront/LF_Sense"
require "LivingFront/LF_Weapons"

LF.Combat = LF.Combat or {}

local TURN_TIMEOUT = 180        -- fire anyway if the turn has not finished after this many ticks
local AIM_YAW_OFFSET = 45       -- +45 is to the right on the map grid (y points south)
local SHOT_MEMORY = 600         -- how long gunfire is remembered (ticks, about 10 s)
local AREA_FIRE_SLOWER = 1.5    -- area fire (at a last-known position) is paced slower than aimed fire
-- Suppression added per round (see LF_Suppress), scaled by the weapon's `suppress`.
local SUPPRESS_HIT, SUPPRESS_MISS, SUPPRESS_SPLASH = 45, 30, 15
local SPLASH_RADIUS = 2         -- tiles around the target that a shot also suppresses
local AREA_RADIUS, SUPPRESS_AREA = 3, 25

-- Where a hit lands (weighted by repetition) and the immediate health it takes, on top of
-- the bleeding wound the engine applies.
local BODY_PARTS = { "Torso_Upper", "Torso_Upper", "Torso_Lower", "Torso_Lower", "UpperArm_L", "UpperArm_R",
                     "UpperLeg_L", "UpperLeg_R", "Head" }
local IMPACT = { Head = 70, Torso_Upper = 30, Torso_Lower = 25, UpperArm_L = 10, UpperArm_R = 10,
                 UpperLeg_L = 12, UpperLeg_R = 12 }

local recentShots = {}          -- { x, y, tick }

local function fmt(v)
    if type(v) ~= "number" then return tostring(v) end
    return string.format("%.1f", v)
end

local function angleDiff(a, b)
    return math.abs((a - b + 540) % 360 - 180)
end

local function overallHealth(body)
    return body:getBodyDamage():getOverallBodyHealth()
end

function LF.Combat.health(body)
    return LF.guard("overallHealth", overallHealth, body) or 0
end

-- Is this body holding a firearm?
function LF.Combat.isArmed(body)
    local item = body:getPrimaryHandItem()
    return item ~= nil and instanceof(item, "HandWeapon") and item:isRanged()
end

local function loadGun(gun)
    gun:setCurrentAmmoCount(gun:getMaxAmmo())
    if gun:getMagazineType() ~= nil then gun:setContainsClip(true) end
    gun:setRoundChambered(true)
    gun:setJammed(false)
end

local function equipGun(body, itemType)
    local gun = body:getInventory():AddItem(itemType)
    body:setPrimaryHandItem(gun)
    if gun:isTwoHandWeapon() then body:setSecondaryHandItem(gun) end
    return gun
end

-- Make sure a body holds its own weapon (LF_Weapons: Kar98k, Mosin, MP40 or PPSh), loaded and in
-- both hands. Returns the gun.
function LF.Combat.arm(body)
    local profile = LF.Weapons.profileOf(body)
    local gun = body:getPrimaryHandItem()
    if not (gun and instanceof(gun, "HandWeapon") and gun:isRanged() and gun:getFullType() == profile.item) then
        gun = LF.guard("equip " .. profile.name, equipGun, body, profile.item)
        if not gun then return nil end
        LF.guard("load gun", loadGun, gun)
    end
    return gun
end

-- Body angle that puts the rifle on the target (atan2 degrees on the map grid).
function LF.Combat.aimBodyAngle(shooter, target)
    local dx, dy = target:getX() - shooter:getX(), target:getY() - shooter:getY()
    return math.deg(math.atan2(dy, dx)) + AIM_YAW_OFFSET
end

-- Degrees between where the drawn body points and where it must point to hit the target.
function LF.Combat.stanceError(shooter, target)
    return angleDiff(shooter:getAnimAngle(), LF.Combat.aimBodyAngle(shooter, target))
end

-- Turn the body into the aiming stance; ready once the drawn body has caught up.
-- Returns ready, error in degrees.
function LF.Combat.readyToFire(shooter, target)
    local want = LF.Combat.aimBodyAngle(shooter, target)
    local r = math.rad(want)
    shooter:faceLocation(shooter:getX() + math.cos(r) * 5, shooter:getY() + math.sin(r) * 5)
    local err = angleDiff(shooter:getAnimAngle(), want)
    return (err < 15 and not shooter:isTurning() and not shooter:shouldBeTurning()), err
end

-- The nearest shot fired within range in the last SHOT_MEMORY ticks: x, y, distance.
-- Also prunes old shots.
function LF.Combat.nearestRecentShot(x, y, range)
    local now = LF.tick
    local bx, by, bestSq = nil, nil, range * range
    for i = #recentShots, 1, -1 do
        local shot = recentShots[i]
        if now - shot.tick > SHOT_MEMORY then
            table.remove(recentShots, i)
        else
            local dsq = LF.distSq(x, y, shot.x, shot.y)
            if dsq < bestSq then bx, by, bestSq = shot.x, shot.y, dsq end
        end
    end
    if not bx then return nil end
    return bx, by, math.sqrt(bestSq)
end

-- Hit chance (percent) for one round: the weapon's accuracy falls off with distance (steeply
-- for submachine guns); a badly hurt or suppressed shooter aims worse. Target modifiers (cover,
-- crouching) come from LF.Combat.targetModifier (LF_Cover.lua).
local function hitChance(shooter, target, dist, profile)
    local chance = profile.accBase - dist * profile.accFall
    if chance < profile.accMin then chance = profile.accMin elseif chance > profile.accBase then chance = profile.accBase end
    local hp = LF.Combat.health(shooter)
    if hp < 50 then chance = chance * (0.5 + hp / 100) end
    chance = chance * LF.Suppress.accuracy(shooter)
    if LF.Combat.targetModifier then
        chance = chance * (LF.guard("cover modifier", LF.Combat.targetModifier, shooter, target) or 1)
    end
    return chance
end

local function wound(target, partName, profile)
    target:getBodyDamage():getBodyPart(BodyPartType[partName]):damageFromFirearm(profile.wound)
    target:getBodyDamage():ReduceGeneralHealth((IMPACT[partName] or 15) * profile.impact)
end

local function flinch(target)
    ISTimedActionQueue.clear(target)
    ISTimedActionQueue.add(LF_FlinchAction:new(target))
end

LF.Combat.shotCount = 0
local function shotEffects(shooter, gun)
    LF.Combat.shotCount = LF.Combat.shotCount + 1
    shooter:playSound(gun:getSwingSound())
    shooter:addWorldSoundUnlessInvisible(40, 100, false)
end

-- Suppress everyone hostile to the shooter within radius of (x, y), except `skip`.
local splashCtx = {}
local function splashOne(e, _dsq, ctx)
    if e.body ~= ctx.skip and LF.isHostile(ctx.faction, e.rec.faction) then
        LF.Suppress.add(e.body, ctx.amount)
        ctx.n = ctx.n + 1
    end
end
local function splash(shooter, x, y, radius, amount, skip)
    local rec = LF.Records.get(shooter:getModData().LF_id)
    if not rec then return 0 end
    splashCtx.faction, splashCtx.amount, splashCtx.skip, splashCtx.n = rec.faction, amount, skip, 0
    LF.Sense.near(x, y, radius, splashOne, splashCtx)
    return splashCtx.n
end

-- Resolve one round: sound, noise, hit roll, and on a hit a wound, impact damage and a flinch.
-- The target and anyone hostile right next to it are suppressed either way. Returns false (and
-- fires nothing) if the magazine is empty.
function LF.Combat.resolveShot(shooter, target, gun)
    if not LF.Weapons.useRound(shooter) then return false end
    local profile = LF.Weapons.profileOf(shooter)
    LF.guard("shot effects", shotEffects, shooter, gun)
    recentShots[#recentShots + 1] = { x = shooter:getX(), y = shooter:getY(), tick = LF.tick }
    if #recentShots > 64 then LF.Combat.nearestRecentShot(0, 0, 1) end   -- prune old shots

    local dist = LF.dist(shooter:getX(), shooter:getY(), target:getX(), target:getY())
    local chance = hitChance(shooter, target, dist, profile)
    local result = "MISS"
    if ZombRand(100) < chance then
        local parts = LF.Combat.hitParts and LF.guard("hit parts", LF.Combat.hitParts, shooter, target)
        local partName = LF.pick(parts or BODY_PARTS)
        LF.guard("wound", wound, target, partName, profile)
        LF.guard("flinch", flinch, target)
        result = "HIT " .. partName
    end
    LF.Suppress.add(target, (result == "MISS" and SUPPRESS_MISS or SUPPRESS_HIT) * profile.suppress)
    splash(shooter, target:getX(), target:getY(), SPLASH_RADIUS, SUPPRESS_SPLASH * profile.suppress, target)
    if LF.Config.logShots then
        LF.log("SHOT #" .. tostring(shooter:getModData().LF_id) .. " " .. profile.name .. " -> #" .. tostring(target:getModData().LF_id)
            .. " dist=" .. fmt(dist) .. " chance=" .. fmt(chance) .. " " .. result
            .. " stanceErr=" .. fmt(LF.Combat.stanceError(shooter, target))
            .. " targetHealth=" .. fmt(LF.Combat.health(target)))
    end
    return true
end

-- One engagement step, called every tick while an NPC is fighting a target.
-- state is a per-shooter table owned by the caller ({} to start).
-- opts (optional): aimAnim / fireAnim to use (e.g. crouched clips).
function LF.Combat.engage(shooter, target, state, opts)
    if shooter:isPerformingAnAction() then return end
    if LF.Weapons.rounds(shooter) <= 0 then
        LF.Weapons.reload(shooter, LF.Combat.arm(shooter), "empty")
        return
    end
    if state.nextFire and LF.tick < state.nextFire then
        -- Between shots: hold the aiming stance, only correcting for target movement.
        LF.Combat.readyToFire(shooter, target)
        return
    end
    state.turnStart = state.turnStart or LF.tick
    local ready, err = LF.Combat.readyToFire(shooter, target)
    if not ready and LF.tick - state.turnStart < TURN_TIMEOUT then return end
    if not ready then
        LF.log("TURN TIMEOUT #" .. tostring(shooter:getModData().LF_id) .. " firing anyway, stanceErr=" .. fmt(err))
    end

    state.turnStart = nil
    local profile = LF.Weapons.profileOf(shooter)
    state.nextFire = LF.tick + (profile.interval + ZombRand(40)) * LF.Suppress.cadence(shooter)
    local gun = LF.Combat.arm(shooter)
    if not gun then return end
    ISTimedActionQueue.add(LF_ShootAction:new(shooter, target, gun, function(s, t)
        return LF.Combat.resolveShot(s, t, gun)
    end, opts and opts.aimAnim, opts and opts.fireAnim, profile))
end

-- Area fire: one shot at a point (anything with getX/getY/getZ/isDead, e.g. where the enemy was
-- last seen). No hit roll; it suppresses everyone hostile near the point.
function LF.Combat.resolveAreaShot(shooter, point, gun)
    if not LF.Weapons.useRound(shooter) then return false end
    local profile = LF.Weapons.profileOf(shooter)
    LF.guard("shot effects", shotEffects, shooter, gun)
    recentShots[#recentShots + 1] = { x = shooter:getX(), y = shooter:getY(), tick = LF.tick }
    if #recentShots > 64 then LF.Combat.nearestRecentShot(0, 0, 1) end   -- prune old shots
    local n = splash(shooter, point:getX(), point:getY(), AREA_RADIUS, SUPPRESS_AREA * profile.suppress, nil)
    if LF.Config.logAreaFire then
        LF.log("AREA #" .. tostring(shooter:getModData().LF_id) .. " -> " .. math.floor(point:getX()) .. ","
            .. math.floor(point:getY()) .. " suppressing " .. n)
    end
    return true
end

-- One area-fire step (same rhythm as engage, paced slower).
function LF.Combat.engageArea(shooter, point, state)
    if shooter:isPerformingAnAction() then return end
    if LF.Weapons.rounds(shooter) <= 0 then
        LF.Weapons.reload(shooter, LF.Combat.arm(shooter), "empty")
        return
    end
    if state.nextFire and LF.tick < state.nextFire then
        LF.Combat.readyToFire(shooter, point)
        return
    end
    state.turnStart = state.turnStart or LF.tick
    local ready = LF.Combat.readyToFire(shooter, point)
    if not ready and LF.tick - state.turnStart < TURN_TIMEOUT then return end
    state.turnStart = nil
    local profile = LF.Weapons.profileOf(shooter)
    state.nextFire = LF.tick + (profile.interval + ZombRand(40)) * AREA_FIRE_SLOWER * LF.Suppress.cadence(shooter)
    local gun = LF.Combat.arm(shooter)
    if not gun then return end
    ISTimedActionQueue.add(LF_ShootAction:new(shooter, point, gun, function(s, p)
        return LF.Combat.resolveAreaShot(s, p, gun)
    end, nil, nil, profile))
end

function LF.Combat.armAllSoldiers()
    local n = 0
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and rec.faction ~= "CIV" and LF.Combat.arm(body) then n = n + 1 end
    end
    LF.log("COMBAT armed " .. n .. " soldiers")
    LF.say("Armed " .. n .. " soldiers")
end
