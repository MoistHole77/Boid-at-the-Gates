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
require "LivingFront/Core/LF_Core"

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
-- The patrol pace is the ADS walk: the game's aimed walk forward (Bob_WalkAimRifle) played at its
-- own speed, never scaled. LF.Move.PATROL_PACE is how fast that is (tiles/s), measured in play
-- from the men's forward scans; the other patrol steps (the rifle-down walk, the aimed strafe)
-- are nudged until they walk at that pace too. (Up to 0.30 the pace was a fixed 0.5 tiles/s - the
-- rifle-down walk couldn't go that slow, bottomed out at 40% speed and looked slower than ADS.)
LF.Move.PATROL_PACE = LF.Move.PATROL_PACE or 0.75
-- Legs: the game's slow walk (Bob_WalkSlow - short steps made for a slow pace, so the feet match
-- the ground better than a slowed-down normal walk), rifle carried as usual. (An upper-body
-- "rifle at the ready" overlay was tried in 0.21.4: it put the rifles over their heads.)
-- One animation speed per kind of step (each animation has its own natural stride):
--   shuffle (the slow walk), patrol (plain walk), scan (aimed walk forward / backward) and
--   side (aimed strafe, scanning out to a side). Kept in the save once settled.
-- 0.32: no scaling at all. Every patrol step is an aimed (ADS) walk played at its own speed -
-- forward, or strafing while scanning out to a side - so there is nothing to drift. (0.31's
-- rifle-down walk, nudged to match, swung between 40% and 120% speed: the readings it was nudged
-- by were too noisy, and a scaled clip's feet slide.) The patrol pace is simply how fast that
-- walk goes, measured.
LF.Move.patrolScale = 1.0
LF.Move.scanScale = 1.0
LF.Move.sideScale = 1.0
LF.Move.shuffleScale = 1.0
-- 0.34: low ready between scans. Not scanning, a patrolling man walks the game's slow rifle walk
-- (Bob_WalkSlow_Rifle: short, slow steps, rifle carried low) through our own patrol node, at its
-- own speed - nothing blended or scaled. The patrol pace (LF.Move.PATROL_PACE) is simply how fast
-- that walk goes, measured. He brings the rifle up only to scan (the aimed walks, also at their
-- own speed - a little quicker, but a scan lasts only a second or two). (0.33 tried the game's
-- normal rifle walk slowed by its WalkSpeed blend: NPCs ignore that blend - 1.5 tiles/s at any
-- setting.)
-- mul: this man's own pace correction (LF.March.paceMul) on top of the shared step speeds.
local function setVars(character, patrol, scan, mul)
    mul = 1                                  -- (never scaled: see above)
    local low = patrol and not scan
    local shuffle = low                      -- the slow rifle walk (LF_PatrolShuffle)
    character:setVariable("LFPatrol", patrol)
    -- (An extra condition on every patrol walk node, so they outrank the game's own walks -
    -- including its walk through trees and bushes, which otherwise ties with them and wins.)
    character:setVariable("LFPatrolMove", patrol)
    character:setVariable("LFShuffle", shuffle)
    character:setVariable("LFScan", scan or "none")
    character:setVariable("LFScanOn", scan ~= nil)
    character:setVariable("LFPatrolSpeed", LF.Move.patrolScale * mul)
    character:setVariable("LFShuffleSpeed", LF.Move.shuffleScale * mul)
    character:setVariable("LFScanSpeed", LF.Move.scanScale * mul)
    character:setVariable("LFScanSideSpeed", LF.Move.sideScale * mul)
end
local SCAN_TURN = { fwd = 0, left = -90, right = 90, back = 180 }

local function applyGait(character, gait)
    -- Crawling: never running (the crawl node only plays at a walk).
    if character:getVariableBoolean("LFCrawl") then
        character:setSprinting(false)
        character:setRunning(false)
        return
    end
    if gait == "limp" then
        -- A badly wounded man limping (the game's heavy-limp rifle walk, LF_LimpWalk).
        character:setSprinting(false)
        character:setRunning(false)
        for _, k in ipairs({ "LFLimp", "LFLimpA", "LFLimpB", "LFLimpC", "LFLimpD" }) do character:setVariable(k, true) end
        return
    end
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
    for _, k in ipairs({ "LFLimp", "LFLimpA", "LFLimpB", "LFLimpC", "LFLimpD" }) do character:setVariable(k, false) end
    character:setRunning(false)
    character:setSprinting(false)
    if LF.Move.aimWorks then pcall(setAim, character, false) end
    pcall(setVars, character, false, "none")
end

local function now()
    return getTimestampMs and getTimestampMs() or 0
end

function LF_MoveAction:start()
    if LF.Idle then LF.Idle.standUp(self.character) end     -- sitting: up first
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
    LF.guard("steer", self.steer, self)
    LF.guard("jam check", self.jamCheck, self)
    -- The game could not find a path (a locked gate, a wall): tell the brain, so the soldier
    -- stops retrying the same unreachable spot.
    if self.result == BehaviorResult.Failed then
        -- (A locked door in the way: round to another door first - LF_MoveAction.doorDetour.)
        if LF.guard("door detour", LF_MoveAction.doorDetour, self, "no way through") then return end
        if LF.Move and LF.Move.onFailed then
            LF.Move.onFailed(self.character, self.location:getX() + 0.5, self.location:getY() + 0.5)
        end
    end
end

-- ---- locked doors ----------------------------------------------------------------------------------
-- A man who can't get where he's going because of a locked door:
--   inside the building (its inner doors, or going out): he turns the latch - the inner doors of
--     the building are unlocked, a locked door beside him is opened;
--   outside, going in: he goes round to a door of the building that isn't locked; if every door
--     is locked, to the nearest one, and kicks it in.
-- Returns true if he's doing something about it (the walk goes on).
local function sideTo(self, x, y, z, kick, why)
    local c = self.character
    local pfb = c:getPathFindBehavior2()
    if not (pfb and pcall(function() pfb:pathToLocation(x, y, z) end)) then return false end
    self.side = { x = x + 0.5, y = y + 0.5, untilTick = LF.tick + 900, kick = kick,
                  resume = { x = self.location:getX(), y = self.location:getY(), z = self.location:getZ() } }
    self.result, self.jamBest = nil, nil
    LF.log("MOVE #" .. tostring(c:getModData().LF_id) .. " " .. why)
    return true
end

function LF_MoveAction.doorDetour(self, why)
    if (self.detours or 0) >= 3 then return false end
    local c = self.character
    local dest = self.location
    local here = c:getCurrentSquare()
    local hb, db = here and here:getBuilding(), dest and dest:getBuilding()
    local id = tostring(c:getModData().LF_id)
    -- Right beside a locked door: inside, open it; outside and it's the way in, kick it in.
    local door = LF.Building.lockedDoorBeside(here)
    if door and (hb or db) then
        self.detours = (self.detours or 0) + 1
        LF.Building.unlock(door, c, true)
        LF.log("MOVE #" .. id .. (hb and " unlocks the door beside him and goes through" or " kicks in the locked door"))
        pcall(function() c:playSound(hb and "WoodDoorUnlock" or "ZombieThumpWood") end)
        local pfb = c:getPathFindBehavior2()
        if pfb then pcall(function() pfb:pathToLocation(dest:getX(), dest:getY(), dest:getZ()) end) end
        self.result, self.jamBest = nil, nil
        return true
    end
    if not db then return false end
    local L = LF.Building.at(dest:getX(), dest:getY(), dest:getZ())
    if not L then return false end
    -- Inside the same building: its inner doors are unlocked and he tries again.
    if hb and hb:getID() == db:getID() then
        if self.unlockedInside then return false end
        self.unlockedInside = true
        self.detours = (self.detours or 0) + 1
        if LF.Building.unlockInside(L) == 0 then return false end
        local pfb = c:getPathFindBehavior2()
        if pfb then pcall(function() pfb:pathToLocation(dest:getX(), dest:getY(), dest:getZ()) end) end
        self.result, self.jamBest = nil, nil
        return true
    end
    -- Outside, going in: an unlocked door, else the nearest locked one to kick in.
    local best, bd, bestLocked, bdl = nil, math.huge, nil, math.huge
    for _, o in ipairs(L.openings) do
        if o.kind == "door" then
            local d = LF.Building.doorOf(L, o)
            local ox, oy = o.x + o.dx, o.y + o.dy
            local dist = LF.dist(c:getX(), c:getY(), ox + 0.5, oy + 0.5)
            if d and not (self.triedDoors and self.triedDoors[ox .. "," .. oy]) then
                if LF.Building.isLocked(d) and not LF.Building.isOpen(d) then
                    if dist < bdl then bestLocked, bdl = { o = o, d = d, x = ox, y = oy }, dist end
                elseif dist < bd then best, bd = { o = o, d = d, x = ox, y = oy }, dist end
            end
        end
    end
    local pick = best or bestLocked
    if not pick then return false end
    self.triedDoors = self.triedDoors or {}
    self.triedDoors[pick.x .. "," .. pick.y] = true
    self.detours = (self.detours or 0) + 1
    return sideTo(self, pick.x, pick.y, L.z, pick == bestLocked and pick.d or nil,
        (pick == best and "finds the way in locked - goes round to the door at " or "finds every door locked - goes to kick in the one at ")
        .. pick.x .. "," .. pick.y .. " (" .. why .. ")")
end

-- ---- jams -----------------------------------------------------------------------------------------
-- Two soldiers walking into each other push against each other (the engine keeps solid characters
-- apart) - shuffling, but getting nowhere. A man who has got no closer to where he is going for
-- ~1 s, with another man right against him, is let through - and so is the other man: the engine
-- only stops pushing a pair apart if both are passable (ghost mode). After ~1.5 s both are solid
-- again. (0.28.0 only made the one man passable, and only noticed a man standing dead still.)
local JAM_TICKS = 20         -- (~0.3 s getting nowhere with a man against him; was 1 s)
local GHOST_TICKS = 90
local ghosts = {}           -- body -> tick when he is solid again
local still = {}             -- body -> true while made passable for standing still (below)

local function setGhost(c, on) pcall(function() c:setGhostMode(on) end) end

local ghostCount = 0         -- (Kahlua has no next(): count them instead)

local function ghost(c)
    setGhost(c, true)
    if not ghosts[c] then ghostCount = ghostCount + 1 end
    ghosts[c] = LF.tick + GHOST_TICKS
end

Events.OnTick.Add(function()
    if ghostCount == 0 then return end
    for c, untilTick in pairs(ghosts) do
        if LF.tick >= untilTick or c:isDead() then
            if not still[c] then setGhost(c, false) end
            ghosts[c] = nil
            ghostCount = ghostCount - 1
        end
    end
end)

-- Men standing still are passable to everyone else (the engine pushes two characters apart only
-- if both are solid - ghost mode makes one not): a man running to his place goes through the man
-- crouched in cover beside his path, instead of bumping into him, staggering and getting stuck on
-- him. Men on the move stay solid to each other (they steer round one another, above); they
-- keep their footsteps and the slow-down of trees and wounds, which ghost mode would take away.
local function moving(b)
    local q = ISTimedActionQueue.getTimedActionQueue(b)
    local a = q and q.queue and q.queue[1]
    return a ~= nil and (a.Type == "LF_MoveAction" or a.Type == "ISWalkToTimedAction")
end
Events.OnTick.Add(function()
    if LF.tick % 10 ~= 3 then return end
    for _, b in pairs(LF.Bodies.all()) do
        if not b:isDead() and not ghosts[b] then
            local s = not moving(b)
            if s ~= (still[b] == true) then
                setGhost(b, s)
                still[b] = s or nil
            end
        end
    end
    for b in pairs(still) do
        if b:isDead() then still[b] = nil end
    end
end)

local function someoneAgainst(c)
    local x, y, z = c:getX(), c:getY(), c:getZ()
    for _, b in pairs(LF.Bodies.all()) do
        if b ~= c and math.abs(b:getZ() - z) < 0.5 and LF.distSq(b:getX(), b:getY(), x, y) < 1.44 then return b end
    end
    return nil
end

function LF_MoveAction.jamCheck(self)
    if LF.tick % 5 ~= 0 then return end
    local c = self.character
    local tx, ty = self.location:getX() + 0.5, self.location:getY() + 0.5
    local d = LF.dist(c:getX(), c:getY(), tx, ty)
    if d < 1.0 then return end
    if not self.jamBest or d < self.jamBest - 0.25 then
        self.jamBest, self.jamT, self.headT = d, LF.tick, LF.tick   -- making headway
        return
    end
    if LF.tick - self.jamT < JAM_TICKS or ghosts[c] then return end
    self.jamT = LF.tick
    local other = someoneAgainst(c)
    if not other then
        LF_MoveAction.stallCheck(self, d)
        -- Nobody in his way, getting nowhere: walking into a locked door?
        if LF.Building and LF.Building.lockedDoorBeside(c:getCurrentSquare()) then
            LF.guard("door detour", LF_MoveAction.doorDetour, self, "walked into a locked door")
        end
        return
    end
    ghost(c)
    ghost(other)
    LF.Move.jams = (LF.Move.jams or 0) + 1
    if LF.Move.jams <= 10 or LF.Move.jams % 50 == 0 then
        LF.log("MOVE #" .. tostring(c:getModData().LF_id) .. " jammed against #" .. tostring(other:getModData().LF_id)
            .. " - both slip past (" .. LF.Move.jams .. ")")
    end
end

-- ---- getting nowhere ----------------------------------------------------------------------------
-- Nobody against him, no locked door, but no headway for 3 s (0.47: two men stood frozen in front
-- of a fence, walking on the spot): whatever the game's state is stuck on is cleared and the path
-- is planned again; still nowhere 3 s later, the spot is given up as unreachable and the brain
-- picks another.
local STALL_TICKS = 180
function LF_MoveAction.stallCheck(self, d)
    local c = self.character
    if self.side then self.headT = LF.tick; return end   -- (round to a door: away from the spot for a while)
    if LF.tick - (self.headT or LF.tick) < STALL_TICKS then return end
    if LF.Brain and LF.Brain.climbing and LF.Brain.climbing(c) then return end   -- (his own watchdog)
    local okB, down = pcall(function() return c:isBumped() or c:isOnFloor() end)
    if okB and down then return end
    self.headT = LF.tick
    self.stalls = (self.stalls or 0) + 1
    local id = tostring(c:getModData().LF_id)
    local okS, state = pcall(function() return c:getCurrentStateName() end)
    LF.log("MOVE #" .. id .. " getting nowhere (" .. string.format("%.1f", d) .. " tiles short, at "
        .. math.floor(c:getX()) .. "," .. math.floor(c:getY()) .. ", state " .. tostring(okS and state)
        .. ", try " .. self.stalls .. ")")
    if self.stalls >= 2 then
        if LF.Move and LF.Move.onFailed then
            LF.Move.onFailed(c, self.location:getX() + 0.5, self.location:getY() + 0.5)
        end
        self:forceStop()
        return
    end
    pcall(function()
        for _, v in ipairs({ "ClimbFenceFinished", "ClimbWindowFinished", "ClimbWallFinished", "BumpDone" }) do c:setVariable(v, true) end
        c:setVariable("ClimbFenceStarted", false)
        c:setBumpType("")
        c:reportEvent("ActiveAnimFinishing")    -- (out of a stagger state with no animation left)
    end)
    local pfb = c:getPathFindBehavior2()
    if pfb then
        pcall(function() pfb:pathToLocation(self.location:getX(), self.location:getY(), self.location:getZ()) end)
    end
    self.result = nil
end

local function unghost(self) end   -- (ghosts end on their own timer)

-- ---- steering round each other ---------------------------------------------------------------
-- Before it comes to a jam: every few ticks a walking man looks just ahead along his way. Someone
-- there (standing, or coming the other way) - he steps off to his right, a tile and a bit, and
-- goes on from there to where he was going. Two men walking into each other both keep right, so
-- they pass. (The pathfinder plans round walls and furniture, not round people.)
local STEER_AHEAD = 1.8      -- look this far ahead
local STEER_WIDTH = 0.7      -- a man this close to his line is in the way
local STEER_STEP = 1.2       -- how far to the side he steps

local function inTheWay(c, dx, dy)
    local x, y, z = c:getX(), c:getY(), c:getZ()
    local best, bestT = nil, STEER_AHEAD
    for _, b in pairs(LF.Bodies.all()) do
        if b ~= c and math.abs(b:getZ() - z) < 0.5 and not b:isDead() then
            local vx, vy = b:getX() - x, b:getY() - y
            local t = vx * dx + vy * dy                   -- along his way
            if t > 0.2 and t < bestT then
                local lat = math.abs(vx * dy - vy * dx)   -- off his line
                if lat < STEER_WIDTH then best, bestT = b, t end
            end
        end
    end
    local p = getPlayer()
    if p and not best then
        local vx, vy = p:getX() - x, p:getY() - y
        local t = vx * dx + vy * dy
        if math.abs(p:getZ() - z) < 0.5 and t > 0.2 and t < STEER_AHEAD and math.abs(vx * dy - vy * dx) < STEER_WIDTH then best = p end
    end
    return best
end

function LF_MoveAction.steer(self)
    if LF.tick % 6 ~= 0 then return end
    local c = self.character
    local px, py, pz = c:getX(), c:getY(), math.floor(c:getZ())
    if self.side then
        -- Stepping aside: on to the side point, then back on the way.
        local sd = self.side
        if LF.dist(px, py, sd.x, sd.y) < (sd.kick and 1.2 or 0.6) or LF.tick > sd.untilTick then
            self.side = nil
            if sd.kick and LF.dist(px, py, sd.x, sd.y) < 1.6 then
                LF.Building.unlock(sd.kick, c, true)
                pcall(function() c:playSound("ZombieThumpWood") end)
                LF.log("MOVE #" .. tostring(c:getModData().LF_id) .. " kicks in the locked door")
            end
            local o = sd.resume
            local pfb = c:getPathFindBehavior2()
            if pfb then pcall(function() pfb:pathToLocation(o.x, o.y, o.z) end) end
            self.location = getCell():getGridSquare(o.x, o.y, o.z) or self.location
            self.jamBest = nil
        end
        return
    end
    if self.gait == "patrol" or self.gait == "aim" then return end   -- (a formation, a room entry keep their line)
    local tx, ty = self.location:getX() + 0.5, self.location:getY() + 0.5
    local dx, dy = tx - px, ty - py
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 2.5 then return end                          -- nearly there: no swerving now
    -- His way: the direction he's actually moving, else straight at the goal.
    if self.lastSX then
        local mx, my = px - self.lastSX, py - self.lastSY
        local m = math.sqrt(mx * mx + my * my)
        if m > 0.02 then dx, dy, d = mx, my, m end
    end
    self.lastSX, self.lastSY = px, py
    dx, dy = dx / d, dy / d
    local other = inTheWay(c, dx, dy)
    if not other then return end
    -- Keep right (on the map grid, right of (dx, dy) is (-dy, dx)); if that's blocked, left.
    for _, sgn in ipairs({ 1, -1 }) do
        local sx, sy = px + dx * 0.8 - dy * STEER_STEP * sgn, py + dy * 0.8 + dx * STEER_STEP * sgn
        local sq = getCell():getGridSquare(math.floor(sx), math.floor(sy), pz)
        if sq and sq:isFree(false) and LF.Cover.crossings(px, py, sx, sy, pz, 1) == 0 then
            local pfb = c:getPathFindBehavior2()
            local ok = pfb and pcall(function() pfb:pathToLocation(math.floor(sx), math.floor(sy), pz) end)
            if ok then
                self.side = { x = math.floor(sx) + 0.5, y = math.floor(sy) + 0.5, untilTick = LF.tick + 60,
                              resume = { x = self.location:getX(), y = self.location:getY(), z = self.location:getZ() } }
                LF.Move.steers = (LF.Move.steers or 0) + 1
                if LF.Move.steers <= 5 or LF.Move.steers % 100 == 0 then
                    LF.log("MOVE #" .. tostring(c:getModData().LF_id) .. " steps round someone in his way (" .. LF.Move.steers .. ")")
                end
            end
            return
        end
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
local CAL_STEP = 0.03        -- ... but never more than this (3%) per sample
local CAL_KEEP = 9           -- readings kept (per kind of step) for the median
local function scaleKey(scan)
    if scan == "left" or scan == "right" then return "sideScale" end
    if scan then return "scanScale" end
    return LF.Move.shuffle ~= false and "shuffleScale" or "patrolScale"
end
local function saveScales()
    local data = LF.Records and LF.Records.data and LF.Records.data()
    if not data then return end
    data.moveScales = data.moveScales or {}
    data.moveScalesV = 6
    for _, k in ipairs({ "PATROL_PACE" }) do data.moveScales[k] = LF.Move[k] end
end
Events.OnInitGlobalModData.Add(function()
    local data = LF.Records and LF.Records.data and LF.Records.data()
    local s = data and data.moveScalesV == 6 and data.moveScales
    if s and type(s.PATROL_PACE) == "number" then LF.Move.PATROL_PACE = s.PATROL_PACE end
end)

function LF_MoveAction.patrolStep(self)
    local c = self.character
    local scanning = self.scan and self.scanUntil and LF.tick < self.scanUntil
    local scan = scanning and self.scan or nil
    if scan == "back" then scan = "fwd" end
    local low = scan == nil
    local mul = self.paceMul or 1
    setVars(c, true, scan, mul)

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
    if self.calScan ~= scan or step < 0.0005 or step > 0.3 or not self.calMs or ms <= 0
        or math.abs(mul - (self.calMul or mul)) > 0.1 then
        self.calMs, self.calLen, self.calScan, self.calMul = ms, 0, scan, mul   -- broken: start a new sample
        return
    end
    self.calLen = (self.calLen or 0) + step
    local secs = (ms - self.calMs) / 1000
    local normalSpeed = not (getGameSpeed and getGameSpeed() ~= 1) and not (isGamePaused and isGamePaused())
    if secs >= 1.0 and secs < 3 and normalSpeed then
        local speed = self.calLen / secs
        -- His step speed without his own pace correction: what the shared scale gives.
        local base = speed / ((mul + (self.calMul or mul)) / 2)
        local key = scaleKey(scan)
        -- A reading far off the patrol pace isn't the patrol step at all (the game's own walk
        -- took over for a moment - turning, stepping round something): thrown away.
        if base < LF.Move.PATROL_PACE * 0.4 or base > LF.Move.PATROL_PACE * 2 then
            self.calMs, self.calLen, self.calMul = ms, 0, mul
            return
        end
        if low then
            -- The slow rifle walk: this IS the patrol pace (median of the last few readings).
            LF.Move.lowReadings = LF.Move.lowReadings or {}
            local list = LF.Move.lowReadings
            list[#list + 1] = base
            if #list > CAL_KEEP then table.remove(list, 1) end
            if #list >= 5 then
                local sorted = {}
                for i = 1, #list do sorted[i] = list[i] end
                table.sort(sorted)
                LF.Move.lowMedian = sorted[math.floor((#sorted + 1) / 2)]
                LF.Move.PATROL_PACE = math.max(0.4, math.min(1.8, LF.Move.lowMedian))
            end
            LF.Move.lastPace = base
            LF.Move.samples = (LF.Move.samples or 0) + 1
            if LF.Move.samples % 50 == 0 then saveScales() end
            self.calMs, self.calLen, self.calMul = ms, 0, mul
            return
        end
        if scan == "fwd" then
            -- The ADS walk itself: this IS the patrol pace (the median of the last few readings).
            LF.Move.adsReadings = LF.Move.adsReadings or {}
            local list = LF.Move.adsReadings
            list[#list + 1] = base
            if #list > CAL_KEEP then table.remove(list, 1) end
            if #list >= 3 then
                local sorted = {}
                for i = 1, #list do sorted[i] = list[i] end
                table.sort(sorted)
                LF.Move.adsMedian = sorted[math.floor((#sorted + 1) / 2)]     -- (for the log only)
            end
            self.calMs, self.calLen, self.calMul = ms, 0, mul
            return
        end
        -- Steer by the median of the last few clean readings (one odd reading can't swing it),
        -- a few percent at a time.
        LF.Move.recent = LF.Move.recent or {}
        local list = LF.Move.recent[key] or {}
        LF.Move.recent[key] = list
        list[#list + 1] = base
        if #list > CAL_KEEP then table.remove(list, 1) end
        if false then                                  -- (0.32: nothing is scaled any more)
            local sorted = {}
            for i = 1, #list do sorted[i] = list[i] end
            table.sort(sorted)
            local median = sorted[math.floor((#sorted + 1) / 2)]
            local f = 1 + CAL_GAIN * (LF.Move.PATROL_PACE / median - 1)
            f = math.max(1 - CAL_STEP, math.min(1 + CAL_STEP, f))
            LF.Move[key] = math.max(0.4, math.min(2.0, LF.Move[key] * f))
        end
        LF.Move.lastPace = base
        LF.Move.samples = (LF.Move.samples or 0) + 1
        if LF.Move.samples % 50 == 0 then saveScales() end
        if (scan == "left" or scan == "right") and not LF.Move.sideLogged then
            LF.Move.sideLogged = true
            LF.log(string.format("MOVE sideways scan: walking on at %.2f tiles/s while turned out", speed))
        end
        self.calMs, self.calLen, self.calMul = ms, 0, mul
    elseif secs >= 3 or (secs >= 1.0 and not normalSpeed) then
        self.calMs, self.calLen = ms, 0                         -- a hitch (loading, pause): throw it away
    end
end

-- Now and then (at most every ~10 s): the pace the patrol is walking at, and the scales.
local lastPaceLog = -100000
Events.EveryOneMinute.Add(function()
    if LF.Move.lastPace and LF.tick - lastPaceLog >= 600 then
        lastPaceLog = LF.tick
        LF.log(string.format("PACE last step %.2f tiles/s; patrol pace %.2f (slow rifle walk median %s; aimed walk forward %s)",
            LF.Move.lastPace, LF.Move.PATROL_PACE,
            LF.Move.lowMedian and string.format("%.2f", LF.Move.lowMedian) or "-",
            LF.Move.adsMedian and string.format("%.2f", LF.Move.adsMedian) or "-"))
        LF.Move.lastPace = nil
    end
end)

-- Re-aim a walk that is under way at a new spot, without stopping it (a man keeping his place in
-- a moving formation). Returns false if it couldn't, and the caller starts a new walk.
function LF_MoveAction:retarget(x, y, z)
    self.side = nil                                   -- (a new place to go: any sidestep is off)
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z))
    if not sq then return false end
    local pfb = self.character:getPathFindBehavior2()
    if not pfb then return false end
    local ok = pcall(function() pfb:pathToLocation(math.floor(x), math.floor(y), math.floor(z)) end)
    if not ok then return false end
    self.location = sq
    self.jamBest = nil
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
    unghost(self)
    logSpeed(self, "stopped")
    if self.overlay then self:setActionAnim(""); self.overlay = nil end
    clearGait(self.character)
    ISWalkToTimedAction.stop(self)
end

function LF_MoveAction:perform()
    unghost(self)
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
