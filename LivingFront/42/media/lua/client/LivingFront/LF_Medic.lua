-- Living Front: the medic - stage 1, dragging a downed man.
--
-- A drag, done the way the game drags a corpse, with the game's own animations (all player
-- clips; the game only ever plays the "being dragged" side on a corpse, so here both sides are
-- our own animation nodes - AnimSets/player/idle/LF_Drag*, LF_Lie*, movement/LF_DragWalk):
--   approach - the medic walks to the man's head end and faces along him
--   lift     - he takes him under the arms and lifts his shoulders (Bob_PickUp_Person_FromOnBack;
--              the man: Bob_PickedUp_FromOnBack)
--   drag     - he walks backward along his path, the man's shoulders at his feet
--              (Bob_WalkBwdDrag_Person / Bob_WalkBwdDragged, Bob_IdleDrag_Person / Bob_IdleDragged
--              when he stops)
--   lay      - he lays him down on his back (Bob_LayDown_Person_OnBack / Bob_LaidDown_OnBack)
-- The geometry is the game's: while dragged, the man is 0.3 tiles in front of the medic, facing
-- the same way (m_GrappleOffsetForward 0.3 on the game's drag nodes); for the lift (-1.2) the medic
-- stands 1.2 tiles behind the man's head, looking down him, and the man stays where he lies.
-- Both are passable (ghosted) while it lasts, and the brain leaves them alone (LF.Medic.busy).
--
-- Test: Living Front > Tests > Medic drag (spawns a German fire team: one man goes down, another
-- drags him 8 tiles back toward the rear).

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Units"
require "LivingFront/LF_MoveAction"
require "LivingFront/LF_Cover"

LF.Medic = LF.Medic or {}

local CFG = {
    liftOffset = -1.2,      -- the game's pick-up node: the medic stands at the man + his facing x this
                            -- (behind his head, looking down the length of him)
    dragOffset = 0.3,       -- the game's drag nodes: the man at the medic + forward x this
    liftTicks = 150,        -- the lift clip (~2.5 s)
    layTicks = 130,         -- the lay-down clip (~2 s)
    tween = 20,             -- ticks to ease the man from where he lay to the medic's feet
    approachTimeout = 1200, -- can't get to him in ~20 s: give up
    dragTimeout = 2400,     -- the drag itself: ~40 s at most
    arrive = 0.6,           -- the medic is there when this close to the spot
    stallTicks = 60,        -- no headway for ~1 s: something is in the way, he stops there
    dragSpeed = 0.45,       -- tiles/s, only if the drag clip doesn't move him by itself (see below)
    dragDist = 8,           -- the test: this far back toward the rear
}
LF.Medic.CFG = CFG

local busy = {}             -- id -> what he's doing ("lying", "dragging", "dragged")
local jobs = {}             -- drags under way
local jobCount = 0          -- (Kahlua has no next())
Events.OnInitGlobalModData.Add(function() busy, jobs, jobCount = {}, {}, 0 end)

function LF.Medic.busy(id) return busy[id] ~= nil end

local function setVars(body, prefix, value)
    body:setVariable(prefix, value or "none")
    for _, k in ipairs({ "A", "B", "C", "D" }) do body:setVariable(prefix .. k, value ~= nil) end
end
local function setDrag(body, v) setVars(body, "LFDrag", v) end
local function setLie(body, v) setVars(body, "LFLie", v) end

local function ghost(body, on) pcall(function() body:setGhostMode(on) end) end

local function face(body, fx, fy)
    body:setForwardDirection(fx, fy)
    pcall(function() body:setTargetAndCurrentDirection(fx, fy) end)
end

-- Put a body exactly here (a body being dragged doesn't walk: it is carried along).
local function place(body, x, y)
    body:setX(x); body:setY(y)
    pcall(function() body:setNextX(x); body:setNextY(y) end)
    pcall(function() body:setLastX(x); body:setLastY(y) end)
    pcall(function() body:ensureOnTile() end)
end

local function fwdOf(body)
    local v = body:getForwardDirection()
    local fx, fy = v:getX(), v:getY()
    local l = math.sqrt(fx * fx + fy * fy)
    if l < 0.001 then return 1, 0 end
    return fx / l, fy / l
end

local function moving(body)
    local q = ISTimedActionQueue.getTimedActionQueue(body)
    local a = q and q.queue and q.queue[1]
    return a ~= nil and a.Type == "LF_MoveAction"
end

local function walk(body, x, y, z, gait)
    ISTimedActionQueue.clear(body)
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), z)
    if not sq then return false end
    ISTimedActionQueue.add(LF_MoveAction:new(body, sq, gait))
    return true
