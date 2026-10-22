-- Living Front: debug menu (right-click in the world).
--
-- Kept small on purpose: the basic per-type tools (spawn / move / kill / delete) plus only the
-- commands for the test at hand. Current test: fire-team and squad tactics (bounding,
-- suppression, orders).

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
    LF.guard("heal player", healPlayer, p)
    LF.guard("clean player", cleanPlayer, p)
    LF.log("RESET WORLD removed " .. counts.corpses .. " corpses, " .. counts.items .. " items, "
        .. forgotten .. " dead records, " .. unitsRemoved .. " wiped-out units; player healed")
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
    sub:addOption("Test: team vs team (4 vs 4)", nil, function() battle(x, y, z, true, 14) end)
    sub:addOption("Test: squad vs squad (17 vs 17)", nil, function() battle(x, y, z, false, 18) end)
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
    sub:addOption("Reset world (clear bodies, blood, debris; heal me)", nil, function() resetWorld(playerNum) end)
end

Events.OnFillWorldObjectContextMenu.Add(onMenu)

Events.OnGameStart.Add(function()
    local dropped = LF.Records.dropOutdated()
    if dropped > 0 then LF.log("removed " .. dropped .. " NPC records from an older mod version") end
    LF.log("v" .. LF.VERSION .. " loaded, " .. LF.Records.count() .. " NPC records in this save")
end)
