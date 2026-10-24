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
    dragOffset = 0.3,
    getUpTicks = 75,        -- the get-up clip (~1.2 s)       -- the game's drag nodes: the man at the medic + forward x this
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

-- He has been knocked over backward by the game (on the floor, on his back): keep him there.
-- The game's knocked-down state is ended under him and our lying pose takes over - the same clip
-- the game lies him there with (Zombie_Idle_FloorOnBack), so nothing visibly moves - and he
-- doesn't get up.
function LF.Medic.holdDown(id, body)
    pcall(function() body:setBumpDone(true) end)
    pcall(function() body:setVariable("BumpDone", true) end)
    pcall(function() body:setBumpFall(false) end)
    pcall(function() body:setVariable("BumpFall", false) end)
    pcall(function() body:setKnockedDown(false) end)
    pcall(function() body:setOnFloor(false) end)
    LF.Medic.lieDown(id, body)
end

-- He gets up off his back (the game's get-up clip, Bob_GetUp_Back) and is himself again after
-- ~1.2 s. onUp() is called then.
function LF.Medic.getUp(id, body, onUp)
    if not body or body:isDead() then busy[id] = nil; if onUp then onUp() end; return end
    busy[id] = "rising"
    setLie(body, "getup")
    local t0 = LF.tick
    local function tick()
        if LF.tick - t0 < CFG.getUpTicks and not body:isDead() then return end
        Events.OnTick.Remove(tick)
        LF.Medic.standUp(id, body)
        if onUp then LF.guard("got up", onUp) end
    end
    Events.OnTick.Add(tick)
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
    if J.onDone then LF.guard("drag done", J.onDone, ok, J) end
end

-- Medic (mid, mb) drags the man (pid, pb) lying on his back to (tx, ty). Returns true if it starts.
-- opts.route: waypoints { {x, y}, ... } ending at (tx, ty) - round corners, through doorways;
-- opts.onDone(ok, J): called when it is over.
function LF.Medic.drag(mid, mb, pid, pb, tx, ty, opts)
    opts = opts or {}
    if busy[mid] or not pb or pb:isDead() or not mb or mb:isDead() then return false end
    if busy[pid] ~= "lying" then LF.Medic.lieDown(pid, pb) end
    local dx, dy = fwdOf(pb)
    local z = math.floor(pb:getZ())
    local px, py = pb:getX(), pb:getY()
    -- Where the medic stands to lift him: the game's lift geometry.
    local sx, sy = px + dx * CFG.liftOffset, py + dy * CFG.liftOffset
    local J = { mid = mid, mb = mb, pid = pid, pb = pb, phase = "approach", at = LF.tick, started = LF.tick,
                px = px, py = py, z = z, dx = dx, dy = dy, sx = sx, sy = sy, tx = tx, ty = ty,
                route = opts.route or { { x = tx, y = ty } }, wi = 1, onDone = opts.onDone }
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
        -- On to the next waypoint once he's at this one.
        local wp = J.route[J.wi]
        if J.wi < #J.route and LF.dist(mx, my, wp.x, wp.y) <= 0.5 then
            J.wi = J.wi + 1
            wp = J.route[J.wi]
            J.bestD, J.bestAt = math.huge, LF.tick
        end
        local tx, ty = wp.x - mx, wp.y - my
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
        local there = J.wi == #J.route and d <= CFG.arrive
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

-- =================================================================================================
-- The squad medic (stage 2)
-- =================================================================================================
--
-- Who: in every full squad, one private of the rearmost team (Bravo 2) is the medic. He carries a
-- leather satchel of dressings (Bag_Satchel_Leather) and a sub-machine gun instead of a rifle
-- (MP40 / PPSh). His kit holds CFG2.kit dressings; it doesn't refill in a fight.
--
-- Critical, not dead: when a man of a squad whose medic is alive and has dressings left takes a
-- hit that would kill him - not a head shot, not the middle of a grenade blast - there's a chance
-- (the medic's: green 50%, veteran 75%, shaken 40%) that he goes down critical instead. He lies
-- on his back calling for the medic, bleeding out: 60-90 s (a veteran medic's squad gets 30%
-- longer). Reach him in time and he's stabilised - he lives, out of the fight, lying in cover
-- until it's over, then gets up as wounded. Nobody comes: he dies when the clock runs out. Hit
-- again while he's down: he dies.
--
-- The medic: every half second he looks for the worst case in his squad within 30 tiles - the
-- critical first (soonest to die), then badly hurt men still bleeding - and goes to him at a run
-- (the sergeant calls "Cover the medic!" when the enemy is near the man). Next to him he crouches,
-- slings his SMG and works (the game's low-reach clip): stabilising a critical man takes ~6 s and
-- 2 dressings, bandaging a bleeder ~2.5 s and 1. An enemy in sight within 8 tiles of him, or a
-- knockdown, breaks it off - he fights first, then goes back. A shaken medic hesitates 4 s before
-- going out; a veteran one (5 men saved) works 30% faster.

require "LivingFront/LF_Aid"

local CFG2 = {
    kit = 8, stabiliseCost = 2, bandageCost = 1,
    chance = { green = 50, veteran = 75, shaken = 40 },
    bleedOut = { 3600, 1800 },  -- 60 s + up to 30 s
    vetWindow = 1.3,
    vetSaves = 5,               -- saves for a medic to count as a veteran at it
    floor = 3,                  -- a critical man's health is held at this (the clock kills him)
    dyingAt = 10,               -- a man this low (from a hit, or bleeding) is dying: he may go critical
    stableFloor = 15,           -- a stabilised man's health never drops below this
    stabiliseTicks = 360, bandageTicks = 150, vetSpeed = 0.7,
    range = 30,                 -- he goes to men this close
    severeHealth = 45,          -- "badly hurt" (and bleeding): worth his dressings
    threatRange = 8,            -- an enemy in sight this close: he fights first
    shakenDelay = 240,
    quietRelease = 3600,        -- stabilised men get up after ~60 s with no enemy known
}
LF.Medic.CFG2 = CFG2

local crit = {}             -- id -> { squad, untilTick, since }
local stable = {}           -- id -> { squad, quietSince }
local jobs2 = {}            -- medic id -> { pid, kind, phase, at, nextPath }
local cooldown = {}         -- medic id -> tick he may take a new job
Events.OnInitGlobalModData.Add(function() crit, stable, jobs2, cooldown = {}, {}, {}, {} end)

function LF.Medic.isCritical(id) return crit[id] ~= nil end
function LF.Medic.isStable(id) return stable[id] ~= nil end
function LF.Medic.critLeft(id) local c = crit[id]; return c and math.max(0, c.untilTick - LF.tick) or nil end
function LF.Medic.job(id) return jobs2[id] end

local SMG = { GER = "MP40", SOV = "PPSh" }

-- His level at it: "veteran" (enough men saved, or a veteran soldier), "shaken", or "green".
local function levelOf(rec)
    local s = rec.svc
    if s and s.shaken then return "shaken" end
    if (rec.medicSaves or 0) >= CFG2.vetSaves or (s and s.veteran) then return "veteran" end
    return "green"
end
LF.Medic.levelOf = levelOf

-- Put the satchel on him and the SMG in his hands (at spawn, or when he's made the medic).
function LF.Medic.equip(body, rec)
    if not rec.medic then return end
    local inv = body:getInventory()
    local have = false
    pcall(function()
        local worn = body:getWornItems()
        for i = 0, worn:size() - 1 do
            local it = worn:getItemByIndex(i)
            if it and it:getFullType() == "Base.Bag_Satchel_Leather" then have = true end
        end
    end)
    if not have then
        local bag = inv:AddItem("Base.Bag_Satchel_Leather")
        local worn = false
        if bag then
            for _, loc in ipairs({ function() return bag:canBeEquipped() end, function() return "base:satchel" end,
                                   function() return "Satchel" end }) do
                local ok = pcall(function()
                    local l = loc()
                    if not l or l == "" then error("no location") end
                    body:setWornItem(l, bag)
                end)
                if ok then worn = true; break end
            end
        end
        pcall(function() body:onWornItemsChanged(); body:resetModelNextFrame() end)
        if not worn then LF.log("MEDIC #" .. rec.id .. " couldn't put the satchel on") end
    end
    if LF.Combat then LF.guard("medic arm", LF.Combat.arm, body) end
end

-- Make one private of the squad's rearmost team its medic.
function LF.Medic.pick(squad)
    if not squad or squad.kind ~= "squad" or squad.teamOnly then return nil end
    squad.medicSet = true
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r and r.medic and r.alive then return r end
    end
    local team = LF.Units.get(squad.teams[4]) or LF.Units.get(squad.teams[#squad.teams])
    if not team then return nil end
    local pick = nil
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.alive and r.rank == "PVT" then pick = r end
    end
    if not pick then return nil end
    pick.medic, pick.kit, pick.medicSaves = true, CFG2.kit, pick.medicSaves or 0
    pick.weapon = SMG[pick.faction] or pick.weapon
    local b = LF.Bodies.get(pick.id)
    if b then LF.guard("medic equip", LF.Medic.equip, b, pick) end
    LF.log("MEDIC " .. LF.Units.title(pick) .. " (#" .. pick.id .. ") of " .. team.name .. " is " .. squad.name .. "'s medic")
    return pick
end

-- The squad's medic, if he's alive, on his feet and has dressings.
local function medicOf(squadId)
    for _, rid in ipairs(LF.Units.members(squadId)) do
        local r = LF.Records.get(rid)
        if r and r.medic then
            if r.alive and not crit[rid] and not stable[rid] and (r.kit or 0) > 0 then return r end
            return nil
        end
    end
    return nil
end
LF.Medic.medicOf = medicOf

local function kill(body)
    pcall(function() body:setHealth(0) end)
    pcall(function() body:Kill(nil) end)
end

-- His health now. (The game only re-tallies a man's overall health from his body parts in its
-- own update, so straight after a hit the number is stale - 0.39 checked that and never saw a
-- killing blow. Re-tally first.)
local function hp(body)
    pcall(function() body:getBodyDamage():calculateOverallHealth() end)
    return LF.Combat.health(body)
end
LF.Medic.hp = hp

-- Bring his health up to at least `to` (healing his body parts, the way the game does).
local function healTo(body, to)
    for _ = 1, 12 do
        if hp(body) >= to then return end
        pcall(function() body:getBodyDamage():AddGeneralHealth(10) end)
    end
end
local function addHealth(body, n) healTo(body, hp(body) + n) end

-- ---- going critical -----------------------------------------------------------------------------

-- After any wound (LF_Combat, LF_Grenade): a killing blow may leave him critical instead.
-- cause: "shot" (part = where), "blast", "blastLethal", "melee".
function LF.Medic.onHit(body, cause, part, force)
    if body:isDead() then return end
    local id = body:getModData().LF_id
    local rec = id and LF.Records.get(id)
    if not (rec and rec.alive and rec.squad and rec.faction ~= "CIV") then return end
    if hp(body) > CFG2.dyingAt then return end
    if crit[id] then
        if hp(body) <= 0 then crit[id] = nil; busy[id] = nil end    -- hit again while down: he's gone
        return
    end
    if stable[id] or rec.critOnce then return end
    if cause == "blastLethal" or (cause == "shot" and part == "Head") then return end
    local medic = medicOf(rec.squad)
    if not medic or medic.id == id or (medic.kit or 0) < CFG2.stabiliseCost then return end
    local lvl = levelOf(medic)
    if not force and ZombRand(100) >= CFG2.chance[lvl] then return end
    rec.critOnce = true
    healTo(body, CFG2.floor + 5)
    if LF.Tactics and LF.Tactics.dropCasualty then LF.Tactics.dropCasualty(id) end
    LF.Medic.holdDown(id, body)
    local secs = CFG2.bleedOut[1] + ZombRand(CFG2.bleedOut[2])
    if lvl == "veteran" then secs = math.floor(secs * CFG2.vetWindow) end
    crit[id] = { squad = rec.squad, untilTick = LF.tick + secs, since = LF.tick }
    if LF.Units.relieve then LF.Units.relieve(rec) end
    if LF.Tactics then LF.Tactics.shout(id, "Medic! MEDIC!") end
    LF.log(string.format("CRITICAL #%d %s is down, bleeding out in %d s (medic %s, %s)", id, LF.Units.title(rec),
        math.floor(secs / 60), LF.Units.title(medic), lvl))
end

-- ---- treating -----------------------------------------------------------------------------------

LF_TreatAction = ISBaseTimedAction:derive("LF_TreatAction")
function LF_TreatAction:isValid() return not self.character:isDead() and not self.patient:isDead() end
function LF_TreatAction:waitToStart() return false end
function LF_TreatAction:start()
    self.character:faceThisObject(self.patient)
    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "Low")
end
function LF_TreatAction:update()
    self.character:faceThisObject(self.patient)
end
function LF_TreatAction:stop()
    if self.onStop then LF.guard("treat stopped", self.onStop) end
    ISBaseTimedAction.stop(self)
end
function LF_TreatAction:perform()
    if self.onDone then LF.guard("treat done", self.onDone) end
    ISBaseTimedAction.perform(self)
end
function LF_TreatAction:new(medic, patient, ticks, onDone, onStop)
    local o = ISBaseTimedAction.new(self, medic)
    o.patient, o.onDone, o.onStop = patient, onDone, onStop
    o.maxTime = ticks
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

local function dressAll(body)
    local parts = body:getBodyDamage():getBodyParts()
    local n = 0
    for i = 0, parts:size() - 1 do
        local p = parts:get(i)
        if p:bleeding() or p:haveBullet() then
            pcall(function() p:setBleeding(false); p:setBleedingTime(0) end)
            pcall(function() p:setHaveBullet(false, 0) end)
            pcall(function() p:setBandaged(true, 10) end)
            n = n + 1
        end
    end
    return n
end

local function endJob(mid, why)
    local J = jobs2[mid]
    jobs2[mid] = nil
    busy[mid] = nil
    cooldown[mid] = LF.tick + (why and 180 or 60)
    local mb = LF.Bodies.get(mid)
    if mb and not mb:isDead() then
        if LF.Posture and LF.Posture.crouched(mb) then LF.Posture.set(mb, false) end
        if J and J.slung and LF.Combat then LF.Combat.unsling(mb) end
    end
    if why then LF.log("MEDIC #" .. mid .. " breaks off (" .. why .. ")") end
end

local function finishTreat(mid, J)
    local mrec, prec = LF.Records.get(mid), LF.Records.get(J.pid)
    local pb = LF.Bodies.get(J.pid)
    if not (mrec and prec and pb) or pb:isDead() then endJob(mid, "the man died"); return end
    local n = dressAll(pb)
    if J.kind == "stabilise" then
        mrec.kit = math.max(0, (mrec.kit or 0) - CFG2.stabiliseCost)
        crit[J.pid] = nil
        stable[J.pid] = { squad = prec.squad, quietSince = nil }      -- (stepStable: up, limp to cover)
        busy[J.pid] = "lying"
        healTo(pb, CFG2.stableFloor + 5)
        mrec.medicSaves = (mrec.medicSaves or 0) + 1
        LF.log(string.format("MEDIC #%d %s stabilises #%d %s (%d wounds dressed; %d saved; kit %d)", mid,
            LF.Units.title(mrec), J.pid, LF.Units.title(prec), n, mrec.medicSaves, mrec.kit))
        if LF.Tactics then LF.Tactics.shout(mid, "He'll live - keep your head down!") end
    else
        mrec.kit = math.max(0, (mrec.kit or 0) - CFG2.bandageCost)
        LF.log(string.format("MEDIC #%d %s dresses #%d %s's wounds (%d; kit %d)", mid, LF.Units.title(mrec), J.pid,
            LF.Units.title(prec), n, mrec.kit))
    end
    if (mrec.kit or 0) <= 0 and LF.Tactics then LF.Tactics.shout(mid, "I'm out of dressings!") end
    endJob(mid)
end

-- The worst case in his squad he can go to: (patient id, body, kind) or nil.
local function worstCase(mrec, mb)
    local best, bestScore, bestKind = nil, math.huge, nil
    for _, rid in ipairs(LF.Units.members(mrec.squad)) do
        local r, b = LF.Records.get(rid), LF.Bodies.get(rid)
        if rid ~= mrec.id and r and r.alive and b and not b:isDead() and math.abs(b:getZ() - mb:getZ()) < 0.5 then
            local d = LF.dist(mb:getX(), mb:getY(), b:getX(), b:getY())
            local taken = false
            for oid, oj in pairs(jobs2) do if oid ~= mrec.id and oj.pid == rid then taken = true end end
            if d <= CFG2.range and not taken then
                if crit[rid] then
                    local score = crit[rid].untilTick - LF.tick + d * 30
                    if score < bestScore then best, bestScore, bestKind = rid, score, "stabilise" end
                elseif not stable[rid] and (mrec.kit or 0) >= CFG2.bandageCost and LF.Combat.health(b) < CFG2.severeHealth
                    and LF.Aid.bleedingPart(b) and not busy[rid] then
                    local score = 100000 + LF.Combat.health(b) * 100 + d * 30
                    if score < bestScore then best, bestScore, bestKind = rid, score, "bandage" end
                end
            end
        end
    end
    return best, best and LF.Bodies.get(best), bestKind
end

local function enemyClose(mid, mb, mrec)
    local seen = LF.Sense.look(mid, mb, mrec, CFG2.threatRange)
    return #seen > 0
end

local function startJob(mid, mb, mrec, pid, pb, kind)
    local lvl = levelOf(mrec)
    local J = { pid = pid, kind = kind, phase = "go", at = LF.tick, nextPath = 0,
                waitUntil = lvl == "shaken" and LF.tick + CFG2.shakenDelay or nil }
    jobs2[mid] = J
    busy[mid] = "treating"
    ISTimedActionQueue.clear(mb)
    if LF.Idle then LF.Idle.stop(mb) end
    local prec = LF.Records.get(pid)
    LF.log(string.format("MEDIC #%d %s goes to %s #%d %s, %d tiles", mid, LF.Units.title(mrec),
        kind == "stabilise" and "save" or "dress", pid, prec and LF.Units.title(prec) or "?",
        math.floor(LF.dist(mb:getX(), mb:getY(), pb:getX(), pb:getY()))))
    -- The enemy near the man: the squad gives him cover.
    local near = false
    for _, c in ipairs(LF.Squad.contactPoints(mrec.squad, 600, 24)) do
        if LF.dist(c.x, c.y, pb:getX(), pb:getY()) <= 25 then near = true; break end
    end
    if near and LF.Tactics then
        local squad = LF.Units.get(mrec.squad)
        local caller = squad and LF.Units.commander(squad)
        if caller and caller ~= mid and caller ~= pid and LF.Bodies.get(caller) then LF.Tactics.shout(caller, "Cover the medic!") end
        if kind == "stabilise" then LF.Tactics.shout(mid, "I'm coming - hold on!") end
    end
end

local function stepJob(mid, J)
    local mb, pb = LF.Bodies.get(mid), LF.Bodies.get(J.pid)
    local mrec = LF.Records.get(mid)
    if not (mb and mrec and mrec.alive) or mb:isDead() then jobs2[mid] = nil; busy[mid] = nil; return end
    if not pb or pb:isDead() then endJob(mid, "the man is dead"); return end
    if J.kind == "stabilise" and not crit[J.pid] then endJob(mid); return end
    -- (Only really down: a bump running past his own men isn't - 0.40 broke off for those,
    -- walked back to his place and came out again.)
    local down = false
    pcall(function() down = mb:isOnFloor() or mb:isKnockedDown() end)
    if down then endJob(mid, "knocked down"); return end
    if enemyClose(mid, mb, mrec) then
        local q = ISTimedActionQueue.getTimedActionQueue(mb)
        local a = q and q.queue and q.queue[1]
        if a and a.Type == "LF_TreatAction" then ISTimedActionQueue.clear(mb) end
        endJob(mid, "enemy in sight close by")
        return
    end
    if J.waitUntil and LF.tick < J.waitUntil then return end
    if J.phase == "go" then
        local d = LF.dist(mb:getX(), mb:getY(), pb:getX(), pb:getY())
        if d <= 1.4 then
            ISTimedActionQueue.clear(mb)
            if LF.Posture then LF.Posture.set(mb, true) end
            if LF.Combat then J.slung = LF.Combat.sling(mb) end
            local ticks = J.kind == "stabilise" and CFG2.stabiliseTicks or CFG2.bandageTicks
            if levelOf(mrec) == "veteran" then ticks = math.floor(ticks * CFG2.vetSpeed) end
            J.phase, J.at = "treat", LF.tick
            ISTimedActionQueue.add(LF_TreatAction:new(mb, pb, ticks,
                function() finishTreat(mid, J) end,
                function() if jobs2[mid] == J and J.phase == "treat" then endJob(mid, "interrupted") end end))
            LF.log("MEDIC #" .. mid .. " works on #" .. J.pid)
            if LF.Tactics then LF.Tactics.shout(mid, J.kind == "stabilise" and "Stay with me!" or "Hold still, I've got you.") end
        elseif LF.tick >= J.nextPath or not moving(mb) then
            J.nextPath = LF.tick + 60
            if LF.Suppress and LF.Suppress.isPinned(mb) then
                -- Pinned on the way: he gets down and fights like anyone (not frozen in the open
                -- with his job still on); he tries again in a few seconds.
                ISTimedActionQueue.clear(mb)
                endJob(mid, "pinned down on the way")
                return
            end
            -- Beside him, on the side nearest the medic.
            local dx, dy = mb:getX() - pb:getX(), mb:getY() - pb:getY()
            local l = math.max(0.1, math.sqrt(dx * dx + dy * dy))
            local tx, ty = pb:getX() + dx / l * 0.9, pb:getY() + dy / l * 0.9
            walk(mb, tx, ty, math.floor(pb:getZ()), d > 4 and "run" or "walk")
        elseif LF.tick - J.at > 2400 then
            endJob(mid, "couldn't get to him")
        end
    end
end

local function stepCrit(id, c)
    local b = LF.Bodies.get(id)
    local rec = LF.Records.get(id)
    if not b or b:isDead() or not (rec and rec.alive) then crit[id] = nil; busy[id] = nil; return end
    -- Being worked on: the clock stops.
    local treating = false
    for _, J in pairs(jobs2) do if J.pid == id and J.phase == "treat" then treating = true end end
    if treating then c.untilTick = c.untilTick + 1 end
    if hp(b) < CFG2.floor then healTo(b, CFG2.floor) end
    if LF.tick >= c.untilTick then
        crit[id] = nil
        busy[id] = nil
        LF.log("CRITICAL #" .. id .. " " .. LF.Units.title(rec) .. " bled out - nobody reached him")
        kill(b)
    end
end

-- Stabilised: he gets up and limps off to cover - a hiding spot out of the enemy's sight, toward
-- his squad's rear - and stays down there until the fight is over; then he's himself again
-- (wounded: out of the fight).
local function limpAway(id, b, rec, s)
    s.phase = "limp"
    s.at = LF.tick
    -- A limp: his legs hurt (the game limps a man with painful legs).
    pcall(function()
        local bd = b:getBodyDamage()
        bd:getBodyPart(BodyPartType.UpperLeg_L):setAdditionalPain(60)
        bd:getBodyPart(BodyPartType.LowerLeg_L):setAdditionalPain(60)
    end)
    local tx, ty = nil, nil
    local c = LF.Squad.bestContact(s.squad, b:getX(), b:getY(), 3600, 60)
    local rx, ry = LF.Squad.rear(rec, 10)
    if c and LF.Cover.findHidingSpot then
        local threat = LF.Tactics.point(c.x, c.y, c.z or b:getZ())
        tx, ty = LF.Cover.findHidingSpot(id, b, threat, rx, ry, nil)
        if tx then tx, ty = tx + 0.5, ty + 0.5 end
    end
    if not tx then tx, ty = rx, ry end
    if tx then
        s.spot = { x = tx, y = ty }
        walk(b, tx, ty, math.floor(b:getZ()), "limp")
        LF.log(string.format("MEDIC #%d %s limps off to cover at %d,%d", id, LF.Units.title(rec), math.floor(tx), math.floor(ty)))
    else
        s.phase = "rest"
    end
end

local function stepStable(id, s)
    local b = LF.Bodies.get(id)
    local rec = LF.Records.get(id)
    if not b or b:isDead() or not (rec and rec.alive) then stable[id] = nil; busy[id] = nil; return end
    if hp(b) < CFG2.stableFloor then healTo(b, CFG2.stableFloor) end
    if s.phase == nil then
        -- Up off his back first.
        s.phase = "rising"
        LF.Medic.getUp(id, b, function()
            busy[id] = "resting"
            LF.guard("limp to cover", limpAway, id, b, rec, s)
        end)
        return
    end
    if s.phase == "rising" then return end
    if s.phase == "limp" then
        local there = s.spot and LF.dist(b:getX(), b:getY(), s.spot.x, s.spot.y) <= 1.5
        if there or (not moving(b) and LF.tick - s.at > 120) or LF.tick - s.at > 3600 then
            ISTimedActionQueue.clear(b)
            s.phase = "rest"
        elseif not moving(b) and s.spot then
            walk(b, s.spot.x, s.spot.y, math.floor(b:getZ()), "limp")
        end
        return
    end
    -- Resting in cover until the fight is over: sitting, tending his wounds.
    s.mind = s.mind or {}
    if LF.Idle and LF.Idle.nurse then LF.guard("nurse", LF.Idle.nurse, b, s.mind) end
    local quiet = #LF.Squad.contactPoints(s.squad, CFG2.quietRelease, 24) == 0
    if not quiet then s.quietSince = nil
    else
        s.quietSince = s.quietSince or LF.tick
        if LF.tick - s.quietSince > 120 then
            stable[id] = nil
            busy[id] = nil
            rec.wounded = true
            LF.log("MEDIC #" .. id .. " " .. LF.Units.title(rec) .. " - the fight's over; he comes out, wounded")
        end
    end
end

-- Dying where he stands (bleeding out, not from one hit): he may go critical too.
local function monitor()
    for id, b in pairs(LF.Bodies.all()) do
        if not crit[id] and not stable[id] and not b:isDead() then
            local r = LF.Records.get(id)
            if r and r.alive and not r.critOnce and r.squad and r.faction ~= "CIV" and LF.Combat.health(b) <= CFG2.dyingAt + 5 then
                LF.Medic.onHit(b, "bleeding")
            end
        end
    end
end

Events.OnTick.Add(function()
    for id, c in pairs(crit) do LF.guard("critical", stepCrit, id, c) end
    if LF.tick % 10 == 5 then LF.guard("dying check", monitor) end
    if LF.tick % 30 == 0 then
        for id, s in pairs(stable) do LF.guard("stabilised", stepStable, id, s) end
        for mid, J in pairs(jobs2) do LF.guard("medic job", stepJob, mid, J) end
    end
    if LF.tick % 30 ~= 15 then return end
    -- Medics without a job look for one.
    for _, squad in pairs(LF.Units.all()) do
        if squad.kind == "squad" and not squad.teamOnly then
            if not squad.medicSet then LF.guard("pick medic", LF.Medic.pick, squad) end
            local mrec = medicOf(squad.id)
            local mb = mrec and LF.Bodies.get(mrec.id)
            if mb and not mb:isDead() and not jobs2[mrec.id] and not busy[mrec.id] and LF.tick >= (cooldown[mrec.id] or 0)
                and LF.Combat.health(mb) >= 35 and not LF.Combat.knockedDown(mb) and not enemyClose(mrec.id, mb, mrec) then
                local pid, pb, kind = worstCase(mrec, mb)
                if pid then LF.guard("medic start", startJob, mrec.id, mb, mrec, pid, pb, kind) end
            end
        end
    end
end)

-- Test: the soldier nearest (x, y) whose squad has a medic takes a killing wound and goes critical.
function LF.Medic.testCritical(x, y)
    local best, bd = nil, math.huge
    for id, b in pairs(LF.Bodies.all()) do
        local r = LF.Records.get(id)
        if r and r.alive and not r.medic and r.squad and not crit[id] and not stable[id] and medicOf(r.squad) then
            local d = LF.dist(b:getX(), b:getY(), x, y)
            if d < bd then best, bd = b, d end
        end
    end
    if not best then LF.say("No soldier with a squad medic nearby"); return end
    local id = best:getModData().LF_id
    local r = LF.Records.get(id)
    r.critOnce = nil
    pcall(function() best:getBodyDamage():getBodyPart(BodyPartType.Torso_Upper):damageFromFirearm(60) end)
    pcall(function() best:getBodyDamage():ReduceGeneralHealth(LF.Combat.health(best)) end)
    LF.Medic.onHit(best, "shot", "Torso_Upper", true)
    LF.say(crit[id] and ("#" .. id .. " is down critical - his medic should come") or "Couldn't make him critical (see log)")
end
