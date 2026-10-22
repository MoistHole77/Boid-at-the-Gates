-- Living Front: walking, running and sprinting NPCs.
--
-- Why this works (see README "Engine findings"):
--   * An NPC's running flag is overwritten twice every frame inside IsoPlayer.updateInternal2:
--     first cleared, then copied from the hidden AI component (AIComponent.postUpdatePlayer),
--     which Lua can't reach. Setting it from OnTick or OnPlayerUpdate is therefore wiped
--     before anything reads it.
--   * But the character's timed action is updated later in the same frame
--     (IsoGameCharacter.update, after updateInternal2), and the animation state machine and
--     animator run after that (postUpdate). A flag set from the action's update() survives into
--     the animation pass, so the body really enters the game's run / sprint states.
--   * Movement speed comes from the animation itself (pathfinding moves the body by the
--     animation's deferred movement), so a running animation is a real run: no speed hacks.
--   * The engine's own rules still apply: a tired NPC (endurance moodle 3+) can't run
--     (isRunning() returns false), and sprinting turns into running when injured.
--
-- LF_MoveAction:new(character, square, gait)  gait = "walk" | "run" | "sprint" | "aim" | "patrol"

require "TimedActions/ISBaseTimedAction"
require "TimedActions/WalkToTimedAction"
require "LivingFront/LF_Core"

LF_MoveAction = ISWalkToTimedAction:derive("LF_MoveAction")
LF.Move = LF.Move or {}

-- "aim": a slow walk with the rifle up (clearing a building). Like running, the aiming flag is
-- set from the action's update so the animation pass sees it; whether NPCs honour it is logged
-- once (LF.Move.aimWorks).
local function setAim(character, on) character:setIsAiming(on) end

-- "patrol": a slow, careful walk (about the pace of walking with the rifle up). The walk
-- animation blends between the normal and the slow walk on the "WalkSpeed" variable, which the
-- engine writes in updateInternal2 - so, like running, it is set from the action's update.
-- Whether it took is logged once (LF.Move.speedWorks).
LF.Move.PATROL_WALK = 0.15
local function setWalkSpeed(character, v) character:setVariable("WalkSpeed", v) end
local function readWalkSpeed(character) return character:getVariableFloat("WalkSpeed", -1) end

local function applyGait(character, gait)
    if gait == "patrol" then
        character:setSprinting(false)
        character:setRunning(false)
        if LF.Move.speedWorks ~= false then
            local ok = pcall(setWalkSpeed, character, LF.Move.PATROL_WALK)
            if LF.Move.speedWorks == nil then
                local ok2, v = pcall(readWalkSpeed, character)
                LF.Move.speedWorks = ok and ok2 and math.abs(v - LF.Move.PATROL_WALK) < 0.01 or false
                LF.log("MOVE patrol pace " .. (LF.Move.speedWorks and "works (slow walk)" or ("not available (WalkSpeed reads " .. tostring(v) .. ")")))
            end
        end
    elseif gait == "aim" then
        character:setSprinting(false)
        character:setRunning(false)
        if LF.Move.aimWorks ~= false then
            local ok = pcall(setAim, character, true)
            if LF.Move.aimWorks == nil then
                LF.Move.aimWorks = ok and character:isAiming() or false
                LF.log("MOVE aim-walk " .. (LF.Move.aimWorks and "works (rifle up while walking)" or "not available for NPCs (plain walk)"))
            end
        end
    elseif gait == "sprint" then
        character:setSprinting(true)
        character:setRunning(false)
    elseif gait == "run" then
        character:setSprinting(false)
        character:setRunning(true)
    end
end

local function clearGait(character)
    character:setRunning(false)
    character:setSprinting(false)
    if LF.Move.aimWorks then pcall(setAim, character, false) end
    if LF.Move.speedWorks then pcall(setWalkSpeed, character, 1) end
end

local function now()
    return getTimestampMs and getTimestampMs() or 0
end

function LF_MoveAction:start()
    ISWalkToTimedAction.start(self)
    applyGait(self.character, self.gait)
    self.startX, self.startY, self.startMs = self.character:getX(), self.character:getY(), now()
    if self.awayX then
        self.awayStart = LF.dist(self.startX, self.startY, self.awayX, self.awayY)
    end
end

-- A retreat whose route leads back toward the enemy (the path goes round an obstacle the wrong
-- way) is abandoned: better to stay put than to run through the enemy line.
local function headingIntoEnemy(self)
    if not (self.awayStart and LF.tick % 10 == 0) then return false end
    local c = self.character
    return LF.dist(c:getX(), c:getY(), self.awayX, self.awayY) < self.awayStart - 2.5
end

function LF_MoveAction:update()
    -- Before the path step, so this frame's movement and animation both see the gait.
    applyGait(self.character, self.gait)
    if LF.Config.logGait and LF.tick % 60 == 0 then
        LF.log("GAIT #" .. tostring(self.character:getModData().LF_id) .. " want=" .. self.gait
            .. " running=" .. tostring(self.character:isRunning())
            .. " sprinting=" .. tostring(self.character:isSprinting())
            .. " state=" .. tostring(self.character:getCurrentActionContextStateName()))
    end
    if headingIntoEnemy(self) then
        LF.log("MOVE #" .. tostring(self.character:getModData().LF_id) .. " retreat route leads toward the enemy; stopping")
        if LF.Move and LF.Move.onFailed then
            LF.Move.onFailed(self.character, self.location:getX() + 0.5, self.location:getY() + 0.5)
        end
        self:forceStop()
        return
    end
    ISWalkToTimedAction.update(self)
    -- The game could not find a path (a locked gate, a wall): tell the brain, so the soldier
    -- stops retrying the same unreachable spot.
    if self.result == BehaviorResult.Failed and LF.Move and LF.Move.onFailed then
        LF.Move.onFailed(self.character, self.location:getX() + 0.5, self.location:getY() + 0.5)
    end
end

local function logSpeed(self, how)
    if not (LF.Config.logGait and self.startMs and self.startMs > 0) then return end
    local secs = (now() - self.startMs) / 1000
    if secs <= 0.5 then return end
    local d = LF.dist(self.startX, self.startY, self.character:getX(), self.character:getY())
    LF.log("GAIT #" .. tostring(self.character:getModData().LF_id) .. " " .. self.gait .. " " .. how
        .. ": " .. string.format("%.1f tiles in %.1f s = %.2f tiles/s", d, secs, d / secs))
end

function LF_MoveAction:stop()
    logSpeed(self, "stopped")
    clearGait(self.character)
    ISWalkToTimedAction.stop(self)
end

function LF_MoveAction:perform()
    logSpeed(self, "arrived")
    clearGait(self.character)
    ISWalkToTimedAction.perform(self)
end

-- awayX, awayY (optional): a retreat - abandon it if the route closes on that point.
function LF_MoveAction:new(character, location, gait, awayX, awayY)
    local o = ISWalkToTimedAction.new(self, character, location)
    o.gait = gait or "walk"
    o.awayX, o.awayY = awayX, awayY
    return o
end
