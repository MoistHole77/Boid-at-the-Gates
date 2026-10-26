-- Living Front: sectors, the front line, and what each side knows (roadmap phase 5, steps A and B).
--
-- A. A SECTOR is the ground around an objective: every point within CFG.reach tiles of an
--    objective belongs to the nearest one (so neighbouring objectives split the ground between
--    them, and country far from any objective is no one's sector). A sector is held by whoever
--    holds its objective, and contested while the objective is - walking in takes nothing: to
--    take a sector and move the front line you have to take and hold its objective. The front
--    line is every border between a German and a Soviet sector. A sector changing sides is an
--    event in the log ("sector").
--    The shapes are worked out on a CFG.cell-tile grid, once each time objectives are added,
--    moved or removed (not every pass): strips to fill, and borders between sectors.
--
-- B. Neither side sees the truth. Each keeps SIGHTINGS of the enemy's units - where, how many fit
--    men, when - refreshed when one of its units is within sight of them or in contact with them,
--    and forgotten after CFG.forget seconds. Each side also keeps what it believes of every
--    OBJECTIVE (holder, name): its own it knows, another only once one of its units has it in
--    sight; otherwise as last seen. Its picture of the sectors follows from that, so a side's map
--    lags behind what really happened - the commanders (step C) will plan on it.
--
-- Cost: one pass over the units every CFG.passTicks, a unit-to-unit sight check between the two
-- sides, and a unit-to-objective one; the sector shapes only when the objectives change.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Objective"
require "LivingFront/World/LF_Clash"

LF.Front = LF.Front or {}

local CFG = {
    reach = 120,            -- tiles: an objective's sector reaches this far at most
    cell = 10,              -- tiles: the grid the sector shapes are worked out on
    passTicks = 300,        -- how often sectors and sightings are brought up to date
    sight = 40,             -- tiles: a unit sees an enemy unit (or an objective) this close
    fresh = 600,            -- simulated seconds a sighting counts as fresh ...
    forget = 3 * 3600,      -- ... and is forgotten after
}
LF.Front.CFG = CFG

local SIDES = { "GER", "SOV" }
local ENEMY = { GER = "SOV", SOV = "GER" }
LF.Front.ENEMY = ENEMY

local function store()
    local d = LF.Records.data()
    d.front = d.front or {}
    local f = d.front
    f.version = f.version or 0
    if f.version < 2 then
        -- (0.63's grid sectors are replaced by objective sectors: start their table afresh.)
        f.sectors, f.belief, f.version = {}, { GER = {}, SOV = {} }, 2
    end
    f.sectors = f.sectors or {}
    f.sight = f.sight or { GER = {}, SOV = {} }
    f.belief = f.belief or { GER = {}, SOV = {} }
    f.objBelief = f.objBelief or { GER = {}, SOV = {} }
    return f
end

-- ---- sector shapes ------------------------------------------------------------------------------

local function centreOf(obj)
    if obj.bounds then return (obj.bounds[1] + obj.bounds[3]) / 2, (obj.bounds[2] + obj.bounds[4]) / 2 end
    return obj.x, obj.y
end

local shape = { sig = nil, cells = {}, runs = {}, edges = {} }

-- A fingerprint of the objectives' places: the shapes are worked out again when it changes.
local function signature()
    local parts = {}
    for id, obj in pairs(LF.Objective.all()) do
        local x, y = centreOf(obj)
        parts[#parts + 1] = tostring(id) .. "@" .. math.floor(x) .. "," .. math.floor(y)
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function rebuild()
    local C, R = CFG.cell, CFG.reach
    local objs = {}
    for id, obj in pairs(LF.Objective.all()) do
        local x, y = centreOf(obj)
        objs[#objs + 1] = { key = tostring(id), x = x, y = y }
    end
    -- Each cell within reach of an objective: the nearest one's.
    local cells = {}
    local reachSq = R * R
    for _, o in ipairs(objs) do
        local cx1, cy1 = math.floor((o.x - R) / C), math.floor((o.y - R) / C)
        local cx2, cy2 = math.floor((o.x + R) / C), math.floor((o.y + R) / C)
        for cy = cy1, cy2 do
            local row = cells[cy]
            if not row then row = {}; cells[cy] = row end
            for cx = cx1, cx2 do
                if row[cx] == nil then
                    local px, py = (cx + 0.5) * C, (cy + 0.5) * C
                    local best, bd = nil, reachSq
                    for _, q in ipairs(objs) do
                        local d = LF.distSq(px, py, q.x, q.y)
                        if d <= bd then best, bd = q.key, d end
                    end
                    row[cx] = best or false
                end
            end
        end
    end
    -- Strips: a row's run of cells of one sector, as one box to fill.
    local runs = {}
    for cy, row in pairs(cells) do
        local xs = {}
        for cx in pairs(row) do xs[#xs + 1] = cx end
        table.sort(xs)
        local start, key, last = nil, nil, nil
        local function flush()
            if key then runs[#runs + 1] = { key = key, x1 = start * C, y1 = cy * C, x2 = (last + 1) * C, y2 = (cy + 1) * C } end
        end
        for _, cx in ipairs(xs) do
            local k = row[cx]
            if k and k == key and cx == last + 1 then last = cx
            else
                flush()
                if k then start, key, last = cx, k, cx else key = nil end
            end
        end
        flush()
    end
    -- Borders between two sectors (a, b), joined into straight runs.
    local edges = {}
    local function keyAtCell(cx, cy) local row = cells[cy]; return row and row[cx] or false end
    for cy, row in pairs(cells) do
        for cx, k in pairs(row) do
            if k then
                local r = keyAtCell(cx + 1, cy)
                if r and r ~= k then edges[#edges + 1] = { a = k, b = r, x1 = (cx + 1) * C, y1 = cy * C, x2 = (cx + 1) * C, y2 = (cy + 1) * C } end
                local d = keyAtCell(cx, cy + 1)
                if d and d ~= k then edges[#edges + 1] = { a = k, b = d, x1 = cx * C, y1 = (cy + 1) * C, x2 = (cx + 1) * C, y2 = (cy + 1) * C } end
            end
        end
    end
    -- (Join neighbouring pieces of the same border into one line: fewer lines to draw.)
    table.sort(edges, function(p, q)
        local pv, qv = p.x1 == p.x2, q.x1 == q.x2
        if pv ~= qv then return pv end
        if pv then
            if p.x1 ~= q.x1 then return p.x1 < q.x1 end
            return p.y1 < q.y1
        end
        if p.y1 ~= q.y1 then return p.y1 < q.y1 end
        return p.x1 < q.x1
    end)
    local joined = {}
    for _, e in ipairs(edges) do
        local l = joined[#joined]
        if l and l.a == e.a and l.b == e.b and l.x2 == e.x1 and l.y2 == e.y1 and ((l.x1 == l.x2) == (e.x1 == e.x2)) then
            l.x2, l.y2 = e.x2, e.y2
        else
            joined[#joined + 1] = { a = e.a, b = e.b, x1 = e.x1, y1 = e.y1, x2 = e.x2, y2 = e.y2 }
        end
    end
    shape.cells, shape.runs, shape.edges = cells, runs, joined
    LF.log("FRONT sectors laid out: " .. #objs .. " objective(s), " .. #runs .. " strips, " .. #joined .. " border lines")
end

local function ensureShape()
    if shape.checked == LF.tick and shape.sig then return end     -- (once a tick is plenty)
    shape.checked = LF.tick
    local sig = signature()
    if sig ~= shape.sig then
        shape.sig = sig
        LF.guard("front shapes", rebuild)
    end
end

-- The sector at a point (its key: the objective's id as a string), or nil.
function LF.Front.keyAt(x, y)
    ensureShape()
    local row = shape.cells[math.floor(y / CFG.cell)]
    local k = row and row[math.floor(x / CFG.cell)]
    return k or nil
end

-- ---- who holds what -------------------------------------------------------------------------------

local units = {}            -- this pass: { u, x, y, fit, faction }

-- The fighting units, where their men are, and how many are fit.
local function survey()
    local out = {}
    for _, u in pairs(LF.Units.all()) do
        if ((u.kind == "squad" and not u.joined) or u.kind == "hq") and ENEMY[u.faction] then
            local sx, sy, n, fit = 0, 0, 0, 0
            for _, rid in ipairs(LF.Units.members(u.id)) do
                local r = LF.Records.get(rid)
                if r and r.alive and not r.captured then
                    local b = LF.Bodies and LF.Bodies.get(rid)
                    local x, y = r.x, r.y
                    if b and not b:isDead() then x, y = b:getX(), b:getY() end
                    if x and y then
                        sx, sy, n = sx + x, sy + y, n + 1
                        if not r.wounded then fit = fit + 1 end
                    end
                end
            end
            if n > 0 then out[#out + 1] = { u = u, x = sx / n, y = sy / n, fit = fit, faction = u.faction } end
        end
    end
    return out
end

local function updateSectors()
    ensureShape()
    local S = store().sectors
    -- Who is in each (for the commanders: how many fit men of each side).
    local men = {}
    for _, e in ipairs(units) do
        local key = LF.Front.keyAt(e.x, e.y)
        if key then
            local m = men[key] or { GER = 0, SOV = 0 }
            m[e.faction] = m[e.faction] + e.fit
            men[key] = m
        end
    end
    for id, obj in pairs(LF.Objective.all()) do
        local key = tostring(id)
        local s = S[key]
        if not s then s = { owner = nil, since = LF.simTime }; S[key] = s end
        local owner = (obj.holder and ENEMY[obj.holder]) and obj.holder or nil
        if owner ~= s.owner then
            if s.owner and owner and LF.Clash and LF.Clash.note then
                local x, y = centreOf(obj)
                LF.log("FRONT the sector of " .. (obj.name or "?") .. " taken: " .. s.owner .. " -> " .. owner)
                LF.Clash.note("sector", { sector = key, obj = id, from = s.owner, to = owner, x = math.floor(x), y = math.floor(y) })
            end
            s.owner, s.since = owner, LF.simTime
        end
        s.contested = obj.contested and true or nil
        s.name = obj.name
        s.men = men[key]
    end
    for key in pairs(S) do
        if not LF.Objective.get(tonumber(key)) then S[key] = nil end
    end
end

-- ---- what each side knows ------------------------------------------------------------------------

local function see(side, e, how)
    local S = store().sight[side]
    S[e.u.id] = { x = math.floor(e.x), y = math.floor(e.y), men = e.fit, at = LF.simTime, how = how,
                  kind = e.u.kind }
end

local function updateSightings()
    local byId = {}
    for _, e in ipairs(units) do byId[e.u.id] = e end
    -- Within sight of one of ours.
    local sightSq = CFG.sight * CFG.sight
    for _, a in ipairs(units) do
        if a.fit > 0 then
            for _, b in ipairs(units) do
                if b.faction == ENEMY[a.faction] and LF.distSq(a.x, a.y, b.x, b.y) <= sightSq then
                    see(a.faction, b, "seen")
                end
            end
        end
    end
    -- In contact (the off-screen fights say who is fighting whom).
    for _, a in ipairs(units) do
        local u = a.u
        if u.offContactAt and LF.simTime - u.offContactAt < 30 and u.offContactAt <= LF.simTime and u.offContactBy then
            local b = byId[u.offContactBy]
            if b then see(a.faction, b, "contact") end
        end
    end
    -- Forget old sightings, and ones of units that are gone.
    for _, side in ipairs(SIDES) do
        local S = store().sight[side]
        for id, s in pairs(S) do
            if LF.simTime - s.at > CFG.forget or s.at > LF.simTime or not LF.Units.get(id) then S[id] = nil end
        end
    end
end

-- Contact events from the fights refresh the picture at once (they say who met whom).
local lastSeq = nil
local function readEvents()
    local data = LF.Records.data()
    local seq = data.lfEventSeq or 0
    if lastSeq == nil then lastSeq = seq end
    if seq <= lastSeq then return end
    local byId = {}
    for _, e in ipairs(units) do byId[e.u.id] = e end
    for _, ev in ipairs(LF.Clash.events()) do
        if ev.seq and ev.seq > lastSeq and ev.kind == "contact" and ev.unit and ev.by then
            local a, b = byId[ev.unit], byId[ev.by]
            if a and b then see(a.faction, b, "contact"); see(b.faction, a, "contact") end
        end
    end
    lastSeq = seq
end

-- The enemy a side believes is in a sector: fit men (as last seen) and how old the news is.
function LF.Front.believedEnemy(side, key)
    local men, newest = 0, nil
    for _, s in pairs(store().sight[side] or {}) do
        if LF.Front.keyAt(s.x, s.y) == key then
            men = men + s.men
            local age = LF.simTime - s.at
            if not newest or age < newest then newest = age end
        end
    end
    return men, newest
end

-- What each side believes of each objective: who holds it and what it is called. Its own it
-- knows; another it learns by having a unit within sight of it; otherwise it remembers what it
-- last saw (a new objective: as it stood when it appeared).
local function updateObjectives()
    local sightSq = CFG.sight * CFG.sight
    for _, side in ipairs(SIDES) do
        local OB = store().objBelief[side]
        for id, obj in pairs(LF.Objective.all()) do
            local knows = obj.holder == side or not OB[id]
            if not knows then
                for _, e in ipairs(units) do
                    if e.faction == side and e.fit > 0 and LF.distSq(e.x, e.y, obj.x, obj.y) <= sightSq then
                        knows = true
                        break
                    end
                end
            end
            if knows then
                local b = OB[id]
                if not b or b.holder ~= obj.holder or b.name ~= obj.name or (b.contested or false) ~= (obj.contested or false) then
                    OB[id] = { holder = obj.holder, name = obj.name, contested = obj.contested or nil, at = LF.simTime }
                end
            end
        end
        for id in pairs(OB) do if not LF.Objective.get(id) then OB[id] = nil end end
    end
end

-- A side's picture of the sectors: who it believes holds each objective.
local function updateBelief()
    for _, side in ipairs(SIDES) do
        local B, OB = {}, store().objBelief[side]
        for id in pairs(LF.Objective.all()) do
            local b = OB[id]
            if b then
                B[tostring(id)] = { owner = b.contested and "contested" or ((b.holder and ENEMY[b.holder]) and b.holder or nil), at = b.at }
            end
        end
        store().belief[side] = B
    end
end

local function pass()
    units = survey()
    updateSectors()
    readEvents()
    updateSightings()
    updateObjectives()
    updateBelief()
end

-- What a side believes of an objective: { holder, name, contested, at } (nil: never heard of it).
function LF.Front.objectiveBelief(side, id)
    local OB = store().objBelief[side]
    return OB and OB[id] or nil
end

Events.OnTick.Add(function()
    if LF.tick % CFG.passTicks ~= 151 then return end
    LF.guard("front", pass)
end)
Events.OnInitGlobalModData.Add(function() lastSeq = nil; units = {}; shape.sig = nil end)

-- ---- for the map and the commanders -----------------------------------------------------------

function LF.Front.sectors() return store().sectors end
function LF.Front.sightings(side) return store().sight[side] or {} end
function LF.Front.belief(side) return store().belief[side] or {} end

-- Who holds a sector, really: "GER" / "SOV" / nil, and whether it's contested.
function LF.Front.owner(key)
    local s = store().sectors[key]
    if not s then return nil, false end
    return s.owner, s.contested == true
end

-- Who holds each sector, in a view: "truth", or a side ("GER" / "SOV") for what it believes.
-- key -> "GER" / "SOV" / "contested" / nil.
function LF.Front.owners(view)
    local own = {}
    if view == "GER" or view == "SOV" then
        for key, b in pairs(store().belief[view]) do own[key] = b.owner end
    else
        for key, s in pairs(store().sectors) do own[key] = s.contested and "contested" or s.owner end
    end
    return own
end

-- The sector shapes, to draw: strips { key, x1, y1, x2, y2 } and borders { a, b, x1, y1, x2, y2 }.
function LF.Front.shapes()
    ensureShape()
    return shape.runs, shape.edges
end

-- The front line in a view: the borders between a German and a Soviet sector.
function LF.Front.line(view)
    local own = LF.Front.owners(view)
    local out = {}
    local _, edges = LF.Front.shapes()
    for _, e in ipairs(edges) do
        local a, b = own[e.a], own[e.b]
        if (a == "GER" and b == "SOV") or (a == "SOV" and b == "GER") then out[#out + 1] = { e.x1, e.y1, e.x2, e.y2 } end
    end
    return out
end
