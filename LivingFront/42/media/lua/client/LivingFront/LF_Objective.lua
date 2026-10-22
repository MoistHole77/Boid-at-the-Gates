-- Living Front: objectives - places to take and hold.
--
-- An objective is a point with a radius (often a building). A unit gets a task on it:
--   defend - the men take posts: in a building, standing in the windows (and doorways) that
--            face the enemy, a second man behind each front window, then the flank windows;
--            in the open, covered squares facing it. Men without a post wait a few tiles inside
--            as a reserve and step up when a post falls vacant. Posts are re-dealt against where
--            the enemy actually is. Defenders don't advance, reposition or flank.
--   attack - the unit marches on it and, once in a fight, storms it (LF_Tactics ASSAULT): the
--            bravo teams bound straight for the nearest entrance, the alpha teams swing round
--            a flank to another entrance; a pinned team waits, the rest keep going.
-- The objective's building doors are unlocked and opened when it is created.
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

function LF.Objective.clear()
    local data = store()
    data.objectives = {}
    data.nextObjectiveId = 1
    LF.Objective.forgetRuntime()
end

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
    if obj.building then LF.Objective.layout(obj) end
    return obj
end

-- ---- building layout ------------------------------------------------------------------------

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local layoutCache = {}     -- objective id -> { openings, inside, entrances, minX, maxX, minY, maxY }

-- Open (and unlock) a door so soldiers can path through it.
local function openDoor(door)
    if door.setLockedByKey then door:setLockedByKey(false) end
    if door.setLocked then door:setLocked(false) end
    if door.IsOpen and not door:IsOpen() and door.ToggleDoorSilent then door:ToggleDoorSilent() end
end

