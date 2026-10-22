-- Living Front: objectives - places to take and hold.
--
-- An objective is a point with a radius (often a building). A unit gets a task on it:
--   defend - the men take posts: in a building, the squares just inside windows and doorways
--            that face the expected attack (best-facing first); in the open, covered squares
--            facing it. Men without a post wait near the centre as a reserve. Defenders don't
--            advance, reposition or flank; they hold their posts and fight.
--   attack - the unit marches on it (bounding, LF_Tactics ASSAULT) and, once in a fight, uses
--            everything it has (advance, suppress, reposition, flank) until the defence is
--            thin enough to storm it.
-- Whoever has the only living soldiers inside the radius holds it. When attackers take it,
-- their task becomes defend (posts facing on, the way they came).
-- Objectives are saved; posts are recomputed at runtime.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Units"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Sense"
require "LivingFront/LF_Cover"

LF.Objective = LF.Objective or {}

local CFG = {
    updateTicks = 60,       -- ownership is checked once a second
    labelRange = 70,        -- objective labels are drawn within this many tiles of the player
}

local function store()
    local data = LF.Records.data()
    if not data.objectives then data.objectives = {} end
    if not data.nextObjectiveId then data.nextObjectiveId = 1 end
    return data
end

function LF.Objective.get(id) return id and store().objectives[id] or nil end
function LF.Objective.all() return store().objectives end

local postCache = {}       -- record id -> post { x, y, z } (runtime)
local postsDone = {}       -- squad id -> true once posts are assigned (runtime)

function LF.Objective.clear()
    local data = store()
    data.objectives = {}
    data.nextObjectiveId = 1
    postCache, postsDone = {}, {}
end

Events.OnInitGlobalModData.Add(function() postCache, postsDone = {}, {} end)

local function buildingId(sq)
    local b = sq and sq:getBuilding()
    return b and b:getID() or nil
end

function LF.Objective.create(x, y, z, name, radius)
    local data = store()
    local id = data.nextObjectiveId
    data.nextObjectiveId = id + 1
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), z)
    local obj = { id = id, x = x, y = y, z = z, name = name or ("Objective " .. id), radius = radius or 10,
                  building = buildingId(sq), holder = nil }
    data.objectives[id] = obj
    LF.log("OBJECTIVE created " .. obj.name .. " (#" .. id .. ") at " .. math.floor(x) .. "," .. math.floor(y)
        .. (obj.building and " (building)" or " (open ground)") .. ", radius " .. obj.radius)
    return obj
end

