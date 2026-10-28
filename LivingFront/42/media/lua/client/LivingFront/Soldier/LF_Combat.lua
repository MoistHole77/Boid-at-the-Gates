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

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Soldier/LF_ShootAction"
require "LivingFront/Soldier/LF_Suppress"
require "LivingFront/World/LF_Sense"
require "LivingFront/Soldier/LF_Weapons"
require "LivingFront/Soldier/LF_Shot"

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

-- (Kept for the tick: asked many times a think for every man - 0.75.2.)
local hTick, hVal = -1, {}
function LF.Combat.health(body)
    if hTick ~= LF.tick then hTick = LF.tick; hVal = {} end
    local v = hVal[body]
    if v then return v end
    v = LF.guard("overallHealth", overallHealth, body) or 0
    hVal[body] = v
    return v
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

-- ---- slinging the rifle ------------------------------------------------------------------------
-- A man who needs his hands (eating, working on his kit, smoking) slings his rifle on his back
-- (over his pack if he wears one) and takes it back afterwards.

local BACK_SLOTS = { "Rifle On Back with Bag", "Rifle On Back" }

local function backSlot(body)
    local ok, bag = pcall(function() return body:getClothingItem_Back() end)
    return (ok and bag) and BACK_SLOTS[1] or BACK_SLOTS[2]
end

-- (An officer's pistol isn't slung: it goes back in its holster - out of his hands, unseen.)
local holstered = setmetatable({}, { __mode = "k" })     -- body -> pistol

local function isPistol(gun)
    local ok, a = pcall(function() return gun:getSwingAnim() end)
    return ok and a == "Handgun"
end

-- (A man sitting down at rest may lay his rifle on the ground beside him instead: it lies there
-- as a real item in the world and he picks it up when he gets up.)
-- Which body has which gun down is runtime only, so each grounded rifle is also tagged with its
-- owner (item mod data LF_owner) and listed in the save (data.groundGuns): a rifle whose owner
-- no longer has it down - the game was quit with him sitting, he was put away far off, a pick-up
-- went wrong - is swept up when its square is loaded (and he gets his own back from his kit).
local grounded = {}         -- body -> { gun, sq } (runtime)

local function groundList()
    local d = LF.Records.data()
    d.groundGuns = d.groundGuns or {}
    return d.groundGuns
end