end

-- ---- down on his back ---------------------------------------------------------------------------

-- He goes down on his back where he stands, and stays there until he's picked up (or stands up).
function LF.Medic.lieDown(id, body)
    ISTimedActionQueue.clear(body)
    if LF.Idle then LF.Idle.stop(body) end
    if LF.Posture and LF.Posture.crouched(body) then LF.Posture.set(body, false) end
    busy[id] = "lying"
    setLie(body, "back")
    LF.log("MEDIC #" .. id .. " is down on his back at " .. math.floor(body:getX()) .. "," .. math.floor(body:getY()))
end

function LF.Medic.standUp(id, body)
    busy[id] = nil
    if body then setLie(body, nil); ghost(body, false) end
end

-- ---- the drag -----------------------------------------------------------------------------------

local function finish(J, why, ok)
    jobCount = jobCount - 1
    for i, j in ipairs(jobs) do if j == J then table.remove(jobs, i); break end end
    if J.mb and not J.mb:isDead() then
        setDrag(J.mb, nil)
        ghost(J.mb, false)
        ISTimedActionQueue.clear(J.mb)
        if LF.Combat and J.slung then LF.Combat.unsling(J.mb) end
    end
    busy[J.mid] = nil
    if J.pb and not J.pb:isDead() then
        setLie(J.pb, "back")
        ghost(J.pb, false)
        busy[J.pid] = "lying"
    else
        busy[J.pid] = nil
    end
    local moved = J.pb and LF.dist(J.px, J.py, J.pb:getX(), J.pb:getY()) or 0
    LF.log(string.format("MEDIC #%d %s #%d: %s (%.1f tiles in %.1f s)", J.mid, ok and "dragged" or "gave up dragging",
        J.pid, why, moved, (LF.tick - J.started) / 60))
end

