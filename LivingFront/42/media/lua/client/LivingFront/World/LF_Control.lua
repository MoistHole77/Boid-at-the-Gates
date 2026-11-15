-- Living Front: control - who holds which part of the city, finer than the sectors (0.88, strategic layer S1).
--
-- Three levels (docs/strategic-layer.md, "Control and the front line"):
--   1. SECTIONS. Every building of the district (the sites file, LF_Sites_*, made by the map
--      pipeline) is cut into sections - its stair sections or wings, or the whole of a small one.
--      A section belongs to the side whose fit men are in it; with both sides in it, it is
--      contested (and keeps its owner); with nobody, it keeps its last owner. It changes hands only
--      when one side has had it to itself for CFG.holdFor simulated seconds - men walking through
--      don't take it.
--   2. THE CONTROL MAP. A grid over the district at CFG.cell tiles: a building's cells follow its
--      sections; open ground goes to the side whose held buildings are nearest (within CFG.reach),
--      and where both sides' buildings are about as near it is no-man's land.
--   3. SECTORS (LF_Front, LF_District) are still held through their objectives; here only each
--      side's share of a sector's buildings, for the district panel.
-- Sections are looked at every CFG.every simulated seconds, only where there are men; the grid is
-- worked out again only when a section changes hands. Owners are saved (with the battle's data).

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Bodies"
require "LivingFront/World/LF_Sites_DowntownNorth"

LF.Control = LF.Control or {}

local CFG = {
    every = 5,              -- simulated seconds between looks at the sections
    holdFor = 60,           -- simulated seconds a side must have a section to itself to take it
    cell = 4,               -- tiles: the control map's grid
    reach = 28,             -- tiles: open ground belongs to held buildings this close
    band = 10,              -- tiles: both sides' buildings within this of the same distance - no-man's land
    show = false,           -- the control map on the world map (debug tools)
    alpha = 0.22,
}
LF.Control.CFG = CFG

local SITES = LF.Sites.downtown_north
local SIDES = { GER = true, SOV = true }

-- ---- the sites -------------------------------------------------------------------------------------

local byId, bucket = nil, nil
local BUCKET = 16
local function index()
    if byId then return end
    byId, bucket = {}, {}
    for _, s in ipairs(SITES) do
        byId[s.id] = s
        for k, p in ipairs(s.parts) do
            for bx = math.floor(p[1] / BUCKET), math.floor(p[3] / BUCKET) do
                for by = math.floor(p[2] / BUCKET), math.floor(p[4] / BUCKET) do
                    local key = bx * 4096 + by
                    bucket[key] = bucket[key] or {}
                    table.insert(bucket[key], { s = s, k = k, p = p })
                end
            end
        end
    end
end

function LF.Control.sites() return SITES end
function LF.Control.site(id) index(); return byId[id] end

-- The site and section at (x, y), or nil.
function LF.Control.partAt(x, y)
    index()
    x, y = math.floor(x), math.floor(y)
    local list = bucket[math.floor(x / BUCKET) * 4096 + math.floor(y / BUCKET)]
    if not list then return nil end
    for _, e in ipairs(list) do
        local p = e.p
        if x >= p[1] and x <= p[3] and y >= p[2] and y <= p[4] then return e.s, e.k end
    end
    return nil
end

-- The site whose box holds (x, y) (any section), or nil.
function LF.Control.siteAt(x, y)
    local s = LF.Control.partAt(x, y)
    if s then return s end
    index()
    x, y = math.floor(x), math.floor(y)
    for _, e in ipairs(bucket[math.floor(x / BUCKET) * 4096 + math.floor(y / BUCKET)] or {}) do
        local b = e.s.box
        if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then return e.s end
    end
    return nil
end

-- A signature of the sites file: a save made with other sites (the map regenerated) starts afresh.
local sigCache = nil
local function signature()
    if sigCache then return sigCache end
    local n, t = 0, 0
    for _, s in ipairs(SITES) do n = n + 1; t = (t + s.box[1] * 3 + s.box[2] * 7 + s.box[3] * 11 + s.box[4] * 13 + #s.parts) % 1000003 end
    sigCache = n .. ":" .. t
    return sigCache
end

-- ---- saved state ---------------------------------------------------------------------------------

local cachedStore = nil
local function store()
    local d = LF.Records.data()
    if cachedStore and d.control == cachedStore then return cachedStore end
    d.control = d.control or {}
    local c = d.control
    cachedStore = c
    local sig = signature()
    if c.sig ~= sig then
        if c.sig then LF.log("CONTROL the sites have changed (the map was regenerated) - control starts afresh") end
        c.sig, c.own, c.pend, c.contest, c.version = sig, {}, {}, {}, 1
    end
    return c
end

local function key(id, k) return id .. ":" .. k end

local dirty = true
local rev = 0               -- (bumped whenever a section changes hands: the shares are cached by it)
Events.OnInitGlobalModData.Add(function() dirty = true; byId = nil; rev = rev + 1 end)

function LF.Control.owner(id, k) return store().own[key(id, k)] end
function LF.Control.contested(id, k) return store().contest[key(id, k)] == true end

function LF.Control.set(id, k, side)
    local s = store()
    s.own[key(id, k)] = side
    s.pend[key(id, k)] = nil
    dirty, rev = true, rev + 1
end

function LF.Control.clear()
    local s = store()
    s.own, s.pend, s.contest = {}, {}, {}
    dirty, rev = true, rev + 1
end

-- A building's owner: "GER" / "SOV" (all its sections), "split" (both sides hold sections), nil.
function LF.Control.siteOwner(site)
    local ger, sov, n = 0, 0, 0
    for k in ipairs(site.parts) do
        local o = LF.Control.owner(site.id, k)
        n = n + 1
        if o == "GER" then ger = ger + 1 elseif o == "SOV" then sov = sov + 1 end
    end
    if ger > 0 and sov > 0 then return "split" end
    if ger > 0 then return "GER" end
    if sov > 0 then return "SOV" end
    return nil
end

local WORDS = { GER = "German", SOV = "Soviet" }
local function siteName(s)
    return (s.obj and (s.obj .. " ") or "") .. s.kind .. " #" .. s.id .. " at " .. s.box[1] .. "," .. s.box[2]
end
LF.Control.siteName = siteName

-- ---- each look: who is in which section -----------------------------------------------------------

local counts = {}
local function look()
    index()
    local s = store()
    for k in pairs(counts) do counts[k] = nil end
    for _, r in pairs(LF.Records.all()) do
        if r.alive and SIDES[r.faction] and not r.wounded and not r.aid and not r.captured then
            local x, y = r.x, r.y
            local b = LF.Bodies.get(r.id)
            if b and not b:isDead() then x, y = b:getX(), b:getY() end
            local site, k = LF.Control.partAt(x, y)
            if site then
                local kk = key(site.id, k)
                local c = counts[kk]
                if not c then c = { GER = 0, SOV = 0, id = site.id, k = k }; counts[kk] = c end
                c[r.faction] = c[r.faction] + 1
            end
        end
    end
    for kk in pairs(s.contest) do
        local c = counts[kk]
        if not (c and c.GER > 0 and c.SOV > 0) then s.contest[kk] = nil end
    end
    for kk in pairs(s.pend) do
        if not counts[kk] then s.pend[kk] = nil end
    end
    for kk, c in pairs(counts) do
        if c.GER > 0 and c.SOV > 0 then
            if not s.contest[kk] then
                s.contest[kk] = true
                LF.log("CONTROL " .. siteName(byId[c.id]) .. " section " .. c.k .. " is contested ("
                    .. c.GER .. " German, " .. c.SOV .. " Soviet)")
            end
            s.pend[kk] = nil
        else
            local side = c.GER > 0 and "GER" or "SOV"
            if s.own[kk] == side then s.pend[kk] = nil
            else
                local p = s.pend[kk]
                if not p or p.side ~= side or p.since > LF.simTime then s.pend[kk] = { side = side, since = LF.simTime }
                elseif LF.simTime - p.since >= CFG.holdFor then
                    local was = s.own[kk]
                    s.own[kk], s.pend[kk] = side, nil
                    dirty, rev = true, rev + 1
                    LF.log("CONTROL " .. siteName(byId[c.id]) .. " section " .. c.k .. " taken by the "
                        .. (WORDS[side] or side) .. "s" .. (was and (" (was " .. (WORDS[was] or was) .. ")") or ""))
                end
            end
        end
    end
end

local last = nil
LF.on("OnTick", "Control", function()
    if not LF.due(60, 41) then return end
    if last and last <= LF.simTime and LF.simTime - last < CFG.every then return end
    last = LF.simTime
    LF.guard("control", look)
end)
Events.OnInitGlobalModData.Add(function() last = nil end)

-- ---- the control map ----------------------------------------------------------------------------

local grid = nil            -- { x0, y0, w, h, v = { [i] = "GER"/"SOV"/"contested"/"none" } }
local B = { 52, 0, 630, 942 }   -- (the district's bounds)

local function build()
    local C = CFG.cell
    local w, h = math.ceil((B[3] - B[1] + 1) / C), math.ceil((B[4] - B[2] + 1) / C)
    local v, dist = {}, { GER = {}, SOV = {} }
    local function idx(cx, cy) return cy * w + cx end
    local q = { GER = {}, SOV = {} }
    for _, s in ipairs(SITES) do
        for k, p in ipairs(s.parts) do
            local o = LF.Control.owner(s.id, k)
            local cont = LF.Control.contested(s.id, k)
            for cx = math.floor((p[1] - B[1]) / C), math.floor((p[3] - B[1]) / C) do
                for cy = math.floor((p[2] - B[2]) / C), math.floor((p[4] - B[2]) / C) do
                    if cx >= 0 and cy >= 0 and cx < w and cy < h then
                        local i = idx(cx, cy)
                        if cont then v[i] = "contested"
                        elseif o and v[i] ~= "contested" then
                            v[i] = (v[i] and v[i] ~= o) and "contested" or o
                        end
                        if o and not dist[o][i] then dist[o][i] = 0; q[o][#q[o] + 1] = i end
                    end
                end
            end
        end
    end
    -- How far each cell is from each side's held buildings (in cells, 4-way).
    local R = math.ceil(CFG.reach / C)
    for side, list in pairs(q) do
        local D = dist[side]
        local head = 1
        while head <= #list do
            local i = list[head]; head = head + 1
            local d = D[i]
            if d < R then
                local cx, cy = i % w, math.floor(i / w)
                for _, n in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                    local nx, ny = cx + n[1], cy + n[2]
                    if nx >= 0 and ny >= 0 and nx < w and ny < h then
                        local j = idx(nx, ny)
                        if not D[j] then D[j] = d + 1; list[#list + 1] = j end
                    end
                end
            end
        end
    end
    local band = CFG.band / C
    for i = 0, w * h - 1 do
        if not v[i] then
            local g, s = dist.GER[i], dist.SOV[i]
            if g and s then
                if math.abs(g - s) <= band then v[i] = "none" else v[i] = g < s and "GER" or "SOV" end
            elseif g then v[i] = "GER" elseif s then v[i] = "SOV" end
        end
    end
    grid = { x0 = B[1], y0 = B[2], w = w, h = h, v = v }
    dirty = false
    return grid
end

function LF.Control.grid()
    if dirty or not grid then build() end
    return grid
end

-- What is at (x, y) on the control map: "GER", "SOV", "contested", "none" (no-man's land) or nil.
function LF.Control.at(x, y)
    local g = LF.Control.grid()
    local cx, cy = math.floor((x - g.x0) / CFG.cell), math.floor((y - g.y0) / CFG.cell)
    if cx < 0 or cy < 0 or cx >= g.w or cy >= g.h then return nil end
    return g.v[cy * g.w + cx]
end

-- Each side's share of a sector's buildings (by their ground floors): { GER, SOV, split, total } in squares.
local shares, sharesRev = {}, -1
function LF.Control.share(sec)
    if sharesRev ~= rev then shares, sharesRev = {}, rev end
    if shares[sec] then return shares[sec] end
    local t = { GER = 0, SOV = 0, total = 0 }
    shares[sec] = t
    for _, s in ipairs(SITES) do
        if s.sec == sec then
            for k, p in ipairs(s.parts) do
                local o = LF.Control.owner(s.id, k)
                t.total = t.total + p[7]
                if o then t[o] = t[o] + p[7] end
            end
        end
    end
    return t
end

-- Counts for the log: sections held by each side, contested, and the cells of the map.
function LF.Control.summary()
    local s = store()
    local t = { GER = 0, SOV = 0, contested = 0, sections = 0, split = 0 }
    for _, site in ipairs(SITES) do
        for k in ipairs(site.parts) do
            t.sections = t.sections + 1
            local o = s.own[key(site.id, k)]
            if o then t[o] = t[o] + 1 end
            if s.contest[key(site.id, k)] then t.contested = t.contested + 1 end
        end
        if LF.Control.siteOwner(site) == "split" then t.split = t.split + 1 end
    end
    local g = LF.Control.grid()
    local cells = { GER = 0, SOV = 0, none = 0, contested = 0 }
    for _, v in pairs(g.v) do cells[v] = (cells[v] or 0) + 1 end
    t.cells = cells
    return t
end

-- ---- on the world map (debug tools: the truth) ----------------------------------------------------

local COL = { GER = { 0.55, 0.65, 0.82 }, SOV = { 0.85, 0.25, 0.22 }, contested = { 0.95, 0.62, 0.15 }, none = { 0.95, 0.9, 0.45 } }

local function quad(ui, api, x1, y1, x2, y2, c, a)
    local ax, ay = api:worldToUIX(x1, y1), api:worldToUIY(x1, y1)
    local bx, by = api:worldToUIX(x2, y1), api:worldToUIY(x2, y1)
    local cx, cy = api:worldToUIX(x2, y2), api:worldToUIY(x2, y2)
    local dx, dy = api:worldToUIX(x1, y2), api:worldToUIY(x1, y2)
    ui:drawPolygon(nil, ax, ay, bx, by, cx, cy, dx, dy, c[1], c[2], c[3], a)
end

function LF.Control.drawMap(ui, api, mini)
    if not CFG.show or mini then return end
    local g = LF.Control.grid()
    local C = CFG.cell
    -- The open ground, a run of cells at a time.
    for cy = 0, g.h - 1 do
        local cx = 0
        while cx < g.w do
            local v = g.v[cy * g.w + cx]
            local e = cx
            while e + 1 < g.w and g.v[cy * g.w + e + 1] == v do e = e + 1 end
            if v then
                quad(ui, api, g.x0 + cx * C, g.y0 + cy * C, g.x0 + (e + 1) * C, g.y0 + (cy + 1) * C, COL[v], v == "none" and CFG.alpha * 1.4 or CFG.alpha * 0.6)
            end
            cx = e + 1
        end
    end
    -- The sections, stronger.
    for _, s in ipairs(SITES) do
        for k, p in ipairs(s.parts) do
            local o = LF.Control.contested(s.id, k) and "contested" or LF.Control.owner(s.id, k)
            if o then quad(ui, api, p[1], p[2], p[3] + 1, p[4] + 1, COL[o], CFG.alpha * 2.4) end
        end
    end
end
