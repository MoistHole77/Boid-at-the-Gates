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

local function stressTest(x, y, z)
    local obj = objectiveAt(x, y, z)
    if not obj then LF.say("Right-click on a building for the stress test"); return end
    if not (LF.Config.logPerf) then LF.Perf.toggle() end
    local ger = LF.Platoon.create("GER", obj.x + 0.5, obj.y + 0.5, obj.z or 0, 1, 0, true)
    local sov = LF.Platoon.create("SOV", obj.x + 70.5, obj.y + 0.5, obj.z or 0, -1, 0, true)
    local okH, whyH = LF.Platoon.hold(ger, obj)
    local okT, whyT = LF.Platoon.take(sov, obj)
    stress = { started = getTimestampMs(), windows = {}, seen = LF.Perf.last(), obj = obj.name }
    LF.log(string.format("STRESS start at %s (%d,%d): %s holds it (%s), %s attacks from 70 tiles east (%s); version %s",
        obj.name, math.floor(obj.x), math.floor(obj.y), ger.name, okH and "ok" or tostring(whyH), sov.name,
        okT and "ok" or tostring(whyT), tostring(LF.VERSION)))
    LF.say("Stress test: " .. ger.name .. " holds " .. obj.name .. ", " .. sov.name .. " attacks - summary in the log in 2 minutes")
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
    LF.say(string.format("Stress test done: %.1f fps, frame %.1f ms, mod %.2f ms - see the log", fps / n, f / n, m / n))
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


    -- Tools.
    LF.guard("menu: tools", function()
    local tools = sub(main, "Tools")
    if LF.Map and LF.Map.CFG then
        local on = LF.Map.CFG.trackers
        tools:addOption("Unit trackers on the map: " .. (on and "ON (click to hide)" or "OFF (click to show)"), nil, function()
            LF.Map.CFG.trackers = not LF.Map.CFG.trackers
            LF.say("Unit trackers on the map: " .. (LF.Map.CFG.trackers and "ON" or "OFF"))
        end)
    end
    if LF.Map and LF.Map.CFG then
        local reveal, runs = LF.Map.CFG.revealAll, LF.Map.CFG.mapRuns
        tools:addOption("Map: show the whole map: " .. (reveal and "ON (click to hide unvisited)" or "OFF (click to show all)"), nil, function()
            LF.Map.setRevealAll(not LF.Map.CFG.revealAll)
            LF.say("Whole map shown: " .. (LF.Map.CFG.revealAll and "ON" or "OFF"))
        end)
        tools:addOption("Map: the game keeps running while it's open: " .. (runs and "ON (click to pause instead)" or "OFF (click to keep running)"), nil, function()
            LF.Map.CFG.mapRuns = not LF.Map.CFG.mapRuns
            LF.say("Game keeps running with the map open: " .. (LF.Map.CFG.mapRuns and "ON - speed buttons on the map" or "OFF"))
        end)
    end
    if LF.Captain then
        local on = LF.Captain.CFG.on
        tools:addOption("Captains command their companies: " .. (on and "ON (click to stop)" or "OFF (click to start)"), nil, function()
            LF.say("Captains command their companies: " .. (LF.Captain.toggle() and "ON" or "OFF"))
        end)
    end
    if LF.Map and LF.Map.CFG then
        local on = LF.Map.CFG.platoonPicture
        tools:addOption("Lieutenants' picture on the map: " .. (on and "ON (click to hide)" or "OFF (click to show)"), nil, function()
            LF.Map.CFG.platoonPicture = not LF.Map.CFG.platoonPicture
            LF.say("Lieutenants' picture on the map: " .. (LF.Map.CFG.platoonPicture and "ON" or "OFF"))
        end)
    end
    if LF.Map and LF.Map.CFG and LF.Front then
        local ORDER = { "truth", "GER", "SOV", "off" }
        local cur = LF.Map.CFG.warView or "truth"
        local words = LF.Map.VIEW_WORDS and LF.Map.VIEW_WORDS[cur] or (cur == "off" and "off")
        tools:addOption("Front on the map: " .. (words or "off") .. " (click to change)", nil, function()
            local i = 1
            for k, v in ipairs(ORDER) do if v == cur then i = k end end
            local nxt = ORDER[i % #ORDER + 1]
            LF.Map.CFG.warView = nxt
            LF.say("Front on the map: " .. ((LF.Map.VIEW_WORDS and LF.Map.VIEW_WORDS[nxt]) or "off"))
        end)
    end
    if LF.Radio then
        local cur = LF.Radio.SIDES[LF.Radio.listening()] or "?"
        tools:addOption("Radio: listening to " .. cur .. " (click to change)", nil, function()
            local _, words = LF.Radio.cycle()
            LF.say("Radio: listening to " .. words)
        end)
    end
    if LF.Chasm then
        local st = LF.Chasm.status()
        local words = { ok = "ready", starting = "loading", missing = "not found (see the bridge window)", off = "off" }
        tools:addOption("LF bridge: " .. (st.alive and ("running - language model " .. (words[st.llm] or st.llm))
            or "not running - soldiers answer in Living Front's own words"))
    end
    if LF.Wounds and LF.AidPost then
        local wm = sub(tools, "Wounds and the aid post")
        for _, g in ipairs({ "light", "serious", "critical" }) do
            wm:addOption("Give the nearest soldier a " .. g .. " wound", nil, function() LF.Wounds.test(x, y, g) end)
        end
        if LF.XO then wm:addOption("Supply run now (every company)", nil, LF.XO.runNow) end
        wm:addOption("Company status (aid post, replacements, supplies) - to the log", nil, function()
            local n = 0
            for _, c in pairs(LF.Units.all()) do
                if c.kind == "company" and LF.Company.hq(c) then
                    n = n + 1
                    for _, l in ipairs(LF.AidPost.status(c)) do LF.log("STATUS " .. l) end
                    local xo = LF.XO and LF.XO.of(c)
                    LF.log("STATUS XO: " .. (xo and LF.Units.title(xo) or "none"))
                end
            end
            LF.say(n > 0 and ("Status of " .. n .. " compan" .. (n == 1 and "y" or "ies") .. " written to the log (hover the red cross on the map too)")
                or "No companies")
        end)
    end
    if LF.Ground then
        local OV = LF.Ground.overlay
        local gm = sub(tools, "Ground: cover map and sight (overlay " .. OV.mode .. ")")
        local words = { off = "off", cover = "cover", sight = "how far you can see" }
        gm:addOption("Overlay: " .. words[OV.mode] .. " (click to change)", nil, function()
            local m = LF.Ground.cycleMode()
            LF.say("Ground overlay: " .. words[m])
        end)
        gm:addOption("Overlay direction: from / toward the " .. LF.Ground.DIR_NAMES[OV.dir + 1] .. " (click to turn)", nil, function()
            local d = LF.Ground.cycleDir()
            LF.say("Overlay direction: " .. LF.Ground.DIR_NAMES[d + 1])
        end)
        local nc, ns = LF.Ground.size()
        gm:addOption(string.format("Cached: cover of %d squares, sight of %d", nc, ns))
    end
    do
        local safe = LF.Debug.playerSafe()
        tools:addOption("You: god mode, ignored by soldiers: " .. (safe and "ON (click to turn off)" or "OFF (click to turn on)"), nil, function()
            LF.Records.data().debugPlayerSafe = not LF.Debug.playerSafe()
            LF.say("God mode, ignored by soldiers: " .. (LF.Debug.playerSafe() and "ON" or "OFF"))
        end)
    end
    tools:addOption(stress and "Stress test running - summary in the log when done" or "Stress test here (right-click a building): a German platoon holds it, a Soviet platoon attacks",
        nil, function() if not stress then stressTest(x, y, z) end end)
    tools:addOption("Clear all objectives", nil, clearObjectives)
    tools:addOption("Delete ALL NPCs", nil, deleteAll)
    tools:addOption("Reset world (clear bodies, blood, debris; refuel vehicles; heal me; 08:00; no fog)", nil, function() resetWorld(playerNum) end)
    end)
end

Events.OnFillWorldObjectContextMenu.Add(onMenu)

Events.OnGameStart.Add(function()
    local dropped = LF.Records.dropOutdated()
    if dropped > 0 then LF.log("removed " .. dropped .. " NPC records from an older mod version") end
    LF.log("v" .. LF.VERSION .. " loaded, " .. LF.Records.count() .. " NPC records in this save")
end)