-- Medic (mid, mb) drags the man (pid, pb) lying on his back to (tx, ty). Returns true if it starts.
function LF.Medic.drag(mid, mb, pid, pb, tx, ty)
    if busy[mid] or not pb or pb:isDead() or not mb or mb:isDead() then return false end
    if busy[pid] ~= "lying" then LF.Medic.lieDown(pid, pb) end
    local dx, dy = fwdOf(pb)
    local z = math.floor(pb:getZ())
    local px, py = pb:getX(), pb:getY()
    -- Where the medic stands to lift him: the game's lift geometry.
    local sx, sy = px + dx * CFG.liftOffset, py + dy * CFG.liftOffset
    local J = { mid = mid, mb = mb, pid = pid, pb = pb, phase = "approach", at = LF.tick, started = LF.tick,
                px = px, py = py, z = z, dx = dx, dy = dy, sx = sx, sy = sy, tx = tx, ty = ty }
    if not walk(mb, sx, sy, z, "walk") then return false end
    busy[mid] = "dragging"
    jobs[#jobs + 1] = J
    jobCount = jobCount + 1
    LF.log(string.format("MEDIC #%d goes to drag #%d from %d,%d to %d,%d", mid, pid, math.floor(px), math.floor(py),
        math.floor(tx), math.floor(ty)))
    return true
end

local function step(J)
    local mb, pb = J.mb, J.pb
    if mb:isDead() then finish(J, "the medic is down", false); return end
    if pb:isDead() then finish(J, "the man died", false); return end
    local age = LF.tick - J.at
    if J.phase == "approach" then
        local d = LF.dist(mb:getX(), mb:getY(), J.sx, J.sy)
        if d <= 0.6 or (d <= 1.2 and not moving(mb)) then
            ISTimedActionQueue.clear(mb)
            place(mb, J.sx, J.sy)
            face(mb, J.dx, J.dy)
            face(pb, J.dx, J.dy)
            if LF.Combat then J.slung = LF.Combat.sling(mb) end
            ghost(mb, true); ghost(pb, true)
            setDrag(mb, "lift")
            setLie(pb, "lifted")
            busy[J.pid] = "dragged"
            J.phase, J.at = "lift", LF.tick
            LF.log("MEDIC #" .. J.mid .. " lifts #" .. J.pid)
        elseif age > CFG.approachTimeout then
            finish(J, "couldn't get to him", false)
        elseif not moving(mb) and age % 60 == 0 then
            walk(mb, J.sx, J.sy, J.z, "walk")
        end
    elseif J.phase == "lift" then
        place(pb, J.px, J.py)                    -- he stays where he lies while he's lifted
        face(pb, J.dx, J.dy)
        if age >= CFG.liftTicks then
            J.fromX, J.fromY = pb:getX(), pb:getY()
            J.liftMoved = LF.dist(mb:getX(), mb:getY(), J.sx, J.sy)
            setDrag(mb, "pull")
            setLie(pb, "dragged")
            J.lastX, J.lastY, J.bestD, J.bestAt = mb:getX(), mb:getY(), math.huge, LF.tick
            J.phase, J.at, J.dragStart = "drag", LF.tick, LF.tick
            J.startX, J.startY = mb:getX(), mb:getY()
            LF.log(string.format("MEDIC #%d drags #%d back (the lift moved him %.2f tiles)", J.mid, J.pid, J.liftMoved))
        end
    elseif J.phase == "drag" then
        -- He walks backward toward the spot: facing away from it (at the man), and the drag clip
        -- itself carries him - the way the game moves a player dragging a corpse, at the clip's
        -- own pace. (0.35 walked him there on the pathfinder: NPC paths go at walking pace
        -- whatever the clip, so he dragged at a trot.)
        local mx, my = mb:getX(), mb:getY()
        local tx, ty = J.tx - mx, J.ty - my
        local d = math.sqrt(tx * tx + ty * ty)
        if d > 0.05 then
            local fx, fy = -tx / d, -ty / d
            local ox, oy = fwdOf(mb)
            fx, fy = ox * 0.8 + fx * 0.2, oy * 0.8 + fy * 0.2
            local l = math.max(0.0001, math.sqrt(fx * fx + fy * fy))
            face(mb, fx / l, fy / l)
        end
        -- If the clip doesn't carry an NPC by itself, he is moved at the drag pace by hand.
        if J.manual == nil and age >= 60 then
            local moved = LF.dist(mx, my, J.startX, J.startY)
            J.manual = moved < 0.1
            LF.log(string.format("MEDIC drag: the clip %s (%.2f tiles in the first second)",
                J.manual and "doesn't move him - moving him at the drag pace by hand" or "moves him itself", moved))
        end
        if J.manual and d > 0.05 then
            local k = math.min(d, CFG.dragSpeed / 60)
            local nx, ny = mx + tx / d * k, my + ty / d * k
            local sq = getCell():getGridSquare(math.floor(nx), math.floor(ny), J.z)
            if sq and sq:isFree(false) and LF.Cover.crossings(mx, my, nx, ny, J.z, 1) == 0 then place(mb, nx, ny) end
        end
        local fx, fy = fwdOf(mb)
        local wx, wy = mb:getX() + fx * CFG.dragOffset, mb:getY() + fy * CFG.dragOffset
        if age < CFG.tween then                  -- eased in from where he lay
            local k = age / CFG.tween
            wx, wy = J.fromX + (wx - J.fromX) * k, J.fromY + (wy - J.fromY) * k
        end
        place(pb, wx, wy)
        face(pb, fx, fy)
        if d < J.bestD - 0.1 then J.bestD, J.bestAt = d, LF.tick end
        local there = d <= CFG.arrive
        local stuck = LF.tick - J.bestAt > CFG.stallTicks
        if there or stuck or age > CFG.dragTimeout then
            local secs = (LF.tick - J.dragStart) / 60
            local dist = LF.dist(mb:getX(), mb:getY(), J.startX, J.startY)
            LF.log(string.format("MEDIC drag: %.1f tiles in %.1f s = %.2f tiles/s%s", dist, secs, dist / math.max(0.1, secs),
                there and "" or (stuck and " (stopped: something in the way)" or " (took too long)")))
            J.layX, J.layY = pb:getX(), pb:getY()
            setDrag(mb, "lay")
            setLie(pb, "laid")
            J.arrived = there
            J.phase, J.at = "lay", LF.tick
        end
    elseif J.phase == "lay" then
        place(pb, J.layX, J.layY)
        if age >= CFG.layTicks then
            finish(J, J.arrived and "there" or "stopped short (path blocked)", true)
        end
    end
end

Events.OnTick.Add(function()
    if jobCount == 0 then return end
    for i = #jobs, 1, -1 do
        local J = jobs[i]
        if J then LF.guard("medic drag", step, J) end
    end
end)

-- ---- the test -----------------------------------------------------------------------------------

-- Spawn a German fire team here; once it's in, one private goes down on his back and another
-- drags him dragDist tiles back toward the rear (toward the player: the team faces away).
function LF.Medic.testDrag(x, y, z, playerNum)
    local p = getSpecificPlayer(playerNum)
    local fx, fy = 1, 0
    if p then fx, fy = x + 0.5 - p:getX(), y + 0.5 - p:getY() end
    local l = math.max(0.01, math.sqrt(fx * fx + fy * fy))
    fx, fy = fx / l, fy / l
    local unit = LF.Units.createSquad("GER", x + 0.5, y + 0.5, z, fx, fy, true)
    local team = LF.Units.get(unit.teams[1])
    local t0 = LF.tick
    local stage = 0
    local pid, mid
    local function tick()
        if LF.tick - t0 > 900 then Events.OnTick.Remove(tick); LF.say("Medic test: the team never spawned"); return end
        if stage == 0 then
            local pvts = {}
            for _, rid in ipairs(team.members) do
                local r = LF.Records.get(rid)
                if r and r.rank == "PVT" and LF.Bodies.get(rid) then pvts[#pvts + 1] = rid end
            end
            if #pvts < 2 then return end
            pid, mid = pvts[1], pvts[#pvts]
            LF.Medic.lieDown(pid, LF.Bodies.get(pid))
            stage, t0 = 1, LF.tick
        elseif stage == 1 and LF.tick - t0 >= 120 then
            Events.OnTick.Remove(tick)
            local pb, mb = LF.Bodies.get(pid), LF.Bodies.get(mid)
            if not (pb and mb) then return end
            -- Back toward the rear: the first spot along that way he can walk to with nothing to
            -- climb (no fence, wall or window between).
            local bx, by = pb:getX(), pb:getY()
            local tx, ty = bx - fx * CFG.dragDist, by - fy * CFG.dragDist
            for d = CFG.dragDist, 3, -1 do
                local cx, cy = bx - fx * d, by - fy * d
                local sq = getCell():getGridSquare(math.floor(cx), math.floor(cy), z)
                if sq and sq:isFree(false) and (not LF.Cover or LF.Cover.crossings(bx, by, cx, cy, z, 2) == 0) then
                    tx, ty = cx, cy
                    break
                end
            end
            if LF.Medic.drag(mid, mb, pid, pb, tx, ty) then
                LF.say("Medic test: #" .. mid .. " drags #" .. pid .. " back " .. math.floor(LF.dist(bx, by, tx, ty)) .. " tiles")
            else
                LF.say("Medic test: couldn't start the drag (see the log)")
            end
        end
    end
    Events.OnTick.Add(tick)
end

-- Everyone lying from the test gets up.
function LF.Medic.endTest()
    for i = #jobs, 1, -1 do finish(jobs[i], "test ended", false) end
    local ids = {}
    for id in pairs(busy) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do LF.Medic.standUp(id, LF.Bodies.get(id)) end
    busy = {}
    LF.say("Medic test ended")
end