-- Take a world item off its square, each step on its own (one failing mustn't leave it half there).
local function removeWorldItem(wio, sq)
    sq = sq or wio:getSquare()
    -- (Only on a square still in a loaded chunk: the game's pathfinder throws otherwise.)
    if not (sq and sq:getChunk()) then return false end
    pcall(function() sq:transmitRemoveItemFromSquare(wio) end)
    pcall(function() wio:removeFromWorld() end)
    pcall(function() wio:removeFromSquare() end)
    pcall(function() wio:setSquare(nil) end)
    return true
end

-- Take the gun off the ground (the world item goes, the gun back into his inventory).
local function lift(g)
    local wio = nil
    pcall(function() wio = g.gun:getWorldItem() end)
    if wio then
        if not removeWorldItem(wio, g.sq) then return end       -- (left for the sweep)
        pcall(function() g.gun:setWorldItem(nil) end)
    end
    pcall(function() g.gun:getModData().LF_owner = nil end)
end

-- Rifles left lying: an owner who no longer has it down. Every couple of seconds.
local function sweep()
    local list = groundList()
    local cell = getCell()
    for i = #list, 1, -1 do
        local e = list[i]
        local sq = cell and cell:getGridSquare(e.x, e.y, e.z)
        if sq and sq:getChunk() then
            local body = LF.Bodies and LF.Bodies.get(e.id)
            local g = body and grounded[body]
            local live = g and g.sq == sq
            if not live then
                local objs = sq:getWorldObjects()
                for k = objs:size() - 1, 0, -1 do
                    local wio = objs:get(k)
                    local item = wio and wio:getItem()
                    local md = item and item:getModData()
                    if md and md.LF_owner == e.id then
                        md.LF_owner = nil
                        removeWorldItem(wio, sq)
                        LF.log("swept up #" .. e.id .. "'s rifle left on the ground at " .. e.x .. "," .. e.y)
                    end
                end
                table.remove(list, i)
            end
        elseif LF.simTime and e.t and LF.simTime - e.t > 86400 then
            table.remove(list, i)       -- (a day on and still never loaded: forget it)
        end
    end
end

local function doGround(body)
    if grounded[body] or holstered[body] then return false end
    local gun = body:getPrimaryHandItem()
    if not (gun and instanceof(gun, "HandWeapon")) or isPistol(gun) then return false end
    local sq = body:getCurrentSquare()
    if not sq then return false end
    body:setPrimaryHandItem(nil)
    body:setSecondaryHandItem(nil)
    body:getInventory():Remove(gun)
    local ox, oy = 0.25 + ZombRand(30) / 100, 0.25 + ZombRand(30) / 100
    local id = body:getModData().LF_id
    gun:getModData().LF_owner = id
    sq:AddWorldInventoryItem(gun, ox, oy, 0)
    grounded[body] = { gun = gun, sq = sq }
    if id then
        local list = groundList()
        list[#list + 1] = { id = id, x = sq:getX(), y = sq:getY(), z = sq:getZ(), t = LF.simTime }
    end
    return true
end
function LF.Combat.ground(body) return LF.guard("ground rifle", doGround, body) end

-- Picked up with him, the moment he is put away (LF_Bodies.despawn calls this first, while his
-- square is still loaded).
function LF.Combat.liftGrounded(body)
    local g = grounded[body]
    if g then
        grounded[body] = nil
        LF.guard("lift rifle", lift, g)
    end
end

-- A body that went away (despawned, dead) leaves no rifle lying about for ever: a dead man's stays
-- where it is (it's his), a despawned man's is picked up with him.
LF.on("OnTick", "Combat", function()
    if LF.due(120, 61) then LF.guard("sweep rifles", sweep) end
    if not LF.due(60, 23) then return end
    for b, g in pairs(grounded) do
        local id = b:getModData().LF_id
        if b:isDead() then
            grounded[b] = nil
            -- (His now: it stays where he left it, out of the sweep.)
            pcall(function() g.gun:getModData().LF_owner = nil end)
            local list = groundList()
            for i = #list, 1, -1 do if list[i].id == id then table.remove(list, i) end end
        elseif not (id and LF.Bodies and LF.Bodies.get(id) == b) then
            LF.guard("lift rifle", lift, g)
            grounded[b] = nil
        end
    end
end)

-- The rifle on his back (or on the ground beside him), and where; nil if none.
function LF.Combat.slungGun(body)
    if holstered[body] then return holstered[body], "holster" end
    if grounded[body] then return grounded[body].gun, "ground" end
    for _, loc in ipairs(BACK_SLOTS) do
        local ok, g = pcall(function() return body:getAttachedItem(loc) end)
        if ok and g then return g, loc end
    end
    return nil
end

local function doSling(body)
    local gun = body:getPrimaryHandItem()
    if not (gun and instanceof(gun, "HandWeapon")) then return false end
    if isPistol(gun) then
        body:setPrimaryHandItem(nil)
        holstered[body] = gun
        return true
    end
    local loc = backSlot(body)
    body:setPrimaryHandItem(nil)
    body:setSecondaryHandItem(nil)
    body:setAttachedItem(loc, gun)
    gun:setAttachedSlot(1)
    gun:setAttachedSlotType("Back")
    gun:setAttachedToModel(loc)
    return true
end

local function doUnsling(body)
    local gun, loc = LF.Combat.slungGun(body)
    if not gun then return nil end
    if loc == "holster" then
        holstered[body] = nil
        body:setPrimaryHandItem(gun)
        return gun
    end
    if loc == "ground" then
        local g = grounded[body]
        grounded[body] = nil
        lift(g)
        if not body:getInventory():contains(gun) then body:getInventory():AddItem(gun) end
        body:setPrimaryHandItem(gun)
        if gun:isTwoHandWeapon() then body:setSecondaryHandItem(gun) end
        return gun
    end
    if not pcall(function() body:removeAttachedItem(gun) end) then body:setAttachedItem(loc, nil) end
    gun:setAttachedSlot(-1)
    gun:setAttachedSlotType(nil)
    gun:setAttachedToModel(nil)
    body:setPrimaryHandItem(gun)
    if gun:isTwoHandWeapon() then body:setSecondaryHandItem(gun) end
    return gun
end

function LF.Combat.sling(body) return LF.guard("sling rifle", doSling, body) end
function LF.Combat.unsling(body) return LF.guard("unsling rifle", doUnsling, body) end

-- Make sure a body holds its own weapon (LF_Weapons: Kar98k, Mosin, MP40 or PPSh), loaded and in
-- both hands. Returns the gun. (A slung rifle comes off his back first.)
function LF.Combat.arm(body)
    -- (Some men carry no weapon at all - a company commander, his first sergeant, the surgeon.)
    local rec = LF.Records.get(body:getModData().LF_id)
    if rec and rec.unarmed then return nil end
    local profile = LF.Weapons.profileOf(body)
    local gun = body:getPrimaryHandItem()
    if not gun and LF.Combat.slungGun(body) then
        LF.Combat.unsling(body)
        gun = body:getPrimaryHandItem()
    end
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
LF.Combat.hitChance = hitChance

-- Down critical, calling for the medic (LF_Medic): nothing more can hurt him, or knock him about,
-- until his clock runs out. (The game's own god mode can't be relied on for an NPC: 0.46 still
-- lost men to grenades and stray rounds while they lay waiting.)
local function untouchable(target)
    local id = target:getModData().LF_id
    return id ~= nil and LF.Medic ~= nil and LF.Medic.isCritical(id)
end
LF.Combat.untouchable = untouchable

local function wound(target, partName, profile)
    if untouchable(target) then return end
    target:getBodyDamage():getBodyPart(BodyPartType[partName]):damageFromFirearm(profile.wound)
    target:getBodyDamage():ReduceGeneralHealth((IMPACT[partName] or 15) * profile.impact)
end

-- A shrapnel / blast wound: severity like a rifle wound's (0-100), plus a general health loss.
function LF.Combat.blastWound(target, partName, severity, impact)
    return LF.guard("blast wound", function()
        if untouchable(target) then return end
        target:getBodyDamage():getBodyPart(BodyPartType[partName]):damageFromFirearm(severity)
        target:getBodyDamage():ReduceGeneralHealth(impact)
    end)
end

-- ---- knocked off his feet ----------------------------------------------------------------------
-- A hit can stagger a man, or put him down - the same stagger, fall and getting-up clips as the
-- player's (the game's "bump"). The chance depends on where he's hit.
local KNOCK = {     -- part -> { fall %, stagger % }
    UpperLeg_L = { 55, 30 }, UpperLeg_R = { 55, 30 }, LowerLeg_L = { 55, 30 }, LowerLeg_R = { 55, 30 },
    Torso_Lower = { 25, 35 }, Torso_Upper = { 25, 35 }, Head = { 40, 0 },
    UpperArm_L = { 0, 30 }, UpperArm_R = { 0, 30 },
}

-- Knock him over (fall) or stagger him, from a hit or blast coming from (sx, sy).
local function knockFrom(target, sx, sy, fall)
    if untouchable(target) then return end
    -- From the front, he goes over backwards; from behind, forwards.
    local fx, fy = target:getForwardDirection():getX(), target:getForwardDirection():getY()
    local front = (sx - target:getX()) * fx + (sy - target:getY()) * fy > 0
    ISTimedActionQueue.clear(target)
    if LF.Posture and LF.Posture.crouched(target) then LF.Posture.set(target, false) end
    target:setBumpType("stagger")
    target:setBumpDone(false)
    target:setVariable("BumpDone", false)
    target:setBumpFall(fall)
    target:setVariable("BumpFall", fall)
    if fall then
        local t = front and "pushedFront" or "pushedBehind"
        target:setBumpFallType(t)
        target:setVariable("BumpFallType", t)
        -- Over backward while clearing a building: he stays down and is dragged out (LF_Tactics).
        if front and LF.Tactics and LF.Tactics.onKnockedBack then LF.guard("knocked back", LF.Tactics.onKnockedBack, target) end
    end
end
local function knock(target, shooter, fall) knockFrom(target, shooter:getX(), shooter:getY(), fall) end
function LF.Combat.knock(target, sx, sy, fall) return LF.guard("knock", knockFrom, target, sx, sy, fall) end

-- Staggering, or down on the ground (and getting up): he can't do anything else just now.
-- (Sitting on the ground counts as "on the floor" to the game: a man resting while his unit
-- stands by isn't knocked down - up to 0.37 the brain took him for one and never woke him when
-- the unit was given orders.)
-- (Plain functions handed to pcall, not new ones each call - 0.75.2.)
local function bumpedOf(b) return b:isBumped() end
local function downOf(b) return b:isBumped() or b:isOnFloor() or b:isKnockedDown() end
function LF.Combat.knockedDown(body)
    if LF.Idle and LF.Idle.isSitting(body) then
        local ok, v = pcall(bumpedOf, body)
        return ok and v or false
    end
    local ok, v = pcall(downOf, body)
    return ok and v or false
end

-- ---- crawling ---------------------------------------------------------------------------------
-- A man whose legs are badly hurt crawls (LF_Crawl / LF_ProneIdle animation nodes) instead of
-- limping: a leg below 30% of its health, or 55% with much of his health gone.
local LEGS = { "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R", "Foot_L", "Foot_R" }
function LF.Combat.legsOut(body)
    local bd = body:getBodyDamage()
    local worst = 100
    for _, name in ipairs(LEGS) do
        local h = bd:getBodyPart(BodyPartType[name]):getHealth()
        if h < worst then worst = h end
    end
    return worst < 30 or (worst <= 55 and LF.Combat.health(body) < 60)
end

local function setCrawlVars(body, on)
    for _, v in ipairs({ "LFCrawl", "LFCrawlA", "LFCrawlB", "LFCrawlC", "LFCrawlD" }) do body:setVariable(v, on) end
end

-- Set (or clear) his crawling. Returns whether he crawls.
-- (The animation variables are only written when it changes - 0.75.2: six writes a think per man.)
local crawlSet = {}
local crawlSweep = 0
local crawlHp = {}
function LF.Combat.updateCrawl(body)
    if LF.tick - crawlSweep > 3600 or crawlSweep > LF.tick then crawlSet, crawlHp, crawlSweep = {}, {}, LF.tick end
    -- (His legs only change when his health does: looked at again only then - 0.75.3.)
    local hp = LF.Combat.health(body)
    local crawl
    if crawlHp[body] == hp and crawlSet[body] ~= nil then
        crawl = crawlSet[body]
    else
        local ok, out = pcall(LF.Combat.legsOut, body)
        crawl = ok and out or false
        crawlHp[body] = hp
    end
    if crawlSet[body] ~= crawl then
        crawlSet[body] = crawl
        setCrawlVars(body, crawl)
        body:setVariable("LFCrawlSpeed", 1.0)
    end
    if crawl then
        body:setRunning(false)
        body:setSprinting(false)
    end
    return crawl
end

local function flinch(target)
    if untouchable(target) then return end
    ISTimedActionQueue.clear(target)
    ISTimedActionQueue.add(LF_FlinchAction:new(target))
end

LF.Combat.shotCount = 0
local function shotEffects(shooter, gun)
    LF.Combat.shotCount = LF.Combat.shotCount + 1
    if LF.Brain and LF.Brain.onShot then LF.guard("reaction", LF.Brain.onShot, shooter) end
    -- (The SMGs use a short gun's model - the sawn-off - with a sub-machine gun's report.)
    local prof = LF.Weapons.profileOf(shooter)
    shooter:playSound(prof.sound or gun:getSwingSound())
    shooter:addWorldSoundUnlessInvisible(40, 100, false)
end

-- Suppress everyone hostile to the shooter within radius of (x, y), except `skip`.
local splashCtx = {}
local function splashOne(e, _dsq, ctx)
    if e.body ~= ctx.skip and LF.isHostile(ctx.faction, e.rec.faction) then
        LF.Suppress.add(e.body, ctx.amount, ctx.shooter, ctx.cap)
        if LF.Service then LF.Service.action(e.rec.id) end      -- being shot at: he's in action
        ctx.n = ctx.n + 1
    end
end
local function splash(shooter, x, y, radius, amount, skip)
    local rec = LF.Records.get(shooter:getModData().LF_id)
    if not rec then return 0 end
    splashCtx.faction, splashCtx.amount, splashCtx.skip, splashCtx.n, splashCtx.shooter = rec.faction, amount, skip, 0, shooter
    -- (Rifle fire alone suppresses, it doesn't pin - LF_Suppress.)
    local prof = LF.Weapons.profileOf(shooter)
    splashCtx.cap = not (prof and prof.kind == "mg") and LF.Suppress.CFG.rifleCap or nil
    LF.Sense.near(x, y, radius, splashOne, splashCtx)
    return splashCtx.n
end

-- His health brought to a level (the game's own healing and harm, as LF_Medic does it).
local function healthTo(body, to)
    local bd = body:getBodyDamage()
    pcall(function() bd:calculateOverallHealth() end)
    local hp = LF.Combat.health(body)
    if hp > to then pcall(function() bd:ReduceGeneralHealth(hp - to) end)
    else
        for _ = 1, 12 do
            if LF.Combat.health(body) >= to then break end
            pcall(function() bd:AddGeneralHealth(10) end)
        end
    end
end

-- Health a man's body is left at for each grade (LF_Wounds reads the grade back from it).
local GRADE_HEALTH = { light = 75, serious = 45, critical = 22 }

-- What a hit does, from the shot table (LF_Shot, 0.72): killed, critical, serious or light, by
-- where it lands. His grade is set straight away (LF_Wounds); his body shows the wound - and
-- doesn't bleed to death on top of it (the grade's clock does that). A man who would be killed
-- (but not by a head shot) may go down dying instead, calling for his squad's medic (LF_Medic).
-- Civilians (no grades) take the game's own wound, as before.
local function inflict(target, partName, profile)
    if untouchable(target) then return "untouchable" end
    local id = target:getModData().LF_id
    local rec = id and LF.Records.get(id)
    if not (rec and LF.Wounds and rec.faction ~= "CIV") then
        wound(target, partName, profile)
        return "wound"
    end
    local out = LF.Shot.outcome(partName, profile, rec.wound and rec.wound.grade or nil)
    local bd = target:getBodyDamage()
    -- The wound you see (blood, the bullet), then dressed: no bleeding out on top of the grade.
    pcall(function() bd:getBodyPart(BodyPartType[partName]):damageFromFirearm(25) end)
    LF.Wounds.stopBleeding(target)
    if out == "killed" then
        if partName ~= "Head" and LF.Medic and LF.Medic.onHit then
            healthTo(target, 6)
            LF.guard("critical", LF.Medic.onHit, target, "shot", partName)
            if LF.Medic.isCritical(id) then return "dying, calling for the medic" end
        end
        pcall(function() target:setHealth(0) end)
        pcall(function() target:Kill(nil) end)
        return "killed"
    end
    target:getModData().LF_woundShown = out
    LF.Wounds.grade(rec, out, "shot (" .. partName .. ")")
    local g = rec.wound and rec.wound.grade or out
    healthTo(target, GRADE_HEALTH[g] or GRADE_HEALTH[out] or 75)
    target:getModData().LF_woundShown = g
    return out
end

-- A round that has hit: the wound, then knocked over, staggered - or just a flinch. Returns the
-- body part hit (and what it did).
-- (0.76) A hit settled off screen (LF_Clash) on a man who has a body - one of a unit with bodies
-- fighting a unit left without them by the cap: the same wound, kill or medic's call as a round
-- fired on screen. Returns what it did.
function LF.Combat.inflictPart(target, partName, profile)
    return LF.guard("wound", inflict, target, partName, profile)
end

local function applyHit(shooter, target, profile, dist)
    local parts = LF.Combat.hitParts and LF.guard("hit parts", LF.Combat.hitParts, shooter, target)
    local partName = LF.pick(parts or BODY_PARTS)
    local did = LF.guard("wound", inflict, target, partName, profile)
    if did == "killed" then return partName .. " (killed)" end
    local k = KNOCK[partName] or { 0, 0 }
    -- Point blank, a round is a little more likely to put a man down (+8 points within 3
    -- tiles, +4 within 5; not for arm hits).
    local fall = k[1]
    if fall > 0 then fall = fall + (dist <= 3 and 8 or (dist <= 5 and 4 or 0)) end
    local roll = ZombRand(100)
    if roll < fall then
        LF.guard("knock down", knock, target, shooter, true)
    elseif roll < fall + k[2] then
        LF.guard("stagger", knock, target, shooter, false)
    else
        LF.guard("flinch", flinch, target)
    end
    -- (Civilians: a killing hit may still leave him critical, as before.)
    if did == "wound" and LF.Medic and LF.Medic.onHit then LF.guard("critical", LF.Medic.onHit, target, "shot", partName) end
    return partName .. (did and (" (" .. did .. ")") or "")
end
LF.Combat.applyHit = applyHit
LF.Combat.splash = function(...) return splash(...) end

-- Gunfire heard: remembered (civilians flee it, soldiers turn to it) and heard by the world.
function LF.Combat.noteShot(shooter)
    recentShots[#recentShots + 1] = { x = shooter:getX(), y = shooter:getY(), tick = LF.tick }
    if #recentShots > 64 then LF.Combat.nearestRecentShot(0, 0, 1) end
    shooter:addWorldSoundUnlessInvisible(40, 100, false)
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
    if ZombRand(100) < chance then result = "HIT " .. applyHit(shooter, target, profile, dist) end
    LF.Suppress.add(target, (result == "MISS" and SUPPRESS_MISS or SUPPRESS_HIT) * profile.suppress, shooter,
        profile.kind ~= "mg" and LF.Suppress.CFG.rifleCap or nil)
    splash(shooter, target:getX(), target:getY(), SPLASH_RADIUS, SUPPRESS_SPLASH * profile.suppress, target)
    if LF.Service then
        LF.guard("service shot", LF.Service.shot, shooter:getModData().LF_id, target:getModData().LF_id, result ~= "MISS")
    end
    if LF.Config.logShots then
        LF.log("SHOT #" .. tostring(shooter:getModData().LF_id) .. " " .. profile.name .. " -> #" .. tostring(target:getModData().LF_id)
            .. " dist=" .. fmt(dist) .. " chance=" .. fmt(chance) .. " " .. result
            .. " stanceErr=" .. fmt(LF.Combat.stanceError(shooter, target))
            .. " targetHealth=" .. fmt(LF.Combat.health(target)))
    end
    return true
end

-- ---- hand to hand ------------------------------------------------------------------------------
--
-- Empty and the enemy right on top of him (within 2 tiles): no standing there reloading in his
-- face - he goes for him with the rifle butt (the game's butt-strike clip, LF_ButtStrike). A hit
-- (65% close in, 40% at arm's length) is a heavy blow - the head or body - that staggers him, or
-- knocks him down a third of the time. A reload already under way is dropped for it. When the
-- enemy is out of reach again, he reloads as usual.

local MELEE = { range = 2.0, near = 1.3, hitNear = 65, hitFar = 40, strikeAt = 16, ticks = 50,
                fall = 33, severity = 30, impact = 14,
                charge = 4.5 }     -- empty with the enemy this close (and in sight): he goes for him
LF.Combat.MELEE = MELEE
local MELEE_PARTS = { "Head", "Torso_Upper", "Torso_Upper", "Torso_Lower", "UpperArm_L", "UpperArm_R" }

LF_MeleeAction = ISBaseTimedAction:derive("LF_MeleeAction")
function LF_MeleeAction:isValid() return not self.character:isDead() end
function LF_MeleeAction:waitToStart() return false end
function LF_MeleeAction:start()
    self.character:faceThisObject(self.target)
    self:setActionAnim("LF_ButtStrike")
    if self.gun then self:setOverrideHandModels(self.gun, nil) end
    pcall(function() self.character:playSound(self.gun:getSwingSound()) end)
    self.hitAt = LF.tick + MELEE.strikeAt
end
local function strike(self)
    if self.done then return end
    self.done = true
    local a, t = self.character, self.target
    if t:isDead() or math.abs(t:getZ() - a:getZ()) > 0.5 then return end
    local d = LF.dist(a:getX(), a:getY(), t:getX(), t:getY())
    if d > MELEE.range + 0.3 then
        LF.log("MELEE #" .. tostring(a:getModData().LF_id) .. " swings and misses (out of reach)")
        return
    end
    local chance = d <= MELEE.near and MELEE.hitNear or MELEE.hitFar
    if ZombRand(100) >= chance then
        LF.log("MELEE #" .. tostring(a:getModData().LF_id) .. " -> #" .. tostring(t:getModData().LF_id) .. " miss")
        return
    end
    local part = MELEE_PARTS[ZombRand(#MELEE_PARTS) + 1]
    LF.Combat.blastWound(t, part, MELEE.severity, MELEE.impact)
    pcall(function() t:playSound("HitPlayerBlunt") end)
    LF.Combat.knock(t, a:getX(), a:getY(), ZombRand(100) < MELEE.fall)
    if LF.Medic and LF.Medic.onHit then LF.guard("critical", LF.Medic.onHit, t, "melee", part) end
    if LF.Suppress then LF.Suppress.add(t, 60) end
    local aid, tid = a:getModData().LF_id, t:getModData().LF_id
    if LF.Service and aid and tid then LF.guard("service melee", LF.Service.shot, aid, tid, true) end
    LF.log("MELEE #" .. tostring(aid) .. " -> #" .. tostring(tid) .. " hits " .. part .. " with the rifle butt")
end
function LF_MeleeAction:update()
    if self.hitAt and LF.tick >= self.hitAt then LF.guard("melee strike", strike, self) end
end
function LF_MeleeAction:stop() ISBaseTimedAction.stop(self) end
function LF_MeleeAction:perform()
    LF.guard("melee strike", strike, self)
    ISBaseTimedAction.perform(self)
end
function LF_MeleeAction:new(character, target, gun)
    local o = ISBaseTimedAction.new(self, character)
    o.target, o.gun = target, gun
    o.maxTime = MELEE.ticks
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

-- Is the enemy close enough to go for him hand to hand?
function LF.Combat.inReach(a, t)
    return math.abs(t:getZ() - a:getZ()) < 0.5 and LF.dist(a:getX(), a:getY(), t:getX(), t:getY()) <= MELEE.range
end

-- Empty with the enemy close (a few steps, in sight, on the same floor): he rushes him - no
-- standing there reloading a few feet from a man who's shooting at him. (Up to 0.44 only an enemy
-- already within arm's length counted, so a man two rooms' width away still got a reload.)
local function chargeIfEmpty(shooter, target)
    if not target or LF.Weapons.rounds(shooter) > 0 or LF.Combat.inReach(shooter, target) then return false end
    if math.abs(target:getZ() - shooter:getZ()) >= 0.5 then return false end
    local d = LF.dist(shooter:getX(), shooter:getY(), target:getX(), target:getY())
    if d > MELEE.charge or not LF.Sense.canSee(shooter, target) then return false end
    -- Not across a building's wall line: a man outside (on the stack, say) doesn't charge in
    -- through the door at a man inside, or out of it.
    local function bid(b)
        local q = getCell():getGridSquare(math.floor(b:getX()), math.floor(b:getY()), math.floor(b:getZ()))
        local bl = q and q:getBuilding()
        return bl and bl:getID() or -1
    end
    if bid(shooter) ~= bid(target) then return false end
    local q = ISTimedActionQueue.getTimedActionQueue(shooter)
    local a = q and q.queue and q.queue[1]
    if a and a.Type == "LF_MoveAction" and a.charging then return true end
    if a and a.Type ~= "LF_ReloadAction" and a.Type ~= "LF_MoveAction" then return false end
    ISTimedActionQueue.clear(shooter)
    if LF.Posture and LF.Posture.crouched(shooter) then LF.Posture.set(shooter, false) end
    local sq = getCell():getGridSquare(math.floor(target:getX()), math.floor(target:getY()), math.floor(target:getZ()))
    if not sq then return false end
    local mv = LF_MoveAction:new(shooter, sq, "run")
    mv.charging = true
    ISTimedActionQueue.add(mv)
    LF.log("MELEE #" .. tostring(shooter:getModData().LF_id) .. " is empty - rushes #" .. tostring(target:getModData().LF_id)
        .. " " .. string.format("%.1f", d) .. " tiles away")
    return true
end

-- Empty, enemy in reach: strike (dropping a reload, or the rush, in progress). Returns true if he did.
local function meleeIfEmpty(shooter, target)
    if not target or LF.Weapons.rounds(shooter) > 0 then return false end
    if not LF.Combat.inReach(shooter, target) then return LF.guard("charge", chargeIfEmpty, shooter, target) == true end
    local q = ISTimedActionQueue.getTimedActionQueue(shooter)
    local a = q and q.queue and q.queue[1]
    if a and a.Type == "LF_MeleeAction" then return true end
    if a and a.Type ~= "LF_ReloadAction" and not (a.Type == "LF_MoveAction" and a.charging) then return false end     -- (busy with something else)
    if a then
        ISTimedActionQueue.clear(shooter)
        LF.log("MELEE #" .. tostring(shooter:getModData().LF_id) .. " drops his reload - enemy in reach")
    end
    if LF.Posture and LF.Posture.crouched(shooter) then LF.Posture.set(shooter, false) end
    ISTimedActionQueue.add(LF_MeleeAction:new(shooter, target, LF.Combat.arm(shooter)))
    return true
end

-- One engagement step, called every tick while an NPC is fighting a target.
-- state is a per-shooter table owned by the caller ({} to start).
-- opts (optional): aimAnim / fireAnim to use (e.g. crouched clips).
function LF.Combat.engage(shooter, target, state, opts)
    if LF.guard("melee", meleeIfEmpty, shooter, target) then return end
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
    if LF.Service then LF.Service.action(shooter:getModData().LF_id) end
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
