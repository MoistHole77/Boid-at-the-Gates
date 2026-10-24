-- Living Front: objectives - a place to take or hold, run as a sequence of drills the units
-- already know.
--
-- An objective is a building (or a point in the open). A unit gets a task on it:
--   hold - the defensive stance on the objective (the building defence, or a perimeter).
--   take - 1. approach:    patrol toward it (the sergeant choosing his formations; long ways
--                          planned in legs) to a rally point ~32 tiles short of it
--          2. assault:     the moment the point man reaches the rally point, the offensive stance
--                          against the objective, facing it: the bravo teams form a base of
--                          fire on the building, the alpha teams flank round it; with nobody in
--                          sight the men fire on the building's windows. When the defence is down
--                          to a few men (or nobody has been seen in it for ~30 s), a team clears
--                          it (stack on the door, in one at a time)
--          3. consolidate: once no enemy is left inside and his men are in it, the defensive
--                          stance in the building - men to the windows - and the objective is held
-- Who holds an objective: the faction with the only living soldiers in it.
-- Objectives and tasks are saved (task progress is kept on the unit: squad.objTask).

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/World/LF_Bodies"
require "LivingFront/World/LF_Building"
require "LivingFront/Units/LF_March"
require "LivingFront/Units/LF_Squad"
require "LivingFront/Units/LF_Stance"

LF.Objective = LF.Objective or {}

local CFG = {
    rallyDistance = 32,     -- the rally point is this far short of the objective
    nearAssault = 45,       -- contact this close to the objective on the way in: straight to the assault
    unseenClear = 1800,     -- nobody seen in the building for ~30 s during the assault: clear it
    clearRange = 35,        -- ... if the squad is within this of it
    updateTicks = 30,
    labelRange = 80,
}
LF.Objective.CFG = CFG

local FACTION = { GER = "Germans", SOV = "Soviets", CIV = "civilians" }

local function store()
    local data = LF.Records.data()
    data.objectives = data.objectives or {}
    data.nextObjectiveId = data.nextObjectiveId or 1
    return data
end

function LF.Objective.get(id) return id and store().objectives[id] or nil end
function LF.Objective.all() return store().objectives end

function LF.Objective.clear()
    local data = store()
    data.objectives = {}
    data.nextObjectiveId = 1
    for _, u in pairs(LF.Units.all()) do u.objTask = nil end
end

function LF.Objective.create(x, y, z, name)
    local data = store()
    local id = data.nextObjectiveId
    data.nextObjectiveId = id + 1
    z = math.floor(z or 0)
    local obj = { id = id, x = math.floor(x) + 0.5, y = math.floor(y) + 0.5, z = z, name = name or ("Objective " .. id),
                  building = LF.Building.idAt(x, y, z), holder = nil }
    local L = obj.building and LF.Building.at(x, y, z)
    if L then obj.x, obj.y = L.cx, L.cy end
    data.objectives[id] = obj
    LF.log("OBJECTIVE created " .. obj.name .. " (#" .. id .. ") at " .. math.floor(obj.x) .. "," .. math.floor(obj.y)
        .. (obj.building and " (a building)" or " (open ground)"))
    return obj
end

-- Is (x, y) at the objective (in its building, or within 8 tiles of its point)?
local function atObjective(obj, x, y, z)
    if obj.building then return LF.Building.idAt(x, y, z or obj.z) == obj.building end
    return LF.dist(x, y, obj.x, obj.y) <= 8
end
LF.Objective.at = atObjective

local function say(squad, text)
    local cid = LF.Units.commander(squad)
    if cid and LF.Bodies.get(cid) and LF.Tactics then LF.Tactics.shout(cid, text) end
end

local function setPhase(squad, phase, why)
    local t = squad.objTask
    LF.log("OBJECTIVE " .. squad.name .. ": " .. tostring(t.phase) .. " -> " .. phase .. (why and (" (" .. why .. ")") or ""))
    t.phase, t.since = phase, LF.tick
end

-- ---- tasks ----------------------------------------------------------------------------------

