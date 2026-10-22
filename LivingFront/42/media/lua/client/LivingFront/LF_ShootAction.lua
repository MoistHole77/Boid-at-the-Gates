-- Living Front: a timed action that makes an NPC aim and fire a rifle at a target.
--
-- Why a timed action: the engine's own aim/fire pipeline is driven by a hidden AI component
-- Lua cannot reach (for NPCs, isAiming() returns its value). Timed actions already work on our
-- NPC bodies, and they can play any animation registered under PerformingAction. The mod adds
-- two entries (media/AnimSets/player/actions/LF_AimRifle.xml and LF_FireRifle.xml) that reuse
-- the game's own rifle clips.
--
-- The action aims for most of its duration, then switches to the firing clip and calls
-- onFire(shooter, target) once, which is where the hit is resolved.

require "TimedActions/ISBaseTimedAction"

LF_ShootAction = ISBaseTimedAction:derive("LF_ShootAction")

-- The shooter turns into the aiming stance with the normal turning animation BEFORE this action
-- starts (see LF.Combat.readyToFire); during the aim, trackTarget() below sweeps the body to
-- follow a moving target. The upper-body twist stays off so the rifle stays lined up with the body.
function LF_ShootAction.faceTarget(character, target)
    character:setMaxTwist(0)
end

function LF_ShootAction:isValid()
    return self.target ~= nil and not self.target:isDead() and not self.character:isDead()
end

-- No turning here: the shooter is already turned into the aiming stance before this action is
-- queued (LF.Combat.readyToFire), and turning to face the target would undo the stance.
function LF_ShootAction:waitToStart()
    return false
end

function LF_ShootAction:start()
    LF_ShootAction.faceTarget(self.character, self.target)
    self:setActionAnim(self.fireOnly and "LF_FireRifle" or "LF_AimRifle")
    if self.gun then self:setOverrideHandModels(self.gun, nil) end
end

-- Track a moving target while aiming: rotate the body toward the aiming stance a few degrees
-- per update (a smooth sweep, not a snap). Setting the direction directly does rotate the drawn
-- body mid-action. Only a target that ends up nearly behind the shooter makes them lower the
-- rifle and turn properly.
local TRACK_DEG_PER_UPDATE = 3
local ABORT_ERROR = 100

local function trackTarget(character, target)
    local want = LF.Combat.aimBodyAngle(character, target)
    local cur = character:getAnimAngle()
    local diff = (want - cur + 540) % 360 - 180
    if math.abs(diff) < 0.5 then return math.abs(diff) end
    local step = math.max(-TRACK_DEG_PER_UPDATE, math.min(TRACK_DEG_PER_UPDATE, diff))
    local r = math.rad(cur + step)
    character:setForwardDirection(math.cos(r), math.sin(r))
    character:setTargetAndCurrentDirection(math.cos(r), math.sin(r))
    return math.abs(diff)
end

function LF_ShootAction:update()
    LF_ShootAction.faceTarget(self.character, self.target)
    if not self.fired and LF and LF.Combat and LF.Combat.aimBodyAngle then
        local err = trackTarget(self.character, self.target)
        if err > ABORT_ERROR then
            LF.log("AIM ABORT #" .. tostring(self.character:getModData().LF_id) .. " target got behind the shooter")
            self:forceStop()
            return
        end
    end
    if not self.fired and self:getJobDelta() >= self.fireAt then
        self.fired = true
        if not self.fireOnly then self:setActionAnim("LF_FireRifle") end
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
-- fireOnly: skip the long aim and play only the short firing motion.
function LF_ShootAction:new(character, target, gun, onFire, fireOnly)
    local o = ISBaseTimedAction.new(self, character)
    o.target = target
    o.gun = gun
    o.onFire = onFire
    o.fireOnly = fireOnly
    o.fired = false
    o.fireAt = fireOnly and 0.15 or 0.65
    o.maxTime = fireOnly and 45 or 110
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    o.ignoreHandsWounds = true
    return o
end

-- A short flinch when hit, using the game's own shot reaction clip (registered as the
-- LF_HitShot action animation). The engine's hit-reaction state is flagged but never shown
-- for our NPCs, so the flinch is played as an action instead.
LF_FlinchAction = ISBaseTimedAction:derive("LF_FlinchAction")

function LF_FlinchAction:isValid()
    return not self.character:isDead()
end

function LF_FlinchAction:start()
    self:setActionAnim("LF_HitShot")
end

function LF_FlinchAction:stop()
    ISBaseTimedAction.stop(self)
end

function LF_FlinchAction:perform()
    ISBaseTimedAction.perform(self)
end

function LF_FlinchAction:new(character)
    local o = ISBaseTimedAction.new(self, character)
    o.maxTime = 40
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    o.ignoreHandsWounds = true
    return o
end
