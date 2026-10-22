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
end

Events.OnFillWorldObjectContextMenu.Add(onMenu)

Events.OnGameStart.Add(function()
    local dropped = LF.Records.dropOutdated()
    if dropped > 0 then LF.log("removed " .. dropped .. " NPC records from an older mod version") end
    LF.log("v" .. LF.VERSION .. " loaded, " .. LF.Records.count() .. " NPC records in this save")
end)
