-- Living Front: the right-click menu.
--
--   Inspect <soldier>     - when you right-click on or right next to a soldier (top of the menu)
--   Living Front >
--     Spawn here          - a soldier, a fire team (4), a squad (10), a machine-gun squad (10) or a
--                           platoon (43: headquarters and four squads), German or Soviet; a civilian
--     Give orders to      - any platoon (take / hold this place, withdraw to here) or unit in the
--                           game (by side, nearest the click first): stance, patrol here, take /
--                           hold this place as an objective, clear this building, inspect its leader
--     Sergeants choose their stance (on/off)
--     Tools               - move / kill / delete the nearest of a type, clear objectives, unit
--                           report, delete all,
--                           reset world

require "LivingFront/Tactics/LF_Company"
require "LivingFront/Tactics/LF_Captain"
require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Soldier/LF_Combat"
require "LivingFront/Soldier/LF_Brain"
require "LivingFront/Soldier/LF_MoveAction"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Squad"
require "LivingFront/Soldier/LF_Suppress"
require "LivingFront/Tactics/LF_Command"
require "LivingFront/World/LF_Building"
require "LivingFront/Units/LF_Stance"
require "LivingFront/Units/LF_March"
require "LivingFront/Units/LF_Objective"
require "LivingFront/Soldier/LF_Weapons"
require "LivingFront/UI/LF_Inspect"
require "LivingFront/Units/LF_Join"
require "LivingFront/Specialists/LF_Medic"
require "LivingFront/Specialists/LF_MG"
require "LivingFront/Tactics/LF_Platoon"

LF.Debug = LF.Debug or {}

local TYPES = {
    { key = "CIV", label = "civilian" },
    { key = "GER", label = "German soldier" },
    { key = "SOV", label = "Soviet soldier" },
}

local function create(faction, x, y, z)
    local rec = LF.Records.create({ faction = faction, x = x + 0.5, y = y + 0.5, z = z })
    LF.log("created #" .. rec.id .. " " .. LF.Records.fullName(rec) .. " [" .. faction .. "]")
    LF.say("Created " .. LF.Records.fullName(rec) .. " (" .. LF.Factions[faction].name .. ")")
end

-- The living body of this faction nearest (x, y).
local function nearestOf(faction, x, y)
    local best, bestD = nil, math.huge
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and rec.faction == faction and not body:isDead() then
            local d = LF.distSq(body:getX(), body:getY(), x + 0.5, y + 0.5)
            if d < bestD then best, bestD = body, d end
        end
    end
    return best
end

local function moveNearest(faction, x, y, z)
    local body = nearestOf(faction, x, y)
    local sq = getCell():getGridSquare(x, y, z)
    if not (body and sq) then LF.say("No " .. faction .. " NPC nearby"); return end
    ISTimedActionQueue.clear(body)
    ISTimedActionQueue.add(LF_MoveAction:new(body, sq, "walk"))
end

local function killNearest(faction, x, y)
    local body = nearestOf(faction, x, y)
    if not body then LF.say("No " .. faction .. " NPC nearby"); return end
    LF.log("DEBUG killing #" .. tostring(body:getModData().LF_id))
    body:getBodyDamage():ReduceGeneralHealth(500)
end

local function deleteNearest(faction, x, y)
    local body = nearestOf(faction, x, y)
    if not body then LF.say("No " .. faction .. " NPC nearby"); return end
    local id = body:getModData().LF_id
    LF.Bodies.despawn(id)
    LF.Records.remove(id)
    LF.log("DEBUG deleted #" .. tostring(id))
end

local function deleteAll()
    LF.Bodies.despawnAll()
    for id in pairs(LF.Records.all()) do LF.Records.remove(id) end
    LF.Units.clear()
    LF.Squad.forgetAll()
    LF.Suppress.forgetAll()
    LF.Tactics.forgetAll()
    LF.March.forgetAll()
    LF.Objective.clear()
    LF.Weapons.forgetAll()
    LF.log("deleted all records")
    LF.say("Living Front: all NPCs deleted")
end

-- ---- reset world ----------------------------------------------------------------------------

local RESET_RADIUS = 60   -- tiles around the player
local CLEAR_STATS = { "HUNGER", "THIRST", "FATIGUE", "STRESS", "PANIC", "BOREDOM", "UNHAPPINESS", "PAIN",
                      "SICKNESS", "FOOD_SICKNESS", "POISON", "ANGER", "DISCOMFORT", "INTOXICATION", "WETNESS" }

-- Battlefield leftovers: rifles, ammunition and spent casings lying on the ground.
local function isRemnant(item)
    local t = item:getFullType()
    return t == "Base.HuntingRifle" or t:find("Casing") ~= nil or t:find("Bullets") ~= nil or t:find("Shell") ~= nil
end

local function clearSquare(sq, counts)
    local dead = sq:getDeadBodys()
    for i = dead:size() - 1, 0, -1 do
        sq:removeCorpse(dead:get(i), false)
        counts.corpses = counts.corpses + 1
    end
    sq:removeBlood(false, false)
    local items = sq:getWorldObjects()
    for i = items:size() - 1, 0, -1 do
        local obj = items:get(i)
        local item = obj:getItem()
        if item and isRemnant(item) then
            sq:transmitRemoveItemFromSquare(obj)
            counts.items = counts.items + 1
        end
    end
end

