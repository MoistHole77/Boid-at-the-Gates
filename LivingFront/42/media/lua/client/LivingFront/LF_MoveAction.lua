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

-- "patrol": the patrol walk, at the pace of walking with the rifle up (ADS). The mod's own walk
-- nodes (AnimSets/player/movement/LF_Patrol*.xml) take over while the variable LFPatrol is true;
-- their speed comes from LFPatrolSpeed (rifle down) and LFScanSpeed (scanning). A scan
-- (action.scan = "fwd" | "left" | "right" | "back") keeps him walking with the rifle up, turned
-- out to that side: an aimed walk to the front, an aimed strafe to the sides, an aimed walk
-- backward to the rear.
-- The patrol pace is fixed: LF.Move.PATROL_PACE tiles per second, always, for every man in the
-- patrolling stance. The animation scales are nudged in play until they walk at exactly that.
LF.Move.PATROL_PACE = 0.5
-- Legs: the game's slow walk (Bob_WalkSlow - short steps made for a slow pace, so the feet match
-- the ground better than a slowed-down normal walk), rifle carried as usual. (An upper-body
-- "rifle at the ready" overlay was tried in 0.21.4: it put the rifles over their heads.)
LF.Move.patrolScale = LF.Move.patrolScale or 0.7
LF.Move.scanScale = LF.Move.scanScale or 0.9
LF.Move.shuffleScale = LF.Move.shuffleScale or 1.0
local function setVars(character, patrol, scan)
    local shuffle = patrol and LF.Move.shuffle ~= false
    character:setVariable("LFPatrol", patrol)
    character:setVariable("LFShuffle", shuffle)
    character:setVariable("LFScan", scan or "none")
    character:setVariable("LFScanOn", scan ~= nil)
    character:setVariable("LFPatrolSpeed", LF.Move.patrolScale)
    character:setVariable("LFShuffleSpeed", LF.Move.shuffleScale)
    character:setVariable("LFScanSpeed", LF.Move.scanScale)
end
local SCAN_TURN = { fwd = 0, left = -90, right = 90, back = 180 }

local function applyGait(character, gait)
    if gait == "patrol" then
        character:setSprinting(false)
        character:setRunning(false)
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
    pcall(setVars, character, false, "none")
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
    if self.gait == "patrol" then LF.guard("patrol walk", self.patrolStep, self) end
    -- The game could not find a path (a locked gate, a wall): tell the brain, so the soldier
    -- stops retrying the same unreachable spot.
    if self.result == BehaviorResult.Failed and LF.Move and LF.Move.onFailed then
        LF.Move.onFailed(self.character, self.location:getX() + 0.5, self.location:getY() + 0.5)
    end
end

-- Patrol walk: the animation variables, the scan facing, and the pace calibration.
local CAL_TICKS = 60
function LF_MoveAction.patrolStep(self)
    local c = self.character
    local scanning = self.scan and self.scanUntil and LF.tick < self.scanUntil
    local scan = scanning and self.scan or nil
    if scan and scan ~= "fwd" and LF.Move.strafeWorks == false then scan = "fwd" end
    setVars(c, true, scan)

    -- Turned out to his side while walking on: face the travel direction turned by the scan.
    local px, py = c:getX(), c:getY()
    if self.lastX then
        local mx, my = px - self.lastX, py - self.lastY
        local ml = math.sqrt(mx * mx + my * my)
        if ml > 0.005 then self.dirX, self.dirY = mx / ml, my / ml end
    end
    self.lastX, self.lastY = px, py
    if scan and scan ~= "fwd" and self.dirX then
        local r = math.rad(SCAN_TURN[scan])
        local fx = self.dirX * math.cos(r) - self.dirY * math.sin(r)
        local fy = self.dirX * math.sin(r) + self.dirY * math.cos(r)
        c:setForwardDirection(fx, fy)
        c:setTargetAndCurrentDirection(fx, fy)
    end
    -- Pace: measure his speed over each second of steady walking and nudge the scale toward the
    -- player's aiming pace. A sideways scan that stalls him means strafing doesn't work here.
    self.calT = (self.calT or 0) + 1
    if not self.calX then self.calX, self.calY, self.calScan = px, py, scan end
    if self.calT >= CAL_TICKS then
        local speed = LF.dist(self.calX, self.calY, px, py) * 60 / self.calT
        local target = LF.Move.PATROL_PACE
        if self.calScan == scan and speed > 0.15 then
            local f = math.max(0.7, math.min(1.3, 1 + 0.4 * (target / speed - 1)))
            if scan then
                LF.Move.scanScale = math.max(0.3, math.min(1.6, LF.Move.scanScale * f))
            elseif LF.Move.shuffle ~= false then
                LF.Move.shuffleScale = math.max(0.3, math.min(1.6, LF.Move.shuffleScale * f))
            else
                LF.Move.patrolScale = math.max(0.25, math.min(1.6, LF.Move.patrolScale * f))
            end
            LF.Move.lastPace = speed
        elseif scan and scan ~= "fwd" and self.calScan == scan and speed <= 0.15 and LF.Move.strafeWorks == nil then
            LF.Move.strafeWorks = false
            LF.log("MOVE sideways scan stalls the walk; scans will look ahead instead")
        end
        if scan and scan ~= "fwd" and speed > 0.15 and LF.Move.strafeWorks == nil then
            LF.Move.strafeWorks = true
            LF.log("MOVE sideways scan works (walking on while turned out)")
        end
        self.calT, self.calX, self.calY, self.calScan = 0, px, py, scan
    end
end

-- Now and then (at most every ~10 s): the patrol pace against the player's aiming pace.
local lastPaceLog = -100000
Events.EveryOneMinute.Add(function()
    if LF.Move.lastPace and LF.tick - lastPaceLog >= 600 then
        lastPaceLog = LF.tick
        LF.log(string.format("PACE patrol %.2f tiles/s (fixed pace %.2f) - scales shuffle %.2f, walk %.2f, scan %.2f",
            LF.Move.lastPace, LF.Move.PATROL_PACE,
            LF.Move.shuffleScale, LF.Move.patrolScale, LF.Move.scanScale))
        LF.Move.lastPace = nil
    end
end)

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
    if self.overlay then self:setActionAnim(""); self.overlay = nil end
    clearGait(self.character)
    ISWalkToTimedAction.stop(self)
end

function LF_MoveAction:perform()
    logSpeed(self, "arrived")
    if self.overlay then self:setActionAnim(""); self.overlay = nil end
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
