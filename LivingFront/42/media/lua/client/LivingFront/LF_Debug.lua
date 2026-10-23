-- Living Front: debug menu (right-click in the world).
--
-- Kept small on purpose: the basic per-type tools (spawn / move / kill / delete) plus only the
-- commands for the test at hand. Current test: objectives (a Soviet team holds a building, a
-- German squad 100+ tiles away takes it: patrol in, rally, assault, clear, consolidate).

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Combat"
require "LivingFront/LF_Brain"
require "LivingFront/LF_MoveAction"
require "LivingFront/LF_Units"
require "LivingFront/LF_Squad"
require "LivingFront/LF_Suppress"
require "LivingFront/LF_Tactics"
require "LivingFront/LF_Building"
require "LivingFront/LF_Stance"
require "LivingFront/LF_March"
require "LivingFront/LF_Objective"
require "LivingFront/LF_Weapons"

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

local function healPlayer(p)
    p:getBodyDamage():RestoreToFullHealth()
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
    getGameTime():setTimeOfDay(8.0)
    LF.Records.data().noFog = true
    LF.guard("clear fog", clearFog)
    LF.guard("heal player", healPlayer, p)
    LF.guard("clean player", cleanPlayer, p)
    LF.log("RESET WORLD removed " .. counts.corpses .. " corpses, " .. counts.items .. " items, "
        .. forgotten .. " dead records, " .. unitsRemoved .. " wiped-out units; player healed; time set to 08:00; fog off")
    LF.say("World reset: " .. counts.corpses .. " bodies and " .. counts.items .. " items cleared")
end

-- Two units facing each other across the clicked square, Germans west and Soviets east,
-- far enough apart that they must advance to get in rifle range.
local function battle(x, y, z, teamOnly, gap)
    LF.Units.createSquad("GER", x - gap + 0.5, y + 0.5, z, 1, 0, teamOnly)
    LF.Units.createSquad("SOV", x + gap + 0.5, y + 0.5, z, -1, 0, teamOnly)
    local what = teamOnly and "Team vs team (4 vs 4)" or "Squad vs squad (17 vs 17)"
    LF.log("DEBUG " .. what .. " around " .. x .. "," .. y)
    LF.say(what)
end

-- Perimeter test: a German unit digs in around the clicked spot in the defensive stance; a
-- Soviet unit of the same size starts 28 tiles east and attacks (offensive stance).
local function perimeterTest(x, y, z, teamOnly)
    local def = LF.Units.createSquad("GER", x + 0.5, y + 0.5, z, 1, 0, teamOnly)
    LF.Tactics.setStance(def, "defensive")
    LF.Tactics.noteStanceSet(def)
    LF.Units.createSquad("SOV", x + 28.5, y + 0.5, z, -1, 0, teamOnly)
    local what = teamOnly and "team" or "squad"
    LF.log("DEBUG perimeter test (" .. what .. ") around " .. x .. "," .. y)
    LF.say("Perimeter test: German " .. what .. " defends, Soviet " .. what .. " attacks from the east")
end

