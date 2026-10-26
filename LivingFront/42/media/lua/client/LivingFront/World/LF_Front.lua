-- Living Front: sectors, the front line, and what each side knows (roadmap phase 5, steps A and B).
--
-- A. The ground is split into square sectors (CFG.size tiles). A sector exists once a unit or an
--    objective has been in it, so empty country costs nothing. Every pass (a few seconds) each
--    sector is HELD by the side with fit men in it, CONTESTED if both sides have, and otherwise
--    stays with whoever held it last - ground is yours until the enemy walks in. A held objective
--    holds its sector while no enemy is there. The front line is every edge between a German and
--    a Soviet sector; a sector changing hands is an event in the log ("sector").
--
-- B. Neither side sees the truth. Each keeps SIGHTINGS of the enemy's units - where, how many fit
--    men, when - refreshed when one of its units is within sight of them or in contact with them,
--    and forgotten after CFG.forget seconds. From those each side keeps its own BELIEF of who holds
--    each sector: its own ground it knows; enemy ground only where it has seen the enemy; and a
--    sector it last saw as the enemy's stays the enemy's in its mind until it sees otherwise.
--    So a side's map lags behind what really happened - the commanders (step C) will plan on it.
--
-- Cost: one pass over the units (not the men one by one more than once) every CFG.passTicks, and a
-- unit-to-unit sight check between the two sides; nothing per frame except drawing the map.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Objective"
require "LivingFront/World/LF_Clash"

LF.Front = LF.Front or {}

local CFG = {
    size = 50,              -- tiles a side
    passTicks = 300,        -- how often sectors and sightings are brought up to date
    sight = 40,             -- tiles: a unit sees an enemy unit this close (cover, buildings aside)
    fresh = 600,            -- simulated seconds a sighting counts as fresh ...
    forget = 3 * 3600,      -- ... and is forgotten after
    minMen = 1,             -- fit men that make a presence
}
LF.Front.CFG = CFG

local SIDES = { "GER", "SOV" }
local ENEMY = { GER = "SOV", SOV = "GER" }
LF.Front.ENEMY = ENEMY

local function store()
    local d = LF.Records.data()
    d.front = d.front or { sectors = {}, sight = { GER = {}, SOV = {} }, belief = { GER = {}, SOV = {} } }
    local f = d.front
    f.sectors = f.sectors or {}
    f.sight = f.sight or { GER = {}, SOV = {} }
    f.belief = f.belief or { GER = {}, SOV = {} }
    f.objBelief = f.objBelief or { GER = {}, SOV = {} }
    return f
end

-- ---- sectors ----------------------------------------------------------------------------------

local function cellOf(x, y) return math.floor(x / CFG.size), math.floor(y / CFG.size) end
local function keyOf(cx, cy) return cx .. "," .. cy end
function LF.Front.keyAt(x, y) return keyOf(cellOf(x, y)) end
function LF.Front.cellOfKey(key)
    local a, b = key:match("^(%-?%d+),(%-?%d+)$")
    return tonumber(a), tonumber(b)
end
-- The square of a sector in world tiles: x1, y1, x2, y2.
function LF.Front.bounds(key)
    local cx, cy = LF.Front.cellOfKey(key)
    return cx * CFG.size, cy * CFG.size, (cx + 1) * CFG.size, (cy + 1) * CFG.size
end

local function sector(key)
    local S = store().sectors
    local s = S[key]
    if not s then s = { owner = nil, since = LF.simTime }; S[key] = s end
    return s
end