-- What the objective's building looks like: its openings (windows and doors to the outside,
-- each as the inside square, the outward direction and the kind), its inside squares, its
-- entrances (doorways: inside and outside square) and its extent. Cached per objective.
function LF.Objective.layout(obj)
    local L = layoutCache[obj.id]
    if L then return L end
    L = { openings = {}, inside = {}, entrances = {}, minX = obj.x, maxX = obj.x, minY = obj.y, maxY = obj.y }
    layoutCache[obj.id] = L
    if not obj.building then return L end
    local cell = getCell()
    local cx, cy, z = math.floor(obj.x), math.floor(obj.y), obj.z
    local R = obj.radius
    for x = cx - R, cx + R do
        for y = cy - R, cy + R do
            local sq = cell:getGridSquare(x, y, z)
            if sq and buildingId(sq) == obj.building then
                if x < L.minX then L.minX = x end
                if x + 1 > L.maxX then L.maxX = x + 1 end
                if y < L.minY then L.minY = y end
                if y + 1 > L.maxY then L.maxY = y + 1 end
                if sq:isFree(false) then
                    L.inside[#L.inside + 1] = { x = x, y = y }
                    for _, d in ipairs(DIRS) do
                        local nb = cell:getGridSquare(x + d[1], y + d[2], z)
                        if nb and buildingId(nb) ~= obj.building then
                            if sq:isWindowTo(nb) then
                                L.openings[#L.openings + 1] = { x = x, y = y, dx = d[1], dy = d[2], kind = "window" }
                            elseif sq:isDoorTo(nb) then
                                L.openings[#L.openings + 1] = { x = x, y = y, dx = d[1], dy = d[2], kind = "door" }
                                if nb:isFree(false) then
                                    L.entrances[#L.entrances + 1] = { ix = x, iy = y, ox = x + d[1], oy = y + d[2], dx = d[1], dy = d[2] }
                                end
                                local door = sq:getDoorTo(nb)
                                if door then LF.guard("open door", openDoor, door) end
                            end
                        end
                    end
                end
            end
        end
    end
    LF.log("OBJECTIVE " .. obj.name .. " layout: " .. #L.openings .. " windows/doors, " .. #L.entrances
        .. " entrances (doors unlocked and opened), " .. #L.inside .. " squares inside")
    return L
end

-- ---- posts ----------------------------------------------------------------------------------
--
-- Posts, best first, against a threat from direction (fx, fy):
--   window squares facing the threat (a man stands in the window and fires out of it),
--   then doorways, then the square behind a front window (a second man fires past the first),
--   then windows on the flanks. Windows facing away from the threat are kept for when it moves.
-- Men left over wait as a reserve a few tiles inside behind the front posts (each on his own
-- square) and step up to a post when its man falls.
-- Posts are re-dealt every few seconds against where the enemy actually is, so the defence
-- turns to face a flank. A man keeps his post unless a better one needs him.

local postCache = {}       -- record id -> post { x, y, z, ox, oy (a point out of the window), reserve }
local postsAt = {}         -- squad id -> tick posts were last dealt

local function computePosts(obj, fx, fy)
    local list = {}
    local cell = getCell()
    local z = obj.z
    if obj.building then
        local L = LF.Objective.layout(obj)
        for _, o in ipairs(L.openings) do
            local facing = o.dx * fx + o.dy * fy     -- 1 = straight at the threat
            local score = facing + (o.kind == "window" and 0.5 or 0.1)
            list[#list + 1] = { x = o.x, y = o.y, z = z, score = score, ox = o.x + 0.5 + o.dx * 8, oy = o.y + 0.5 + o.dy * 8 }
            -- Second rank behind a window that faces the threat.
            if o.kind == "window" and facing > 0.3 then
                local bx, by = o.x - o.dx, o.y - o.dy
                local bsq = cell:getGridSquare(bx, by, z)
                if bsq and bsq:isFree(false) and buildingId(bsq) == obj.building and not bsq:isWallTo(cell:getGridSquare(o.x, o.y, z)) then
                    list[#list + 1] = { x = bx, y = by, z = z, score = facing - 0.45, ox = o.x + 0.5 + o.dx * 8, oy = o.y + 0.5 + o.dy * 8 }
                end
            end
        end
    else
        local cx, cy = math.floor(obj.x), math.floor(obj.y)
        local R = obj.radius
        for x = cx - R, cx + R do
            for y = cy - R, cy + R do
                local sq = cell:getGridSquare(x, y, z)
                if sq and sq:isFree(false) and LF.distSq(x + 0.5, y + 0.5, obj.x, obj.y) <= R * R then
                    local q = LF.Cover.quality(x, y, z, obj.x + fx * 15, obj.y + fy * 15)
                    if q ~= LF.Cover.NONE then
                        list[#list + 1] = { x = x, y = y, z = z, score = q + ((x - cx) * fx + (y - cy) * fy) / R,
                                            ox = x + 0.5 + fx * 8, oy = y + 0.5 + fy * 8 }
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    return list
end

-- Reserve spots: inside squares a few tiles back from the threat side, not on a post.
local function reserveSpots(obj, fx, fy, taken)
    local out = {}
    if not obj.building then return out end
    local L = LF.Objective.layout(obj)
    local front = -math.huge
    for _, s in ipairs(L.inside) do
        local f = (s.x + 0.5 - obj.x) * fx + (s.y + 0.5 - obj.y) * fy
        if f > front then front = f end
    end
    for _, s in ipairs(L.inside) do
        if not taken[s.x .. "," .. s.y] then
            local f = (s.x + 0.5 - obj.x) * fx + (s.y + 0.5 - obj.y) * fy
            -- Best about 3 tiles back from the front wall.
            out[#out + 1] = { x = s.x, y = s.y, z = obj.z, score = -math.abs(front - 3 - f), reserve = true,
                              ox = s.x + 0.5 + fx * 8, oy = s.y + 0.5 + fy * 8 }
        end
    end
    table.sort(out, function(a, b) return a.score > b.score end)
    return out
end

local function posOf(rid)
    local b = LF.Bodies.get(rid)
    if b then return b:getX(), b:getY() end
    local r = LF.Records.get(rid)
    return r.x, r.y
end

-- Deal a defending squad's posts against a threat from (fx, fy). Each post, best first, goes
-- to the nearest man not yet posted (a man already on it is preferred); the sergeant goes last.
local function assignPosts(squad, obj, fx, fy, why)
    local posts = computePosts(obj, fx, fy)
    local men, sgt = {}, nil
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r and r.alive and not r.wounded then
            if rid == squad.leader then sgt = rid else men[#men + 1] = rid end
        end
    end
    if sgt then men[#men + 1] = sgt end
    local free = {}
    for i, rid in ipairs(men) do free[i] = rid end
    local taken = {}
    local given = 0
    local new = {}
    for _, p in ipairs(posts) do
        if #free == 0 or p.score <= -0.5 then break end
        local bestI, bestD = nil, math.huge
        for i, rid in ipairs(free) do
            local x, y = posOf(rid)
            local d = LF.dist(x, y, p.x + 0.5, p.y + 0.5)
            local cur = postCache[rid]
            if cur and not cur.reserve and cur.x == p.x and cur.y == p.y then d = d - 100 end
            if rid == sgt and #free > 1 then d = d + 1000 end     -- the sergeant takes a post last
            if d < bestD then bestI, bestD = i, d end
        end
        local rid = table.remove(free, bestI)
        new[rid] = p
        taken[p.x .. "," .. p.y] = true
        given = given + 1
    end
    local spots = reserveSpots(obj, fx, fy, taken)
    for i, rid in ipairs(free) do
        new[rid] = spots[i]          -- nil (the objective's centre) if the building is full
    end
    -- Forget this squad's old posts (including the fallen's), then hand out the new ones.
    for rid in pairs(postCache) do
        local r = LF.Records.get(rid)
        if not r or r.squad == squad.id then postCache[rid] = nil end
    end
    for rid, p in pairs(new) do postCache[rid] = p end
    postsAt[squad.id] = LF.tick
    if why then
        LF.log("OBJECTIVE " .. squad.name .. " takes up " .. given .. " posts at " .. obj.name .. " ("
            .. #posts .. " found, " .. #free .. " in reserve) - " .. why)
    end
end

-- Re-deal the posts against where the enemy is (every few seconds, and whenever a posted man
-- has fallen). (tx, ty): the enemy's last-known position, or nil.
function LF.Objective.updatePosts(squad, obj, tx, ty)
    local fx, fy = squad.facingX or 1, squad.facingY or 0
    if tx then
        local dx, dy = tx - obj.x, ty - obj.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 2 then fx, fy = dx / len, dy / len end
    end
    local last = postsAt[squad.id]
    local vacant = false
    if last then
        for rid, p in pairs(postCache) do
            if not p.reserve then
                local r = LF.Records.get(rid)
                if r and r.squad == squad.id and (not r.alive or r.wounded) then vacant = true; break end
            end
        end
    end
    if not last then
        assignPosts(squad, obj, fx, fy, "first posting")
    elseif vacant then
        assignPosts(squad, obj, fx, fy, "a post fell vacant")
    elseif LF.tick - last >= 300 then
        assignPosts(squad, obj, fx, fy, nil)
    end
end

-- A defender's post: x, y, z, isPost, outX, outY (a point outside to face).
function LF.Objective.postFor(rec, squad, obj)
    if not postsAt[squad.id] then LF.Objective.updatePosts(squad, obj) end
    local p = postCache[rec.id]
    if p then return p.x + 0.5, p.y + 0.5, p.z, not p.reserve, p.ox, p.oy end
    return obj.x, obj.y, obj.z, false, obj.x + (squad.facingX or 1) * 8, obj.y + (squad.facingY or 0) * 8
end

-- Where attackers go in: entrances sorted by how near they are to (x, y). Each is
-- { ix, iy (inside), ox, oy (outside), dx, dy (outward) }.
function LF.Objective.entrances(obj)
    return LF.Objective.layout(obj).entrances
end

function LF.Objective.forgetRuntime()
    postCache, postsAt, layoutCache = {}, {}, {}
end
Events.OnInitGlobalModData.Add(function() LF.Objective.forgetRuntime() end)

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
    postsAt[squad.id] = nil
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