-- Hold it: the defensive stance on the objective.
function LF.Objective.hold(squad, obj)
    squad.objTask = { obj = obj.id, kind = "hold", phase = "hold", since = LF.tick }
    LF.Tactics.setStance(squad, "defensive", obj.building and { x = math.floor(obj.x), y = math.floor(obj.y), z = obj.z } or nil)
    LF.log("OBJECTIVE " .. squad.name .. " holds " .. obj.name)
end

-- Take it: patrol to the rally point short of it, then the assault.
function LF.Objective.take(squad, obj)
    if LF.Join then LF.guard("join", LF.Join.gather, squad, "take") end     -- standing-by teams come along
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    if not cmd then return false, "its commander isn't here" end
    local dx, dy = cmd:getX() - obj.x, cmd:getY() - obj.y
    local d = math.max(1, math.sqrt(dx * dx + dy * dy))
    local r = math.min(CFG.rallyDistance, d * 0.5)
    local rx, ry = obj.x + dx / d * r, obj.y + dy / d * r
    squad.objTask = { obj = obj.id, kind = "take", phase = "approach", since = LF.tick,
                      rally = { x = math.floor(rx), y = math.floor(ry) } }
    squad.facingX, squad.facingY = -dx / d, -dy / d
    local ok, why = LF.March.order(squad, math.floor(rx), math.floor(ry), obj.z, "auto")
    if not ok then squad.objTask = nil; return false, why end
    LF.log("OBJECTIVE " .. squad.name .. " ordered to take " .. obj.name .. ": rally point " .. math.floor(rx) .. ","
        .. math.floor(ry) .. ", " .. math.floor(d) .. " tiles away")
    return true
end