-- Runtime picture of this pass: key -> { GER = fit men, SOV = fit men, units = { ... } }
local present = {}
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
    present = {}
    for _, e in ipairs(units) do
        if e.fit >= CFG.minMen then
            local key = LF.Front.keyAt(e.x, e.y)
            local p = present[key] or { GER = 0, SOV = 0 }
            p[e.faction] = p[e.faction] + e.fit
            present[key] = p
        end
    end
    -- Objectives hold their ground.
    local held = {}
    for _, obj in pairs(LF.Objective.all()) do
        local key = LF.Front.keyAt(obj.x, obj.y)
        sector(key)
        if obj.holder and ENEMY[obj.holder] and not obj.contested then held[key] = obj.holder end
    end
    for key in pairs(present) do sector(key) end
    for key, s in pairs(store().sectors) do
        local p = present[key]
        local g, v = p and p.GER or 0, p and p.SOV or 0
        local owner, contested = s.owner, false
        if g > 0 and v > 0 then contested = true
        elseif g > 0 then owner = "GER"
        elseif v > 0 then owner = "SOV"
        elseif held[key] then owner = held[key] end
        if owner ~= s.owner then
            local x1, y1, x2, y2 = LF.Front.bounds(key)
            -- (Only ground changing sides is news: a march claiming empty country is not, and would
            -- crowd the fights out of the event log.)
            if s.owner and owner and LF.Clash and LF.Clash.note then
                LF.log("FRONT sector " .. key .. " taken: " .. s.owner .. " -> " .. owner)
                LF.Clash.note("sector", { sector = key, from = s.owner, to = owner,
                                          x = math.floor((x1 + x2) / 2), y = math.floor((y1 + y2) / 2) })
            end
            s.owner, s.since = owner, LF.simTime
        end
        s.contested = contested or nil
        s.men = p and { GER = g, SOV = v } or nil
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

local function updateBelief()
    for _, side in ipairs(SIDES) do
        local B = store().belief[side]
        local enemy = ENEMY[side]
        -- Fresh enemy, per sector.
        local seen = {}
        for _, s in pairs(store().sight[side]) do
            if LF.simTime - s.at <= CFG.fresh then
                local key = LF.Front.keyAt(s.x, s.y)
                seen[key] = (seen[key] or 0) + s.men
            end
        end
        for key, sec in pairs(store().sectors) do
            local mine = sec.men and sec.men[side] or 0
            local b = B[key]
            local was = b and b.owner
            local now = was
            if mine > 0 and (seen[key] or 0) > 0 then now = "contested"
            elseif mine > 0 then now = side
            elseif (seen[key] or 0) > 0 then now = enemy
            elseif sec.owner == side then now = side            -- (our own ground we know is ours)
            elseif was == "contested" then now = enemy          -- (we left it with them in it)
            end
            if now ~= was or not b then
                B[key] = { owner = now, at = LF.simTime }
            end
        end
    end
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

local function pass()
    units = survey()
    updateSectors()
    readEvents()
    updateSightings()
    updateBelief()
    updateObjectives()
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
Events.OnInitGlobalModData.Add(function() lastSeq = nil; present = {}; units = {} end)

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

-- The front line: the edges between sectors held by the two sides, as { x1, y1, x2, y2 } in tiles.
-- view: "truth", or a side ("GER" / "SOV") for the line as that side believes it is.
function LF.Front.line(view)
    local own = {}
    if view == "GER" or view == "SOV" then
        for key, b in pairs(store().belief[view]) do own[key] = b.owner end
    else
        for key, s in pairs(store().sectors) do own[key] = s.contested and "contested" or s.owner end
    end
    local out = {}
    local size = CFG.size
    for key, o in pairs(own) do
        if o == "GER" then
            local cx, cy = LF.Front.cellOfKey(key)
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                if own[keyOf(cx + d[1], cy + d[2])] == "SOV" then
                    local x1, y1 = cx * size, cy * size
                    if d[1] == 1 then out[#out + 1] = { x1 + size, y1, x1 + size, y1 + size }
                    elseif d[1] == -1 then out[#out + 1] = { x1, y1, x1, y1 + size }
                    elseif d[2] == 1 then out[#out + 1] = { x1, y1 + size, x1 + size, y1 + size }
                    else out[#out + 1] = { x1, y1, x1 + size, y1 } end
                end
            end
        end
    end
    return out
end