-- Every wound on every body part, one call at a time (one that doesn't exist in this build
-- can't stop the rest).
local function healParts(p)
    local bd = p:getBodyDamage()
    local parts = bd:getBodyParts()
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        for _, f in ipairs({
            function() bp:RestoreToFullHealth() end,
            function() bp:setBleeding(false) end, function() bp:setBleedingTime(0) end,
            function() bp:setHaveBullet(false, 0) end, function() bp:setHaveGlass(false) end,
            function() bp:setDeepWounded(false) end, function() bp:setDeepWoundTime(0) end,
            function() bp:setFractureTime(0) end, function() bp:setSplint(false, 0) end,
            function() bp:setCut(false) end, function() bp:setCutTime(0) end,
            function() bp:setScratched(false, false) end, function() bp:setScratchTime(0) end,
            function() bp:SetBitten(false) end, function() bp:setBurnTime(0) end,
            function() bp:setBandaged(false, 0) end, function() bp:setStitched(false) end,
            function() bp:setWoundInfectionLevel(0) end, function() bp:SetInfected(false) end,
            function() bp:setAdditionalPain(0) end, function() bp:SetHealth(100) end,
        }) do pcall(f) end
    end
    -- (Only methods this game version has: calling a missing one inside pcall still writes a
    -- stack trace to the log every reset.)
    local function try(o, name, ...)
        local f = o and o[name]
        if f then pcall(f, o, ...) end
    end
    try(bd, "setOverallBodyHealth", 100)
    try(bd, "setInfected", false)
    try(bd, "setInfectionLevel", 0)
    pcall(function() p:setHealth(1) end)
    -- Up off the ground if a blast or a hit had him down.
    pcall(function() p:setKnockedDown(false) end)
    pcall(function() p:setOnFloor(false) end)
    pcall(function() p:setBumpDone(true) end)
end

local function healPlayer(p)
    p:getBodyDamage():RestoreToFullHealth()
    LF.guard("heal wounds", healParts, p)
    -- Once more next tick (the game recalculates health from the parts each frame).
    local n = 0
    local function again()
        n = n + 1
        if n < 2 then return end
        Events.OnTick.Remove(again)
        LF.guard("heal wounds", healParts, p)
        local ok, h = pcall(function() return p:getBodyDamage():getOverallBodyHealth() end)
        LF.log("RESET WORLD player health now " .. (ok and math.floor(h) or "?"))
    end
    Events.OnTick.Add(again)
    local stats = p:getStats()
    for _, name in ipairs(CLEAR_STATS) do
        if CharacterStat[name] then stats:set(CharacterStat[name], 0) end
    end
    stats:set(CharacterStat.ENDURANCE, 1)
end

local function cleanPlayer(p)
    local hv = p:getHumanVisual()
    hv:removeBlood()
    hv:removeDirt()
    p:resetModel()
end

-- Fog off (kept off: the setting is saved and re-applied when the game loads).
local function clearFog()
    local cm = getClimateManager()
    local f = cm:getClimateFloat(ClimateManager.FLOAT_FOG_INTENSITY)
    f:setEnableModded(true)
    f:setModdedValue(0)
    f:setModdedInterpolate(1)
end

Events.OnGameStart.Add(function()
    if LF.Records.data().noFog then LF.guard("clear fog", clearFog) end
end)

-- Clear corpses, blood and battlefield debris around the player, forget the dead, and restore
-- the player's health and needs.
-- Fill the tank of every vehicle within the reset radius. Returns how many were filled.
-- (Found square by square: the cell's vehicle list is a Java Set, which Lua can't index - 0.44
-- failed on it.)
local function refuelVehicles(px, py, pz)
    local n, seen = 0, {}
    local cell = getCell()
    for x = px - RESET_RADIUS, px + RESET_RADIUS, 2 do
        for y = py - RESET_RADIUS, py + RESET_RADIUS, 2 do
            local sq = cell:getGridSquare(x, y, pz)
            local v = sq and sq:getVehicleContainer()
            if v then
                local key = tostring(v:getId())
                if not seen[key] then
                    seen[key] = true
                    local ok = pcall(function()
                        local tank = v:getPartById("GasTank")
                        if not tank then error("no tank") end
                        local cap = tank:getContainerCapacity()
                        if tank:getContainerContentAmount() < cap then
                            tank:setContainerContentAmount(cap)
                            n = n + 1
                            pcall(function() v:transmitPartModData(tank) end)
                        end
                    end)
                    if not ok then LF.log("RESET WORLD couldn't refuel the vehicle at " .. x .. "," .. y) end
                end
            end
        end
    end
    return n
end

local function resetWorld(playerNum)
    local p = getSpecificPlayer(playerNum)
    if not p then return end
    local cell = getCell()
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    local counts = { corpses = 0, items = 0 }
    for z = math.max(0, pz - 1), pz + 1 do
        for x = px - RESET_RADIUS, px + RESET_RADIUS do
            for y = py - RESET_RADIUS, py + RESET_RADIUS do
                local sq = cell:getGridSquare(x, y, z)
                if sq then LF.guard("clear square", clearSquare, sq, counts) end
            end
        end
    end
    -- Units with nobody left go first (they need the dead records to know who was in them).
    local unitsRemoved = LF.Units.pruneDead()
    local forgotten = 0
    for id, rec in pairs(LF.Records.all()) do
        if not rec.alive then LF.Records.remove(id); forgotten = forgotten + 1 end
    end
    local fuelled = LF.guard("refuel vehicles", refuelVehicles, px, py, pz) or 0
    getGameTime():setTimeOfDay(8.0)
    LF.Records.data().noFog = true
    LF.guard("clear fog", clearFog)
    LF.guard("heal player", healPlayer, p)
    LF.guard("clean player", cleanPlayer, p)
    LF.log("RESET WORLD removed " .. counts.corpses .. " corpses, " .. counts.items .. " items, "
        .. forgotten .. " dead records, " .. unitsRemoved .. " wiped-out units, " .. fuelled .. " vehicles refuelled; player healed; time set to 08:00; fog off")
    LF.say("World reset: " .. counts.corpses .. " bodies and " .. counts.items .. " items cleared, " .. fuelled .. " vehicles refuelled")
end

-- ---- choosing a unit ----------------------------------------------------------------------------

-- Where a unit is: its commander, else any living member (body, else record).
local function unitPos(u)
    local cid = LF.Units.commander(u)
    local b = cid and LF.Bodies.get(cid)
    if b and not b:isDead() then return b:getX(), b:getY(), b:getZ() end
    for _, rid in ipairs(LF.Units.members(u.id)) do
        local r = LF.Records.get(rid)
        if r and r.alive then
            local rb = LF.Bodies.get(rid)
            if rb then return rb:getX(), rb:getY(), rb:getZ() end
            return r.x, r.y, r.z
        end
    end
    return nil
end

local function alive(u)
    local n, total = 0, 0
    for _, rid in ipairs(LF.Units.members(u.id)) do
        local r = LF.Records.get(rid)
        if r then
            total = total + 1
            if r.alive then n = n + 1 end
        end
    end
    return n, total
end

-- Every unit in the game that can take orders, by faction, nearest the click first.
local function unitList(x, y)
    local by = {}
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "squad" and not u.joined then
            local n, total = alive(u)
            local ux, uy = unitPos(u)
            if n > 0 and ux then
                by[u.faction] = by[u.faction] or {}
                local list = by[u.faction]
                list[#list + 1] = { u = u, n = n, total = total, d = LF.dist(ux, uy, x + 0.5, y + 0.5) }
            end
        end
    end
    for _, list in pairs(by) do table.sort(list, function(a, b) return a.d < b.d end) end
    return by
end

-- ---- orders to a chosen unit ------------------------------------------------------------------

local function setStanceOf(u, x, y, z, stance)
    -- Defensive, clicked on a building: hold that building.
    local hold = stance == "defensive" and LF.Building.idAt(x, y, z) and { x = x, y = y, z = z } or nil
    LF.Tactics.setStance(u, stance, hold)
    LF.Tactics.noteStanceSet(u)
    LF.say(u.name .. ": " .. stance .. (hold and " - holding the building" or ""))
end

local function patrolOf(u, x, y, z, form)
    local ok, why = LF.March.order(u, x, y, z, form)
    LF.say(ok and (u.name .. " patrols there" .. (LF.March.FORMATIONS[form] and (" in " .. LF.March.FORMATIONS[form]) or " (sergeant's choice of formation)"))
        or ("Can't move: " .. tostring(why)))
end

local function clearOf(u, x, y, z)
    local L = LF.Building.at(x, y, z)
    if not L then LF.say("Click on a building for this order"); return end
    local team = LF.Units.get(u.teams[1])
    local goes = team and LF.Tactics.orderClear(u, team, L, "debug order")
    LF.say(goes and (u.name .. ": " .. goes.name .. " clears the building") or "Couldn't plan it - see the log (CLEAR ...)")
end

-- Spawn a unit at the clicked spot, facing away from the player.
local function spawnUnit(faction, x, y, z, size, playerNum)
    if size == "soldier" then create(faction, x, y, z); return end
    local p = getSpecificPlayer(playerNum)
    local fx, fy = 1, 0
    if p then fx, fy = x + 0.5 - p:getX(), y + 0.5 - p:getY() end
    if size == "companyHQ" then
        local c = LF.Company.create(faction, x + 0.5, y + 0.5, z, fx, fy)
        LF.say("Spawned " .. c.name .. " HQ (10) - right-click the captain to give him his platoons")
        return
    end
    if size == "platoon" or size == "platoonMG" then
        local plt = LF.Platoon.create(faction, x + 0.5, y + 0.5, z, fx, fy, size == "platoonMG")
        LF.say("Spawned " .. plt.name .. " (23)")
        return
    end
    local unit = LF.Units.createSquad(faction, x + 0.5, y + 0.5, z, fx, fy, size == "team", size == "mg")
    LF.say("Spawned " .. unit.name .. (size == "team" and " (4)" or " (10)"))
end

-- ---- platoon orders -----------------------------------------------------------------------------

local function platoonList(x, y)
    local by = {}
    for _, p in pairs(LF.Units.all()) do
        if p.kind == "platoon" then
            local hq = LF.Units.get(p.hq)
            local px, py = nil, nil
            if hq then px, py = unitPos(hq) end       -- (both values: "hq and unitPos(hq)" keeps only the first)
            if not px then
                for _, sid in ipairs(p.squads or {}) do
                    local s = LF.Units.get(sid)
                    if s then px, py = unitPos(s) end
                    if px then break end
                end
            end
            if px then
                by[p.faction] = by[p.faction] or {}
                table.insert(by[p.faction], { p = p, d = LF.dist(px, py, x + 0.5, y + 0.5) })
            end
        end
    end
    for _, list in pairs(by) do table.sort(list, function(a, b) return a.d < b.d end) end
    return by
end

-- The objective at (x, y), or a new one there. A building that is already an objective stays that
-- objective; a click in the open within 15 tiles of an objective means that objective (its yard,
-- the street in front of it) - not a new one beside it.
local function objectiveAt(x, y, z)
    local bid = LF.Building.idAt(x, y, z)
    local near, nd = nil, 15
    for _, o in pairs(LF.Objective.all()) do
        if bid and o.building == bid then return o end
        if not bid then
            local d = LF.dist(o.x, o.y, x + 0.5, y + 0.5)
            if d <= nd then near, nd = o, d end
        end
    end
    if near then return near end
    if not bid then return nil end          -- (objectives are buildings)
    return LF.Objective.create(x, y, z)
end

-- ---- the stress test (0.70) -----------------------------------------------------------------------
-- The same fight every time, so each release is measured on it: a German platoon (3 rifle squads
-- and an MG squad) holds the building you right-clicked, a Soviet platoon spawned 70 tiles east
-- of it is ordered to take it. For 2 minutes of real time every PERF window is collected; then a
-- STRESS summary goes to the log: average and worst frame, the mod's share, the game's share, the
-- costliest modules, the most bodies. Stand where you can see the building.

local stress = nil
local STRESS_WINDOWS = 24       -- PERF windows (5 s each) = 2 minutes
local pair = {}                 -- the last stress run's men hit, on and off screen (the 0.73 test 4)

-- Every man of a platoon (its headquarters and its squads).
local function platoonMen(p)
    local ids = {}
    for _, u in pairs(LF.Units.all()) do
        if u.id == p.hq or u.platoon == p.id then
            for _, rid in ipairs(LF.Units.members(u.id)) do ids[#ids + 1] = rid end
        end
    end
    return ids
end

-- How a side has come out of it: killed, critical, serious, light, unhurt.
local function casualties(ids)
    local c = { killed = 0, critical = 0, serious = 0, light = 0, unhurt = 0 }
    for _, rid in ipairs(ids) do
        local r = LF.Records.get(rid)
        if not r or not r.alive then c.killed = c.killed + 1
        else
            local g = r.wound and r.wound.grade
            if g and c[g] then c[g] = c[g] + 1 else c.unhurt = c.unhurt + 1 end
        end
    end
    return string.format("%d killed, %d critical, %d serious, %d light, %d unhurt", c.killed, c.critical, c.serious, c.light, c.unhurt)
end

-- Men of these hit at all (killed or wounded).
local function hitCount(ids)
    local n = 0
    for _, rid in ipairs(ids) do
        local r = LF.Records.get(rid)
        if not r or not r.alive or (r.wound and r.wound.grade) then n = n + 1 end
    end
    return n
end

-- offscreen: the same fight with nobody given a body - settled the off-screen way (LF_Clash) even
-- with you standing there, to compare with the real thing (the 0.72 gate: within 20%).
local function stressTest(x, y, z, offscreen)
    local obj = objectiveAt(x, y, z)
    if not obj then LF.say("Right-click on a building for the stress test"); return end
    if not (LF.Config.logPerf) then LF.Perf.toggle() end
    local ger = LF.Platoon.create("GER", obj.x + 0.5, obj.y + 0.5, obj.z or 0, 1, 0, true)
    local sov = LF.Platoon.create("SOV", obj.x + 70.5, obj.y + 0.5, obj.z or 0, -1, 0, true)
    local gerMen, sovMen = platoonMen(ger), platoonMen(sov)
    if offscreen then
        for _, rid in ipairs(gerMen) do local r = LF.Records.get(rid); if r then r.noBody = true end end
        for _, rid in ipairs(sovMen) do local r = LF.Records.get(rid); if r then r.noBody = true end end
    end
    local okH, whyH = LF.Platoon.hold(ger, obj)
    local okT, whyT = LF.Platoon.take(sov, obj)
    stress = { started = getTimestampMs(), sim = LF.simTime, windows = {}, seen = LF.Perf.last(), obj = obj.name,
               ger = gerMen, sov = sovMen, offscreen = offscreen }
    LF.log(string.format("STRESS start%s at %s (%d,%d): %s holds it (%s), %s attacks from 70 tiles east (%s); version %s",
        offscreen and " (OFF-SCREEN: no bodies)" or "", obj.name, math.floor(obj.x), math.floor(obj.y), ger.name,
        okH and "ok" or tostring(whyH), sov.name, okT and "ok" or tostring(whyT), tostring(LF.VERSION)))
    LF.say("Stress test" .. (offscreen and " (off-screen)" or "") .. ": " .. ger.name .. " holds " .. obj.name .. ", "
        .. sov.name .. " attacks - summary in the log in 2 minutes")
end

local function stressSummary()
    local W = stress.windows
    local n = #W
    if n == 0 then return end
    local f, m, r, fps, worst, bodies = 0, 0, 0, 0, 0, 0
    local mods = {}
    for _, w in ipairs(W) do
        f, m, r, fps = f + w.frame, m + w.mod, r + w.rest, fps + w.fps
        worst = math.max(worst, w.frame)
        bodies = math.max(bodies, w.bodies)
        for _, part in ipairs(w.top) do
            local name, v = part:match("^(.-)=([%d%.]+)$")
            if name then mods[name] = (mods[name] or 0) + tonumber(v) end
        end
    end
    local list = {}
    for name, v in pairs(mods) do list[#list + 1] = { name = name, v = v / n } end
    table.sort(list, function(a, b) return a.v > b.v end)
    local top = {}
    for i, e in ipairs(list) do if i <= 8 then top[#top + 1] = e.name .. "=" .. string.format("%.2f", e.v) end end
    LF.log(string.format("STRESS summary (%s, version %s, %d windows): fps %.1f, frame %.1f ms (worst %.1f), mod %.2f ms (%.0f%%), game %.1f ms, most bodies %d | %s",
        stress.obj, tostring(LF.VERSION), n, fps / n, f / n, worst, m / n, f > 0 and m / f * 100 or 0, r / n, bodies, table.concat(top, " ")))
    LF.log(string.format("STRESS casualties after %.0f simulated seconds%s: defenders (German) %s | attackers (Soviet) %s",
        LF.simTime - (stress.sim or LF.simTime), stress.offscreen and " (off-screen)" or "", casualties(stress.ger or {}),
        casualties(stress.sov or {})))
    LF.say(string.format("Stress test done: %.1f fps, frame %.1f ms, mod %.2f ms - see the log", fps / n, f / n, m / n))
    -- Test 4: the same fight on and off screen should hit about as many men (within 20%).
    local hits = hitCount(stress.ger or {}) + hitCount(stress.sov or {})
    pair[stress.offscreen and "off" or "on"] = hits
    if pair.on and pair.off then
        local big = math.max(pair.on, pair.off, 1)
        local diff = math.abs(pair.on - pair.off) / big
        local verdict = diff <= 0.2 and "PASS" or "FAIL"
        LF.log(string.format("TEST 4 %s: stress pair - on screen %d men hit, off screen %d (%.0f%% apart, 20%% allowed)",
            verdict, pair.on, pair.off, diff * 100))
        LF.say(string.format("Test 4 %s: on screen %d hit, off screen %d (%.0f%% apart)", verdict, pair.on, pair.off, diff * 100))
        pair = {}
    else
        LF.say("Test 4: " .. hits .. " men hit " .. (stress.offscreen and "off" or "on") .. " screen - now run the "
            .. (stress.offscreen and "on" or "off") .. "-screen half")
    end
end

LF.onTick("Debug", function()
    if not stress or LF.frame % 30 ~= 0 then return end
    local w = LF.Perf.last()
    if w and w ~= stress.seen then
        stress.seen = w
        stress.windows[#stress.windows + 1] = w
        if #stress.windows >= STRESS_WINDOWS then
            LF.guard("stress summary", stressSummary)
            stress = nil
        end
    end
end)

-- ---- you, while testing: god mode, and the soldiers leave you alone -------------------------------
-- On by default while the mod is in debug (Tools to turn it off). Soldiers don't pick you as a
-- target (when fire at you comes, from 0.72, it is skipped), and nothing can kill you.
LF.Debug = LF.Debug or {}
function LF.Debug.playerSafe()
    local d = LF.Records.data()
    if d.debugPlayerSafe == nil then return true end
    return d.debugPlayerSafe
end
LF.onTick("Debug", function()
    if LF.frame % 60 ~= 13 then return end
    local p = getPlayer()
    if not p or p:isDead() then return end
    local on = LF.Debug.playerSafe()
    local okG, god = pcall(function() return p:isGodMod() end)
    if okG and god ~= on then
        -- (Forced, as for the medic's critical men: the plain call needs a capability the game may
        -- not grant outside its own debug mode.)
        pcall(function() p:setGodMod(on, true) end)
        local _, now = pcall(function() return p:isGodMod() end)
        if now ~= on and not LF.Debug.godWarned then
            LF.Debug.godWarned = true
            LF.log("DEBUG couldn't set god mode on the player (" .. tostring(on) .. ")")
        end
    end
end)

local function holdObj(u, obj)
    -- Far away: patrol there first, then hold it.
    local ux, uy = unitPos(u)
    if ux and LF.dist(ux, uy, obj.x, obj.y) > 25 then
        local ok, why = LF.March.order(u, math.floor(obj.x), math.floor(obj.y), obj.z, "auto")
        if ok then
            u.pendingHold = obj.id
            LF.say(u.name .. " patrols to " .. obj.name .. " to hold it")
        else
            LF.say("Can't move: " .. tostring(why))
        end
        return true
    end
    return false
end

local function holdOf(u, x, y, z, given)
    local obj = given or objectiveAt(x, y, z)
    if not obj then LF.say("Objectives are buildings - right-click on one"); return end
    -- A friendly unit already holds it: help that unit hold it (one objective, one defence).
    for _, other in pairs(LF.Units.all()) do
        local t = other.objTask
        if other ~= u and other.kind == "squad" and not other.joined and other.faction == u.faction
            and t and t.kind == "hold" and t.obj == obj.id then
            local ok, why = LF.Join.attach(other, u, "defend")
            if ok then
                -- Re-deal the defence with the new team in it.
                LF.Tactics.setStance(other, "defensive", obj.building and { x = math.floor(obj.x), y = math.floor(obj.y), z = obj.z } or nil)
                LF.say(u.name .. " joins " .. other.name .. " to hold " .. obj.name)
                return
            end
            LF.say(u.name .. " can't join " .. other.name .. " (" .. tostring(why) .. ") - holding " .. obj.name .. " alongside it")
            break
        end
    end
    if holdObj(u, obj) then return end          -- far away: it patrols there first
    LF.Objective.hold(u, obj)
    LF.Tactics.noteStanceSet(u)
    LF.say(u.name .. " holds " .. obj.name)
end

local function takeOf(u, x, y, z, given)
    local obj = given or objectiveAt(x, y, z)
    if not obj then LF.say("Objectives are buildings - right-click on one"); return end
    local ok, why = LF.Objective.take(u, obj)
    LF.say(ok and (u.name .. " moves to take " .. obj.name) or ("Can't: " .. tostring(why)))
end

-- (For the orders given from the world map - LF_Map.)
LF.Debug.orders = { unitList = unitList, platoonList = platoonList, takeOf = takeOf, holdOf = holdOf, patrolOf = patrolOf }

local function clearObjectives()
    LF.Objective.clear()
    LF.say("Objectives cleared")
end


-- ---- the 0.73 tests ---------------------------------------------------------------------------
-- One click sets each up and the log (TEST ...) gives the verdict. A Soviet rifle squad spawns
-- where you click, a German machine-gun squad beyond it (on the far side from you) holding where
-- it is; the Soviet squad's meter is watched once a second.
--   1  open:  defensive in the open, gun 26 tiles off: pinned within 30 s of the gun opening up
--   2  wall:  holding the building you clicked, gun 26 tiles off: suppressed but never pinned
--   (26: inside the 30 tiles a man can see - at 35, 0.73.1, the two never saw each other)
--   3  break: offensive in the open with its nerve already gone (morale 25), gun 18 tiles off (a
--             squad only falls back from inside 26 tiles): pinned, falls back at least 5 tiles
--             together (spread no more than 4 tiles wider than it was before it broke), then
--             rallies - stops falling back and holds

local TESTS = {
    open = { n = 1, name = "MG pins a squad in the open", secs = 60 },
    wall = { n = 2, name = "the same squad behind a wall only gets suppressed", secs = 60 },
    broke = { n = 3, name = "a broken squad falls back together and rallies", secs = 120 },
}
local test = nil

-- The fit men of a squad: their middle, how many, and the farthest of them from the middle.
local function squadSpread(sid)
    local xs, ys = {}, {}
    for _, rid in ipairs(LF.Units.members(sid)) do
        local b = LF.Bodies.get(rid)
        local r = LF.Records.get(rid)
        if b and not b:isDead() and r and not r.wounded and not r.aid then
            xs[#xs + 1], ys[#ys + 1] = b:getX(), b:getY()
        end
    end
    local n = #xs
    if n == 0 then return nil end
    local cx, cy = 0, 0
    for i = 1, n do cx, cy = cx + xs[i], cy + ys[i] end
    cx, cy = cx / n, cy / n
    local far = 0
    for i = 1, n do far = math.max(far, LF.dist(cx, cy, xs[i], ys[i])) end
    return { x = cx, y = cy, n = n, far = far }
end

local function startTest(kind, x, y, z, playerNum)
    if test then LF.say("A test is already running - stop it first"); return end
    local T = TESTS[kind]
    if kind == "wall" and not LF.Building.idAt(x, y, z) then
        LF.say("Test 2: right-click inside a building (the squad holds it)"); return
    end
    local p = getSpecificPlayer(playerNum)
    local fx, fy = 1, 0
    if p then fx, fy = x + 0.5 - p:getX(), y + 0.5 - p:getY() end
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 2 then fx, fy = 1, 0 else fx, fy = fx / len, fy / len end
    local tx, ty = x + 0.5, y + 0.5
    local range = kind == "broke" and 18 or 26
    local gx, gy = tx + fx * range, ty + fy * range
    local target = LF.Units.createSquad("SOV", tx, ty, z, fx, fy)
    local gun = LF.Units.createSquad("GER", gx, gy, 0, -fx, -fy, false, true)
    LF.Tactics.setStance(target, kind == "broke" and "offensive" or "defensive", kind == "wall" and { x = x, y = y, z = z } or nil)
    LF.Tactics.setStance(gun, "defensive", nil)
    LF.Tactics.noteStanceSet(target)
    LF.Tactics.noteStanceSet(gun)
    if kind == "broke" then
        for _, rid in ipairs(LF.Units.members(target.id)) do
            local r = LF.Records.get(rid)
            if r then r.morale = 25 end
        end
    end
    test = { kind = kind, T = T, target = target.id, gun = gun.id, t0 = LF.simTime, peak = 0, at = {},
             state = "steady", gx = gx, gy = gy, far = 0, bursts = LF.MG and LF.MG.bursts or 0,
             rounds = LF.MG and LF.MG.rounds or 0 }
    LF.log(string.format("TEST %d start: %s - %s at (%d,%d), %s %d tiles away at (%d,%d); version %s",
        T.n, T.name, target.name, math.floor(tx), math.floor(ty), gun.name, range, math.floor(gx), math.floor(gy), tostring(LF.VERSION)))
    LF.say("Test " .. T.n .. ": " .. T.name .. " - verdict in the log in " .. T.secs .. " s (game time)")
end

local function verdict()
    local t, T = test, test.T
    local fire = t.at.fire
    local ok, words
    if not fire then
        ok, words = false, "the gun never got a round onto the squad - check the two spots can see each other"
    elseif t.kind == "open" then
        local pin = t.at.pinned
        ok = pin ~= nil and pin - fire <= 30
        words = pin and string.format("pinned %.0f s after the first round", pin - fire)
            or string.format("never pinned (meter peaked at %.0f, pinned is 65)", t.peak)
    elseif t.kind == "wall" then
        ok = t.at.suppressed ~= nil and not t.at.pinned
        words = t.at.pinned and string.format("pinned after %.0f s (peak %.0f) - cover isn't helping enough", t.at.pinned - fire, t.peak)
            or t.at.suppressed and string.format("suppressed after %.0f s, never pinned (peak %.0f)", t.at.suppressed - fire, t.peak)
            or string.format("never even suppressed (peak %.0f, suppressed is 30)", t.peak)
    else
        local fell, rally = t.at.fell, t.at.rallied
        local back = t.backBy or 0
        local base = t.baseFar or 12
        ok = t.at.pinned ~= nil and fell ~= nil and back >= 5 and t.far <= base + 4 and rally ~= nil
        local parts = {}
        parts[#parts + 1] = t.at.pinned and string.format("pinned at %.0f s", t.at.pinned - fire) or string.format("never pinned (peak %.0f)", t.peak)
        parts[#parts + 1] = fell and string.format("fell back at %.0f s, %.0f tiles, widest spread %.0f tiles (%.0f before)", fell - fire, back, t.far, base)
            or "never fell back"
        parts[#parts + 1] = rally and string.format("rallied at %.0f s (%s)", rally - fire, t.rallyState or "?") or "never stopped falling back"
        words = table.concat(parts, "; ")
    end
    local guns = string.format("the gun fired %d bursts (%d rounds)", (LF.MG and LF.MG.bursts or 0) - t.bursts,
        (LF.MG and LF.MG.rounds or 0) - t.rounds)
    words = words .. "; " .. guns
    LF.log(string.format("TEST %d %s: %s - %s", T.n, ok and "PASS" or "FAIL", T.name, words))
    LF.say("Test " .. T.n .. (ok and " PASS: " or " FAIL: ") .. words)
    test = nil
end

local function testTick()
    local t = test
    if not t then return end
    local el = LF.simTime - t.t0
    if el < 0 then test = nil; return end           -- (a reload)
    local v = LF.Suppress.squadValue(t.target)
    local st = LF.Suppress.squadState(t.target)
    if v > 0 and not t.at.fire then t.at.fire = el end
    if v > t.peak then t.peak = v end
    if st ~= "steady" and not t.at[st] then t.at[st] = el end
    if st == "pinned" and not t.at.suppressed then t.at.suppressed = el end
    local intent = LF.Tactics.intent(t.target)
    local sp = squadSpread(t.target)
    if sp and not t.at.fell then t.baseFar = math.max(t.baseFar or 0, sp.far) end
    if intent == "FALLBACK" and not t.at.fell then
        t.at.fell = el
        if sp then t.fromGun = LF.dist(sp.x, sp.y, t.gx, t.gy) end
    end
    if t.at.fell and sp then
        if t.fromGun then t.backBy = math.max(t.backBy or 0, LF.dist(sp.x, sp.y, t.gx, t.gy) - t.fromGun) end
        if el - t.at.fell <= 30 then t.far = math.max(t.far, sp.far) end
        if intent ~= "FALLBACK" and not t.at.rallied then t.at.rallied, t.rallyState = el, st end
    end
    if st ~= t.state or intent ~= t.intent then
        LF.log(string.format("TEST %d t=%.0fs meter %.0f %s, intent %s%s", t.T.n, el, v, st, tostring(intent),
            sp and string.format(", %d fit, spread %.0f", sp.n, sp.far) or ""))
        t.state, t.intent = st, intent
    end
    if el >= t.T.secs then verdict() end
end
LF.onTick("Debug", function()
    if test and LF.due(60, 23) then LF.guard("test", testTick) end
end)

local function testLine()
    local t = test
    if not t then return nil end
    return string.format("Running: test %d, %.0f s of %d, meter %.0f (%s) - click to stop", t.T.n,
        LF.simTime - t.t0, t.T.secs, LF.Suppress.squadValue(t.target), LF.Suppress.squadState(t.target))
end

local function sub(menu, label)
    local o = menu:addOption(label)
    local m = ISContextMenu:getNew(menu)
    menu:addSubMenu(o, m)
    return m
end

local function onMenu(playerNum, context, worldObjects, test)
    if test then return end
    local sq = LF.try("clicked square", function() return worldObjects[1]:getSquare() end)
    if not sq then
        local p = getSpecificPlayer(playerNum)
        sq = p and p:getSquare()
    end
    if not sq then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()

    -- Inspect the soldiers right here.
    for _, f in ipairs(LF.Inspect.near(x, y, z)) do
        local rec = LF.Records.get(f.id)
        if rec then
            local id = f.id
            context:addOption("Inspect " .. LF.Units.title(rec), nil, function() LF.Inspect.open(id) end)
        end
    end

    local main = sub(context, "Living Front")

    -- Spawn.
    local spawn = sub(main, "Spawn here")
    for _, f in ipairs({ { "GER", "German" }, { "SOV", "Soviet" } }) do
        local fm = sub(spawn, f[2])
        local key = f[1]
        -- (Units spawned here are outside any chain of command. A company's platoons are spawned
        -- by right-clicking its captain.)
        fm:addOption("Squad (10)", nil, function() spawnUnit(key, x, y, z, "squad", playerNum) end)
        fm:addOption("Machine-gun squad (10, " .. (key == "GER" and "2 MG34s" or "2 DP-27s") .. ")", nil,
            function() spawnUnit(key, x, y, z, "mg", playerNum) end)
        fm:addOption("Platoon (43: HQ + 3 rifle squads + MG squad)", nil, function() spawnUnit(key, x, y, z, "platoonMG", playerNum) end)
        fm:addOption("Company HQ (10: Capt., 1stSgt., XO, radio, surgeon, security team)", nil,
            function() spawnUnit(key, x, y, z, "companyHQ", playerNum) end)
    end

    -- Orders: pick any unit in the game (nearest the click first), then what it does here.
    local building = LF.Building.idAt(x, y, z) ~= nil
    local orders = sub(main, "Give orders to")
    -- (Each part of the menu is built on its own: a slip in one - 0.49.0 broke on the platoon list -
    -- doesn't take the rest of the menu, the tools included, with it.)
    local any = false
    LF.guard("menu: orders", function()
        local lists = unitList(x, y)
        local plists = platoonList(x, y)
        for _, f in ipairs({ { "GER", "German platoons" }, { "SOV", "Soviet platoons" } }) do
            local list = plists[f[1]]
            if list and #list > 0 then
                any = true
                local fm = sub(orders, f[2])
                for _, e in ipairs(list) do
                    local plt = e.p
                    local pm = sub(fm, LF.Platoon.describe(plt) .. string.format(" (%d tiles)", math.floor(e.d)))
                    pm:addOption("Patrol here (squads abreast, HQ centre rear)", nil, function()
                    local ok, why = LF.Platoon.patrol(plt, x, y, z)
                    LF.say(ok and (plt.name .. " patrols there") or ("Can't: " .. tostring(why)))
                end)
                pm:addOption(building and "Take this building" or "Take this spot", nil, function()
                        local obj = objectiveAt(x, y, z)
                        if not obj then LF.say("Objectives are buildings - right-click on one"); return end
                        local ok, why = LF.Platoon.take(plt, obj)
                        LF.say(ok and (plt.name .. " moves to take " .. obj.name) or ("Can't: " .. tostring(why)))
                    end)
                    pm:addOption(building and "Hold this building" or "Hold this spot", nil, function()
                        local obj = objectiveAt(x, y, z)
                        if not obj then LF.say("Objectives are buildings - right-click on one"); return end
                        local ok, why = LF.Platoon.hold(plt, obj)
                        LF.say(ok and (plt.name .. " holds " .. obj.name) or ("Can't: " .. tostring(why)))
                    end)
                    pm:addOption("Withdraw to here", nil, function()
                        LF.Platoon.withdraw(plt, x, y, z, "debug order")
                        LF.say(plt.name .. " withdraws")
                    end)
                    local cmd = LF.Platoon.commander(plt)
                    if cmd then
                        local cid = cmd.id
                        pm:addOption("Inspect " .. LF.Units.title(cmd), nil, function() LF.Inspect.open(cid) end)
                    end
                end
            end
        end
        for _, f in ipairs({ { "GER", "German units" }, { "SOV", "Soviet units" }, { "CIV", "Civilian units" } }) do
            local list = lists[f[1]]
            if list and #list > 0 then
                any = true
                local fm = sub(orders, f[2])
                for _, e in ipairs(list) do
                    local u = e.u
                    local st = LF.Stance.get(u).name
                    local task = u.objTask and (" - " .. u.objTask.kind) or ""
                    local um = sub(fm, string.format("%s  (%d/%d, %s%s, %d tiles)", u.name, e.n, e.total, st, task, math.floor(e.d)))
                    local sm = sub(um, "Stance (now " .. st .. ")")
                    sm:addOption("Stand by (rest where it is)", nil, function() setStanceOf(u, x, y, z, "standby") end)
                    sm:addOption("Offensive", nil, function() setStanceOf(u, x, y, z, "offensive") end)
                    sm:addOption(building and "Defensive - hold this building" or "Defensive - all-round, where it is",
                        nil, function() setStanceOf(u, x, y, z, "defensive") end)
                    um:addOption("Patrol here", nil, function() patrolOf(u, x, y, z, "auto") end)
                    um:addOption(building and "Take this building (objective)" or "Take this spot (objective)", nil, function() takeOf(u, x, y, z) end)
                    um:addOption(building and "Hold this building (objective)" or "Hold this spot (objective)", nil, function() holdOf(u, x, y, z) end)
                    -- Any objective, wherever it is (no need to be near it).
                    local objs = {}
                    for _, o in pairs(LF.Objective.all()) do objs[#objs + 1] = o end
                    table.sort(objs, function(a, b) return a.id < b.id end)
                    if #objs > 0 then
                        local ux, uy = unitPos(u)
                        local function label(o)
                            local holder = o.holder and (", held by the " .. (o.holder == "GER" and "Germans" or o.holder == "SOV" and "Soviets" or o.holder)) or ""
                            return o.name .. " (" .. math.floor(LF.dist(ux or o.x, uy or o.y, o.x, o.y)) .. " tiles" .. holder .. ")"
                        end
                        local am = sub(um, "Attack an objective")
                        local hm = sub(um, "Hold an objective")
                        for _, o in ipairs(objs) do
                            local obj = o
                            am:addOption(label(obj), nil, function() takeOf(u, x, y, z, obj) end)
                            hm:addOption(label(obj), nil, function() holdOf(u, x, y, z, obj) end)
                        end
                    end
                    local cid = LF.Units.commander(u)
                    if cid then um:addOption("Inspect its leader", nil, function() LF.Inspect.open(cid) end) end
                end
            end
        end
    end)
    if not any then orders:addOption("(no units yet - spawn some)") end


    -- Tests (0.73).
    LF.guard("menu: tests", function()
        local tm = sub(main, "Tests (0.73)")
        local line = testLine()
        if line then tm:addOption(line, nil, function() test = nil; LF.say("Test stopped") end) end
        tm:addOption("1. MG pins a squad in the open (right-click open ground, open to the far side)", nil,
            function() startTest("open", x, y, z, playerNum) end)
        tm:addOption("2. The same squad behind a wall only gets suppressed (right-click inside a building)", nil,
            function() startTest("wall", x, y, z, playerNum) end)
        tm:addOption("3. A broken squad falls back together and rallies (right-click open ground)", nil,
            function() startTest("broke", x, y, z, playerNum) end)
        if stress then
            tm:addOption("4. Stress pair: running - summary in the log when done")
        else
            tm:addOption("4a. Stress pair, on screen (right-click a building)" .. (pair.on and (" - done: " .. pair.on .. " hit") or ""), nil,
                function() stressTest(x, y, z) end)
            tm:addOption("4b. Stress pair, off screen (same building)" .. (pair.off and (" - done: " .. pair.off .. " hit") or ""), nil,
                function() stressTest(x, y, z, true) end)
        end
        tm:addOption("(Before each: Tools > Delete ALL NPCs. Verdicts: TEST lines in the log)")
    end)

    -- Tools.
    LF.guard("menu: tools", function()
    local tools = sub(main, "Tools")
    do
        local safe = LF.Debug.playerSafe()
        tools:addOption("You: god mode, ignored by soldiers: " .. (safe and "ON (click to turn off)" or "OFF (click to turn on)"), nil, function()
            LF.Records.data().debugPlayerSafe = not LF.Debug.playerSafe()
            LF.say("God mode, ignored by soldiers: " .. (LF.Debug.playerSafe() and "ON" or "OFF"))
        end)
    end
    if LF.Ground then
        local OV = LF.Ground.overlay
        local words = { off = "off", cover = "cover", sight = "how far you can see" }
        tools:addOption("Ground overlay: " .. words[OV.mode] .. " (click to change)", nil, function()
            LF.say("Ground overlay: " .. words[LF.Ground.cycleMode()])
        end)
        if OV.mode ~= "off" then
            tools:addOption("Ground overlay direction: " .. LF.Ground.DIR_NAMES[OV.dir + 1] .. " (click to turn)", nil, function()
                LF.say("Overlay direction: " .. LF.Ground.DIR_NAMES[LF.Ground.cycleDir() + 1])
            end)
        end
    end
    if LF.Captain then
        local on = LF.Captain.CFG.on
        tools:addOption("Captains command their companies: " .. (on and "ON (click to stop)" or "OFF (click to start)"), nil, function()
            LF.say("Captains command their companies: " .. (LF.Captain.toggle() and "ON" or "OFF"))
        end)
    end
    if LF.Map and LF.Map.CFG then
        local mm = sub(tools, "Map")
        local C = LF.Map.CFG
        mm:addOption("Unit trackers: " .. (C.trackers and "ON" or "OFF"), nil, function()
            C.trackers = not C.trackers
            LF.say("Unit trackers on the map: " .. (C.trackers and "ON" or "OFF"))
        end)
        mm:addOption("Whole map shown: " .. (C.revealAll and "ON" or "OFF"), nil, function()
            LF.Map.setRevealAll(not C.revealAll)
            LF.say("Whole map shown: " .. (C.revealAll and "ON" or "OFF"))
        end)
        mm:addOption("Game keeps running while it's open: " .. (C.mapRuns and "ON" or "OFF"), nil, function()
            C.mapRuns = not C.mapRuns
            LF.say("Game keeps running with the map open: " .. (C.mapRuns and "ON" or "OFF"))
        end)
        if LF.Front then
            local ORDER = { "truth", "GER", "SOV", "off" }
            local cur = C.warView or "truth"
            local words = LF.Map.VIEW_WORDS and LF.Map.VIEW_WORDS[cur] or (cur == "off" and "off")
            mm:addOption("Front: " .. (words or "off") .. " (click to change)", nil, function()
                local i = 1
                for k, v in ipairs(ORDER) do if v == cur then i = k end end
                local nxt = ORDER[i % #ORDER + 1]
                C.warView = nxt
                LF.say("Front on the map: " .. ((LF.Map.VIEW_WORDS and LF.Map.VIEW_WORDS[nxt]) or "off"))
            end)
        end
    end
    tools:addOption("Clear all objectives", nil, clearObjectives)
    tools:addOption("Delete ALL NPCs", nil, function() test = nil; deleteAll() end)
    tools:addOption("Reset world (clear bodies, blood, debris; refuel vehicles; heal me; 08:00; no fog)", nil, function() resetWorld(playerNum) end)
    end)
end

Events.OnFillWorldObjectContextMenu.Add(onMenu)

Events.OnGameStart.Add(function()
    local dropped = LF.Records.dropOutdated()
    if dropped > 0 then LF.log("removed " .. dropped .. " NPC records from an older mod version") end
    LF.log("v" .. LF.VERSION .. " loaded, " .. LF.Records.count() .. " NPC records in this save")
end)
