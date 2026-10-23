-- Living Front: the right-click menu.
--
--   Inspect <soldier>     - when you right-click on or right next to a soldier (top of the menu)
--   Living Front >
--     Spawn here          - a soldier, a fire team (4) or a squad (17), German or Soviet; a civilian
--     Orders for <unit>   - the unit nearest the click: stance, patrol here, clear this building
--     Objective here      - make the clicked place an objective and have the nearest unit hold or
--                           take it; clear objectives
--     Sergeants choose their stance (on/off)
--     Tools               - move / kill / delete the nearest of a type, unit report, delete all,
--                           reset world

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
require "LivingFront/LF_Inspect"

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

-- Spawn a unit at the clicked spot, facing away from the player.
local function spawnUnit(faction, x, y, z, size, playerNum)
    if size == "soldier" then create(faction, x, y, z); return end
    local p = getSpecificPlayer(playerNum)
    local fx, fy = 1, 0
    if p then fx, fy = x + 0.5 - p:getX(), y + 0.5 - p:getY() end
    local unit = LF.Units.createSquad(faction, x + 0.5, y + 0.5, z, fx, fy, size == "team")
    LF.say("Spawned " .. unit.name .. (size == "team" and " (4)" or " (17)"))
end

-- The objective at (x, y), or a new one there.
local function objectiveAt(x, y, z)
    for _, o in pairs(LF.Objective.all()) do
        if LF.Objective.at(o, x + 0.5, y + 0.5, z) then return o end
    end
    local n = 0
    for _ in pairs(LF.Objective.all()) do n = n + 1 end
    return LF.Objective.create(x, y, z, "Objective " .. string.char(65 + n % 26))
end

local function holdHere(x, y, z)
    local squad = nearestUnit(x, y)
    if not squad then LF.say("No unit nearby"); return end
    local obj = objectiveAt(x, y, z)
    LF.Objective.hold(squad, obj)
    LF.Tactics.noteStanceSet(squad)
    LF.say(squad.name .. " holds " .. obj.name)
end

local function takeHere(x, y, z)
    local obj = objectiveAt(x, y, z)
    -- The nearest unit that isn't already holding this objective.
    local best, bestD = nil, math.huge
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        local u = rec and rec.squad and LF.Units.get(rec.squad)
        if u and not body:isDead() and not (u.objTask and u.objTask.kind == "hold" and u.objTask.obj == obj.id) then
            local d = LF.distSq(body:getX(), body:getY(), x + 0.5, y + 0.5)
            if d < bestD then best, bestD = u, d end
        end
    end
    if not best then LF.say("No unit to send"); return end
    local ok, why = LF.Objective.take(best, obj)
    LF.say(ok and (best.name .. " moves to take " .. obj.name) or ("Can't: " .. tostring(why)))
end

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
        fm:addOption("Soldier", nil, function() spawnUnit(key, x, y, z, "soldier", playerNum) end)
        fm:addOption("Fire team (4)", nil, function() spawnUnit(key, x, y, z, "team", playerNum) end)
        fm:addOption("Squad (17)", nil, function() spawnUnit(key, x, y, z, "squad", playerNum) end)
    end
    spawn:addOption("Civilian", nil, function() create("CIV", x, y, z) end)

    -- Orders for the nearest unit.
    local unit = nearestUnit(x, y)
    if unit then
        local orders = sub(main, "Orders for " .. unit.name)
        local st = sub(orders, "Stance (now " .. LF.Stance.get(unit).name .. ")")
        st:addOption("Stand by (rest here)", nil, function() setStanceNearest(x, y, z, "standby") end)
        st:addOption("Offensive", nil, function() setStanceNearest(x, y, z, "offensive") end)
        st:addOption(LF.Building.idAt(x, y, z) and "Defensive - hold this building" or "Defensive - all-round defence here",
            nil, function() setStanceNearest(x, y, z, "defensive") end)
        local pm = sub(orders, "Patrol here")
        pm:addOption("Sergeant's choice of formation", nil, function() marchNearest(x, y, z, "auto") end)
        pm:addOption("Ranger file", nil, function() marchNearest(x, y, z, "file") end)
        pm:addOption("Tactical column", nil, function() marchNearest(x, y, z, "column") end)
        pm:addOption("Wedge", nil, function() marchNearest(x, y, z, "wedge") end)
        if LF.Building.idAt(x, y, z) then
            orders:addOption("Clear this building (Alpha 1)", nil, function() clearOrder(x, y, z) end)
        end
    end

    -- Objectives.
    local om = sub(main, LF.Building.idAt(x, y, z) and "Objective: this building" or "Objective: this spot")
    om:addOption("Nearest unit holds it", nil, function() holdHere(x, y, z) end)
    om:addOption("Nearest unit takes it", nil, function() takeHere(x, y, z) end)
    om:addOption("Clear all objectives", nil, clearObjectives)

    main:addOption("Sergeants choose their stance: " .. (LF.Tactics.autoStance and "ON (click to turn off)" or "OFF (click to turn on)"), nil, function()
        LF.Tactics.autoStance = not LF.Tactics.autoStance
        LF.log("DEBUG automatic stance " .. (LF.Tactics.autoStance and "on" or "off"))
        LF.say("Sergeants choose their stance: " .. (LF.Tactics.autoStance and "ON" or "OFF"))
    end)

    -- Tools.
    local tools = sub(main, "Tools")
    for _, m in ipairs({
        { "Move nearest here", function(k) moveNearest(k, x, y, z) end },
        { "Kill nearest", function(k) killNearest(k, x, y) end },
        { "Delete nearest", function(k) deleteNearest(k, x, y) end },
    }) do
        local typeMenu = sub(tools, m[1])
        for _, t in ipairs(TYPES) do
            local fn, key = m[2], t.key
            typeMenu:addOption(t.label, nil, function() fn(key) end)
        end
    end
    tools:addOption("Unit report (to the log)", nil, function() LF.Units.report(); LF.Brain.report() end)
    tools:addOption("Delete ALL NPCs", nil, deleteAll)
    tools:addOption("Reset world (clear bodies, blood, debris; heal me; 08:00; no fog)", nil, function() resetWorld(playerNum) end)
end

Events.OnFillWorldObjectContextMenu.Add(onMenu)

Events.OnGameStart.Add(function()
    local dropped = LF.Records.dropOutdated()
    if dropped > 0 then LF.log("removed " .. dropped .. " NPC records from an older mod version") end
    LF.log("v" .. LF.VERSION .. " loaded, " .. LF.Records.count() .. " NPC records in this save")
end)