-- ---- posts ----------------------------------------------------------------------------------

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Candidate posts for defending obj against a threat from direction (fx, fy), best first.
local function computePosts(obj, fx, fy)
    local cell = getCell()
    local cx, cy, z = math.floor(obj.x), math.floor(obj.y), obj.z
    local R = obj.radius
    local list = {}
    for x = cx - R, cx + R do
        for y = cy - R, cy + R do
            local sq = cell:getGridSquare(x, y, z)
            if sq and sq:isFree(false) then
                if obj.building then
                    if buildingId(sq) == obj.building then
                        -- Just inside a window or doorway that opens to the outside.
                        for _, d in ipairs(DIRS) do
                            local nb = cell:getGridSquare(x + d[1], y + d[2], z)
                            if nb and buildingId(nb) ~= obj.building then
                                local window = sq:isWindowTo(nb)
                                local door = not window and sq:isDoorTo(nb)
                                if window or door then
                                    local facing = d[1] * fx + d[2] * fy    -- 1 = straight at the threat
                                    list[#list + 1] = { x = x, y = y, z = z, score = facing + (window and 0.3 or 0) }
                                    break
                                end
                            end
                        end
                    end
                elseif LF.distSq(x + 0.5, y + 0.5, obj.x, obj.y) <= R * R then
                    local q = LF.Cover.quality(x, y, z, obj.x + fx * 15, obj.y + fy * 15)
                    if q ~= LF.Cover.NONE then
                        list[#list + 1] = { x = x, y = y, z = z, score = q + ((x - cx) * fx + (y - cy) * fy) / R }
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    return list
end

-- Give a defending squad's men their posts (front-facing posts first, the sergeant last).
local function assignPosts(squad, obj)
    local fx, fy = squad.facingX or 1, squad.facingY or 0
    local posts = computePosts(obj, fx, fy)
    local order = {}
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r and r.alive and rid ~= squad.leader then order[#order + 1] = rid end
    end
    if squad.leader then order[#order + 1] = squad.leader end
    local given = 0
    for i, rid in ipairs(order) do
        local p = posts[i]
        if p and p.score > -0.5 then             -- not posts facing straight away from the threat
            postCache[rid] = p
            given = given + 1
        else
            postCache[rid] = nil
        end
    end
    postsDone[squad.id] = true
    LF.log("OBJECTIVE " .. squad.name .. " takes up " .. given .. " posts at " .. obj.name .. " ("
        .. #posts .. " found, " .. (#order - given) .. " in reserve)")
end

-- A defender's post: x, y, z (or the objective's centre for the reserve).
function LF.Objective.postFor(rec, squad, obj)
    if not postsDone[squad.id] then assignPosts(squad, obj) end
    local p = postCache[rec.id]
    if p then return p.x + 0.5, p.y + 0.5, p.z, true end
    return obj.x, obj.y, obj.z, false
end

-- ---- tasks ----------------------------------------------------------------------------------

-- Give a squad a task on an objective. Attackers face the objective; defenders keep their
-- facing (the direction the attack is expected from).
function LF.Objective.assign(squad, kind, obj)
    squad.task = { kind = kind, obj = obj.id }
    if kind == "attack" then
        local cx, cy = 0, 0
        local n = 0
        for _, rid in ipairs(LF.Units.members(squad.id)) do
            local r = LF.Records.get(rid)
            if r then cx, cy, n = cx + r.x, cy + r.y, n + 1 end
        end
        if n > 0 then
            local dx, dy = obj.x - cx / n, obj.y - cy / n
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0.5 then squad.facingX, squad.facingY = dx / len, dy / len end
        end
    end
    postsDone[squad.id] = nil
    LF.log("OBJECTIVE " .. squad.name .. " ordered to " .. kind .. " " .. obj.name)
end

function LF.Objective.taskOf(squad)
    local task = squad.task
    if not task then return nil end
    local obj = LF.Objective.get(task.obj)
    if not obj then return nil end
    return task.kind, obj
end

-- ---- ownership ------------------------------------------------------------------------------

local count = {}
local function countOne(e, _dsq, ctx)
    if e.body:isDead() or math.floor(e.body:getZ()) ~= ctx.z then return end
    count[e.rec.faction] = (count[e.rec.faction] or 0) + 1
end
local countCtx = {}

local FACTION_NAME = { GER = "Germans", SOV = "Soviets", CIV = "civilians" }

local function updateOwnership(obj)
    for k in pairs(count) do count[k] = nil end
    countCtx.z = obj.z
    LF.Sense.near(obj.x, obj.y, obj.radius, countOne, countCtx)
    local only, n = nil, 0
    for faction, c in pairs(count) do
        if c > 0 and faction ~= "CIV" then only = faction; n = n + 1 end
    end
    if n ~= 1 or only == obj.holder then return end
    local was = obj.holder
    obj.holder = only
    LF.log("OBJECTIVE " .. obj.name .. " taken by the " .. (FACTION_NAME[only] or only)
        .. (was and (" from the " .. (FACTION_NAME[was] or was)) or ""))
    -- The squads that were attacking it now hold it.
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "squad" and u.faction == only and u.task and u.task.obj == obj.id and u.task.kind == "attack" then
            LF.Objective.assign(u, "defend", obj)
            if LF.Tactics and LF.Tactics.taskChanged then LF.Tactics.taskChanged(u) end
        end
    end
end

local function onTick()
    if LF.tick % CFG.updateTicks ~= 0 then return end
    for _, obj in pairs(LF.Objective.all()) do LF.guard("objective", updateOwnership, obj) end
end
Events.OnTick.Add(onTick)

-- ---- label ----------------------------------------------------------------------------------

local COLORS = { GER = { 0.75, 0.8, 0.9 }, SOV = { 1.0, 0.55, 0.5 } }

local function drawLabels()
    local p = getPlayer()
    if not p then return end
    local zoom = getCore():getZoom(0)
    local tm = getTextManager()
    for _, obj in pairs(LF.Objective.all()) do
        if LF.distSq(obj.x, obj.y, p:getX(), p:getY()) < CFG.labelRange * CFG.labelRange then
            local sx, sy = isoToScreenX(0, obj.x, obj.y, obj.z), isoToScreenY(0, obj.x, obj.y, obj.z)
            local c = COLORS[obj.holder] or { 1, 1, 0.6 }
            local text = obj.name .. (obj.holder and (" - held by the " .. (FACTION_NAME[obj.holder] or obj.holder)) or " - contested")
            tm:DrawStringCentre(UIFont.Medium, sx, sy - 60 / zoom, text, c[1], c[2], c[3], 0.9)
        end
    end
end
Events.OnPostUIDraw.Add(function() LF.guard("draw objectives", drawLabels) end)
