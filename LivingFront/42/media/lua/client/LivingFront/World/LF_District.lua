-- Living Front: districts - the city fought over a district at a time (Stalingrad map).
--
-- A DISTRICT is a stretch of the city cut into SECTORS of about the same size - rectangles where
-- they can be - each with one named objective somewhere in it, worth 1 or 2 (the famous places: 2).
-- A district objective's sector is its rectangle, not the ground nearest it (LF_Front). The district is held by the side holding more than half
-- its worth, contested while neither does. Its objectives are ordinary objectives (LF_Objective)
-- - the captains fight for them, sectors and the front line follow from them - only named
-- ("Pavlov's House") rather than lettered.
-- Some objectives are buildings; others are sites (a square, a works yard, a plot whose landmark
-- isn't built yet): a box of ground, held by whoever has the only fit men in it.
--
-- On the Stalingrad map the district's objectives are made once per save, the first time the
-- game runs (debug tools can make them again). The world map shows the district's outline in its
-- holder's colour and a panel with who holds what.
--
-- The district test (debug tools, Tests): a Soviet company holding the district, a German company
-- coming in from the west, both captains left to fight it out; every objective changing hands is
-- logged with the time since the start, and the verdict (how long the Germans took for the
-- district, or how far they got) is a TEST line.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Objective"
require "LivingFront/Tactics/LF_Company"

LF.District = LF.District or {}

local CFG = {
    testLimit = 3 * 3600,       -- simulated seconds before the district test gives its verdict anyway
    testEvery = 30,             -- simulated seconds between the test's looks
}
LF.District.CFG = CFG

-- The districts, map by map. Coordinates are world tiles. An objective is a building (at: a square
-- inside it) or a site (area: x1, y1, x2, y2).
local DATA = {
    {
        map = "Stalingrad",
        districts = {
            {
                -- 12 sectors of about the same ground (each within 7% of the mean), rectangles on
                -- the 10-tile grid the front is drawn on; one objective somewhere in each.
                id = "downtown_north", name = "Downtown North", version = 2,
                bounds = { 80, 0, 970, 1450 },
                objectives = {
                    { key = "raildepot", title = "Rail Depot", weight = 1, at = { 264, 78 }, sector = { 80, 0, 590, 230 } },
                    { key = "railwaymen", title = "Railwaymen's House", weight = 1, area = { 821, 168, 845, 192 }, kind = "site", sector = { 590, 0, 970, 230 } },
                    { key = "square", title = "9 January Square", weight = 2, area = { 447, 324, 495, 372 }, kind = "square", sector = { 80, 230, 500, 590 } },
                    { key = "pavlov", title = "Pavlov's House", weight = 2, area = { 560, 358, 627, 432 }, kind = "houses", sector = { 500, 230, 730, 590 } },
                    { key = "mill", title = "Gerhardt's Mill", weight = 2, at = { 880, 346 }, sector = { 730, 230, 970, 590 } },
                    { key = "engworks", title = "Engineering Works", weight = 1, at = { 371, 707 }, sector = { 80, 590, 470, 980 } },
                    { key = "workshops", title = "Central Workshops", weight = 1, at = { 523, 840 }, sector = { 470, 590, 700, 980 } },
                    { key = "warehouses", title = "Riverside Warehouses", weight = 1, at = { 887, 848 }, sector = { 700, 590, 970, 980 } },
                    { key = "station", title = "Stalingrad-1 Station", weight = 2, at = { 209, 1172 }, sector = { 80, 980, 580, 1230 } },
                    { key = "depot", title = "Depot", weight = 1, at = { 825, 1172 }, sector = { 580, 980, 970, 1230 } },
                    { key = "nails", title = "Nail Factory", weight = 1, area = { 155, 1274, 203, 1322 }, kind = "works", sector = { 80, 1230, 530, 1450 } },
                    { key = "machworks", title = "Machine Works", weight = 1, at = { 734, 1369 }, sector = { 530, 1230, 970, 1450 } },
                },
            },
        },
    },
}

local FACTION = { GER = "Germans", SOV = "Soviets" }

local function store()
    local d = LF.Records.data()
    d.districts = d.districts or {}
    local s = d.districts
    s.seeded = s.seeded or {}
    s.holder = s.holder or {}
    return s
end

-- ---- which map --------------------------------------------------------------------------------

local mapSet, mapChecked = nil, false
local function currentSet()
    if mapChecked then return mapSet end
    mapChecked = true
    local dirs = {}
    pcall(function()
        local l = getLotDirectories()
        for i = 0, l:size() - 1 do dirs[tostring(l:get(i))] = true end
    end)
    pcall(function() dirs[tostring(getWorld():getMap())] = true end)
    for _, set in ipairs(DATA) do
        for name in pairs(dirs) do
            if name == set.map or name:find(set.map, 1, true) then mapSet = set; break end
        end
        if mapSet then break end
    end
    if mapSet then
        LF.log("DISTRICT map " .. mapSet.map .. ": " .. #mapSet.districts .. " district(s)")
        -- (The whole district on the world map, not just where you have been.)
        if LF.Map and LF.Map.setRevealAll then LF.Map.setRevealAll(true) end
    end
    return mapSet
end
Events.OnInitGlobalModData.Add(function() mapSet, mapChecked = nil, false end)

function LF.District.all()
    local set = currentSet()
    return set and set.districts or {}
end

function LF.District.get(id)
    for _, d in ipairs(LF.District.all()) do if d.id == id then return d end end
    return nil
end

-- The objective made for a district's entry, or nil.
local function objectiveOf(d, e)
    for _, o in pairs(LF.Objective.all()) do
        if o.district == d.id and o.districtKey == e.key then return o end
    end
    return nil
end
LF.District.objectiveOf = objectiveOf

-- ---- making the objectives ----------------------------------------------------------------------

local function makeOne(d, e)
    local obj, why
    if e.at then
        obj, why = LF.Objective.create(e.at[1], e.at[2], 0)
        if not obj then
            -- (No building there after all: a site round the point.)
            LF.log("DISTRICT " .. e.title .. ": no building at " .. e.at[1] .. "," .. e.at[2] .. " (" .. tostring(why) .. ") - a site instead")
            local r = 12
            obj = LF.Objective.createArea(e.at[1] - r, e.at[2] - r, e.at[1] + r, e.at[2] + r, 0, "site")
        end
    else
        local a = e.area
        obj = LF.Objective.createArea(a[1], a[2], a[3], a[4], 0, e.kind or "site")
    end
    if not obj then return nil end
    obj.title, obj.weight, obj.district, obj.districtKey = e.title, e.weight or 1, d.id, e.key
    LF.Objective.rename(obj)
    return obj
end

-- Make the district's objectives that aren't there yet. Returns how many were made.
function LF.District.seed(d)
    local n = 0
    for _, e in ipairs(d.objectives) do
        if not objectiveOf(d, e) then
            if makeOne(d, e) then n = n + 1 end
        end
    end
    store().seeded[d.id] = d.version or 1
    LF.log("DISTRICT " .. d.name .. ": " .. n .. " objective(s) made, " .. #d.objectives .. " in all")
    return n
end

-- The district's objectives made afresh (every objective of the district is removed first - those
-- of an older list too). Debug tools, and a save made with an older list of the district.
function LF.District.reset(d)
    local gone = {}
    for id, o in pairs(LF.Objective.all()) do
        if o.district == d.id then gone[#gone + 1] = id end
    end
    for _, id in ipairs(gone) do LF.Objective.remove(id) end
    store().holder[d.id] = nil
    return LF.District.seed(d)
end

-- The sectors of the district objectives there are: { { key = objective id as a string, x1, y1,
-- x2, y2 } } (LF_Front gives them their ground first; other objectives get theirs round them).
function LF.District.sectors()
    local out = {}
    for _, d in ipairs(LF.District.all()) do
        for _, e in ipairs(d.objectives) do
            local o = e.sector and objectiveOf(d, e)
            if o then out[#out + 1] = { key = tostring(o.id), e.sector[1], e.sector[2], e.sector[3], e.sector[4] } end
        end
    end
    return out
end

-- ---- who holds it -------------------------------------------------------------------------------

-- { total, GER, SOV, contested, none, holder } - holder "GER"/"SOV" (more than half the worth),
-- "contested" (both sides hold some of it) or nil (nobody holds any of it, or one side holds
-- some and the rest nobody).
function LF.District.tally(d)
    local t = { total = 0, GER = 0, SOV = 0, contested = 0, none = 0 }
    for _, e in ipairs(d.objectives) do
        local w = e.weight or 1
        t.total = t.total + w
        local o = objectiveOf(d, e)
        if o and o.contested then t.contested = t.contested + w
        elseif o and (o.holder == "GER" or o.holder == "SOV") then t[o.holder] = t[o.holder] + w
        else t.none = t.none + w end
    end
    if t.GER * 2 > t.total then t.holder = "GER"
    elseif t.SOV * 2 > t.total then t.holder = "SOV"
    elseif t.GER > 0 and t.SOV > 0 or t.contested > 0 then t.holder = "contested" end
    return t
end

function LF.District.holderWords(h)
    if h == "contested" then return "contested" end
    if h then return "held by the " .. (FACTION[h] or h) end
    return "held by nobody"
end

-- ---- the district test ---------------------------------------------------------------------------

local test = nil            -- { d, start, last, took = { key -> secs }, log = {} } while running

local function clock(secs)
    secs = math.max(0, math.floor(secs))
    local h, m, s = math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end
LF.District.clock = clock

function LF.District.test() return test end

-- Start it: every objective of the district Soviet; a Soviet company by the river, a German one
-- on the west road, all platoons spawned; the captains do the rest.
function LF.District.startTest(d)
    d = d or LF.District.all()[1]
    if not d then LF.say("District test: this isn't a map with districts"); return false end
    if not LF.Company then LF.say("District test: companies aren't loaded"); return false end
    LF.District.seed(d)
    for _, e in ipairs(d.objectives) do
        local o = objectiveOf(d, e)
        if o then o.holder, o.contested = "SOV", nil; LF.Objective.rename(o) end
    end
    local sp = d.test or { SOV = { 907, 700, -1, 0 }, GER = { 280, 450, 1, 0 } }
    local companies = {}
    for _, f in ipairs({ "SOV", "GER" }) do
        local s = sp[f]
        local c = LF.Company.create(f, s[1] + 0.5, s[2] + 0.5, 0, s[3], s[4])
        for _ = 1, 4 do
            local p = LF.Company.addPlatoon(c)
            if not p then break end
        end
        companies[f] = c.id
    end
    if LF.Captain and LF.Captain.CFG then LF.Captain.CFG.on = true end
    test = { d = d, start = LF.simTime, last = LF.simTime, took = {}, held = {}, companies = companies, lines = {} }
    for _, e in ipairs(d.objectives) do test.held[e.key] = "SOV" end
    test.districtHolder = "SOV"
    LF.log("TEST district " .. d.name .. ": started - a Soviet company holding all " .. #d.objectives
        .. " objectives, a German company attacking from the west; verdict when the Germans hold the district or after "
        .. clock(CFG.testLimit) .. " (simulated)")
    LF.say("District test started - watch the world map (M); verdict in the log (TEST district)")
    return true
end

local function fitMen(faction)
    local n = 0
    for _, r in pairs(LF.Records.all()) do
        if r.alive and r.faction == faction and not r.captured and not (r.wounded or r.offWound) then n = n + 1 end
    end
    return n
end

local function finish(verdict)
    local d = test.d
    local took = 0
    for _ in pairs(test.took) do took = took + 1 end
    local t = LF.District.tally(d)
    LF.log(string.format("TEST district %s: %s - after %s, the Germans took %d of %d objectives (worth %d of %d); fit men left: German %d, Soviet %d",
        d.name, verdict, clock(LF.simTime - test.start), took, #d.objectives, t.GER, t.total, fitMen("GER"), fitMen("SOV")))
    for _, e in ipairs(d.objectives) do
        LF.log("TEST district   " .. e.title .. ": " .. (test.took[e.key] and ("taken at " .. clock(test.took[e.key])) or "not taken"))
    end
    LF.say("District test: " .. verdict .. " - see the log (TEST district)")
    test = nil
end

local function updateTest()
    if not test or LF.simTime - test.last < CFG.testEvery then return end
    test.last = LF.simTime
    local d = test.d
    local el = LF.simTime - test.start
    for _, e in ipairs(d.objectives) do
        local o = objectiveOf(d, e)
        local h = o and (o.contested and "contested" or o.holder) or nil
        if h ~= test.held[e.key] then
            LF.log("TEST district " .. clock(el) .. " " .. e.title .. ": " .. LF.District.holderWords(test.held[e.key])
                .. " -> " .. LF.District.holderWords(h))
            if h == "GER" and not test.took[e.key] then test.took[e.key] = el end
            test.held[e.key] = h
        end
    end
    local t = LF.District.tally(d)
    if t.holder ~= test.districtHolder then
        LF.log("TEST district " .. clock(el) .. " " .. d.name .. " is now " .. LF.District.holderWords(t.holder))
        test.districtHolder = t.holder
    end
    if t.holder == "GER" then finish("PASS - the Germans hold the district")
    elseif fitMen("GER") == 0 then finish("the German attack is spent")
    elseif el >= CFG.testLimit then finish("time up") end
end

-- ---- each update --------------------------------------------------------------------------------

LF.on("OnTick", "District", function()
    if not LF.due(300, 17) then return end
    local districts = LF.District.all()
    if #districts == 0 then return end
    local s = store()
    for _, d in ipairs(districts) do
        -- (Made once per save - and again if every objective was cleared away, as Delete ALL NPCs does.)
        local any = false
        for _, e in ipairs(d.objectives) do if objectiveOf(d, e) then any = true; break end end
        local v = s.seeded[d.id]
        if v and v ~= true and v < (d.version or 1) or v == true and (d.version or 1) > 1 then
            LF.log("DISTRICT " .. d.name .. ": the save has an older list of its objectives - made afresh")
            LF.guard("district reset", LF.District.reset, d)
        elseif not v or not any then LF.guard("district seed", LF.District.seed, d) end
        local t = LF.District.tally(d)
        if t.holder ~= s.holder[d.id] then
            LF.log("DISTRICT " .. d.name .. " is now " .. LF.District.holderWords(t.holder)
                .. string.format(" (German %d, Soviet %d, contested %d of %d)", t.GER, t.SOV, t.contested, t.total))
            s.holder[d.id] = t.holder
        end
    end
    if test then LF.guard("district test", updateTest) end
end)
Events.OnInitGlobalModData.Add(function() test = nil end)

-- ---- on the world map ------------------------------------------------------------------------------

local COLORS = {
    GER = { 0.55, 0.65, 0.82 }, SOV = { 0.85, 0.25, 0.22 }, contested = { 0.95, 0.62, 0.15 }, none = { 0.85, 0.85, 0.8 },
}

local function shadowText(ui, text, x, y, c, font)
    ui:drawText(text, x + 1, y + 1, 0, 0, 0, 0.85, font)
    ui:drawText(text, x, y, c[1], c[2], c[3], 1, font)
end

-- The outline of each district in its holder's colour; on the world map, a panel at the top right:
-- the district, who holds it, and each objective with its holder (and the test's clock).
function LF.District.drawMap(ui, api, mini)
    local districts = LF.District.all()
    if #districts == 0 then return end
    local tm = getTextManager()
    local py = 20
    for _, d in ipairs(districts) do
        local t = LF.District.tally(d)
        local c = COLORS[t.holder or "none"] or COLORS.none
        local b = d.bounds
        local pts = { { b[1], b[2] }, { b[3], b[2] }, { b[3], b[4] }, { b[1], b[4] } }
        for i = 1, 4 do
            local p, q = pts[i], pts[i % 4 + 1]
            local ax, ay = api:worldToUIX(p[1], p[2]), api:worldToUIY(p[1], p[2])
            local bx, by = api:worldToUIX(q[1], q[2]), api:worldToUIY(q[1], q[2])
            ui.javaObject:DrawLine(nil, ax, ay, bx, by, mini and 2 or 4, 0, 0, 0, 0.5)
            ui.javaObject:DrawLine(nil, ax, ay, bx, by, mini and 1 or 2, c[1], c[2], c[3], 0.9)
        end
        if not mini then
            local font = UIFont.Small
            local fh = tm:getFontHeight(font)
            local lines = { { d.name .. " - " .. LF.District.holderWords(t.holder), c, UIFont.Medium },
                            { string.format("German %d  Soviet %d  contested %d  of %d", t.GER, t.SOV, t.contested, t.total), COLORS.none, font } }
            for _, e in ipairs(d.objectives) do
                local o = objectiveOf(d, e)
                local h = o and (o.contested and "contested" or o.holder) or nil
                lines[#lines + 1] = { string.format("%s (%d) - %s", e.title, e.weight or 1, LF.District.holderWords(h)),
                                      COLORS[h or "none"] or COLORS.none, font }
            end
            if test and test.d == d then
                lines[#lines + 1] = { "District test: " .. clock(LF.simTime - test.start), COLORS.none, font }
            end
            local w = 0
            for _, l in ipairs(lines) do w = math.max(w, tm:MeasureStringX(l[3], l[1])) end
            local px = ui.width - w - 30
            local h = 0
            for _, l in ipairs(lines) do h = h + tm:getFontHeight(l[3]) + 2 end
            ui:drawRect(px - 10, py - 6, w + 20, h + 12, 0.55, 0, 0, 0)
            for _, l in ipairs(lines) do
                shadowText(ui, l[1], px, py, l[2], l[3])
                py = py + tm:getFontHeight(l[3]) + 2
            end
            py = py + 20
        end
    end
end