-- During the assault, with nobody in sight: what the squad treats as the enemy's position - the
-- window of the objective building nearest the squad (or the objective's point). Used by
-- LF_Tactics so the squad closes in, fires on the windows and flanks without having seen anyone.
local aimCache = {}           -- squad id -> { point, at }
function LF.Objective.fallbackContact(squad)
    local t = squad.objTask
    if not (t and t.kind == "take" and t.phase == "assault") then return nil end
    local obj = LF.Objective.get(t.obj)
    if not obj then return nil end
    local c = aimCache[squad.id]
    if c and LF.tick - c.at < 600 then return c.point end
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    local px, py = obj.x, obj.y
    if cmd and obj.building then
        local L = LF.Building.at(obj.x, obj.y, obj.z)
        local best, bd = nil, math.huge
        for _, o in ipairs(L and L.openings or {}) do
            if o.kind == "window" then
                local d = LF.dist(cmd:getX(), cmd:getY(), o.x + 0.5, o.y + 0.5)
                if d < bd then best, bd = o, d end
            end
        end
        if best then px, py = best.x + 0.5, best.y + 0.5 end
    end
    c = c or { point = LF.Tactics.point(px, py, obj.z) }
    c.point.x, c.point.y, c.point.z, c.at = px, py, obj.z, LF.tick
    aimCache[squad.id] = c
    return c.point
end

-- The building a squad assaulting an objective should clear now, or nil: the defence there is
-- down to a few men it knows of, or nobody has been seen in it for a while.
function LF.Objective.clearTarget(squad, countsByBuilding, clearAt)
    local t = squad.objTask
    if not (t and t.kind == "take" and t.phase == "assault") then return nil end
    local obj = LF.Objective.get(t.obj)
    if not (obj and obj.building) then return nil end
    local knownInside = countsByBuilding[obj.building] or 0
    local L = LF.Building.at(obj.x, obj.y, obj.z)
    if not L then return nil end
    if knownInside > 0 and knownInside <= clearAt then return L, knownInside .. " enemy known inside" end
    -- Nobody known inside: a building to take is cleared all the same, room by room - nobody
    -- walks into it on the strength of not having seen anyone.
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    if knownInside == 0 and cmd and LF.dist(cmd:getX(), cmd:getY(), obj.x, obj.y) <= CFG.clearRange then
        return L, "nobody known inside - clearing it anyway"
    end
    return nil
end

-- Does this unit have an objective task (the sergeant doesn't change stance on his own then)?
function LF.Objective.busy(squad)
    return squad.objTask ~= nil
end

-- ---- each update ----------------------------------------------------------------------------

-- Who is at the objective: counts of living soldiers per faction (from their records, so it
-- works whether or not they have bodies).
local counts = {}
local function whoIsThere(obj)
    for k in pairs(counts) do counts[k] = nil end
    for _, r in pairs(LF.Records.all()) do
        if r.alive and r.faction ~= "CIV" and LF.dist(r.x, r.y, obj.x, obj.y) < 30 then
            local b = LF.Bodies.get(r.id)
            local x, y, z = r.x, r.y, r.z
            if b then x, y, z = b:getX(), b:getY(), b:getZ() end
            if atObjective(obj, x, y, math.floor(z or obj.z)) then counts[r.faction] = (counts[r.faction] or 0) + 1 end
        end
    end
    return counts
end

-- Into the assault, at once: the squad faces the objective and goes offensive; the sergeant's
-- plan is made, so nobody waits to get his bearings (LF.Objective.planned).
local function startAssault(squad, obj, why, words)
    local t = squad.objTask
    setPhase(squad, "assault", why)
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    if cmd then
        local dx, dy = obj.x - cmd:getX(), obj.y - cmd:getY()
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 1 then squad.facingX, squad.facingY = dx / d, dy / d end
    end
    LF.Tactics.setStance(squad, "offensive")
    say(squad, words or "Bravo, base of fire on that building! Alpha teams, round the flank - move!")
    return t
end

-- The patrol carrying a "take" task has arrived (LF_March calls this the moment the point man
-- reaches the rally point): straight into the assault. True if the task took over.
function LF.Objective.onArrived(squad)
    -- Sent to hold an objective from afar: there now - take up the defence.
    if squad.pendingHold then
        local obj = LF.Objective.get(squad.pendingHold)
        squad.pendingHold = nil
        if obj then
            LF.Objective.hold(squad, obj)
            return true
        end
    end
    local t = squad.objTask
    if not (t and t.kind == "take" and t.phase == "approach") then return false end
    local obj = LF.Objective.get(t.obj)
    if not obj then return false end
    startAssault(squad, obj, "at the rally point")
    return true
end

-- Is the squad carrying out a planned assault (no bearings needed when the shooting starts)?
function LF.Objective.planned(squad)
    local t = squad and squad.objTask
    return t ~= nil and t.kind == "take" and t.phase == "assault"
end

local function updateTake(squad, obj)
    local t = squad.objTask
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    if not cmd then return end
    -- Has the squad seen anyone at the objective lately?
    for _, c in ipairs(LF.Squad.contactPoints(squad.id, 600, 24)) do
        if atObjective(obj, c.x, c.y, math.floor(c.z or obj.z)) then t.lastSeen = LF.tick; break end
    end
    if t.phase == "approach" then
        local M = LF.March.get(squad.id)
        local near = LF.dist(cmd:getX(), cmd:getY(), obj.x, obj.y)
        if M and M.halted and near <= CFG.nearAssault then
            startAssault(squad, obj, "contact " .. math.floor(near) .. " tiles from the objective",
                "That's them - deploy! Bravo, base of fire! Alpha, round the flank!")
        elseif not M and LF.Stance.get(squad).name ~= "patrolling" then
            -- The patrol was cut short (a fight, or it couldn't route): go straight in from here.
            startAssault(squad, obj, "the approach ended " .. math.floor(near) .. " tiles out")
        elseif M and M.arrived then
            LF.Objective.onArrived(squad)
        end
    elseif t.phase == "rally" then
        -- (A task saved in the old rally phase.)
        startAssault(squad, obj, "at the rally point")
    elseif t.phase == "assault" then
        local c = whoIsThere(obj)
        local ours = c[squad.faction] or 0
        local theirs = 0
        for f, n in pairs(c) do if f ~= squad.faction and LF.isHostile(squad.faction, f) then theirs = theirs + n end end
        -- A building is only taken once a team has cleared it (LF_Clearing sets t.cleared).
        if theirs == 0 and ours > 0 and (not obj.building or t.cleared) then
            obj.holder = squad.faction
            setPhase(squad, "hold", "no enemy left at " .. obj.name)
            t.kind = "hold"
            LF.Tactics.setStance(squad, "defensive", obj.building and { x = math.floor(obj.x), y = math.floor(obj.y), z = obj.z } or nil)
            say(squad, "It's ours! Take the windows!")
            LF.log("OBJECTIVE " .. obj.name .. " taken by the " .. (FACTION[squad.faction] or squad.faction))
            if LF.Service then LF.guard("service objective", LF.Service.objectiveTaken, squad) end
        end
    end
end

local function updateHolder(obj)
    local c = whoIsThere(obj)
    local only, n = nil, 0
    for f, k in pairs(c) do
        if k > 0 then only = f; n = n + 1 end
    end
    if n == 1 and only ~= obj.holder then
        local was = obj.holder
        obj.holder = only
        LF.log("OBJECTIVE " .. obj.name .. " now held by the " .. (FACTION[only] or only)
            .. (was and (" (was the " .. (FACTION[was] or was) .. ")") or ""))
    end
end

local function onTick()
    if LF.tick % CFG.updateTicks ~= 0 then return end
    for _, squad in pairs(LF.Units.all()) do
        -- A newly spawned unit given a "take" order: it sets off once its men have bodies.
        if squad.kind == "squad" and squad.pendingTake then
            local obj = LF.Objective.get(squad.pendingTake)
            local cid = LF.Units.commander(squad)
            local all = true
            for _, rid in ipairs(LF.Units.members(squad.id)) do
                local r = LF.Records.get(rid)
                if r and r.alive and not LF.Bodies.get(rid) then all = false end
            end
            squad.pendingSince = squad.pendingSince or LF.tick
            if not obj then
                squad.pendingTake = nil
            elseif cid and LF.Bodies.get(cid) and (all or LF.tick - squad.pendingSince > 300) then
                squad.pendingTake, squad.pendingSince = nil, nil
                local ok, why = LF.Objective.take(squad, obj)
                if not ok then LF.log("OBJECTIVE " .. squad.name .. " can't set off: " .. tostring(why)) end
            end
        end
    end
    for _, squad in pairs(LF.Units.all()) do
        local t = squad.kind == "squad" and squad.objTask
        local obj = t and LF.Objective.get(t.obj)
        if t and not obj then squad.objTask = nil
        elseif t and t.kind == "take" then LF.guard("objective task", updateTake, squad, obj) end
    end
    if LF.tick % 120 == 0 then
        for _, obj in pairs(LF.Objective.all()) do LF.guard("objective holder", updateHolder, obj) end
    end
end
Events.OnTick.Add(onTick)
Events.OnInitGlobalModData.Add(function() aimCache = {} end)

-- ---- labels ---------------------------------------------------------------------------------

local COLORS = { GER = { 0.75, 0.8, 0.9 }, SOV = { 1.0, 0.55, 0.5 } }

local function drawLabels()
    local p = getPlayer()
    if not p then return end
    local zoom = getCore():getZoom(0)
    local tm = getTextManager()
    for _, obj in pairs(LF.Objective.all()) do
        if LF.distSq(obj.x, obj.y, p:getX(), p:getY()) < CFG.labelRange * CFG.labelRange then
            local sx, sy = isoToScreenX(0, obj.x, obj.y, obj.z), isoToScreenY(0, obj.x, obj.y, obj.z)
            local col = COLORS[obj.holder] or { 1, 1, 0.6 }
            local text = obj.name .. (obj.holder and (" - held by the " .. (FACTION[obj.holder] or obj.holder)) or " - contested")
            tm:DrawStringCentre(UIFont.Medium, sx, sy - 70 / zoom, text, col[1], col[2], col[3], 0.9)
        end
    end
end
Events.OnPostUIDraw.Add(function() LF.guard("draw objectives", drawLabels) end)
