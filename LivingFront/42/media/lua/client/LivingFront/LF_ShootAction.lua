-- Living Front: timed actions for NPC gunfire.
--
-- Why timed actions: the engine's own aim/fire pipeline is driven by a hidden AI component Lua
-- cannot reach (for NPCs, isAiming() returns its value). Timed actions work on our NPC bodies
-- and can play any animation registered under PerformingAction. The mod registers the game's
-- own rifle clips as LF_AimRifle / LF_FireRifle and its shot reaction as LF_HitShot
-- (media/AnimSets/player/actions/).
--
-- LF_ShootAction: the shooter has already turned into the aiming stance (LF.Combat.readyToFire).
-- It aims, sweeping the body to follow a moving target, then switches to the fire clip and calls
-- onFire(shooter, target) once, which is where the hit is resolved.
-- LF_FlinchAction: a short flinch when hit.

require "TimedActions/ISBaseTimedAction"

LF_ShootAction = ISBaseTimedAction:derive("LF_ShootAction")

-- Tracking: rotate the body toward the aiming stance a few degrees per update (a sweep, not a
-- snap). Setting the direction directly does rotate the drawn body mid-action. A target that
-- ends up nearly behind the shooter makes them lower the rifle and turn properly instead.
local TRACK_DEG_PER_UPDATE = 3
local ABORT_ERROR = 100

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
end

function LF_ShootAction:update()
    if self.fired then return end
    if trackTarget(self.character, self.target) > ABORT_ERROR then
        LF.log("AIM ABORT #" .. tostring(self.character:getModData().LF_id) .. " target got behind the shooter")
        self:forceStop()
        return
    end
    if self:getJobDelta() >= self.fireAt then
        self.fired = true
        self:setActionAnim(self.fireAnim)
        if self.onFire then self.onFire(self.character, self.target) end
    end
end

function LF_ShootAction:stop()
    ISBaseTimedAction.stop(self)
end

function LF_ShootAction:perform()
    ISBaseTimedAction.perform(self)
end

-- maxTime is in timed-action units (about 1/60 s at normal speed).
-- aimAnim / fireAnim default to the standing rifle clips.
function LF_ShootAction:new(character, target, gun, onFire, aimAnim, fireAnim)
    local o = ISBaseTimedAction.new(self, character)
    o.target = target
    o.gun = gun
    o.onFire = onFire
    o.aimAnim = aimAnim or "LF_AimRifle"
    o.fireAnim = fireAnim or "LF_FireRifle"
    o.fired = false
    o.fireAt = 0.65
    o.maxTime = 110
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
