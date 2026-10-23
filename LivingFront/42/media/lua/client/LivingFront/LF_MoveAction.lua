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
-- One animation speed per kind of step (each animation has its own natural stride):
--   shuffle (the slow walk), patrol (plain walk), scan (aimed walk forward / backward) and
--   side (aimed strafe, scanning out to a side). Kept in the save once settled.
LF.Move.patrolScale = LF.Move.patrolScale or 0.7
LF.Move.scanScale = LF.Move.scanScale or 0.9
LF.Move.sideScale = LF.Move.sideScale or 1.0
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
    character:setVariable("LFScanSideSpeed", LF.Move.sideScale)
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
--
-- Calibration: a sample is one second of steady walking - the same step all through (no scan
-- starting or ending), moving every tick (not held up, not stopped at his place), measured along
-- the ground he actually covered (curves count). Each good sample nudges that step's speed a
-- few percent toward the patrol pace; a bad one is thrown away. So the scales settle instead of
-- swinging between their limits, and once settled the pace barely moves.
local CAL_GAIN = 0.25        -- share of the error corrected per sample
local CAL_STEP = 0.06        -- ... but never more than this (6%) per sample
local function scaleKey(scan)
    if scan == "left" or scan == "right" then return "sideScale" end
    if scan then return "scanScale" end
    return LF.Move.shuffle ~= false and "shuffleScale" or "patrolScale"
end
local function saveScales()
    local data = LF.Records and LF.Records.data and LF.Records.data()
    if not data then return end
    data.moveScales = data.moveScales or {}
    for _, k in ipairs({ "shuffleScale", "patrolScale", "scanScale", "sideScale" }) do data.moveScales[k] = LF.Move[k] end
end
Events.OnInitGlobalModData.Add(function()
    local data = LF.Records and LF.Records.data and LF.Records.data()
    local s = data and data.moveScales
    if s then
        for k, v in pairs(s) do if type(v) == "number" then LF.Move[k] = v end end
    end
end)

function LF_MoveAction.patrolStep(self)
    local c = self.character
    local scanning = self.scan and self.scanUntil and LF.tick < self.scanUntil
    local scan = scanning and self.scan or nil
    setVars(c, true, scan)

    -- Turned out to his side while walking on: face the travel direction turned by the scan.
    local px, py = c:getX(), c:getY()
    local step = 0
    if self.lastX then
        local mx, my = px - self.lastX, py - self.lastY
        step = math.sqrt(mx * mx + my * my)
        if step > 0.005 then self.dirX, self.dirY = mx / step, my / step end
    end
    self.lastX, self.lastY = px, py
    if scan and scan ~= "fwd" and self.dirX then
        local r = math.rad(SCAN_TURN[scan])
        local fx = self.dirX * math.cos(r) - self.dirY * math.sin(r)
        local fy = self.dirX * math.sin(r) + self.dirY * math.cos(r)
        c:setForwardDirection(fx, fy)
        c:setTargetAndCurrentDirection(fx, fy)
    end
    -- Pace sample (see above).
    local ms = now()
    if self.calScan ~= scan or step < 0.0005 or step > 0.3 or not self.calMs or ms <= 0 then
        self.calMs, self.calLen, self.calScan = ms, 0, scan     -- broken: start a new sample
        return
    end
    self.calLen = (self.calLen or 0) + step
    local secs = (ms - self.calMs) / 1000
    local normalSpeed = not (getGameSpeed and getGameSpeed() ~= 1) and not (isGamePaused and isGamePaused())
    if secs >= 1.0 and secs < 3 and normalSpeed then
        local speed = self.calLen / secs
        local key = scaleKey(scan)
        local f = 1 + CAL_GAIN * (LF.Move.PATROL_PACE / speed - 1)
        f = math.max(1 - CAL_STEP, math.min(1 + CAL_STEP, f))
        LF.Move[key] = math.max(0.3, math.min(2.0, LF.Move[key] * f))
        LF.Move.lastPace = speed
        LF.Move.samples = (LF.Move.samples or 0) + 1
        if LF.Move.samples % 50 == 0 then saveScales() end
        if (scan == "left" or scan == "right") and not LF.Move.sideLogged then
            LF.Move.sideLogged = true
            LF.log(string.format("MOVE sideways scan: walking on at %.2f tiles/s while turned out", speed))
        end
        self.calMs, self.calLen = ms, 0
    elseif secs >= 3 or (secs >= 1.0 and not normalSpeed) then
        self.calMs, self.calLen = ms, 0                         -- a hitch (loading, pause): throw it away
    end
end

-- Now and then (at most every ~10 s): the pace the patrol is walking at, and the scales.
local lastPaceLog = -100000
Events.EveryOneMinute.Add(function()
    if LF.Move.lastPace and LF.tick - lastPaceLog >= 600 then
        lastPaceLog = LF.tick
        LF.log(string.format("PACE patrol %.2f tiles/s (fixed pace %.2f) - scales shuffle %.2f, walk %.2f, scan %.2f, side %.2f",
            LF.Move.lastPace, LF.Move.PATROL_PACE,
            LF.Move.shuffleScale, LF.Move.patrolScale, LF.Move.scanScale, LF.Move.sideScale))
        LF.Move.lastPace = nil
    end
end)

-- Re-aim a walk that is under way at a new spot, without stopping it (a man keeping his place in
-- a moving formation). Returns false if it couldn't, and the caller starts a new walk.
function LF_MoveAction:retarget(x, y, z)
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z))
    if not sq then return false end
    local pfb = self.character:getPathFindBehavior2()
    if not pfb then return false end
    local ok = pcall(function() pfb:pathToLocation(math.floor(x), math.floor(y), math.floor(z)) end)
    if not ok then return false end
    self.location = sq
    return true
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
