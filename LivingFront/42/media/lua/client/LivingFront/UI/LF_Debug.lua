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
require "LivingFront/World/LF_Influence"
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
local summary076           -- (below)
local reactionSummary      -- (below)
local STRESS_WINDOWS = 24       -- PERF windows (5 s each) = 2 minutes
local pooled = { on = 0, off = 0, nOn = 0, nOff = 0 }   -- every run this session, on and off screen (one fight is ~15 hits: too few to judge alone)

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
-- opts (0.76): walkIn - the fight runs off screen for 60 s, then every man gets his body where he
-- stands (walking into a fight under way); big - two platoons a side (~170 men) with the cap on
-- bodies at 80 if none is set.
local function stressTest(x, y, z, offscreen, opts)
    opts = opts or {}
    local obj = objectiveAt(x, y, z)
    -- (0.81) In the open, for an arena you built (Tools > Arena): a field fight - the Germans dig
    -- in where you clicked, the Soviets advance on them from 70 tiles east.
    local field = false
    if not obj and opts.fieldOk then
        field = true
        obj = { name = "the arena", x = math.floor(x) + 0.5, y = math.floor(y) + 0.5, z = math.floor(z or 0) }
    end
    if not obj then LF.say("Right-click on a building for the stress test"); return end
    if not (LF.Config.logPerf) then LF.Perf.toggle() end
    local ger = LF.Platoon.create("GER", obj.x + 0.5, obj.y + 0.5, obj.z or 0, 1, 0, true)
    local sov = LF.Platoon.create("SOV", obj.x + 70.5, obj.y + 0.5, obj.z or 0, -1, 0, true)
    local gerMen, sovMen = platoonMen(ger), platoonMen(sov)
    local ger2, sov2 = nil, nil
    if opts.big then
        ger2 = LF.Platoon.create("GER", obj.x - 12.5, obj.y + 14.5, obj.z or 0, 1, 0, true)
        sov2 = LF.Platoon.create("SOV", obj.x + 70.5, obj.y + 25.5, obj.z or 0, -1, 0, true)
        for _, rid in ipairs(platoonMen(ger2)) do gerMen[#gerMen + 1] = rid end
        for _, rid in ipairs(platoonMen(sov2)) do sovMen[#sovMen + 1] = rid end
        if (LF.Config.maxBodies or 0) <= 0 then LF.Config.maxBodies = 80; opts.setCap = true end
    end
    if opts.walkIn then offscreen = true end
    if offscreen then
        for _, rid in ipairs(gerMen) do local r = LF.Records.get(rid); if r then r.noBody = true end end
        for _, rid in ipairs(sovMen) do local r = LF.Records.get(rid); if r then r.noBody = true end end
    end
    local okH, whyH, okT, whyT
    if field then
        okH = true
        for _, u in pairs(LF.Units.all()) do
            if u.kind == "squad" and u.platoon == ger.id then
                u.stanceLock = true            -- (0.81.1: they hold - in 0.81 their sergeants went offensive on the numbers)
                LF.Tactics.setStance(u, "defensive", nil)
            end
        end
        okT, whyT = LF.Platoon.patrol(sov, obj.x, obj.y, obj.z)
    else
        okH, whyH = LF.Platoon.hold(ger, obj)
        okT, whyT = LF.Platoon.take(sov, obj)
    end
    if ger2 then LF.Platoon.hold(ger2, obj); LF.Platoon.take(sov2, obj) end
    stress = { started = getTimestampMs(), sim = LF.simTime, windows = {}, seen = LF.Perf.last(), obj = obj.name,
               ger = gerMen, sov = sovMen, offscreen = offscreen, big = opts.big, setCap = opts.setCap, reaction = opts.reaction,
               walkIn = opts.walkIn and { at = LF.simTime + 60, pos = {}, moved = {} } or nil }
    if opts.walkIn then
        LF.log("TEST 0.76 walk-in: the fight runs off screen for 60 s, then every man gets his body where he stands")
    end
    if opts.reaction and LF.Brain.reactions then
        LF.Brain.reactions.shot, LF.Brain.reactions.move = {}, {}
        LF.Brain.thinkCount, LF.Brain.wokenCount, stress.thinkTick = 0, 0, LF.tick
        LF.Brain.thinkStats, LF.Brain.oldThinks, LF.Brain.reactions.moveWhy = {}, 0, {}
        if LF.SquadBrain.resetStats then LF.SquadBrain.resetStats() end
        LF.Brain.coverRuns, LF.Brain.leftCover, LF.Brain.runsBy = 0, {}, {}
        LF.log("TEST 0.81 open ground: the stress fight - men left in the open with cover near, spot searches, cost")
    end
    if opts.big then
        LF.log(string.format("TEST 0.76 big fight: %d men, the cap on bodies at %d", #gerMen + #sovMen, LF.Config.maxBodies or 0))
    end
    LF.log(string.format("STRESS start%s at %s (%d,%d): %s holds it (%s), %s attacks from 70 tiles east (%s); version %s",
        offscreen and " (OFF-SCREEN: no bodies)" or "", obj.name, math.floor(obj.x), math.floor(obj.y), ger.name,
        okH and "ok" or tostring(whyH), sov.name, okT and "ok" or tostring(whyT), tostring(LF.VERSION)))
    LF.say("Stress test" .. (offscreen and " (off-screen)" or "") .. ": " .. ger.name .. " holds " .. obj.name .. ", "
        .. sov.name .. " attacks - summary in the log in 2 minutes")
end


-- ---- the 0.74 gate, watched during an on-screen stress test -------------------------------------
-- Every 5 s, every fit man of the two platoons with a body:
--   in the open: holding (engaged, covering or watching, not on the move), no cover against the
--     nearest enemy his squad knows of, outside any building - and a square with cover against
--     that enemy within 10 tiles of him. Two looks running (10 s) = left in the open.
--   among another squad: nearer another squad of his own side's middle than his own (by 3 tiles
--     or more, and 8 or more from his own). Two looks running = crossing.
-- The summary gives both counts (the gate: none of either) and the mod's cost per frame.
local HOLDING = { engage = true, alert = true, guard = true }

local function moving(body)
    local q = ISTimedActionQueue.getTimedActionQueue(body)
    local a = q and q.queue and q.queue[1]
    return a ~= nil and (a.Type == "LF_MoveAction" or a.Type == "ISWalkToTimedAction")
end

-- The nearest square within r of (x, y) with cover against (tx, ty): its distance, or nil.
local function coverWithin(x, y, z, tx, ty, r)
    local bx, by = math.floor(x), math.floor(y)
    local cell = getCell()
    for d = 1, r do
        for dx = -d, d do
            for dy = -d, d do
                if math.max(math.abs(dx), math.abs(dy)) == d then
                    local sq = cell:getGridSquare(bx + dx, by + dy, z)
                    if sq and sq:isFree(false) and LF.Cover.quality(bx + dx, by + dy, z, tx, ty) ~= LF.Cover.NONE then
                        return d
                    end
                end
            end
        end
    end
    return nil
end

local function gateSample()
    local G = stress.gate
    if not G then G = { open = {}, cross = {}, openMen = {}, crossMen = {}, looks = 0 }; stress.gate = G end
    G.looks = G.looks + 1
    -- (0.78) Fire spread: of the men engaging a target, how many different targets.
    do
        local tset, firing = {}, 0
        for _, list in ipairs({ stress.ger or {}, stress.sov or {} }) do
            for _, rid in ipairs(list) do
                if LF.Brain.stateOf(rid) == "engage" then
                    local mm = LF.Brain.mindOf(rid)
                    if mm.targetId then firing = firing + 1; tset[mm.targetId] = true end
                end
            end
        end
        local nt = 0
        for _ in pairs(tset) do nt = nt + 1 end
        G.firing, G.targets = (G.firing or 0) + firing, (G.targets or 0) + nt
    end
    G.idle = G.idle or {}
    G.idleMen = G.idleMen or {}
    -- (0.75) The attackers' assault: a squad flanking while another holds as a base of fire (or
    -- one squad's own teams doing both: its FLANK intent sends alpha round, bravo firing).
    local flanking, basing = nil, false
    for _, rid in ipairs(stress.sov or {}) do
        local r = LF.Records.get(rid)
        local u = r and r.squad and LF.Units.get(r.squad)
        if u and u.kind == "squad" then
            local it = LF.Tactics.intent(u.id)
            -- (A flank started since the last look counts too, however short - 0.75.5: a flank
            -- whose target dropped out of sight a few seconds in was missed between looks.)
            local st = LF.Tactics.state(u)
            local started = st and st.flankStartTick and st.flankStartTick > LF.tick - 300 and LF.simTime - (stress.sim or 0) > 0
            if it == "FLANK" or started then flanking = flanking or u.id end
            if it == "HOLD" and u.id ~= flanking then basing = true end
        end
    end
    if flanking and not G.flankAt then
        G.flankAt = LF.simTime - (stress.sim or LF.simTime)
        G.flankWith = basing and "another squad holding as a base of fire" or "its own bravo team as the base of fire"
        LF.log(string.format("STRESS gate: assault - %s flanks at %.0f s, %s", (LF.Units.get(flanking) or {}).name or "?", G.flankAt, G.flankWith))
    end
    -- The middles of every squad of the two platoons.
    local mids = {}
    local ids = {}
    for _, list in ipairs({ stress.ger or {}, stress.sov or {} }) do
        for _, rid in ipairs(list) do ids[#ids + 1] = rid end
    end
    for _, rid in ipairs(ids) do
        local r = LF.Records.get(rid)
        local b = LF.Bodies.get(rid)
        local u = r and r.squad and LF.Units.get(r.squad)
        if r and r.alive and u and u.kind == "squad" and b and not b:isDead() then
            local m = mids[r.squad]
            if not m then m = { x = 0, y = 0, n = 0, faction = r.faction }; mids[r.squad] = m end
            m.x, m.y, m.n = m.x + b:getX(), m.y + b:getY(), m.n + 1
        end
    end
    for _, m in pairs(mids) do m.x, m.y = m.x / m.n, m.y / m.n end
    for _, rid in ipairs(ids) do
        local r = LF.Records.get(rid)
        local b = LF.Bodies.get(rid)
        local fit = r and r.alive and not r.wounded and not r.aid and r.squad and b and not b:isDead()
        local inOpen, crossing = false, false
        if fit then
            local x, y, z = b:getX(), b:getY(), math.floor(b:getZ())
            local st = LF.Brain.stateOf(rid)
            local sq = getCell():getGridSquare(math.floor(x), math.floor(y), z)
            -- (Judged against the enemy: his target, else the nearest his squad knows of. Not while
            -- pinned - then it's the fire holding him there, not his squad - and not a man watching a
            -- quiet quarter of a perimeter (guard): no fire comes from there - 0.74.4.)
            if st and HOLDING[st] and st ~= "guard" and not moving(b) and sq and not sq:getBuilding() and not LF.Suppress.isPinned(b) then
                local mm = LF.Brain.mindOf(rid)
                local tb = mm.targetId and LF.Bodies.get(mm.targetId)
                local c = nil
                if tb and not tb:isDead() then c = { x = tb:getX(), y = tb:getY() }
                else c = LF.Squad.bestContact(r.squad, x, y, 600, 45) end
                if c and LF.Cover.quality(math.floor(x), math.floor(y), z, c.x, c.y) == LF.Cover.NONE then
                    local d = coverWithin(x, y, z, c.x, c.y, 10)
                    if d then inOpen = true; G.lastOpen = G.lastOpen or {}; G.lastOpen[rid] = d end
                end
            end
            local own = mids[r.squad]
            -- (Men holding still - not marching in a file or moving under orders, where squads
            -- pass close by design - 0.74.3.)
            if own and own.n >= 3 and st and HOLDING[st] and not moving(b) then
                local d0 = LF.dist(x, y, own.x, own.y)
                if d0 >= 8 then
                    for sid, m in pairs(mids) do
                        if sid ~= r.squad and m.faction == r.faction and m.n >= 3 and LF.dist(x, y, m.x, m.y) <= d0 - 3 then
                            crossing = true
                            G.crossWhy = G.crossWhy or {}
                            local ou = LF.Units.get(sid)
                            G.crossWhy[rid] = string.format("%s %.0f tiles off, %s's %.0f; his squad %s, theirs %s",
                                (LF.Units.get(r.squad) or {}).name or "?", d0, ou and ou.name or "?", LF.dist(x, y, m.x, m.y),
                                tostring(LF.Tactics.intent(r.squad)), tostring(LF.Tactics.intent(sid)))
                            break
                        end
                    end
                end
            end
        end
        -- (0.75) Idle in the open: standing about with nothing to do, outdoors, with the enemy his
        -- squad knows of inside 40 tiles.
        local idleOpen = false
        if fit and LF.Brain.stateOf(rid) == "idle" then
            local sq2 = getCell():getGridSquare(math.floor(b:getX()), math.floor(b:getY()), math.floor(b:getZ()))
            if sq2 and not sq2:getBuilding() and LF.Squad.bestContact(r.squad, b:getX(), b:getY(), 600, 40) then idleOpen = true end
        end
        G.idle[rid] = idleOpen and ((G.idle[rid] or 0) + 1) or nil
        if G.idle[rid] == 2 then
            G.idleMen[rid] = true
            LF.log(string.format("STRESS gate: %s idle in the open 10 s at %d,%d, the enemy near (squad %s)", LF.Units.title(r),
                math.floor(b:getX()), math.floor(b:getY()), tostring(LF.Tactics.intent(r.squad))))
        end
        G.open[rid] = inOpen and ((G.open[rid] or 0) + 1) or nil
        G.cross[rid] = crossing and ((G.cross[rid] or 0) + 1) or nil
        if G.open[rid] == 2 then
            G.openMen[rid] = true
            -- (Why: his order, the spot his brain has, and when it last looked for one.)
            local m = LF.Brain.mindOf(rid)
            local c = m.cover
            LF.log(string.format("STRESS gate: %s left in the open 10 s at %d,%d (%s, order %s, %s, looked for cover %s ago, squad %s), cover %d tiles away",
                LF.Units.title(r), math.floor(b:getX()), math.floor(b:getY()), tostring(LF.Brain.stateOf(rid)), tostring(m.order),
                c and string.format("spot %d,%d%s %.0f tiles off", c.x, c.y, c.loose and " (shelter)" or "", LF.dist(b:getX(), b:getY(), c.x + 0.5, c.y + 0.5)) or "no spot",
                m.lastCoverSearch and string.format("%.0f s", (LF.tick - m.lastCoverSearch) / 60) or "never",
                tostring(LF.Tactics.intent(r.squad)), G.lastOpen[rid] or -1))
        end
        if G.cross[rid] == 2 then
            G.crossMen[rid] = true
            LF.log(string.format("STRESS gate: %s among another squad for 10 s at %d,%d (%s, %s; middle of %s)", LF.Units.title(r),
                math.floor(b:getX()), math.floor(b:getY()), tostring(LF.Brain.stateOf(rid)), moving(b) and "moving" or "still",
                G.crossWhy and G.crossWhy[rid] or "?"))
        end
    end
end

local function gateSummary(modMs, bodies)
    local G = stress.gate
    if not G then return end
    local nOpen, nCross = 0, 0
    for _ in pairs(G.openMen) do nOpen = nOpen + 1 end
    for _ in pairs(G.crossMen) do nCross = nCross + 1 end
    local perBody = bodies > 0 and modMs / bodies or 0
    local at72 = perBody * 72
    local ok = nOpen == 0 and nCross == 0 and at72 <= 3
    LF.log(string.format("TEST 0.74 %s: %d men left in the open with cover inside 10 tiles, %d among another squad (%d looks); mod %.2f ms at %d bodies (%.2f ms at 72; the gate 3) - squad brain %s",
        ok and "PASS" or "FAIL", nOpen, nCross, G.looks, modMs, bodies, at72, LF.SquadBrain.enabled and "ON" or "OFF"))
    LF.say(string.format("0.74 gate %s: %d in the open, %d among another squad, %.2f ms at 72 bodies", ok and "PASS" or "FAIL",
        nOpen, nCross, at72))
    -- (0.75) The assault and nobody idle in the open, and the 3 ms carried from 0.74.
    local nIdle = 0
    for _ in pairs(G.idleMen or {}) do nIdle = nIdle + 1 end
    local ok75 = G.flankAt ~= nil and nIdle == 0 and nOpen == 0 and at72 <= 3
    LF.log(string.format("TEST 0.75 %s: assault %s; %d men idle in the open with the enemy near; %d left in the open; %.2f ms at 72 bodies (the gate 3)",
        ok75 and "PASS" or "FAIL", G.flankAt and string.format("flanked at %.0f s with %s", G.flankAt, G.flankWith) or "never flanked",
        nIdle, nOpen, at72))
end

-- ---- the 0.76 tests: walking into a fight under way; a big fight under the cap on bodies ----------
-- Walk-in: after 60 s off screen every man is given his body where his record stands. Each man's
-- position is taken when his body appears and again 15 s later: positions hold if few men have
-- moved far (a man moving under orders - a bound, a flank - is told apart from one re-forming).
-- The usual gate looks (open ground, squads mixing) run from the hand-over on.
local function walkInTick()
    local W = stress.walkIn
    if not W.done then
        if LF.simTime < W.at then return end
        W.done = LF.simTime
        for _, list in ipairs({ stress.ger or {}, stress.sov or {} }) do
            for _, rid in ipairs(list) do
                local r = LF.Records.get(rid)
                if r then r.noBody = nil end
            end
        end
        stress.offscreen = false
        stress.sim = LF.simTime
        stress.windows = {}
        stress.seen = LF.Perf.last()
        LF.log("TEST 0.76 walk-in: hand-over - every man gets his body where he stands")
        LF.say("Walk-in: the fight comes on screen now")
        return
    end
    if not LF.due(30, 9) then return end
    for _, list in ipairs({ stress.ger or {}, stress.sov or {} }) do
        for _, rid in ipairs(list) do
            local b = LF.Bodies.get(rid)
            if b and not b:isDead() then
                local p = W.pos[rid]
                local r = LF.Records.get(rid)
                -- (Under orders: moving in a bound or a file, or his squad flanking, advancing, falling
                -- back, regrouping or marching - when his body appeared or 15 s later. A column leaving
                -- its file in contact, or a flank, should move men - 0.76.1.)
                local function underOrders()
                    local st = LF.Brain.stateOf(rid)
                    if st == "bound" or st == "file" then return true end
                    local sid = r and r.squad
                    if not sid then return false end
                    local it = LF.Tactics.intent(sid)
                    if it == "FLANK" or it == "ADVANCE" or it == "FALLBACK" or it == "REGROUP" then return true end
                    local M = LF.March.get(sid)
                    return M ~= nil and not M.arrived
                end
                if not p then
                    W.pos[rid] = { x = b:getX(), y = b:getY(), t = LF.simTime, orders = underOrders() }
                elseif not W.moved[rid] and LF.simTime - p.t >= 15 then
                    local st = LF.Brain.stateOf(rid)
                    W.moved[rid] = { d = LF.dist(p.x, p.y, b:getX(), b:getY()), orders = p.orders or underOrders(),
                                     squad = r and r.squad, state = st }
                end
            end
        end
    end
end

summary076 = function()
    local G = stress.gate or { openMen = {}, crossMen = {} }
    local nOpen, nCross = 0, 0
    for _ in pairs(G.openMen or {}) do nOpen = nOpen + 1 end
    for _ in pairs(G.crossMen or {}) do nCross = nCross + 1 end
    local W = stress.windows
    local n = #W
    local f, m, fps, bodies = 0, 0, 0, 0
    for _, w in ipairs(W) do f, m, fps, bodies = f + w.frame, m + w.mod, fps + w.fps, math.max(bodies, w.bodies) end
    if n > 0 then f, m, fps = f / n, m / n, fps / n end
    local at72 = bodies > 0 and m / bodies * 72 or 0
    if stress.walkIn then
        local cnt, far, sum, ordered = 0, 0, 0, 0
        for _, v in pairs(stress.walkIn.moved) do
            cnt = cnt + 1
            sum = sum + v.d
            if v.d > 8 then
                if v.orders then ordered = ordered + 1 else far = far + 1 end
            end
        end
        local avg = cnt > 0 and sum / cnt or 0
        -- (Which squads re-formed: name, how many, their stance and what the men were doing.)
        local bySq = {}
        for _, v in pairs(stress.walkIn.moved) do
            if v.d > 8 and not v.orders and v.squad then
                local e = bySq[v.squad]
                if not e then e = { n = 0, states = {} }; bySq[v.squad] = e end
                e.n = e.n + 1
                e.states[tostring(v.state)] = (e.states[tostring(v.state)] or 0) + 1
            end
        end
        for sid, e in pairs(bySq) do
            local u = LF.Units.get(sid)
            local parts = {}
            for st, k in pairs(e.states) do parts[#parts + 1] = st .. " " .. k end
            LF.log(string.format("TEST 0.76 walk-in: %s - %d re-formed (stance %s, intent %s; %s)", u and u.name or tostring(sid), e.n,
                u and LF.Stance.get(u).name or "?", tostring(LF.Tactics.intent(sid)), table.concat(parts, ", ")))
        end
        local ok = cnt > 0 and far <= math.max(2, cnt * 0.1) and nCross == 0
        LF.log(string.format("TEST 0.76 walk-in %s: %d men measured 15 s after their bodies appeared - average %.1f tiles moved, %d moved over 8 tiles re-forming (%d more moving under orders); %d among another squad; %d left in the open; %.1f fps, %.2f ms at 72 bodies",
            ok and "PASS" or "FAIL", cnt, avg, far, ordered, nCross, nOpen, fps, at72))
        LF.say(string.format("Walk-in %s: avg %.1f tiles moved, %d re-formed far, %d mixing", ok and "PASS" or "FAIL", avg, far, nCross))
    else
        local alive = 0
        for _, list in ipairs({ stress.ger or {}, stress.sov or {} }) do
            for _, rid in ipairs(list) do local r = LF.Records.get(rid); if r and r.alive then alive = alive + 1 end end
        end
        local ok = fps >= 30
        LF.log(string.format("TEST 0.76 big fight %s: %d men in it (%d alive at the end), at most %d bodies (cap %s); %.1f fps, frame %.1f ms, mod %.2f ms (%.2f at 72); %d left in the open, %d among another squad",
            ok and "PASS" or "FAIL", #(stress.ger or {}) + #(stress.sov or {}), alive, bodies,
            (LF.Config.maxBodies or 0) > 0 and tostring(LF.Config.maxBodies) or (stress.setCap and "80" or "none"), fps, f, m, at72, nOpen, nCross))
        LF.say(string.format("Big fight %s: %.1f fps with %d bodies", ok and "PASS" or "FAIL", fps, bodies))
    end
end

-- ---- the 0.80 open-ground test ----------------------------------------------------------------------
-- From the stress fight: the verdict is the men left in the open (holding, not pinned, no cover
-- against the enemy, cover inside 10 tiles, two looks running) - fewer than 2. Alongside: the
-- reaction times (first shot once an enemy is in range, first move after an order), the thinks by
-- kind with their cost, the squads' spot searches (how many found nothing, and why), the cost. Also: how spread the fire was (different enemies under fire
-- for each man firing), from the gate looks, and the mod's cost.
local function median(list)
    if #list == 0 then return nil end
    local t = {}
    for i, v in ipairs(list) do t[i] = v end
    table.sort(t)
    return t[math.floor((#t + 1) / 2)]
end

reactionSummary = function(modMs, bodies)
    local R = LF.Brain.reactions
    local shot, move = median(R.shot), median(R.move)
    local G = stress.gate or {}
    local spread = (G.firing or 0) > 0 and (G.targets or 0) / G.firing or 0
    local at72 = bodies > 0 and modMs / bodies * 72 or 0
    local nOpen = 0
    for _ in pairs(G.openMen or {}) do nOpen = nOpen + 1 end
    local ok = nOpen < 2
    LF.log(string.format("TEST 0.81 open ground %s: %d men left in the open with cover inside 10 tiles (fewer than 2 allowed); %.2f ms at 72 bodies",
        ok and "PASS" or "FAIL", nOpen, at72))
    LF.log(string.format("TEST 0.81 reactions: first shot once an enemy is in his range - median %s over %d men (2.6 s in 0.78.1); moving after an order - median %s over %d orders; fire spread %.2f different targets per man firing",
        shot and string.format("%.1f s", shot) or "none", #R.shot,
        move and string.format("%.1f s", move) or "none", #R.move, spread))
    local secs = (LF.tick - (stress.thinkTick or LF.tick)) / 60
    local thinks = LF.Brain.thinkCount or 0
    LF.log(string.format("TEST 0.81 thinking: %d thinks in %.0f s (%.1f a second for every body on average)",
        thinks, secs, (secs > 0 and bodies > 0) and thinks / secs / bodies or 0))
    local SS = LF.SquadBrain.stats
    local W = SS.why or {}
    LF.log(string.format("TEST 0.81 spot searches: %d worked out (%d answered from what the squad already had), %d found nothing, %d found the cover nearest where he was sent; turned down - nothing on his leash %d, wrong cover against his own enemy %d, claimed %d, no view %d; %d placements; cover read from the map %d times, tested live %d; view from the map %d, live %d",
        SS.testSpots or 0, SS.kept or 0, SS.testNone or 0, SS.nearFound or 0, W.empty or 0, W.quality or 0, W.claimed or 0,
        W.noView or 0, SS.testPlaces or 0, SS.tableQ or 0, SS.liveQ or 0, SS.tableV or 0, SS.liveV or 0))
    LF.say(string.format("0.81 open-ground test %s: %d left in the open, %.2f ms at 72 bodies", ok and "PASS" or "FAIL", nOpen, at72))
    -- (0.79.1) What the old rule would have made, and the thinks by kind with their cost.
    local kinds = {}
    for k, v in pairs(LF.Brain.thinkStats or {}) do kinds[#kinds + 1] = { k = k, n = v.n, ms = v.ms } end
    table.sort(kinds, function(a, b) return a.ms > b.ms end)
    local parts = {}
    for _, e in ipairs(kinds) do
        parts[#parts + 1] = string.format("%s %d (%.0f ms, %.2f each)", e.k, e.n, e.ms, e.n > 0 and e.ms / e.n or 0)
    end
    LF.log("TEST 0.81 thinks by kind: " .. table.concat(parts, "; "))
    -- (0.81.2) Running about: runs to a spot, per man in the fight, and why men left cover.
    local nMen = #(stress.ger or {}) + #(stress.sov or {})
    local lw = {}
    for why, k in pairs(LF.Brain.leftCover or {}) do lw[#lw + 1] = why .. " " .. k end
    LF.log(string.format("TEST 0.81 running about: %d runs to a spot (%.1f a man), %d spots kept through a new placement; left cover: %s",
        LF.Brain.coverRuns or 0, nMen > 0 and (LF.Brain.coverRuns or 0) / nMen or 0, SS.held or 0,
        #lw > 0 and table.concat(lw, ", ") or "never"))
    local rb = {}
    for k, v in pairs(LF.Brain.runsBy or {}) do rb[#rb + 1] = k .. " " .. v end
    table.sort(rb)
    LF.log("TEST 0.81 runs by side and kind: " .. table.concat(rb, ", "))
    LF.log("TEST 0.81 moves after orders: " .. table.concat(R.moveWhy or {}, "; "))
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
    if stress.reaction then
        LF.guard("reaction summary", reactionSummary, m / n, bodies)
        return
    end
    if not stress.offscreen then LF.guard("gate summary", gateSummary, m / n, bodies) end
    -- Test 4: the same fight on and off screen should hit about as many men (within 20%).
    -- Test 4: the same fight on and off screen should hit about as many men - the average of every
    -- run this session each way, judged once there are 3 of each (one fight's ~15 hits swing by a
    -- third either way by chance alone). A run whose men were deleted before the end doesn't count.
    local all = stress.ger or {}
    local gone = 0
    for _, ids in ipairs({ stress.ger or {}, stress.sov or {} }) do
        for _, rid in ipairs(ids) do if not LF.Records.get(rid) then gone = gone + 1 end end
    end
    if gone > 0 and gone >= #all + #(stress.sov or {}) then
        LF.log("TEST 4: this run doesn't count - its men were deleted before the end")
        LF.say("Test 4: run not counted (its men were deleted before the end)")
        return
    end
    if stress.setCap then LF.Config.maxBodies = 0 end
    if stress.walkIn or stress.big then
        LF.guard("0.76 summary", summary076)
        return
    end
    local hits = hitCount(stress.ger or {}) + hitCount(stress.sov or {})
    local k = stress.offscreen and "Off" or "On"
    pooled[k == "On" and "on" or "off"] = pooled[k == "On" and "on" or "off"] + hits
    pooled["n" .. k] = pooled["n" .. k] + 1
    local mOn = pooled.nOn > 0 and pooled.on / pooled.nOn or nil
    local mOff = pooled.nOff > 0 and pooled.off / pooled.nOff or nil
    local verdict, diff = "RUN MORE", nil
    if mOn and mOff then
        diff = math.abs(mOn - mOff) / math.max(mOn, mOff, 1)
        if pooled.nOn >= 3 and pooled.nOff >= 3 then verdict = diff <= 0.2 and "PASS" or "FAIL" end
    end
    LF.log(string.format("TEST 4 %s: this run %s screen %d men hit; on screen %d run(s), average %s; off screen %d run(s), average %s%s (20%% allowed, judged from 3 of each)",
        verdict, k == "On" and "on" or "off", hits, pooled.nOn, mOn and string.format("%.1f", mOn) or "-", pooled.nOff,
        mOff and string.format("%.1f", mOff) or "-", diff and string.format(", %.0f%% apart", diff * 100) or ""))
    LF.say(string.format("Test 4 %s: %d hit; on %d runs avg %s, off %d runs avg %s", verdict, hits, pooled.nOn,
        mOn and string.format("%.1f", mOn) or "-", pooled.nOff, mOff and string.format("%.1f", mOff) or "-"))
end

LF.onTick("Debug", function()
    if stress and stress.walkIn then LF.guard("walk-in", walkInTick) end
    if stress and not stress.offscreen and LF.due(300, 151) and LF.simTime - (stress.sim or 0) > 15 then
        LF.guard("gate sample", gateSample)
    end
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
--             together (no man more than 15 tiles from the middle - a squad in a fight here is
--             9-14 tiles across; 0.73.4 judged it against its first few seconds, 7), then
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
        local base = t.baseFar or 0
        ok = t.at.pinned ~= nil and fell ~= nil and back >= 5 and t.far <= 15 and rally ~= nil
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

-- ---- the arena (0.81) ---------------------------------------------------------------------------
-- Low cover you place by hand on open ground, to build a test ground instead of hunting for one: a
-- crate or a counter (the first of these the game has that stands as low cover - something a man
-- can crouch behind and fire over). Kept in the save's records, so "remove" finds them later.
local ARENA_SPRITES = { "carpentry_01_16", "fixtures_counters_01_0", "location_shop_generic_01_40",
                        "furniture_storage_01_8", "carpentry_01_19" }
local function arenaList()
    local d = LF.Records.data()
    d.arena = d.arena or {}
    return d.arena
end
local function spriteOK(name)
    local ok, sp = pcall(function() return getSprite(name) end)
    return ok and sp ~= nil
end
local function placeCover(x, y, z)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, z)
    if not sq then return false, "that square isn't loaded" end
    if not sq:isFree(false) or sq:getBuilding() then return false, "something is already there" end
    for _, name in ipairs(ARENA_SPRITES) do
        if spriteOK(name) then
            local okNew, obj = pcall(function() return IsoObject.new(cell, sq, name) end)
            if okNew and obj then
                sq:AddTileObject(obj)
                pcall(function() sq:RecalcAllWithNeighbours(true) end)
                if sq:isSolidTrans() then
                    local L = arenaList()
                    L[#L + 1] = { x = x, y = y, z = z, sprite = name }
                    LF.Ground.forget(x, y, z, 2)
                    return true, name
                end
                sq:RemoveTileObject(obj)           -- (not low cover after all: the next one)
                pcall(function() sq:RecalcAllWithNeighbours(true) end)
            end
        end
    end
    return false, "no crate or counter sprite worked as low cover"
end
local function removeArena()
    local cell = getCell()
    local L = arenaList()
    local n, kept = 0, {}
    for _, e in ipairs(L) do
        local sq = cell:getGridSquare(e.x, e.y, e.z)
        if sq then
            local objs = sq:getObjects()
            for i = objs:size() - 1, 0, -1 do
                local o = objs:get(i)
                local sp = o and o:getSprite()
                if sp and sp:getName() == e.sprite then sq:RemoveTileObject(o); n = n + 1; break end
            end
            pcall(function() sq:RecalcAllWithNeighbours(true) end)
            LF.Ground.forget(e.x, e.y, e.z, 2)
        else
            kept[#kept + 1] = e                    -- (not loaded here: left on the list for later)
        end
    end
    LF.Records.data().arena = kept
    LF.say("Removed " .. n .. " pieces of cover" .. (#kept > 0 and (" (" .. #kept .. " far off, not loaded)") or ""))
end
-- A run of pieces from (x, y): dx, dy the step.
local function placeRun(x, y, z, dx, dy, count)
    local n, last = 0, nil
    for i = 0, count - 1 do
        local ok, why = placeCover(x + dx * i, y + dy * i, z)
        if ok then n = n + 1 else last = why end
    end
    LF.say("Placed " .. n .. " of " .. count .. " pieces of low cover" .. (last and (" (" .. last .. ")") or ""))
    LF.log("ARENA placed " .. n .. " of " .. count .. " pieces at " .. x .. "," .. y .. (last and (" - " .. last) or ""))
end
-- Scattered pieces round (x, y): short runs of 2-3 facing east, the way the stress fight's
-- attackers come, within r tiles - an open field with something to fight from.
local function scatterCover(x, y, z, r, runs)
    local n = 0
    for _ = 1, runs do
        local px, py = x + ZombRand(-r, r + 1), y + ZombRand(-r, r + 1)
        local len = 2 + ZombRand(2)
        for i = 0, len - 1 do
            if placeCover(px, py + i, z) then n = n + 1 end
        end
    end
    LF.say("Scattered " .. n .. " pieces of low cover round here")
    LF.log("ARENA scattered " .. n .. " pieces round " .. x .. "," .. y)
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


    -- Tests: the one test of this release (the plan "Cutting soldier thinking").
    LF.guard("menu: tests", function()
        local tm = sub(main, "Tests")
        if stress then
            tm:addOption("Test running - the verdict goes to the log when done (TEST line)")
        else
            tm:addOption("0.81 open-ground test: the stress fight - fewer than 2 men left in the open with cover near (on a building: it holds the building; in the open: a field fight, the Germans dug in where you clicked)", nil,
                function() stressTest(x, y, z, false, { reaction = true, fieldOk = true }) end)
        end
        tm:addOption("(First: Tools > Delete ALL NPCs)")
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
    do
        local CAPS = { 0, 40, 60, 80, 100 }
        local cur = LF.Config.maxBodies or 0
        tools:addOption("Cap on bodies near you: " .. (cur > 0 and tostring(cur) or "none") .. " (click to change)", nil, function()
            local i = 1
            for k, v in ipairs(CAPS) do if v == cur then i = k end end
            LF.Config.maxBodies = CAPS[i % #CAPS + 1]
            LF.say("Cap on bodies: " .. (LF.Config.maxBodies > 0 and tostring(LF.Config.maxBodies) or "none"))
        end)
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
    do
        local am = sub(tools, "Arena (low cover on open ground)")
        local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z or 0)
        am:addOption("Place one piece of low cover here", nil, function()
            local ok, why = placeCover(fx, fy, fz)
            LF.say(ok and ("Low cover placed (" .. why .. ")") or ("No cover placed: " .. why))
        end)
        am:addOption("Place a line of 5 here, north to south (facing east and west)", nil, function() placeRun(fx, fy - 2, fz, 0, 1, 5) end)
        am:addOption("Place a line of 5 here, west to east (facing north and south)", nil, function() placeRun(fx - 2, fy, fz, 1, 0, 5) end)
        am:addOption("Scatter low cover round here (12 short runs within 12 tiles)", nil, function() scatterCover(fx, fy, fz, 12, 12) end)
        am:addOption("Remove all the cover placed (" .. #arenaList() .. " pieces)", nil, removeArena)
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