-- Building defence test: click inside a building. A German unit holds it (defensive stance;
-- its sergeant spawns on the clicked square, so the defence forms on this building); a Soviet
-- unit of the same size attacks from 30 tiles east.
local function buildingTest(x, y, z, teamOnly)
    if not LF.Building.idAt(x, y, z) then LF.say("Click inside a building for this test"); return end
    local def = LF.Units.createSquad("GER", x + 0.5, y + 0.5, z, 1, 0, teamOnly)
    -- Everyone starts inside (the formation would put some men outside, behind a closed door).
    local L = LF.Building.at(x, y, z)
    if L then
        local spots = {}
        for _, q in ipairs(L.inside) do
            if (q.x + q.y) % 2 == 0 and not (q.x == x and q.y == y) then spots[#spots + 1] = q end
        end
        table.sort(spots, function(a, b) return LF.dist(a.x, a.y, x, y) < LF.dist(b.x, b.y, x, y) end)
        -- The sergeant on the inside square nearest the click, the rest spread around him.
        local all = {}
        for _, q in ipairs(L.inside) do all[#all + 1] = q end
        table.sort(all, function(a, b) return LF.dist(a.x, a.y, x, y) < LF.dist(b.x, b.y, x, y) end)
        local sgt = def.leader and LF.Records.get(def.leader)
        local sgtSpot = all[1]
        if sgt and sgtSpot then sgt.x, sgt.y, sgt.homeX, sgt.homeY = sgtSpot.x + 0.5, sgtSpot.y + 0.5, sgtSpot.x + 0.5, sgtSpot.y + 0.5 end
        local k = 0
        for _, rid in ipairs(LF.Units.members(def.id)) do
            local r = LF.Records.get(rid)
            if r and rid ~= def.leader then
                k = k + 1
                local q = spots[k]
                if q and sgtSpot and q.x == sgtSpot.x and q.y == sgtSpot.y then k = k + 1; q = spots[k] end
                if q then r.x, r.y, r.homeX, r.homeY = q.x + 0.5, q.y + 0.5, q.x + 0.5, q.y + 0.5 end
            end
        end
    end
    LF.Tactics.setStance(def, "defensive", { x = x, y = y, z = z })
    LF.Tactics.noteStanceSet(def)
    LF.Units.createSquad("SOV", x + 30.5, y + 0.5, z, -1, 0, teamOnly)
    local what = teamOnly and "team" or "squad"
    LF.log("DEBUG building defence test (" .. what .. ") at " .. x .. "," .. y)
    LF.say("Building test: German " .. what .. " holds the building, Soviet " .. what .. " attacks from the east")
end

-- Stance-switching test: a German fire team (offensive) next to the clicked spot - click just
-- outside a house - and a Soviet squad (offensive) 30 tiles east. Outnumbered, the Germans should
-- dig in, in the house.
local function stanceTest(x, y, z)
    LF.Units.createSquad("GER", x + 0.5, y + 0.5, z, 1, 0, true)
    LF.Units.createSquad("SOV", x + 30.5, y + 0.5, z, -1, 0, false)
    LF.log("DEBUG stance test at " .. x .. "," .. y)
    LF.say("Stance test: German team vs Soviet squad - watch the Germans dig in")
end

-- The unit of the living soldier nearest (x, y).
local function nearestUnit(x, y)
    local best, bestD = nil, math.huge
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and rec.squad and not body:isDead() then
            local d = LF.distSq(body:getX(), body:getY(), x + 0.5, y + 0.5)
            if d < bestD then best, bestD = LF.Units.get(rec.squad), d end
        end
    end
    return best
end

-- Order the nearest (offensive) unit's Alpha 1 to clear the clicked building.
local function clearOrder(x, y, z)
    local L = LF.Building.at(x, y, z)
    if not L then LF.say("Click on a building for this order"); return end
    local best, bestD = nil, math.huge
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and rec.squad and not body:isDead() and not LF.Building.isInside(L, body:getX(), body:getY()) then
            local u = LF.Units.get(rec.squad)
            if u and LF.Stance.get(u).maneuvers then
                local d = LF.distSq(body:getX(), body:getY(), x + 0.5, y + 0.5)
                if d < bestD then best, bestD = u, d end
            end
        end
    end
    if not best then LF.say("No attacking unit nearby"); return end
    local team = LF.Units.get(best.teams[1])
    local goes = team and LF.Tactics.orderClear(best, team, L, "debug order")
    if goes then
        LF.say(best.name .. ": " .. goes.name .. " clears the building")
    else
        LF.say("Couldn't plan it - see the log (CLEAR ...)")
    end
end

-- Objective test, step 1: click inside a building. It becomes the objective and a Soviet fire
-- team holds it (they start inside).
local function objectiveHold(x, y, z)
    local L = LF.Building.at(x, y, z)
    if not L then LF.say("Click inside a building for this"); return end
    local obj = LF.Objective.create(x, y, z, "The objective")
    local team = LF.Units.createSquad("SOV", x + 0.5, y + 0.5, z, 1, 0, true)
    local spots = {}
    for _, q in ipairs(L.inside) do if (q.x + q.y) % 2 == 0 then spots[#spots + 1] = q end end
    table.sort(spots, function(a, b) return LF.dist(a.x, a.y, x, y) < LF.dist(b.x, b.y, x, y) end)
    for k, rid in ipairs(LF.Units.members(team.id)) do
        local r, q = LF.Records.get(rid), spots[k]
        if r and q then r.x, r.y, r.homeX, r.homeY = q.x + 0.5, q.y + 0.5, q.x + 0.5, q.y + 0.5 end
    end
    LF.Objective.hold(team, obj)
    LF.Tactics.noteStanceSet(team)
    LF.say("Objective set: a Soviet team holds this building. Now go 100+ tiles away and use step 2.")
end

-- Objective test, step 2: a German squad spawns here and is ordered to take the latest objective.
local function objectiveTake(x, y, z)
    local obj, id = nil, 0
    for oid, o in pairs(LF.Objective.all()) do if oid > id then obj, id = o, oid end end
    if not obj then LF.say("Set an objective first (step 1)"); return end
    local d = LF.dist(x, y, obj.x, obj.y)
    local fx, fy = obj.x - x, obj.y - y
    local squad = LF.Units.createSquad("GER", x + 0.5, y + 0.5, z, fx, fy, false)
    squad.pendingTake = obj.id
    LF.log("DEBUG objective test: " .. squad.name .. " spawned " .. math.floor(d) .. " tiles from " .. obj.name)
    LF.say("German squad will take the objective (" .. math.floor(d) .. " tiles away)"
        .. (d < 100 and " - closer than 100 tiles!" or ""))
end

-- Send the nearest (not defending) unit on patrol to the clicked spot in a formation.
local function marchNearest(x, y, z, form)
    local best, bestD = nil, math.huge
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and rec.squad and not body:isDead() then
            local u = LF.Units.get(rec.squad)
            if u and LF.Stance.get(u).maneuvers then
                local d = LF.distSq(body:getX(), body:getY(), x + 0.5, y + 0.5)
                if d < bestD then best, bestD = u, d end
            end
        end
    end
    if not best then LF.say("No unit nearby (a defending unit won't march: set it offensive first)"); return end
    local ok, why = LF.March.order(best, x, y, z, form)
    LF.say(ok and (best.name .. " patrols here" .. (LF.March.FORMATIONS[form] and (" in " .. LF.March.FORMATIONS[form]) or " (sergeant's choice of formation)")) or ("Can't move: " .. tostring(why)))
end

local function setStanceNearest(x, y, z, stance)
    local squad = nearestUnit(x, y)
    if not squad then LF.say("No unit nearby"); return end
    -- Defensive, clicked on a building: hold that building.
    local hold = stance == "defensive" and LF.Building.idAt(x, y, z) and { x = x, y = y, z = z } or nil
    LF.Tactics.setStance(squad, stance, hold)
    LF.Tactics.noteStanceSet(squad)
    LF.say(squad.name .. ": " .. stance .. " stance")
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

    local option = context:addOption("Living Front (debug)")
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)

    -- Current test.
    sub:addOption("Objective test 1/2: Soviet team holds this building", nil, function() objectiveHold(x, y, z) end)
    sub:addOption("Objective test 2/2: German squad here takes the objective (go 100+ tiles away first)", nil, function() objectiveTake(x, y, z) end)
    sub:addOption("Test: spawn a German squad here (to patrol)", nil, function()
        LF.Units.createSquad("GER", x + 0.5, y + 0.5, z, 1, 0, false)
        LF.say("German squad spawned - right-click somewhere and choose Patrol nearest unit here")
    end)
    local po = sub:addOption("Patrol nearest unit here")
    local pm = ISContextMenu:getNew(sub)
    sub:addSubMenu(po, pm)
    pm:addOption("Sergeant's choice (by the ground)", nil, function() marchNearest(x, y, z, "auto") end)
    pm:addOption("Ranger file", nil, function() marchNearest(x, y, z, "file") end)
    pm:addOption("Tactical column", nil, function() marchNearest(x, y, z, "column") end)
    pm:addOption("Wedge", nil, function() marchNearest(x, y, z, "wedge") end)
    sub:addOption("Sergeants choose their stance: " .. (LF.Tactics.autoStance and "ON (click to turn off)" or "OFF (click to turn on)"), nil, function()
        LF.Tactics.autoStance = not LF.Tactics.autoStance
        LF.log("DEBUG automatic stance " .. (LF.Tactics.autoStance and "on" or "off"))
        LF.say("Sergeants choose their stance: " .. (LF.Tactics.autoStance and "ON" or "OFF"))
    end)
    local so = sub:addOption("Set stance of nearest unit")
    local stanceMenu = ISContextMenu:getNew(sub)
    sub:addSubMenu(so, stanceMenu)
    stanceMenu:addOption("Defensive (all-round defence; click a building to hold it)", nil, function() setStanceNearest(x, y, z, "defensive") end)
    stanceMenu:addOption("Offensive", nil, function() setStanceNearest(x, y, z, "offensive") end)
    sub:addOption("Unit report (orders, suppression)", nil, function() LF.Units.report(); LF.Brain.report() end)

    -- Basics, per type.
    local menus = {
        { "Spawn here", function(k) create(k, x, y, z) end },
        { "Move nearest here", function(k) moveNearest(k, x, y, z) end },
        { "Kill nearest", function(k) killNearest(k, x, y) end },
        { "Delete nearest", function(k) deleteNearest(k, x, y) end },
    }
    for _, m in ipairs(menus) do
        local o = sub:addOption(m[1])
        local typeMenu = ISContextMenu:getNew(sub)
        sub:addSubMenu(o, typeMenu)
        for _, t in ipairs(TYPES) do
            local fn, key = m[2], t.key
            typeMenu:addOption(t.label, nil, function() fn(key) end)
        end
    end
    sub:addOption("Delete ALL NPCs", nil, deleteAll)
    sub:addOption("Reset world (clear bodies, blood, debris; heal me; 08:00; no fog)", nil, function() resetWorld(playerNum) end)
end

Events.OnFillWorldObjectContextMenu.Add(onMenu)

Events.OnGameStart.Add(function()
    local dropped = LF.Records.dropOutdated()
    if dropped > 0 then LF.log("removed " .. dropped .. " NPC records from an older mod version") end
    LF.log("v" .. LF.VERSION .. " loaded, " .. LF.Records.count() .. " NPC records in this save")
end)
