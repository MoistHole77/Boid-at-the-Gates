-- Living Front: tactics - clearing a building. Stacking on a door (and a second team on a back
-- door), the breach, room by room; holding what's been cleared; a man knocked over inside
-- dragged out and the team going again.

require "LivingFront/Tactics/LF_Tactics"
require "LivingFront/Tactics/LF_Manoeuvre"
require "LivingFront/Tactics/LF_Defence"
require "LivingFront/Specialists/LF_Downed"

local I = LF.Tactics.I
local CFG, fit, initTeams, squads, teams = I.CFG, I.fit, I.initTeams, I.squads, I.teams

local casualties = {}       -- man id -> { team, squad, phase, at } (a man knocked down while clearing)
local casualtyCount = 0     -- (Kahlua has no next())

-- ---- clearing a building (offensive) -------------------------------------------------------
--
-- When the sergeant judges a building's defence is down to a few men (the enemy his squad knows
-- about there, CFG.clearAt or fewer), he sends Alpha to clear it while the rest cover. The
-- team, slowly and in order:
--   stack  - single file against the wall beside the nearest door (outside), point man nearest
--            the door, kneeling, facing it
--   breach - a moment's pause, then the door is opened (kicked in if it's locked)
--   go     - one man at a time, the point man first: each walks in with his rifle up to his own
--            spot in the room, spread out; the next man goes once the one ahead is through the
--            doorway. Anyone who sees an enemy close by stops and shoots.
--   in     - when all are on their spots: "Room clear!" - the team holds there.

local function clearKey(x, y) return x .. "," .. y end

-- ---- room by room ----------------------------------------------------------------------------
--
-- Once a team is inside, it clears on from room to room instead of going back out to another
-- door: the next room is the one the enemy was last seen in (or, with nobody seen, the nearest
-- room it hasn't cleared yet). The men go through one at a time, as at the door; the others hold
-- where they are until it's their turn.

local function roomKeyAt(L, x, y)
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), L.z)
    local r = sq and sq:getRoom()
    return r and tostring(r) or nil
end

