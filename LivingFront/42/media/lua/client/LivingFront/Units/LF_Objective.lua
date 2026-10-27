-- Living Front: objectives - a place to take or hold, run as a sequence of drills the units
-- already know.
--
-- An objective is a building (or a point in the open). A unit gets a task on it:
--   hold - the defensive stance on the objective (the building defence, or a perimeter).
--   take - 1. approach:    patrol toward it (the sergeant choosing his formations; long ways
--                          planned in legs) to a rally point ~20 tiles short of it (inside rifle
--                          range, so with nobody seen the squad doesn't bound the last stretch)
--          2. assault:     the moment the point man reaches the rally point, the offensive stance
--                          against the objective, facing it: the bravo teams form a base of
--                          fire on the building, the alpha teams flank round it; with nobody in
--                          sight the men fire on the building's windows. When the defence is down
--                          to a few men (or nobody has been seen in it for ~30 s), a team clears
--                          it (stack on the door, in one at a time)
--          3. consolidate: once no enemy is left inside and his men are in it, the defensive
--                          stance in the building - men to the windows - and the objective is held
-- Who holds an objective: the faction with the only living soldiers in it; both sides in it at
-- once, it is contested.
-- Objectives are buildings (for now). Each remembers its footprint (the rooms of its ground floor,
-- from the building's map definition) and what kind of building it is, so it can be drawn on the
-- map and the minimap (LF_Map) wherever you are; and an inside square (its anchor), so the
-- building is found again after a reload (the game numbers buildings afresh each time).
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
    rallyDistance = 20,     -- the rally point is this far short of the objective (0.51: was 32)
    nearAssault = 45,       -- contact this close to the objective on the way in: straight to the assault
    unseenClear = 1800,     -- nobody seen in the building for ~30 s during the assault: clear it
    clearRange = 35,        -- ... if the squad is within this of it
    updateTicks = 30,
    labelRange = 80,
    stormStand = 8,         -- storming off-screen, the men close up to this far from its middle (at the walls)
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

-- No longer an objective: forget it, and the squads' tasks on it.
function LF.Objective.remove(id)
    local data = store()
    local obj = data.objectives[id]
    if not obj then return end
    data.objectives[id] = nil
    for _, u in pairs(LF.Units.all()) do
        if u.objTask and u.objTask.obj == id then u.objTask = nil end
        if u.pendingHold == id then u.pendingHold = nil end
    end
    LF.log("OBJECTIVE " .. obj.name .. " (#" .. id .. ") removed")
end

function LF.Objective.clear()
    local data = store()
    data.objectives = {}
    data.nextObjectiveId = 1
    data.nextLetter = 0
    for _, u in pairs(LF.Units.all()) do u.objTask = nil end
end

-- ---- the building ----------------------------------------------------------------------------

-- What a building is, from its rooms' names (the map's room types): the first special room type
-- found, by how distinctive it is; rooms of a home -> "house".
local KINDS = {
    { "church", "church" }, { "school", "classroom" }, { "police station", "police" },
    { "fire station", "firestorage" }, { "hospital", "hospital" }, { "clinic", "medical" },
    { "gas station", "gasstore" }, { "grocery", "grocery" }, { "bar", "bar" }, { "restaurant", "restaurant" },
    { "diner", "diner" }, { "motel", "motel" }, { "warehouse", "warehouse" }, { "factory", "factory" },
    { "office", "office" }, { "bank", "bank" }, { "shop", "store" }, { "shop", "shop" }, { "barn", "barn" },
    { "garage", "garage" }, { "storage", "storage" },
}
local HOME = { kitchen = true, bedroom = true, livingroom = true, bathroom = true, hall = true, laundry = true,
               diningroom = true, empty = true, closet = true }

local function call(o, m) local ok, v = pcall(function() return o[m](o) end); if ok then return v end end

-- The building's map definition at a square, or nil.
local function defAt(x, y, z)
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z))
    local b = sq and sq:getBuilding()
    return b and call(b, "getDef")
end

