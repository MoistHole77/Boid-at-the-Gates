-- Living Front: timed actions for NPC gunfire.
--
-- Why timed actions: the engine's own aim/fire pipeline is driven by a hidden AI component Lua
-- cannot reach (for NPCs, isAiming() returns its value). Timed actions work on our NPC bodies
-- and can play any animation registered under PerformingAction. The mod registers the game's
-- own clips as LF_AimRifle / LF_FireRifle / LF_RackBolt / LF_Reload and its shot reaction as
-- LF_HitShot (media/AnimSets/player/actions/).
--
-- LF_ShootAction: the shooter has already turned into the aiming stance (LF.Combat.readyToFire).
-- It aims (sweeping the body to follow a moving target), then fires the weapon's burst - one
-- round for a bolt-action rifle, several for a submachine gun - calling onFire(shooter, target)
-- per round, where the round is resolved. onFire returns false when the magazine runs dry, which
-- ends the burst. A rifleman then works the bolt (LF_RackBolt) before the action ends.
-- Timing is in ticks (LF.tick), from the weapon profile (LF_Weapons).
-- LF_FlinchAction: a short flinch when hit.

require "TimedActions/ISBaseTimedAction"
require "LivingFront/LF_Core"

LF_ShootAction = ISBaseTimedAction:derive("LF_ShootAction")

-- Tracking: rotate the body toward the aiming stance a few degrees per update (a sweep, not a
-- snap). Setting the direction directly does rotate the drawn body mid-action. A target that
-- ends up nearly behind the shooter makes them lower the rifle and turn properly instead.
local TRACK_DEG_PER_UPDATE = 3
local ABORT_ERROR = 100
local RACK_DELAY = 10       -- ticks after a rifle shot before the bolt is worked

local function trackTarget(character, target)
    local want = LF.Combat.aimBodyAngle(character, target)
    local cur = character:getAnimAngle()
    local diff = (want - cur + 540) % 360 - 180
    local err = math.abs(diff)
    if err < 0.5 then return err end
    if diff > TRACK_DEG_PER_UPDATE then diff = TRACK_DEG_PER_UPDATE
    elseif diff < -TRACK_DEG_PER_UPDATE then diff = -TRACK_DEG_PER_UPDATE end
    local r = math.rad(cur + diff)
    local cx, cy = math.cos(r), math.sin(r)
    character:setForwardDirection(cx, cy)
    character:setTargetAndCurrentDirection(cx, cy)
    return err
end

function LF_ShootAction:isValid()
    return self.target ~= nil and not self.target:isDead() and not self.character:isDead()
end

-- No turning here: turning to face the target directly would undo the aiming stance.
function LF_ShootAction:waitToStart()
    return false
end

function LF_ShootAction:start()
    -- The rifle stays lined up with the body only with the upper-body twist off.
    self.character:setMaxTwist(0)
    self:setActionAnim(self.aimAnim)
    if self.gun then self:setOverrideHandModels(self.gun, nil) end
    self.nextRound = LF.tick + self.profile.aimTicks
end

function LF_ShootAction:update()
    local now = LF.tick
    if self.doneAt then
        if self.rackAt and now >= self.rackAt then
            self.rackAt = nil
            self:setActionAnim("LF_RackBolt")
            if self.gun and LF.Weapons.rackSound then LF.guard("rack sound", LF.Weapons.rackSound, self.character, self.gun) end
        end
        if now >= self.doneAt then self:forceComplete() end
        return
    end
    if trackTarget(self.character, self.target) > ABORT_ERROR then
        LF.log("AIM ABORT #" .. tostring(self.character:getModData().LF_id) .. " target got behind the shooter")
        self:forceStop()
        return
    end
    if now < self.nextRound then return end
    if self.fired == 0 then self:setActionAnim(self.fireAnim) end
    local ok = true
    if self.onFire then ok = self.onFire(self.character, self.target) ~= false end
    if ok then self.fired = self.fired + 1 end
    if not ok or self.fired >= self.profile.burst then
        self.doneAt = now + self.profile.recover
        if self.profile.kind == "bolt" and ok then
            self.rackAt = now + RACK_DELAY
            self.doneAt = self.doneAt + RACK_DELAY
        end
    else
        self.nextRound = now + self.profile.gap
    end
end

function LF_ShootAction:stop()
    ISBaseTimedAction.stop(self)
end

function LF_ShootAction:perform()
    ISBaseTimedAction.perform(self)
end

-- profile: the weapon profile (LF_Weapons). aimAnim / fireAnim default to the standing clips.
function LF_ShootAction:new(character, target, gun, onFire, aimAnim, fireAnim, profile)
    local o = ISBaseTimedAction.new(self, character)
    o.target = target
    o.gun = gun
    o.onFire = onFire
    o.aimAnim = aimAnim or "LF_AimRifle"
    o.fireAnim = fireAnim or "LF_FireRifle"
    o.profile = profile or LF.Weapons.PROFILES.Kar98k
    o.fired = 0
    o.maxTime = -1               -- ends itself (forceComplete) when the burst and bolt are done
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    o.ignoreHandsWounds = true
    return o
end

LF_FlinchAction = ISBaseTimedAction:derive("LF_FlinchAction")

function LF_FlinchAction:isValid()
    return not self.character:isDead()
end

function LF_FlinchAction:start()
    self:setActionAnim(self.anim)
end

function LF_FlinchAction:stop()
    ISBaseTimedAction.stop(self)
end

function LF_FlinchAction:perform()
    ISBaseTimedAction.perform(self)
end

function LF_FlinchAction:new(character, anim)
    local o = ISBaseTimedAction.new(self, character)
    o.anim = anim or "LF_HitShot"
    o.maxTime = 40
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    o.ignoreHandsWounds = true
    return o
end