local function planRoom(squad, team, L, file, started, rooms, anchor)
    local live = {}
    local cx, cy = 0, 0
    for _, rid in ipairs(file) do
        local r, b = LF.Records.get(rid), LF.Bodies.get(rid)
        if r and fit(r) and b then
            live[#live + 1] = rid
            cx, cy = cx + b:getX(), cy + b:getY()
        end
    end
    if #live == 0 then return nil, "nobody left to go on" end
    cx, cy = cx / #live, cy / #live
    -- From the man who cleared the last room (the others are still on their way through).
    if anchor then cx, cy = anchor.x, anchor.y end
    rooms = rooms or {}
    local here = roomKeyAt(L, cx, cy)
    if here then rooms[here] = true end
    -- Squares of each room not yet cleared.
    local byRoom = {}
    for _, q in ipairs(L.inside) do
        local k = roomKeyAt(L, q.x, q.y)
        if k and not rooms[k] then
            byRoom[k] = byRoom[k] or {}
            byRoom[k][#byRoom[k] + 1] = q
        end
    end
    -- The room the enemy was last seen in, nearest first; else the nearest room left.
    local target, bestD = nil, math.huge
    for _, c in ipairs(LF.Squad.contactPoints(squad.id, CFG.contactMemory, 24)) do
        if math.floor(c.z or 0) == L.z and LF.Building.isInside(L, c.x, c.y) then
            local k = roomKeyAt(L, c.x, c.y)
            local d = LF.dist(cx, cy, c.x, c.y)
            if k and byRoom[k] and d < bestD then target, bestD = k, d end
        end
    end
    if not target then
        for k, sqs in pairs(byRoom) do
            for _, q in ipairs(sqs) do
                local d = LF.dist(cx, cy, q.x + 0.5, q.y + 0.5)
                if d < bestD then target, bestD = k, d end
            end
        end
    end
    if not target then return nil, "every room cleared" end
    local sqs = byRoom[target]
    -- Where they go into it: its square nearest the team.
    local entry, ed = sqs[1], math.huge
    for _, q in ipairs(sqs) do
        local d = LF.dist(cx, cy, q.x + 0.5, q.y + 0.5)
        if d < ed then entry, ed = q, d end
    end
    -- Each man's spot in the room, spread out, away from the way in.
    local targets, used = {}, {}
    for _, rid in ipairs(live) do
        local best, bestS = nil, -math.huge
        for _, q in ipairs(sqs) do
            local dd = LF.dist(q.x, q.y, entry.x, entry.y)
            local key = q.x .. "," .. q.y
            if not used[key] then
                local sc = math.min(dd, 4)
                for _, u in pairs(targets) do sc = math.min(sc, LF.dist(q.x, q.y, u.x, u.y)) end
                if sc > bestS then best, bestS = q, sc end
            end
        end
        best = best or entry
        targets[rid] = { x = best.x, y = best.y }
        used[best.x .. "," .. best.y] = true
    end
    return { L = L, door = { x = entry.x, y = entry.y, dx = 0, dy = 0 }, stack = {}, file = live, targets = targets,
             phase = "go", started = started or LF.tick, phaseAt = LF.tick, next = 1, manAt = LF.tick,
             face = LF.Tactics.point(entry.x + 0.5, entry.y + 0.5, L.z), faces = {}, room = target, rooms = rooms,
             hold = {} }
end

-- Plan the clearing of building L by a team. Returns the plan or nil.
local function planClear(squad, team, t, L, forceDoor, restack)
    local cx, cy = (t.pos.A.x + t.pos.B.x) / 2, (t.pos.A.y + t.pos.B.y) / 2
    local cell = getCell()
    local z = L.z
    -- The door: near the team, a clear doorstep, and away from the windows the enemy is known to
    -- be at (a stack under a manned window is shot down before the door is open).
    local known = {}
    for _, c in ipairs(LF.Squad.contactPoints(squad.id, CFG.contactMemory, 24)) do
        if math.floor(c.z or 0) == z then known[#known + 1] = c end
    end
    local function exposure(x, y)
        local n = 0
        for _, c in ipairs(known) do
            if LF.dist(x + 0.5, y + 0.5, c.x, c.y) <= 4 then n = n + 1 end
        end
        return n
    end
    local door, doorD = nil, math.huge
    local doors = 0
    for _, o in ipairs(L.openings) do
        if o.kind == "door" and (not forceDoor or o == forceDoor) then
            doors = doors + 1
            local out = cell:getGridSquare(o.x + o.dx, o.y + o.dy, z)
            if out then
                local d = LF.dist(cx, cy, o.x + o.dx + 0.5, o.y + o.dy + 0.5)
                if not out:isFree(false) then d = d + 20 end
                d = d + 8 * exposure(o.x + o.dx, o.y + o.dy)
                if d < doorD then door, doorD = o, d end
            end
        end
    end
    if not door then return nil, doors == 0 and "the building has no door to the outside" or "no door has a doorstep" end
    local file = {}
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        -- (Not the squad medic, who goes with Bravo: he waits outside for the wounded.)
        if r and r.team == team.id and not r.medic and fit(r) and LF.Bodies.get(rid) then file[#file + 1] = rid end
    end
    if #file < 2 then return nil, "only " .. #file .. " fit man in the team" end
    -- Already inside: clear on from room to room rather than going back out to a door.
    local inside = 0
    for _, rid in ipairs(file) do
        local b = LF.Bodies.get(rid)
        if b and math.floor(b:getZ()) == z and LF.Building.isInside(L, b:getX(), b:getY()) then inside = inside + 1 end
    end
    if inside * 2 >= #file and not restack then
        if forceDoor then return nil, "already inside" end
        return planRoom(squad, team, L, file, LF.tick, {})
    end
    local ox, oy = door.x + door.dx, door.y + door.dy
    -- Stack against the wall beside the door, on the side nearer the team.
    local lx, ly = -door.dy, door.dx
    local near = ((cx - ox) * lx + (cy - oy) * ly) >= 0 and 1 or -1
    -- The stack is a chain of squares from the doorstep, each one a free outdoor square a man
    -- can step to from the one before (no wall, fence, railing or window between): along the
    -- wall if there is room, bending back from it (or straight back) where there isn't.
    local doorstep = cell:getGridSquare(ox, oy, z)
    local function chain(side)
        local spots, used = {}, { [clearKey(ox, oy)] = true }
        local prev, px, py = doorstep, ox, oy
        local steps = { { lx * side, ly * side }, { lx * side + door.dx, ly * side + door.dy }, { door.dx, door.dy } }
        for k = 1, #file do
            local got = false
            for _, st in ipairs(steps) do
                local x, y = px + st[1], py + st[2]
                local q = cell:getGridSquare(x, y, z)
                if q and prev and q:isFree(false) and not used[clearKey(x, y)] and not LF.Building.isInside(L, x, y)
                    and LF.Cover.crossings(px, py, x, y, z, 1) == 0 then
                    spots[k] = { x = x, y = y }
                    used[clearKey(x, y)] = true
                    prev, px, py, got = q, x, y, true
                    break
                end
            end
            if not got then break end
        end
        return spots
    end
    -- Which side of the door: the one with room for the whole file, and the fewer men stood in
    -- front of a window or near a known enemy.
    local winOut = {}
    for _, o in ipairs(L.openings) do
        if o.kind == "window" then winOut[clearKey(o.x + o.dx, o.y + o.dy)] = true end
    end
    local function risk(spots)
        local n = 0
        for _, sp in ipairs(spots) do
            if winOut[clearKey(sp.x, sp.y)] then n = n + 1 end
            n = n + exposure(sp.x, sp.y)
        end
        return n
    end
    local stack = nil
    if doorstep then
        local a, b = chain(near), chain(-near)
        local fa, fb = math.min(#a, #file), math.min(#b, #file)
        if fa ~= fb then stack = fb > fa and b or a
        else stack = risk(b) < risk(a) and b or a end
    end
    if not stack or #stack < #file then
        if not stack or #stack < 2 then return nil, "no room to stack up outside the door" end
        -- Room for only some of them: the rest of the file stays out and covers.
        for i = #file, #stack + 1, -1 do table.remove(file, i) end
    end
    -- Each man's own spot inside: spread out in the room behind the door.
    local doorSq = cell:getGridSquare(door.x, door.y, z)
    local room = doorSq and doorSq:getRoom()
    local targets, used = {}, {}
    for i, rid in ipairs(file) do
        local best, bestS = nil, -math.huge
        for _, q in ipairs(L.inside) do
            local dd = LF.dist(q.x, q.y, door.x, door.y)
            local qs = L.insideSet[clearKey(q.x, q.y)]
            if dd >= 2 and dd <= 7 and not used[clearKey(q.x, q.y)] then
                local s = math.min(dd, 4)
                for _, u in pairs(targets) do s = math.min(s, LF.dist(q.x, q.y, u.x, u.y)) end
                if room and qs and qs:getRoom() ~= room then s = s - 5 end
                if s > bestS then best, bestS = q, s end
            end
        end
        best = best or { x = door.x, y = door.y }
        targets[rid] = { x = best.x, y = best.y }
        used[clearKey(best.x, best.y)] = true
    end
    return { L = L, door = door, stack = stack, file = file, targets = targets, phase = "stack",
             started = LF.tick, phaseAt = LF.tick, next = 1, manAt = LF.tick, face = LF.Tactics.point(ox, oy, z),
             faces = {} }
end

-- Where a man of a clearing team goes: "file", x, y, z, facePoint, gait - or nil if he isn't in
-- the file (he then does what he would otherwise).
-- Empty, or reloading right now.
local function emptyGun(b)
    if LF.Weapons.rounds(b) <= 0 then return true end
    local q = ISTimedActionQueue.getTimedActionQueue(b)
    local a = q and q.queue and q.queue[1]
    return a ~= nil and a.Type == "LF_ReloadAction"
end

-- A room's been called clear: anyone at half a magazine or less tops up before the next.
local function topUpFile(file)
    for _, rid in ipairs(file) do
        local b = LF.Bodies.get(rid)
        if b and not b:isPerformingAnAction() and LF.Weapons.rounds(b) <= LF.Weapons.profileOf(b).clip * 0.5 then
            LF.Weapons.reload(b, LF.Combat.arm(b), "between rooms")
        end
    end
end

-- Getting to his stack spot from outside: round the building, never through it. The way straight
-- there crossing the building, he goes by a corner of it first (3 tiles out). (Up to 0.46 a team
-- sent round to the back door walked in at the front, through the house, before anyone had called
-- the go - and was shot inside.)
local function bboxOf(L)
    if L.bbox then return L.bbox end
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, q in ipairs(L.inside) do
        x0, y0 = math.min(x0, q.x), math.min(y0, q.y)
        x1, y1 = math.max(x1, q.x + 1), math.max(y1, q.y + 1)
    end
    L.bbox = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    return L.bbox
end
local function crosses(B, ax, ay, bx, by, pad)
    local d = LF.dist(ax, ay, bx, by)
    local n = math.max(1, math.ceil(d / 0.5))
    for i = 1, n - 1 do
        local x, y = ax + (bx - ax) * i / n, ay + (by - ay) * i / n
        if x > B.x0 - pad and x < B.x1 + pad and y > B.y0 - pad and y < B.y1 + pad then return true end
    end
    return false
end
local function viaCorner(C, rid, body, tx, ty)
    C.via = C.via or {}
    local v = C.via[rid]
    local bx, by = body:getX(), body:getY()
    if v then
        if LF.dist(bx, by, v.x, v.y) > 2.5 then return v end
        C.via[rid] = nil
    end
    local L = C.L
    if LF.Building.isInside(L, bx, by) then return nil end
    local B = bboxOf(L)
    if not crosses(B, bx, by, tx, ty, 0.3) then return nil end
    local best, bd = nil, math.huge
    for _, c in ipairs({ { B.x0 - 3, B.y0 - 3 }, { B.x1 + 3, B.y0 - 3 }, { B.x0 - 3, B.y1 + 3 }, { B.x1 + 3, B.y1 + 3 } }) do
        if not crosses(B, bx, by, c[1], c[2], 0.3) then
            local d = LF.dist(bx, by, c[1], c[2]) + LF.dist(c[1], c[2], tx, ty) * (crosses(B, c[1], c[2], tx, ty, 0.3) and 3 or 1)
            if d < bd then best, bd = { x = c[1], y = c[2] }, d end
        end
    end
    C.via[rid] = best
    return best
end

function LF.Tactics.clearPlace(C, rec)
    if C.halted then
        -- A man down: everyone holds where he is until he has been dragged clear.
        local b = LF.Bodies.get(rec.id)
        if not b then return nil end
        C.haltAt = C.haltAt or {}
        local h = C.haltAt[rec.id]
        if not h then h = { x = b:getX(), y = b:getY() }; C.haltAt[rec.id] = h end
        return "file", h.x, h.y, C.L.z, C.face, "walk"
    end
    local idx = nil
    for i, rid in ipairs(C.file) do if rid == rec.id then idx = i; break end end
    if not idx then return nil end
    local z = C.L.z
    if C.waitReload == rec.id then
        -- Reloading before his turn: he stays where he is.
        local body = LF.Bodies.get(rec.id)
        C.hold = C.hold or {}
        local h = C.hold[rec.id]
        if not h and body then h = { x = body:getX(), y = body:getY() }; C.hold[rec.id] = h end
        if h then return "file", h.x, h.y, z, C.face, "walk" end
    end
    if (C.phase == "go" or C.phase == "in") and idx <= C.next then
        local tg = C.targets[rec.id]
        local f = C.faces[rec.id]
        if not f then
            -- Face on into the room, away from the door.
            local dx, dy = tg.x - C.door.x, tg.y - C.door.y
            local len = math.max(0.5, math.sqrt(dx * dx + dy * dy))
            f = LF.Tactics.point(tg.x + 0.5 + dx / len * 5, tg.y + 0.5 + dy / len * 5, z)
            C.faces[rec.id] = f
        end
        return "file", tg.x + 0.5, tg.y + 0.5, z, f, "aim"
    end
    local sp = C.stack[idx]
    local body = LF.Bodies.get(rec.id)
    if not sp then
        -- Room by room: waiting for his turn, he holds where he is, facing the way in.
        local h = C.hold and C.hold[rec.id]
        if not h and body then
            h = { x = body:getX(), y = body:getY() }
            if C.hold then C.hold[rec.id] = h end
        end
        if not h then return nil end
        return "file", h.x, h.y, z, C.face, "walk"
    end
    local far = body and LF.dist(body:getX(), body:getY(), sp.x + 0.5, sp.y + 0.5) > 3
    local v = body and far and viaCorner(C, rec.id, body, sp.x + 0.5, sp.y + 0.5)
    if v then return "file", v.x, v.y, z, C.face, "run" end
    return "file", sp.x + 0.5, sp.y + 0.5, z, C.face, far and "run" or "walk"
end

local function openDoor(door, body)
    if door.setLockedByKey then door:setLockedByKey(false) end
    if door.setLocked then door:setLocked(false) end
    if door.IsOpen and not door:IsOpen() then door:ToggleDoor(body) end
end

-- Run a clearing (each tactics update). Returns true while it is still going.
local function updateClear(team, t, squad)
    local C = t.clear
    if C.halted then return true end              -- (a man down: see casualties, below)
    local live = {}
    for _, rid in ipairs(C.file) do
        local r = LF.Records.get(rid)
        if r and fit(r) and LF.Bodies.get(rid) then live[#live + 1] = rid end
    end
    local function finish(words, why, done)
        if team.leader and LF.Bodies.get(team.leader) and words then LF.Tactics.shout(team.leader, words) end
        -- Cleared: the objective it was taking can now be called taken (LF_Objective).
        local task = squad.objTask
        if done and task and task.kind == "take" then
            local obj = LF.Objective and LF.Objective.get(task.obj)
            local q = C.L.inside and C.L.inside[1]
            if obj and obj.building and q and LF.Building.idAt(q.x, q.y, C.L.z) == obj.building then task.cleared = true end
        end
        LF.log("CLEAR " .. team.name .. " of " .. squad.name .. ": " .. why)
        -- The team holds where its men are now.
        local sx, sy, n = 0, 0, 0
        for _, rid in ipairs(live) do
            local b = LF.Bodies.get(rid)
            sx, sy, n = sx + b:getX(), sy + b:getY(), n + 1
        end
        if n > 0 then
            t.pos.A.x, t.pos.A.y, t.pos.B.x, t.pos.B.y = sx / n, sy / n, sx / n, sy / n
        end
        t.clear, t.order, t.heard, t.moving, t.shifting = nil, "HOLD", "HOLD", nil, nil
        LF.Tactics.holdInside(team, t, squad, C, live)
        if not t.inside and n > 0 then
            -- Given up outside: back off from the building before taking cover (not crouching
            -- under its windows by the door - or wandering in through it).
            local mx, my = sx / n, sy / n
            local dx, dy = mx - C.L.cx, my - C.L.cy
            local l = math.max(0.5, math.sqrt(dx * dx + dy * dy))
            mx, my = mx + dx / l * 5, my + dy / l * 5
            t.pos.A.x, t.pos.A.y, t.pos.B.x, t.pos.B.y = mx, my, mx, my
        end
    end
    if #live == 0 then
        -- (A man knocked down and about to be dragged out isn't lost yet.)
        for _, rid in ipairs(C.file) do if casualties[rid] then return true end end
        finish(nil, "the whole file is down"); return false
    end
    if LF.tick - C.started > CFG.clearTimeout then finish("Hold here! Hold what we've got!", "took too long"); return false end
    local function at(rid, x, y)
        local b = LF.Bodies.get(rid)
        if not b then return false end
        local d = LF.dist(b:getX(), b:getY(), x + 0.5, y + 0.5)
        -- Close enough after a while: a man who can't get onto his exact square still counts.
        return d <= 1.3 or (C.phase == "stack" and LF.tick - C.phaseAt >= CFG.clearStackClose and d <= 2.5)
    end
    if C.phase == "stack" then
        local all = true
        for i, rid in ipairs(C.file) do
            if LF.Records.get(rid) and fit(LF.Records.get(rid)) and not at(rid, C.stack[i].x, C.stack[i].y) then all = false end
        end
        if not all and LF.tick - C.phaseAt > (C.stackTimeout or CFG.clearStackTimeout) then
            -- Taking too long: go with the men who are on the stack; the rest stay out and cover.
            local file, stack = {}, {}
            for i, rid in ipairs(C.file) do
                local b = LF.Bodies.get(rid)
                local r = LF.Records.get(rid)
                if r and fit(r) and b and LF.dist(b:getX(), b:getY(), C.stack[i].x + 0.5, C.stack[i].y + 0.5) <= 3 then
                    file[#file + 1] = rid
                    stack[#stack + 1] = C.stack[i]
                end
            end
            if #file < 2 then
                finish("Can't get to the door - back to cover!", "couldn't stack up on the door")
                return false
            end
            LF.log("CLEAR " .. team.name .. ": going in with the " .. #file .. " men on the stack")
            C.file, C.stack, all = file, stack, true
        end
        if all then
            C.phase, C.phaseAt = "breach", LF.tick
            LF.log("CLEAR " .. team.name .. ": stacked on the door at " .. C.door.x .. "," .. C.door.y)
            if team.leader and LF.Bodies.get(team.leader) then LF.Tactics.shout(team.leader, "Stacked! Ready...") end
        end
    elseif C.phase == "breach" then
        -- Two doors at once: whichever team is stacked first waits (up to ~15 s) for the other,
        -- then both go in together.
        if C.partner then
            local pt = teams[C.partner]
            local pc = pt and pt.clear
            local close = false
            if pc and pc.phase == "stack" then
                close = true
                for i, rid in ipairs(pc.file) do
                    local b, sp = LF.Bodies.get(rid), pc.stack[i]
                    if b and sp and LF.dist(b:getX(), b:getY(), sp.x + 0.5, sp.y + 0.5) > 4 then close = false; break end
                end
            end
            if close and LF.tick - (C.waitFrom or LF.tick) < CFG.clearPartnerWait then
                C.waitFrom = C.waitFrom or LF.tick
                if not C.saidWait then
                    C.saidWait = true
                    LF.log("CLEAR " .. team.name .. ": stacked - waiting for " .. (LF.Units.get(C.partner) or {}).name .. " at the other door")
                end
                C.phaseAt = LF.tick - 60 + 1     -- (ready to go the moment they are)
                return true
            end
        end
        -- A defender known close to the door: a grenade in on him first (from whichever leader
        -- has a clear throw), then the door.
        if LF.tick - C.phaseAt >= 60 and not C.covered and LF.Grenade then
            C.covered = true
            local wait = LF.guard("grenade covering the door", LF.Grenade.coverDoor, squad, C)
            if wait then
                C.phase, C.phaseAt, C.nadeWait = "cover", LF.tick, wait
                if team.leader and LF.Bodies.get(team.leader) then LF.Tactics.shout(team.leader, "Wait for it...") end
                return true
            end
        end
        if LF.tick - C.phaseAt >= 90 then
            local cell = getCell()
            local inSq = cell:getGridSquare(C.door.x, C.door.y, C.L.z)
            local outSq = cell:getGridSquare(C.door.x + C.door.dx, C.door.y + C.door.dy, C.L.z)
            local door = inSq and outSq and inSq:getDoorTo(outSq)
            local point = LF.Bodies.get(live[1])
            if door then
                local locked = door.isLocked and door:isLocked()
                LF.guard("open door", openDoor, door, point)
                LF.log("CLEAR " .. team.name .. ": " .. (locked and "kicks the locked door in" or "opens the door"))
            end
            -- An enemy known close inside: a grenade through the door first.
            local wait = LF.Grenade and LF.guard("grenade into room", LF.Grenade.intoRoom, squad, team, C)
            if wait then
                C.phase, C.phaseAt, C.nadeWait = "grenade", LF.tick, wait
                return true
            end
            if team.leader and LF.Bodies.get(team.leader) then LF.Tactics.shout(team.leader, "Go! Go!") end
            C.phase, C.next, C.manAt = "go", 1, LF.tick
        end
    elseif C.phase == "cover" then
        if LF.tick - C.phaseAt >= (C.nadeWait or 260) then
            C.phase, C.phaseAt = "breach", LF.tick - 90          -- straight on to the door
        end
    elseif C.phase == "grenade" then
        if LF.tick - C.phaseAt >= (C.nadeWait or 260) then
            if team.leader and LF.Bodies.get(team.leader) then LF.Tactics.shout(team.leader, "Go! Go!") end
            C.phase, C.next, C.manAt = "go", 1, LF.tick
        end
    elseif C.phase == "go" or C.phase == "in" then
        -- One man is enough to call a room clear: the first man in, on his spot, with no enemy
        -- seen in the room. The team moves on to the next room from him while the rest are still
        -- coming through behind (they follow on into the next room).
        local lead = live[1]
        local tg = lead and C.targets[lead]
        local rk = C.room or roomKeyAt(C.L, C.door.x, C.door.y)
        if tg and rk and at(lead, tg.x, tg.y) and LF.tick - C.phaseAt >= 30 then
            local quiet = true
            for _, c in ipairs(LF.Squad.contactPoints(squad.id, 300, 24)) do
                if math.floor(c.z or 0) == C.L.z and roomKeyAt(C.L, c.x, c.y) == rk then quiet = false; break end
            end
            if quiet then
                local lb = LF.Bodies.get(lead)
                local rooms = C.rooms or {}
                rooms[rk] = true
                local count = (C.roomCount or 1)
                local nextC = count < CFG.clearRooms
                    and planRoom(squad, team, C.L, live, LF.tick, rooms, { x = lb:getX(), y = lb:getY() })
                if nextC then
                    nextC.roomCount = count + 1
                    topUpFile(nextC.file)
                    t.clear = nextC
                    LF.log("CLEAR " .. team.name .. " of " .. squad.name .. ": #" .. lead .. " calls the room clear, on to the next room ("
                        .. nextC.roomCount .. ")")
                    LF.Tactics.shout(lead, "Clear! Next room!")
                    return true
                end
                LF.Tactics.shout(lead, "Clear!")
                finish(team.leader ~= lead and "All clear - hold here!" or nil, "every room cleared - holding", true)
                -- Hold where the man who called it is (inside), not halfway back to the door.
                t.pos.A.x, t.pos.A.y, t.pos.B.x, t.pos.B.y = lb:getX(), lb:getY(), lb:getX(), lb:getY()
                return false
            end
        end
    end
    if C.phase == "go" then
        local rid = C.file[C.next]
        local r = rid and LF.Records.get(rid)
        local b = rid and LF.Bodies.get(rid)
        local through
        if C.room then
            through = b and roomKeyAt(C.L, b:getX(), b:getY()) == C.room
        else
            through = b and LF.Building.isInside(C.L, b:getX(), b:getY())
                and LF.dist(b:getX(), b:getY(), C.door.x + 0.5, C.door.y + 0.5) >= 1.5
        end
        -- Nobody goes into a room on an empty magazine: a loaded man behind him takes his turn,
        -- or (none) he holds where he is and reloads first.
        if r and b and fit(r) and not through and emptyGun(b) then
            local swapped = false
            for j = C.next + 1, #C.file do
                local bj = LF.Bodies.get(C.file[j])
                local rj = LF.Records.get(C.file[j])
                if bj and rj and fit(rj) and not emptyGun(bj) then
                    C.file[C.next], C.file[j] = C.file[j], C.file[C.next]
                    LF.log("CLEAR " .. team.name .. ": #" .. rid .. " is empty - #" .. C.file[C.next] .. " goes in first")
                    if not C.saidSwap then
                        C.saidSwap = true
                        LF.Tactics.shout(rid, "I'm empty - you go!")
                    end
                    C.manAt, swapped = LF.tick, true
                    break
                end
            end
            if not swapped then
                if C.waitReload ~= rid then
                    C.waitReload, C.waitSince = rid, LF.tick
                    LF.log("CLEAR " .. team.name .. ": #" .. rid .. " is empty - reloads before he goes in")
                    LF.Tactics.shout(rid, "Reloading!")
                end
                if not b:isPerformingAnAction() then LF.Weapons.reload(b, LF.Combat.arm(b), "before going in") end
                C.manAt = LF.tick
                if LF.tick - C.waitSince < 900 then return true end
            end
        elseif C.waitReload == rid then
            C.waitReload = nil
        end
        if not (r and fit(r) and b) or through or LF.tick - C.manAt > CFG.clearManTimeout then
            C.next, C.manAt = C.next + 1, LF.tick
            if C.next > #C.file then C.phase, C.phaseAt = "in", LF.tick end
        end
    elseif C.phase == "in" then
        local all = true                  -- (the room couldn't be called clear: someone was seen in it)
        for _, rid2 in ipairs(live) do
            local tg = C.targets[rid2]
            if tg and not at(rid2, tg.x, tg.y) then all = false end
        end
        if all or LF.tick - C.phaseAt > 1800 then
            -- On to the next room (the one the enemy was seen in, or the nearest left).
            if C.room or LF.Building.isInside(C.L, C.door.x + 0.5, C.door.y + 0.5) then
                local rooms = C.rooms or {}
                if C.room then rooms[C.room] = true end
                local count = (C.roomCount or 1)
                local nextC = count < CFG.clearRooms and planRoom(squad, team, C.L, live, LF.tick, rooms)
                if nextC then
                    nextC.roomCount = count + 1
                    topUpFile(nextC.file)
                    t.clear = nextC
                    LF.log("CLEAR " .. team.name .. " of " .. squad.name .. ": room clear, on to the next room (" .. nextC.roomCount .. ")")
                    if team.leader and LF.Bodies.get(team.leader) then LF.Tactics.shout(team.leader, "Room clear - next room! Go!") end
                    return true
                end
            end
            finish("Room clear!", "in and holding", true)
            return false
        end
    end
    return true
end



-- ---- holding inside ---------------------------------------------------------------------------
--
-- A clearing that ends with the team inside the building (it ran out of time, or cleared what it
-- could) holds what it has: each man stays on his spot, down and aiming into the rest of the
-- building, until the sergeant sends it on again, the unit stops attacking, or no enemy has been
-- seen in the building for ~45 s. (Up to 0.36 such a team went back under the squad's orders -
-- which sent it round the flank, straight out of the building it was in.)

function LF.Tactics.holdInside(team, t, squad, C, live)
    local spots, inside = {}, 0
    local known = {}
    for _, c in ipairs(LF.Squad.contactPoints(squad.id, CFG.contactMemory, 24)) do
        if math.floor(c.z or 0) == C.L.z and LF.Building.isInside(C.L, c.x, c.y) then known[#known + 1] = c end
    end
    for _, rid in ipairs(live) do
        local b = LF.Bodies.get(rid)
        if b and math.floor(b:getZ()) == C.L.z and LF.Building.isInside(C.L, b:getX(), b:getY()) then
            inside = inside + 1
            local fx, fy = C.L.cx, C.L.cy
            local bd = math.huge
            for _, c in ipairs(known) do
                local d = LF.dist(b:getX(), b:getY(), c.x, c.y)
                if d < bd then bd, fx, fy = d, c.x, c.y end
            end
            spots[rid] = { x = b:getX(), y = b:getY(), face = LF.Tactics.point(fx, fy, C.L.z) }
        end
    end
    if inside == 0 or inside * 2 < #live then return end
    t.inside = { L = C.L, spots = spots, since = LF.tick, lastSeen = LF.tick }
    LF.log("CLEAR " .. team.name .. " of " .. squad.name .. ": holds inside the building (" .. inside .. " men)")
end

function LF.Tactics.updateInside(team, t, squad)
    local I = t.inside
    for _, c in ipairs(LF.Squad.contactPoints(squad.id, CFG.contactMemory, 24)) do
        if math.floor(c.z or 0) == I.L.z and LF.Building.isInside(I.L, c.x, c.y) then I.lastSeen = LF.tick; break end
    end
    local why = nil
    local ssq = squads[squad.id]
    if LF.Stance.get(squad).maneuvers ~= true then why = "the unit isn't attacking any more"
    elseif ssq and ssq.intent == "FALLBACK" then why = "the unit is falling back"
    elseif LF.tick - I.lastSeen > 2700 then why = "no enemy seen in the building for 45 s" end
    if why then
        t.inside = nil
        LF.log("CLEAR " .. team.name .. " of " .. squad.name .. ": stops holding inside (" .. why .. ")")
    end
end

-- Is this man in a team clearing (or holding) a building, and inside it?
function LF.Tactics.clearingInside(rec, body)
    local t = rec and rec.team and teams[rec.team]
    if not t then return false end
    local L = (t.clear and t.clear.L) or (t.inside and t.inside.L)
    return L ~= nil and math.floor(body:getZ()) == L.z and LF.Building.isInside(L, body:getX(), body:getY())
end

-- ---- a man knocked down while clearing ---------------------------------------------------------
--
-- A man of a clearing team who is knocked over backward stays down on his back. The nearest of
-- the others drags him out of the fight - back through the building to a room they've already
-- cleared, or out of the door if they're still on the first room - while the rest of the team
-- holds where it is. Then they regroup there and go on clearing (the downed man stays where he was
-- left until the building is done). Only while a team is clearing a building.


Events.OnInitGlobalModData.Add(function()
    for k in pairs(casualties) do casualties[k] = nil end
    casualtyCount = 0
end)

local function inFile(C, id)
    for _, rid in ipairs(C.file) do if rid == id then return true end end
    return false
end

-- He's gone critical instead (LF_Medic): he isn't a casualty to drag.
function LF.Tactics.dropCasualty(id)
    if casualties[id] then casualties[id] = nil; casualtyCount = casualtyCount - 1 end
end

-- Knocked over backward (LF_Combat): is he one of a clearing team? Then he stays down.
function LF.Tactics.onKnockedBack(body)
    local id = body:getModData().LF_id
    local rec = id and LF.Records.get(id)
    if not (rec and rec.team and rec.squad) or casualties[id] then return end
    local t = teams[rec.team]
    local C = t and t.clear
    if not C or not inFile(C, id) then return end
    -- Only inside the building (in through the door, going room to room) - not on the way to it.
    if math.floor(body:getZ()) ~= C.L.z or not LF.Building.isInside(C.L, body:getX(), body:getY()) then return end
    -- Not a man already badly hurt (or crawling on ruined legs): he's past being dragged back
    -- in to fight - the usual wounded behaviour takes him.
    if LF.Combat.health(body) < CFG.casualtyMinHealth or (LF.Combat.legsOut and LF.Combat.legsOut(body)) then return end
    local squad = LF.Units.get(rec.squad)
    if not squad or LF.Stance.get(squad).maneuvers ~= true then return end
    casualties[id] = { id = id, team = rec.team, squad = rec.squad, phase = "falling", at = LF.tick }
    casualtyCount = casualtyCount + 1
    LF.log("CASUALTY #" .. id .. " " .. LF.Units.title(rec) .. " knocked down on his back while clearing - stays down")
end

-- A route for dragging him (BFS over the floor, through doorways, never through a wall or window):
-- to a square of a room the team has cleared (not the one he's in), or - with none - out of the
-- building, a couple of tiles clear of it. Returns the waypoints (square centres where the way
-- turns, ending at the spot) and whether it leads outside; or nil.
-- The spot must be out of the room he fell in, a few tiles from it, and out of sight of every
-- enemy the squad knows of (up to 0.45 the first square past the doorstep would do: "dragged out of
-- the building, 2 tiles" - still in the doorway, in the enemy's view). Failing a hidden one, the
-- furthest-back spot within reach.
local DRAG_MIN = 3
local function dragRoute(C, px, py, z, contacts)
    local L = C.L
    local function hidden(x, y)
        for _, c in ipairs(contacts or {}) do
            if math.floor(c.z or z) == z and LF.Cover.canSeeFrom(x, y, z, c) then return false end
        end
        return true
    end
    local cell = getCell()
    local sx, sy = math.floor(px), math.floor(py)
    local here = roomKeyAt(L, px, py)
    local cleared = false
    if C.rooms then
        for k, v in pairs(C.rooms) do if v and k ~= here then cleared = true; break end end
    end
    local function ok(x, y)
        if math.abs(x - sx) > 16 or math.abs(y - sy) > 16 then return nil end
        local q = cell:getGridSquare(x, y, z)
        if not q or not q:isFree(false) then return nil end
        if L.insideSet[x .. "," .. y] then return q, true end
        if not cleared and q:getBuilding() == nil then return q, false end
        return nil
    end
    local function pass(a, b)
        if a:isDoorTo(b) then return true end
        return not (a:isWallTo(b) or a:isWindowTo(b) or a:isHoppableTo(b))
    end
    local start = cell:getGridSquare(sx, sy, z)
    if not start then return nil end
    local key = function(x, y) return x .. "," .. y end
    local from, depth, open, head = { [key(sx, sy)] = false }, { [key(sx, sy)] = 0 }, { { sx, sy, start } }, 1
    local goal, firstOut, fallback, fallD = nil, nil, nil, -1
    local checks = 0
    while head <= #open and head < 1500 do
        local c = open[head]; head = head + 1
        local ck = key(c[1], c[2])
        local dd = depth[ck]
        local inside = L.insideSet[ck] ~= nil
        local good = false
        if cleared then
            local rk = inside and roomKeyAt(L, c[1] + 0.5, c[2] + 0.5)
            good = rk and rk ~= here and C.rooms[rk] and dd >= DRAG_MIN
        elseif not inside then
            firstOut = firstOut or dd
            good = dd >= firstOut + DRAG_MIN
        end
        if good then
            if dd > fallD then fallback, fallD = c, dd end
            checks = checks + 1
            if checks <= 60 and hidden(c[1], c[2]) then goal = c; break end
        end
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local nx, ny = c[1] + d[1], c[2] + d[2]
            local nk = key(nx, ny)
            if depth[nk] == nil then
                local q = ok(nx, ny)
                if q and pass(c[3], q) then
                    depth[nk], from[nk] = dd + 1, ck
                    open[#open + 1] = { nx, ny, q }
                end
            end
        end
    end
    goal = goal or fallback
    if not goal then return nil end
    -- Back from the goal to the start, then keep only the turns.
    local pts = {}
    local k = key(goal[1], goal[2])
    while k do
        local x, y = k:match("(-?%d+),(-?%d+)")
        table.insert(pts, 1, { x = tonumber(x) + 0.5, y = tonumber(y) + 0.5 })
        k = from[k] or nil
    end
    table.remove(pts, 1)                         -- (his own square)
    local route = {}
    for i, p in ipairs(pts) do
        local nx = pts[i + 1]
        local pv = pts[i - 1]
        if not nx or not pv or (nx.x - p.x) ~= (p.x - pv.x) or (nx.y - p.y) ~= (p.y - pv.y) then
            route[#route + 1] = p
        end
    end
    return route, not cleared
end

-- The team goes on clearing from where he was dragged to (once he is back on his feet).
local function regroupPlan(cas, J)
    local team, squad = LF.Units.get(cas.team), LF.Units.get(cas.squad)
    local t = team and teams[cas.team]
    local C = t and t.clear
    cas.phase, cas.at = "out", LF.tick
    if not (C and squad) then return end
    local live = {}
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and fit(r) and LF.Bodies.get(rid) then live[#live + 1] = rid end
    end
    local C2
    if #live >= 1 then
        if cas.outside then
            C2 = planClear(squad, team, t, C.L, C.entry, true)       -- everyone out and stack up again
        else
            local mb = J and J.mb
            local anchor = mb and { x = mb:getX(), y = mb:getY() } or nil
            C2 = planRoom(squad, team, C.L, live, LF.tick, C.rooms, anchor)
        end
    end
    if C2 then
        C2.rooms = C2.rooms or C.rooms
        C2.entry = C.entry or (C.door and C.door.dx ~= 0 and C.door) or C.entry
        C2.roomCount = C.roomCount
        t.clear = C2
        LF.log("CASUALTY " .. team.name .. " regroups " .. (cas.outside and "outside" or "in a cleared room") .. " and clears on")
        local caller = (team.leader ~= cas.id and team.leader) or (J and J.mid)
        if caller and LF.Bodies.get(caller) then LF.Tactics.shout(caller, "He's out - regroup! Go again!") end
    else
        t.clear, t.order = nil, "HOLD"
        LF.log("CASUALTY " .. team.name .. " can't go on clearing (" .. #live .. " fit) - holds")
    end
end

-- Put down where he's safe: he gets straight back up, and the team goes again with him in it.
local function regroup(cas, ok, J)
    cas.phase, cas.at = "rising", LF.tick
    local body = J and J.pb
    LF.Medic.getUp(cas.id, body, function()
        if casualties[cas.id] then
            casualties[cas.id] = nil
            casualtyCount = casualtyCount - 1
        end
        LF.log("CASUALTY #" .. cas.id .. " is back on his feet")
        if body and not body:isDead() then LF.Tactics.shout(cas.id, "I'm all right - let's go!") end
        regroupPlan(cas, J)
    end)
end

local function dragHim(id, cas, body)
    local t = teams[cas.team]
    local C = t and t.clear
    if not C then return false end
    -- The nearest of the others in the file.
    local best, bd = nil, math.huge
    for _, rid in ipairs(C.file) do
        local r, b = LF.Records.get(rid), LF.Bodies.get(rid)
        if rid ~= id and r and fit(r) and b and not LF.Combat.knockedDown(b) and math.abs(b:getZ() - body:getZ()) < 0.5 then
            local d = LF.dist(b:getX(), b:getY(), body:getX(), body:getY())
            if d < bd then best, bd = rid, d end
        end
    end
    if not best then return false end
    local z = math.floor(body:getZ())
    local route, outside = dragRoute(C, body:getX(), body:getY(), z, LF.Squad.contactPoints(cas.squad, CFG.contactMemory, 8))
    if not route or #route == 0 then
        LF.log("CASUALTY #" .. id .. ": no way to drag him out - he stays where he is")
        return false
    end
    -- He lies with his head toward the way out: the dragger lifts him from there and walks back
    -- along the route.
    local first = route[1]
    local lx, ly = first.x - body:getX(), first.y - body:getY()
    local l = math.max(0.01, math.sqrt(lx * lx + ly * ly))
    body:setForwardDirection(-lx / l, -ly / l)
    pcall(function() body:setTargetAndCurrentDirection(-lx / l, -ly / l) end)
    local last = route[#route]
    cas.outside = outside
    C.halted, C.haltAt = true, {}
    if not C.entry and C.door and C.door.dx ~= 0 then C.entry = C.door end
    local mb = LF.Bodies.get(best)
    local started = LF.Medic.drag(best, mb, id, body, last.x, last.y,
        { route = route, onDone = function(ok, J) regroup(cas, ok, J) end })
    if not started then C.halted = nil; return false end
    cas.phase, cas.at = "dragged", LF.tick
    local team = LF.Units.get(cas.team)
    if team and team.leader and team.leader ~= best and team.leader ~= id and LF.Bodies.get(team.leader) then
        LF.Tactics.shout(team.leader, "Man down! Get him out of here!")
    end
    LF.Tactics.shout(best, "I've got him!")
    LF.log(string.format("CASUALTY #%d dragged by #%d %s, %d waypoints, %d tiles", id, best,
        outside and "out of the building" or "back to a cleared room", #route,
        math.floor(LF.dist(body:getX(), body:getY(), last.x, last.y))))
    return true
end

local function casualtyStep(id, cas)
    local body = LF.Bodies.get(id)
    local rec = LF.Records.get(id)
    local function drop()
        casualties[id] = nil
        casualtyCount = casualtyCount - 1
        if body and not body:isDead() then LF.Medic.standUp(id, body) end
    end
    if not body or body:isDead() or not (rec and rec.alive) then
        casualties[id] = nil
        casualtyCount = casualtyCount - 1
        if LF.Medic then LF.Medic.standUp(id, nil) end
        local t = teams[cas.team]
        if t and t.clear and t.clear.halted and cas.phase ~= "out" then t.clear.halted = nil end
        return
    end
    local age = LF.tick - cas.at
    if cas.phase == "falling" then
        -- Wait till he's down (the game's fall), then keep him there.
        local down = false
        pcall(function() down = body:isOnFloor() end)
        if down then cas.downSeen = cas.downSeen or LF.tick end
        if (cas.downSeen and LF.tick - cas.downSeen >= 20) or age > 240 then
            LF.Medic.holdDown(id, body)
            cas.phase, cas.at = "down", LF.tick
        end
    elseif cas.phase == "down" then
        if age % 30 == 0 and dragHim(id, cas, body) then return end
        if age > 900 then                          -- nobody to drag him: he gets up by himself
            cas.phase, cas.at = "rising", LF.tick
            LF.Medic.getUp(id, body, function()
                if casualties[id] then casualties[id] = nil; casualtyCount = casualtyCount - 1 end
            end)
        end
    elseif cas.phase == "out" then
        drop()
    end
end

-- Test: knock over (backward) the man of a clearing team nearest (x, y), as if shot from the front.
function LF.Tactics.testKnockBack(x, y)
    local best, bd = nil, math.huge
    for _, t in pairs(teams) do
        local C = t.clear
        if C and not C.halted then
            for _, rid in ipairs(C.file) do
                local b = LF.Bodies.get(rid)
                if b and not b:isDead() and LF.Building.isInside(C.L, b:getX(), b:getY()) then
                    local d = LF.dist(b:getX(), b:getY(), x, y)
                    if d < bd then best, bd = b, d end
                end
            end
        end
    end
    if not best then LF.say("Nobody is clearing a building (inside it) just now"); return end
    local v = best:getForwardDirection()
    LF.Combat.knock(best, best:getX() + v:getX() * 3, best:getY() + v:getY() * 3, true)
    LF.say("Knocked over #" .. tostring(best:getModData().LF_id))
end

Events.OnTick.Add(function()
    if casualtyCount == 0 then return end
    local ids = {}
    for id in pairs(casualties) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do LF.guard("casualty", casualtyStep, id, casualties[id]) end
end)

-- Order a team to clear building L (Alpha, or the next team with enough fit men if it is
-- shot up). Returns the team that goes, or nil.
local function bidOf(L)
    local q = L and L.inside and L.inside[1]
    return q and LF.Building.idAt(q.x, q.y, L.z)
end

function LF.Tactics.orderClear(squad, team, L, why)
    initTeams(squad)
    -- One unit clears a building at a time: another squad already going in through its doors, this
    -- one covers it (up to 0.45 two squads stacked on the same doors at once, crowding each other
    -- off the stack, and men went in without one).
    local bid = bidOf(L)
    for tid, tt in pairs(teams) do
        local tm = LF.Units.get(tid)
        if tt.clear and tm and tm.squad ~= squad.id and bidOf(tt.clear.L) == bid then
            if LF.tick - (squad.clearWaitLogged or -100000) > 1800 then
                squad.clearWaitLogged = LF.tick
                LF.log("CLEAR " .. squad.name .. ": " .. tm.name .. " of another squad is already clearing that building - covering it")
            end
            return nil
        end
    end
    local C, reason = nil, "no team positions yet"
    -- A team already holding inside this building goes on with it first.
    local order = {}
    for _, tid in ipairs(squad.teams) do
        local tt = teams[tid]
        if tt and tt.inside and tt.inside.L == L then order[#order + 1] = tid end
    end
    local function has(id) for _, o in ipairs(order) do if o == id then return true end end return false end
    if not has(team.id) then order[#order + 1] = team.id end
    for _, tid in ipairs(squad.teams) do if not has(tid) then order[#order + 1] = tid end end
    for _, tid in ipairs(order) do
        local tm, t = LF.Units.get(tid), teams[tid]
        if tm and t and not t.clear and not tm.mg then
            C, reason = planClear(squad, tm, t, L)
            if C then team = tm; break end
        end
    end
    local t = teams[team.id]
    if not C then
        LF.log("CLEAR " .. squad.name .. ": can't clear the building - " .. tostring(reason))
        return nil
    end
    t.clear, t.order, t.moving, t.shifting, t.inside = C, "CLEAR", nil, nil, nil
    LF.log("CLEAR " .. team.name .. " of " .. squad.name .. " ordered to clear the building "
        .. (C.room and "room by room from inside" or ("by the door at " .. C.door.x .. "," .. C.door.y)) .. " (" .. why .. ")")
    if team.leader and LF.Bodies.get(team.leader) then
        LF.Tactics.shout(team.leader, C.room and "Next room - go!" or "Stack up on the door!")
    end
    if not C.room then LF.guard("back door", LF.Tactics.backDoor, squad, team, C, L) end
    return team
end

-- A second team round the back: if the building has another door to the outside well away from
-- the one the first team is stacking on (another wall preferred), and the squad has a team to
-- spare after that (one is always left to cover), that team goes round and clears in from it.
-- The two stacks go in together; rooms one team has cleared, the other doesn't clear again.
function LF.Tactics.backDoor(squad, team, C, L)
    local front = C.door
    local fx, fy = front.x + front.dx, front.y + front.dy
    local best, bestS = nil, -math.huge
    for _, o in ipairs(L.openings) do
        if o.kind == "door" and o ~= front then
            local d = LF.dist(fx, fy, o.x + o.dx, o.y + o.dy)
            if d >= CFG.backDoorMin then
                local sc = d + (o.wall ~= front.wall and 10 or 0)
                if sc > bestS then best, bestS = o, sc end
            end
        end
    end
    if not best then
        LF.log("CLEAR " .. squad.name .. ": no back door - one team clears")
        return nil
    end
    -- Teams free to go: not the one already going, not clearing, enough fit men. Alpha 2 first
    -- (Bravo is the base of fire); at least one team stays out to cover.
    local free = {}
    for _, tid in ipairs(squad.teams) do
        local tm, tt = LF.Units.get(tid), teams[tid]
        if tm and tt and tid ~= team.id and not tt.clear and not tm.mg then free[#free + 1] = tm end   -- (the guns stay out)
    end
    if #free < 2 then
        LF.log("CLEAR " .. squad.name .. ": a back door, but no team to spare for it (one stays out to cover)")
        return nil
    end
    table.sort(free, function(a, b) return (a.element == "A" and 0 or 1) < (b.element == "A" and 0 or 1) end)
    for _, tm in ipairs(free) do
        local tt = teams[tm.id]
        local C2 = planClear(squad, tm, tt, L, best)
        if C2 then
            local rooms = {}
            C.rooms, C2.rooms = rooms, rooms
            C.partner, C2.partner = tm.id, team.id
            C2.stackTimeout = CFG.clearStackTimeout * 2       -- it has further to go
            tt.clear, tt.order, tt.moving, tt.shifting, tt.inside = C2, "CLEAR", nil, nil, nil
            LF.log("CLEAR " .. tm.name .. " of " .. squad.name .. " goes round the back: the door at " .. best.x .. "," .. best.y)
            if tm.leader and LF.Bodies.get(tm.leader) then LF.Tactics.shout(tm.leader, "Round the back! Stack on the back door!") end
            return tm
        end
    end
    LF.log("CLEAR " .. squad.name .. ": a back door at " .. best.x .. "," .. best.y .. ", but no team can stack on it")
    return nil
end

-- The sergeant: is the enemy holed up in a building, down to a few men he knows of? Send
-- Alpha in (the rest keep firing on it).
local function sergeantClear(squad, sq, cid)
    if LF.tick - (sq.lastClear or -100000) < CFG.clearCooldown then return end
    local team = LF.Units.get(squad.teams[1])
    if not team then return end
    for _, tid in ipairs(squad.teams) do
        local tt = teams[tid]
        if tt and tt.clear then return end          -- one clearing at a time
    end
    local counts, where, total = {}, {}, 0
    for _, c in ipairs(LF.Squad.contactPoints(squad.id, CFG.contactMemory, 24)) do
        total = total + 1
        local b = LF.Building.idAt(c.x, c.y, c.z)
        if b then counts[b] = (counts[b] or 0) + 1; where[b] = c end
    end
    -- On an objective: its building, once the defence is thin (or nobody has been seen in it).
    if LF.Objective then
        local L, why = LF.Objective.clearTarget(squad, counts, CFG.clearAt)
        if L then
            sq.lastClear = LF.tick
            local goes = LF.Tactics.orderClear(squad, team, L, why)
            if goes then LF.Tactics.shout(cid, goes.name .. ", clear the objective! Everyone else, cover them!") end
            return
        end
        if squad.objTask then return end           -- not some other building
    end
    for b, n in pairs(counts) do
        if n == total and n <= CFG.clearAt then
            local c = where[b]
            local L = LF.Building.at(c.x, c.y, c.z)
            sq.lastClear = LF.tick
            local goes = L and LF.Tactics.orderClear(squad, team, L, n .. " enemy known inside")
            if goes then
                LF.Tactics.shout(cid, goes.name .. ", clear that building! Everyone else, cover them!")
            end
            return
        end
    end
end

-- ---- shared with the other tactics files ----------------------------------------------------
I.openDoor = openDoor I.sergeantClear = sergeantClear I.updateClear = updateClear