-- Fill in the footprint (ground-floor room rectangles), the bounds and the kind, from the def.
local function survey(obj, def)
    local rooms = call(def, "getRooms")
    if not rooms then return false end
    local rects, names = {}, {}
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for i = 0, rooms:size() - 1 do
        local room = rooms:get(i)
        local rz = call(room, "getZ") or 0
        local name = call(room, "getName")
        if name then names[name] = (names[name] or 0) + 1 end
        local rr = call(room, "getRects")
        if rz == obj.z and rr then
            for j = 0, rr:size() - 1 do
                local r = rr:get(j)
                local rx, ry = call(r, "getX"), call(r, "getY")
                local rw = call(r, "getW") or ((call(r, "getX2") or rx) - rx)
                local rh = call(r, "getH") or ((call(r, "getY2") or ry) - ry)
                if rx and ry and rw and rh and rw > 0 and rh > 0 then
                    rects[#rects + 1] = { rx, ry, rw, rh }
                    x1, y1 = math.min(x1, rx), math.min(y1, ry)
                    x2, y2 = math.max(x2, rx + rw), math.max(y2, ry + rh)
                end
            end
        end
    end
    if #rects == 0 then
        -- (No room rectangles: the building's own bounds.)
        local bx, by, bx2, by2 = call(def, "getX"), call(def, "getY"), call(def, "getX2"), call(def, "getY2")
        if not (bx and by and bx2 and by2) then return false end
        rects[1] = { bx, by, bx2 - bx, by2 - by }
        x1, y1, x2, y2 = bx, by, bx2, by2
    end
    obj.rects, obj.bounds = rects, { x1, y1, x2, y2 }
    local kind = nil
    for _, k in ipairs(KINDS) do
        for name in pairs(names) do
            if name:lower():find(k[2], 1, true) then kind = k[1]; break end
        end
        if kind then break end
    end
    if not kind then
        local home = false
        for name in pairs(names) do if HOME[name:lower()] then home = true end end
        kind = home and "house" or "building"
    end
    obj.kind = kind
    return true
end

-- The building's id this session (re-found from its anchor square when that is loaded), and its
-- footprint if it hasn't got one yet. Called when made and every couple of seconds.
local function refresh(obj)
    if not obj.anchor then return end
    local a = obj.anchor
    local sq = getCell():getGridSquare(a[1], a[2], obj.z)
    if not sq then return end                       -- (not loaded: keep what we had)
    local b = sq:getBuilding()
    obj.building = b and b:getID() or nil
    if b and not obj.rects then
        local def = call(b, "getDef")
        if def then LF.guard("objective survey", survey, obj, def) end
    end
end
LF.Objective.refresh = refresh

-- ---- names ------------------------------------------------------------------------------------
-- Each objective has a letter (A, B, C... in the order they are made). It is called by that
-- letter in the spelling alphabet of the side holding it - Objective Ivan to the Soviets is
-- Objective Ida to the Germans - and by the plain letter while nobody holds it.
local ALPHABET = {
    GER = { "Anton", "Berta", "Caesar", "Dora", "Emil", "Friedrich", "Gustav", "Heinrich", "Ida", "Julius",
            "Kaufmann", "Ludwig", "Martha", "Nordpol", "Otto", "Paula", "Quelle", "Richard", "Siegfried",
            "Theodor", "Ulrich", "Viktor", "Wilhelm", "Xanthippe", "Ypsilon", "Zacharias" },
    SOV = { "Anna", "Boris", "Tsaplya", "Dmitri", "Elena", "Fyodor", "Grigory", "Khariton", "Ivan", "Zhenya",
            "Konstantin", "Leonid", "Mikhail", "Nikolai", "Olga", "Pavel", "Kvadrat", "Roman", "Semyon",
            "Tatyana", "Ulyana", "Vasily", "Vladimir", "Kseniya", "Yakov", "Zinaida" },
}

-- Its name now (also kept in obj.name for the logs and the shouted orders).
local function nameOf(obj)
    local n = obj.letter or obj.id
    local idx = (n - 1) % 26 + 1
    local word = obj.holder and ALPHABET[obj.holder] and ALPHABET[obj.holder][idx] or string.char(64 + idx)
    if n > 26 then word = word .. " " .. (math.floor((n - 1) / 26) + 1) end
    return "Objective " .. word
end
LF.Objective.nameOf = nameOf

local function rename(obj)
    local new = nameOf(obj)
    if new ~= obj.name then
        if obj.name then LF.log("OBJECTIVE " .. obj.name .. " is now " .. new) end
        obj.name = new
    end
end

-- The map's definition of the building at (x, y) anywhere in the world, loaded or not, or nil.
local function metaDefAt(x, y)
    local ok, def = pcall(function() return getWorld():getMetaGrid():getBuildingAt(math.floor(x), math.floor(y)) end)
    return ok and def or nil
end
LF.Objective.metaDefAt = metaDefAt

-- Is (x, y) on an objective's footprint (or, with no footprint, within 4 tiles of it)?
local function onFootprint(obj, x, y)
    if obj.rects then
        for _, r in ipairs(obj.rects) do
            if x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4] then return true end
        end
        return false
    end
    return math.abs(x - obj.x) <= 4 and math.abs(y - obj.y) <= 4
end

-- The objective whose building is at (x, y), or nil.
function LF.Objective.atPoint(x, y)
    for _, o in pairs(store().objectives) do
        if onFootprint(o, x, y) then return o end
    end
    local def = metaDefAt(x, y)
    if def then
        local bx, by = call(def, "getX"), call(def, "getY")
        for _, o in pairs(store().objectives) do
            local od = o.anchor and metaDefAt(o.anchor[1], o.anchor[2])
            if od and call(od, "getX") == bx and call(od, "getY") == by then return o end
        end
    end
    return nil
end

-- Make (x, y) an objective - it must be in a building (one nearby, or anywhere on the map: a far
-- one is surveyed from the map's definition and found properly when you get near it). Returns
-- the objective, or nil and why. (name: ignored - objectives are named by their letter and holder.)
function LF.Objective.create(x, y, z, name)
    z = math.floor(z or 0)
    local def = nil
    if not LF.Building.idAt(x, y, z) then
        def = metaDefAt(x, y)
        if not def then return nil, "objectives are buildings - that's open ground" end
    end
    local data = store()
    local id = data.nextObjectiveId
    data.nextObjectiveId = id + 1
    data.nextLetter = (data.nextLetter or 0) + 1
    local obj = { id = id, letter = data.nextLetter, x = math.floor(x) + 0.5, y = math.floor(y) + 0.5, z = z,
                  anchor = { math.floor(x), math.floor(y) }, holder = nil }
    obj.name = nameOf(obj)
    if def then
        -- Not loaded: the footprint from the map; the anchor in its biggest ground-floor room.
        LF.guard("objective survey", survey, obj, def)
        local big, ba = nil, 0
        for _, r in ipairs(obj.rects or {}) do
            if r[3] * r[4] > ba then big, ba = r, r[3] * r[4] end
        end
        if big then obj.anchor = { big[1] + math.floor(big[3] / 2), big[2] + math.floor(big[4] / 2) } end
    end
    refresh(obj)
    local L = obj.building and LF.Building.at(x, y, z)
    if L then obj.x, obj.y = L.cx, L.cy
    elseif obj.bounds then obj.x, obj.y = (obj.bounds[1] + obj.bounds[3]) / 2, (obj.bounds[2] + obj.bounds[4]) / 2 end
    data.objectives[id] = obj
    LF.log("OBJECTIVE created " .. obj.name .. " (#" .. id .. ") at " .. math.floor(obj.x) .. "," .. math.floor(obj.y)
        .. " - " .. (obj.kind or "a building") .. ", " .. (obj.rects and #obj.rects or 0) .. " room areas on the map")
    return obj
end

-- The units with a task on an objective, and what: { { unit, words } }.
function LF.Objective.tasked(obj)
    local out = {}
    for _, u in pairs(LF.Units.all()) do
        local t = u.kind == "squad" and u.objTask
        if t and t.obj == obj.id then
            local words = t.kind == "hold" and "holding" or ("taking it (" .. tostring(t.phase) .. ")")
            out[#out + 1] = { unit = u, words = words }
        elseif u.kind == "platoon" and u.mission and u.mission.obj == obj.id then
            out[#out + 1] = { unit = u, words = (u.mission.kind == "take" and "taking it" or "holding") .. " (" .. tostring(u.mission.phase) .. ")" }
        end
    end
    table.sort(out, function(a, b) return a.unit.id < b.unit.id end)
    return out
end

LF.Objective.FACTION = FACTION

-- Is (x, y) at the objective (in its building, or within 8 tiles of its point)? Where the ground
-- isn't loaded (off-screen), by the building's footprint from the map.
local function atObjective(obj, x, y, z)
    if obj.building and getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or obj.z)) then
        return LF.Building.idAt(x, y, z or obj.z) == obj.building
    end
    if obj.rects then return onFootprint(obj, x, y) end
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

-- Off-screen, the men without bodies move into the objective: each onto his own square of its
-- footprint (2 tiles apart), so they get their bodies inside it when you come near. True if
-- anyone was moved.
local function settleInside(squad, obj)
    local spots = {}
    for _, r in ipairs(obj.rects or {}) do
        for x = r[1] + 1, r[1] + r[3] - 1, 2 do
            for y = r[2] + 1, r[2] + r[4] - 1, 2 do spots[#spots + 1] = { x + 0.5, y + 0.5 } end
        end
    end
    if #spots == 0 then spots[1] = { obj.x, obj.y } end
    local moved, i = 0, 0
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local rec = LF.Records.get(rid)
        if rec and rec.alive and not LF.Bodies.get(rid) then
            i = i + 1
            local sp = spots[(i - 1) % #spots + 1]
            rec.x, rec.y, rec.z = sp[1], sp[2], obj.z
            moved = moved + 1
        end
    end
    return moved > 0
end
LF.Objective.settleInside = settleInside

-- Is the objective in the enemy's hands (held by a hostile side, or contested)?
local function enemyHeld(faction, obj)
    return (obj.holder ~= nil and obj.holder ~= faction and LF.isHostile(faction, obj.holder)) or obj.contested == true
end
LF.Objective.enemyHeld = enemyHeld

-- Hold it: the defensive stance on the objective. (Men off-screen are put inside it.) An
-- objective the enemy holds has to be taken first: that becomes the order.
function LF.Objective.hold(squad, obj)
    if enemyHeld(squad.faction, obj) and squad.kind == "squad" then
        LF.log("OBJECTIVE " .. squad.name .. " told to hold " .. obj.name .. ", which the enemy holds - it takes it first")
        local ok = LF.Objective.take(squad, obj)
        if ok then return end
    end
    squad.objTask = { obj = obj.id, kind = "hold", phase = "hold", since = LF.tick }
    LF.Tactics.setStance(squad, "defensive", obj.building and { x = math.floor(obj.x), y = math.floor(obj.y), z = obj.z } or nil)
    if obj.building or obj.rects then settleInside(squad, obj) end
    LF.log("OBJECTIVE " .. squad.name .. " holds " .. obj.name)
end

-- Take it: patrol to the rally point short of it, then the assault.
function LF.Objective.take(squad, obj)
    if LF.Join then LF.guard("join", LF.Join.gather, squad, "take") end     -- standing-by teams come along
    -- (From where the squad is: its sergeant's body, or his record off-screen.)
    local sx, sy = LF.Squad.anchor(squad.id)
    if not sx then return false, "it has no one in command" end
    local dx, dy = sx - obj.x, sy - obj.y
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
    return squad.objTask ~= nil or squad.platoonTask ~= nil
end

-- ---- each update ----------------------------------------------------------------------------

-- Who is at the objective: counts of living soldiers per faction (from their records, so it
-- works whether or not they have bodies).
local counts = {}
local fitCounts = {}
-- fitOnly: count only men who can still fight - the wounded don't hold a building (0.56: four
-- wounded Germans kept a platoon out of one for good).
local function whoIsThere(obj, fitOnly)
    local counts = fitOnly and fitCounts or counts
    for k in pairs(counts) do counts[k] = nil end
    for _, r in pairs(LF.Records.all()) do
        if r.alive and r.faction ~= "CIV" and (not fitOnly or not (r.wounded or r.offWound))
            and LF.dist(r.x, r.y, obj.x, obj.y) < 30 then
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
    say(squad, words or "Bravo, base of fire on that building! Alpha, round the flank - move!")
    return t
end

-- The patrol carrying a "take" task has arrived (LF_March calls this the moment the point man
-- reaches the rally point): straight into the assault. True if the task took over.
function LF.Objective.onArrived(squad)
    -- (A squad of a platoon sent to a support-by-fire position or a rally point - LF_Platoon.)
    if LF.Platoon and LF.Platoon.onArrived(squad) then return true end
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

-- Off-screen (the sergeant has no body here): the task goes on by the unit's state, and the
-- fighting is LF_Clash's.
--   approach - the march arriving at the rally point starts the assault (LF_March); halted by
--              contact within CFG.nearAssault of the objective, it goes straight into it.
--   assault  - with fit enemy at the objective, the squad works forward to its rally point and
--              fires from there; once it has the upper hand - three fit men of ours near the
--              objective for each of theirs, their morale under 30, or two to one after two
--              minutes - it storms: the men go in (and the defenders lose most of their cover).
--              No fit enemy left: the wounded inside are taken prisoner, the men walk in and the
--              objective is taken.
-- spread (tiles): each man to his own place along a line across the way in, not all to one
-- point (0.69: ten men piled on the objective's middle square, among its defenders).
local function walkMen(squad, tx, ty, z, speed, t, spread)
    local dt = LF.simTime - (t.walkAt or LF.simTime)
    t.walkAt = LF.simTime
    if dt <= 0 then return 0 end
    local far = 0
    local list = LF.Units.members(squad.id)
    local ox, oy = 0, 0
    if spread then
        local ax, ay = LF.Squad.anchor(squad.id)
        if ax then
            local dx, dy = tx - ax, ty - ay
            local l = math.max(0.1, math.sqrt(dx * dx + dy * dy))
            ox, oy = -dy / l * spread, dx / l * spread
        end
    end
    local gx, gy = tx, ty
    for i, rid in ipairs(list) do
        local r = LF.Records.get(rid)
        if r and r.alive and not r.aid and not LF.Bodies.get(rid) then
            local k = i - (#list + 1) / 2
            tx, ty = gx + ox * k, gy + oy * k
            local d = LF.dist(r.x, r.y, tx, ty)
            local step = speed * dt
            if d <= step then r.x, r.y = tx + (r.x - tx) * 0.1, ty + (r.y - ty) * 0.1
            else r.x, r.y = r.x + (tx - r.x) / d * step, r.y + (ty - r.y) / d * step end
            r.z = z
            far = math.max(far, LF.dist(r.x, r.y, tx, ty))
        end
    end
    return far
end

-- Fit men of a faction (theirs or ours) within range of the objective, and their average morale.
local function strengthNear(obj, faction, range)
    local n, m = 0, 0
    for _, r in pairs(LF.Records.all()) do
        if r.alive and r.faction == faction and not (r.wounded or r.offWound) and LF.dist(r.x, r.y, obj.x, obj.y) <= range then
            n = n + 1
            m = m + (LF.Morale and LF.Morale.get(r) or 60)
        end
    end
    return n, n > 0 and m / n or 0
end

-- The wounded enemy left inside when the objective falls: taken prisoner (out of the war).
local function takePrisoners(squad, obj)
    for _, r in pairs(LF.Records.all()) do
        if r.alive and r.faction ~= squad.faction and LF.isHostile(squad.faction, r.faction) and not LF.Bodies.get(r.id)
            and atObjective(obj, r.x, r.y, r.z or obj.z) then
            r.alive, r.captured = false, { by = squad.id, x = r.x, y = r.y, z = r.z or 0 }
            LF.log("OBJECTIVE " .. LF.Units.title(r) .. " #" .. r.id .. " taken prisoner by " .. squad.name .. " at " .. obj.name)
            LF.guard("succession", LF.Units.onDeath, r)
            if LF.Clash and LF.Clash.note then
                LF.Clash.note("captured", { who = r.id, unit = r.squad, by = squad.id, x = math.floor(r.x), y = math.floor(r.y) })
            end
        end
    end
end

local function updateTakeOffscreen(squad, obj)
    local t = squad.objTask
    if t.phase == "approach" then
        local M = LF.March.get(squad.id)
        local ax, ay = LF.Squad.anchor(squad.id)
        local near = ax and LF.dist(ax, ay, obj.x, obj.y) or math.huge
        if M and M.arrived then LF.Objective.onArrived(squad)
        elseif M and M.halted and near <= CFG.nearAssault then
            startAssault(squad, obj, "contact " .. math.floor(near) .. " tiles from the objective (off-screen)")
        elseif not M and LF.Stance.get(squad).name ~= "patrolling" then
            startAssault(squad, obj, "the approach ended (off-screen)")
        end
    elseif t.phase == "rally" then
        startAssault(squad, obj, "at the rally point")
    elseif t.phase == "assault" then
        local cf = whoIsThere(obj, true)
        local theirs, enemyFaction = 0, nil
        for f, n in pairs(cf) do
            if f ~= squad.faction and LF.isHostile(squad.faction, f) then theirs, enemyFaction = theirs + n, f end
        end
        if theirs > 0 then
            t.assaultSince = t.assaultSince or LF.simTime
            if not t.storm then
                local ours = strengthNear(obj, squad.faction, 45)
                local _, theirMorale = strengthNear(obj, enemyFaction, 30)
                local long = LF.simTime - t.assaultSince > 120
                if ours >= theirs * 3 or theirMorale < 30 or (long and ours >= theirs * 2) then
                    t.storm = true
                    LF.log(string.format("OBJECTIVE %s storms %s off-screen (%d of ours against %d, their morale %.0f)",
                        squad.name, obj.name, ours, theirs, theirMorale))
                end
            end
            if t.storm then
                -- In at a rush - up to the walls on their side, spread out, not into the middle
                -- of the defenders: if you come, the fight at the house goes on from there with
                -- bodies (0.69.1 put both squads on the same few squares, in the open).
                local ax, ay = LF.Squad.anchor(squad.id)
                local sx, sy = obj.x, obj.y
                if ax then
                    local dx, dy = ax - obj.x, ay - obj.y
                    local l = math.max(0.1, math.sqrt(dx * dx + dy * dy))
                    local back = math.min(l, CFG.stormStand)
                    sx, sy = obj.x + dx / l * back, obj.y + dy / l * back
                end
                walkMen(squad, sx, sy, obj.z, 1.0, t, 1.5)
            elseif t.rally then
                walkMen(squad, t.rally.x, t.rally.y, obj.z, 0.5, t)   -- (forward by bounds to the rally point)
            end
            if not t.offscreenWait then
                t.offscreenWait = true
                LF.log("OBJECTIVE " .. squad.name .. ": " .. theirs .. " fit enemy at " .. obj.name .. " - fighting for it off-screen")
            end
            return
        end
        t.offscreenWait, t.storm = nil, nil
        takePrisoners(squad, obj)
        local c = whoIsThere(obj)
        local ours = c[squad.faction] or 0
        if ours == 0 then
            settleInside(squad, obj)
            t.cleared = true
            LF.log("OBJECTIVE " .. squad.name .. " walks into " .. obj.name .. " - no one left to fight (off-screen)")
            return
        end
        local was = obj.holder
        obj.holder = squad.faction
        if was ~= obj.holder and LF.Memory then LF.guard("memory objective", LF.Memory.objective, obj, obj.holder, was) end
        rename(obj)
        setPhase(squad, "hold", "no enemy at " .. obj.name .. " (off-screen)")
        t.kind = "hold"
        LF.Tactics.setStance(squad, "defensive", obj.building and { x = math.floor(obj.x), y = math.floor(obj.y), z = obj.z } or nil)
        settleInside(squad, obj)
        LF.log("OBJECTIVE " .. obj.name .. " taken by the " .. (FACTION[squad.faction] or squad.faction) .. " (off-screen)")
        if LF.Service then LF.guard("service objective", LF.Service.objectiveTaken, squad) end
    end
end

local function updateTake(squad, obj)
    local t = squad.objTask
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    if not cmd then return updateTakeOffscreen(squad, obj) end
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
        local cf = whoIsThere(obj, true)
        for f, n in pairs(cf) do if f ~= squad.faction and LF.isHostile(squad.faction, f) then theirs = theirs + n end end
        -- A building is only taken once a team has cleared it (LF_Clearing sets t.cleared).
        if theirs == 0 and ours > 0 and (not obj.building or t.cleared) then
            local was = obj.holder
            obj.holder = squad.faction
            if was ~= obj.holder and LF.Memory then LF.guard("memory objective", LF.Memory.objective, obj, obj.holder, was) end
            rename(obj)
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
    refresh(obj)
    rename(obj)                         -- (objectives from before 0.53 get their new names)
    local c = whoIsThere(obj)
    local only, n = nil, 0
    for f, k in pairs(c) do
        if k > 0 and f ~= "CIV" then only = f; n = n + 1 end
    end
    local contested = n > 1
    if contested ~= (obj.contested == true) then
        obj.contested = contested or nil
        LF.log("OBJECTIVE " .. obj.name .. (contested and " is contested" or " is no longer contested"))
    end
    if n == 1 and only ~= obj.holder then
        local was = obj.holder
        obj.holder = only
        if LF.Memory then LF.guard("memory objective", LF.Memory.objective, obj, only, was) end
        rename(obj)
        LF.log("OBJECTIVE " .. obj.name .. " now held by the " .. (FACTION[only] or only)
            .. (was and (" (was the " .. (FACTION[was] or was) .. ")") or ""))
    end
end

local function onTick()
    if not LF.due(CFG.updateTicks, 0) then return end
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
    if LF.due(120, 0) then
        for _, obj in pairs(LF.Objective.all()) do LF.guard("objective holder", updateHolder, obj) end
    end
end
LF.on("OnTick", "Objective", onTick)
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
LF.on("OnPostUIDraw", "Objective", function() LF.guard("draw objectives", drawLabels) end)
